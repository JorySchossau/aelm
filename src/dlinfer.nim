import q, xmltree
from puppy import fetch
from os import fileExists, extractFilename, findExe
from strutils import strip, contains, join, endsWith, startsWith, toLower, split, find
from sequtils import mapIt, filterIt, keepItIf, deduplicate
from strformat import `&`
from regex import re2, match, Regex2, findAll
from algorithm import sortedByIt
import std/json

# New approach for inferring download assets based on real-world release patterns
# Supports: Windows x64, Linux x64, macOS x64, Linux ARM64, macOS ARM64

type
  Platform* = enum
    WinX64 = "windows-x64"
    WinARM64 = "windows-arm64"
    LinuxX64 = "linux-x64"
    MacX64 = "macos-x64"
    LinuxARM64 = "linux-arm64"
    MacARM64 = "macos-arm64"

  AssetMatch* = object
    platform*: Platform
    url*: string
    confidence*: int  # Higher is better
    toolName*: string

  InferredAssets* = object
    toolName*: string
    assets*: seq[AssetMatch]

# Exclusion patterns (kept minimal; use positive filtering elsewhere)
const

  QUALIFIER_TOKENS = ["musl", "gnu", "msvc", "profile", "baseline", "debug", "test", "example", "source", "doc"]
  PENALTY_TOKENS = ["profile", "baseline", "debug", "test", "example", "source", "doc"]

proc toolNameSignal(baseName, toolName: string): tuple[present: bool, strength: int]
proc hasOsToken(s: string): bool
proc hasAllowedSuffix(url: string): bool

type
  OS2 = enum os2Windows, os2Linux, os2Mac
  CPU2 = enum cpu2X64, cpu2ARM64

proc platformOf2(os: OS2, cpu: CPU2): Platform =
  case os
  of os2Windows:
    case cpu
    of cpu2X64: WinX64
    of cpu2ARM64: WinARM64
  of os2Linux:
    case cpu
    of cpu2X64: LinuxX64
    of cpu2ARM64: LinuxARM64
  of os2Mac:
    case cpu
    of cpu2X64: MacX64
    of cpu2ARM64: MacARM64

type
  FeatureInfo* = object
    baseName*: string
    ext*: string
    versionStripped*: string
    tokens*: seq[string]
    toolPresent*: bool
    toolStrength*: int
    osHits*: array[OS2, int]
    cpuHits*: array[CPU2, int]
    triplet*: bool
    extHasOsHint*: bool
    extOsHint*: OS2
    qualifierCount*: int
    archOnlyNoOs*: bool

# Local helpers for the new detector path
proc stripVersionTokens2(s: string): string =
  let versionRe = re2"(v?\d+(?:\.\d+)+)"
  var result = ""
  var lastEnd = 0
  for m in findAll(s, versionRe):
    let startIdx = m.boundaries.a
    let endIdx = m.boundaries.b + 1
    if startIdx > 0 and s[startIdx-1] notin {'-', '_', '.'}:
      result.add(s[lastEnd ..< startIdx])
      result.add("-")
    else:
      result.add(s[lastEnd ..< startIdx])
    lastEnd = endIdx
  result.add(s[lastEnd .. ^1])
  return result

proc tokenize2(s: string): seq[string] =
  var acc: seq[string] = @[]
  var buf = ""
  for ch in s.toLower():
    if ch in {'a'..'z','0'..'9'}:
      buf.add(ch)
    else:
      if buf.len > 0:
        acc.add(buf)
        buf.setLen(0)
  if buf.len > 0: acc.add(buf)
  return acc

proc osOf2(tok: string; o: var OS2): bool =
  let t = tok.toLower()
  if t == "windows" or t == "win" or t == "win32" or t == "win64" or t == "pc-windows" or t == "msvc":
    o = os2Windows; return true
  if t == "linux" or t == "gnu" or t == "musl" or t == "ubuntu" or t == "debian" or t == "archlinux" or t == "centos":
    o = os2Linux; return true
  if t == "darwin" or t == "mac" or t == "macos" or t == "osx" or t == "apple":
    o = os2Mac; return true
  if t.contains("windows") or t.contains("win32") or t.contains("win64") or t.contains("pc-windows") or t.contains("msvc"):
    o = os2Windows; return true
  if t.contains("linux") or t.contains("gnu") or t.contains("musl") or t.contains("ubuntu") or t.contains("debian") or t.contains("archlinux") or t.contains("centos"):
    o = os2Linux; return true
  if t.contains("darwin") or t.contains("mac") or t.contains("macos") or t.contains("osx") or t.contains("apple"):
    o = os2Mac; return true
  return false

proc cpuOf2(tok: string; c: var CPU2): bool =
  let t = tok.toLower()
  if t == "x86_64" or t == "amd64" or t == "x64" or t == "64bit" or t == "64-bit" or t == "64":
    c = cpu2X64; return true
  if t == "aarch64" or t == "arm64" or t == "armv8":
    c = cpu2ARM64; return true
  if t.contains("x86_64") or t.contains("amd64") or t.contains("x64") or t.contains("64bit") or t.contains("64-bit"):
    c = cpu2X64; return true
  if t.contains("aarch64") or t.contains("arm64") or t.contains("armv8"):
    c = cpu2ARM64; return true
  return false

proc extractFeatures*(asset, toolName: string): FeatureInfo =
  var fi: FeatureInfo
  fi.baseName = extractFilename(asset).toLower()
  # naive extension: take substring from last dot (ok for our hints)
  var lastDot = -1
  for i in 0 ..< fi.baseName.len:
    if fi.baseName[i] == '.':
      lastDot = i
  if lastDot >= 0:
    fi.ext = fi.baseName[lastDot .. ^1]
  else:
    fi.ext = ""
  fi.versionStripped = stripVersionTokens2(fi.baseName)
  fi.tokens = tokenize2(fi.versionStripped & " " & toolName.toLower())
  let sig = toolNameSignal(fi.baseName, toolName)
  fi.toolPresent = sig.present
  fi.toolStrength = sig.strength

  # extension OS hints
  if fi.baseName.endsWith(".exe"):
    fi.extHasOsHint = true
    fi.extOsHint = os2Windows
  elif fi.baseName.endsWith(".dmg"):
    fi.extHasOsHint = true
    fi.extOsHint = os2Mac
  else:
    fi.extHasOsHint = false

  # bare tool-name OS hint (parity with legacy) and tool-os suffixes
  if sig.strength == 3:
    if fi.baseName.endsWith(".exe"):
      fi.osHits[os2Windows].inc
    else:
      fi.osHits[os2Linux].inc
  # tool-os suffix boost like 'tool-darwin', 'tool_linux', 'tool-windows'
  let t = toolName.toLower()
  if fi.baseName == t & "-darwin" or fi.baseName == t & "-mac" or fi.baseName == t & "-macos" or fi.baseName == t & "_darwin" or fi.baseName == t & "_mac" or fi.baseName == t & "_macos":
    fi.osHits[os2Mac].inc
  if fi.baseName == t & "-linux" or fi.baseName == t & "_linux":
    fi.osHits[os2Linux].inc
  if fi.baseName == t & "-windows" or fi.baseName == t & "-win" or fi.baseName == t & "_windows" or fi.baseName == t & "_win":
    fi.osHits[os2Windows].inc

  # qualifier count
  var qcount = 0
  for q in QUALIFIER_TOKENS:
    if fi.baseName.contains(q): qcount.inc
  fi.qualifierCount = qcount

  # token-based os/cpu hits and triplet adjacency
  var trip = false
  for t in fi.tokens:
    var o: OS2
    var c: CPU2
    if osOf2(t, o): fi.osHits[o].inc
    if cpuOf2(t, c): fi.cpuHits[c].inc
  for i in 0 ..< max(0, fi.tokens.len - 1):
    var o: OS2
    var c: CPU2
    if osOf2(fi.tokens[i], o) and cpuOf2(fi.tokens[i+1], c): trip = true
    if cpuOf2(fi.tokens[i], c) and osOf2(fi.tokens[i+1], o): trip = true
  fi.triplet = trip
  if fi.extHasOsHint:
    fi.osHits[fi.extOsHint].inc
  # Fallback filename combo boosts when no triplet adjacency detected (parity with legacy)
  if not fi.triplet:
    let fname = fi.baseName
    if (fname.contains("x86_64") or fname.contains("amd64") or fname.contains("x64")) and (fname.contains("darwin") or fname.contains("macos") or fname.contains("osx") or fname.contains("apple")):
      fi.cpuHits[cpu2X64].inc; fi.osHits[os2Mac].inc; fi.triplet = true
    elif (fname.contains("aarch64") or fname.contains("arm64")) and (fname.contains("darwin") or fname.contains("macos") or fname.contains("osx") or fname.contains("apple")):
      fi.cpuHits[cpu2ARM64].inc; fi.osHits[os2Mac].inc; fi.triplet = true
    elif (fname.contains("x86_64") or fname.contains("amd64") or fname.contains("x64")) and fname.contains("linux"):
      fi.cpuHits[cpu2X64].inc; fi.osHits[os2Linux].inc; fi.triplet = true
    elif (fname.contains("aarch64") or fname.contains("arm64")) and fname.contains("linux"):
      fi.cpuHits[cpu2ARM64].inc; fi.osHits[os2Linux].inc; fi.triplet = true
    elif (fname.contains("x86_64") or fname.contains("amd64") or fname.contains("x64")) and (fname.contains("windows") or fname.contains("win")):
      fi.cpuHits[cpu2X64].inc; fi.osHits[os2Windows].inc; fi.triplet = true
    elif (fname.contains("aarch64") or fname.contains("arm64")) and (fname.contains("windows") or fname.contains("win")):
      fi.cpuHits[cpu2ARM64].inc; fi.osHits[os2Windows].inc; fi.triplet = true

  # archOnlyNoOs signal
  let hasArch64 = (fi.baseName.contains("x86_64") or fi.baseName.contains("amd64") or fi.baseName.contains("x64") or fi.baseName.contains("aarch64") or fi.baseName.contains("arm64"))
  fi.archOnlyNoOs = hasArch64 and (not hasOsToken(fi.baseName)) and (not fi.extHasOsHint)

  return fi

proc detectPlatformRuleTable(asset: string, toolName: string): seq[(Platform, int)] =
  # weights
  const BaseScore = 60
  const TripletBonus = 30
  const HitWeight = 10
  const ExtHintWeight = 10
  const AssumeX64Penalty = -5
  const VariantPenalty = -5
  const BareArchPenalty = -10

  let f = extractFeatures(asset, toolName)
  var base = BaseScore
  if f.triplet: base += TripletBonus
  # extHasOsHint no longer boosts base; ext hint still influences osHits via feature extraction
  let lower = asset.toLower()
  for w in PENALTY_TOKENS:
    if lower.contains(w):
      base += VariantPenalty

  # copy counts
  var osCounts: array[OS2, int]
  var cpuCounts: array[CPU2, int]
  for o in OS2:
    osCounts[o] = f.osHits[o]
  for c in CPU2:
    cpuCounts[c] = f.cpuHits[c]

  var hasOs = false
  for o in OS2:
    if osCounts[o] > 0:
      hasOs = true
  var hasCpu = false
  for c in CPU2:
    if cpuCounts[c] > 0:
      hasCpu = true

  if hasOs and not hasCpu:
    cpuCounts[cpu2X64] = max(cpuCounts[cpu2X64], 1)
    base += AssumeX64Penalty

  # Best scores per platform
  var bestScores: array[Platform, int]
  for pl in Platform: bestScores[pl] = -1

  # Normal emission
  for o in OS2:
    if osCounts[o] > 0:
      for c in CPU2:
        if cpuCounts[c] > 0:
          let score = base + osCounts[o]*HitWeight + cpuCounts[c]*HitWeight
          let pl = platformOf2(o, c)
          if score > bestScores[pl]:
            bestScores[pl] = score

  when true:
    # Bare arch-only emission (Phase 6): emit candidates for all OSs of that arch with a penalty
    if f.archOnlyNoOs and hasAllowedSuffix(asset):
      var anyCpu = false
      for c in CPU2:
        if cpuCounts[c] > 0: anyCpu = true
      if not anyCpu:
        cpuCounts[cpu2X64] = 1
      for c in CPU2:
        if cpuCounts[c] > 0:
          for o in OS2:
            var score = base + cpuCounts[c]*HitWeight + HitWeight + BareArchPenalty
            # Favor extension OS hint if present
            if f.extHasOsHint and o == f.extOsHint:
              score += HitWeight
            let pl = platformOf2(o, c)
            if score > bestScores[pl]:
              bestScores[pl] = score

  for pl in Platform:
    if bestScores[pl] >= 0:
      result.add((pl, bestScores[pl]))

proc detectPlatformUnified*(asset: string, toolName: string): seq[(Platform, int)] =
  detectPlatformRuleTable(asset, toolName)

proc extractToolName*(repoUrl: string): string =
  ## Extract tool name from repository URL (handles GitHub API and user-facing URLs)
  let s = repoUrl.strip(chars={'/'})
  let lower = s.toLower()

  # Handle GitHub API URLs: https://api.github.com/repos/<owner>/<repo>/...
  if "api.github.com/repos/" in lower:
    let base = "api.github.com/repos/"
    let pos = lower.find(base)
    if pos >= 0:
      let tail = s[pos + base.len .. ^1]
      let segs = tail.split('/')
      if segs.len >= 2:
        return segs[1]  # repo

  # Handle user-facing GitHub URLs: https://github.com/<owner>/<repo>/...
  if "github.com/" in lower:
    let base = "github.com/"
    let pos = lower.find(base)
    if pos >= 0:
      let tail = s[pos + base.len .. ^1]
      let segs = tail.split('/')
      if segs.len >= 2:
        return segs[1]  # repo

  # Fallback: last non-empty, non-meta segment
  let parts = s.split('/')
  if parts.len >= 1:
    var j = parts.len - 1
    while j >= 0 and (parts[j].len == 0 or parts[j].toLower() in ["releases", "release", "download", "downloads", "tags"]):
      dec j
    if j >= 0:
      return parts[j]

  return "unknown"



# legacy detectPlatform removed (rule-table scorer is default)

# Positive filtering for candidate assets (supports extensionless binaries by context)
const ALLOWED_SUFFIXES = [
  ".zip", ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".7z",
  ".exe", ".msi", ".dmg", ".pkg", ".appimage"
]

# Extensions for generic binaries (preferred for direct use)
const GENERIC_BINARY_EXTS = [
  # Generic archives and direct binaries
  ".tar.gz", ".tgz", ".tar.xz", ".tar.bz2", ".zip", ".7z",
  ".exe", ".appimage", ".dmg",
  # Also treat .bin, .run, .sh, .command, .jar as generic binaries for CLI tools
  ".bin", ".run", ".sh", ".command", ".jar"
]

# Extensions for OS-specific install packages (less preferred)
const OS_PACKAGE_EXTS = [
  # Linux packages
  ".deb", ".rpm", ".snap", ".flatpak",
  # Windows packages
  ".msi", ".appx", ".msix", ".cab",
  # macOS packages
  ".pkg", ".mpkg",
  # Windows scripts (less preferred than .exe, but more than archives)
  ".bat", ".ps1"
]

proc packagePenaltyScore(url: string): int =
  ## Returns 0 for generic binaries, 1 for OS-specific packages, 2 for other assets
  let lower = url.toLower()
  for ext in GENERIC_BINARY_EXTS:
    if lower.endsWith(ext): return 0
  for ext in OS_PACKAGE_EXTS:
    if lower.endsWith(ext): return 1
  return 2

proc hasAllowedSuffix(url: string): bool =
  let lower = url.toLower()
  for s in ALLOWED_SUFFIXES:
    if lower.endsWith(s): return true
  return false

proc isChecksumLike(url: string): bool =
  let lower = url.toLower()
  if lower.match(re2(r"\.(sha256|sha512|sha1|asc|sig)$")): return true
  let base = extractFilename(lower)
  if match(base, re2(r"(?i)(shasums|sha256sums|checksums|sha256sum)")): return true
  return false

proc looksLikeDownloadEndpoint(url: string): bool =
  let lower = url.toLower()
  if "/releases/download/" in lower: return true   # GitHub releases
  if "/attachments/" in lower: return true         # Gitea/GitLab attachments
  if "/download" in lower or "download?" in lower:
    if ("os=" in lower) or ("arch=" in lower) or ("win" in lower) or ("linux" in lower) or ("darwin" in lower) or ("mac" in lower):
      return true
  return false

proc toolNameSignal(baseName, toolName: string): tuple[present: bool, strength: int] =
  let base = baseName.toLower()
  let t = toolName.toLower()
  if base.len == 0:
    return (false, 0)
  if base == t or base == t & ".exe":
    return (true, 3)
  if base.startsWith(t & "-") or base.startsWith(t & "_"):
    return (true, 2)
  var buf = ""
  for ch in base:
    if ch in {'a'..'z','0'..'9'}:
      buf.add(ch)
    else:
      if buf.len > 0:
        if buf == t: return (true, 1)
        buf.setLen(0)
  if buf.len > 0 and buf == t:
    return (true, 1)
  return (false, 0)

proc looksLikeToolNamedAsset(url, toolName: string): bool =
  let base = extractFilename(url).toLower()
  let sig = toolNameSignal(base, toolName)
  if base.len == 0: return false
  return sig.strength >= 2

proc hasOsToken(s: string): bool =
  let lower = s.toLower()
  if "windows" in lower or "win32" in lower or "win64" in lower or "win-" in lower or "win_" in lower: return true
  if "linux" in lower or "gnu" in lower or "musl" in lower: return true
  if "darwin" in lower or "macos" in lower or "osx" in lower or "apple" in lower or "mac-" in lower or "mac_" in lower or "mac" in lower: return true
  return false



proc isBareArchOnlyAsset(url, toolName: string): bool =
  # Looks like a tool-named asset, has a 64-bit arch token, but no explicit OS token.
  let base = extractFilename(url).toLower()
  let sig = toolNameSignal(base, toolName)
  if not sig.present: return false
  if not (base.contains("x86_64") or base.contains("amd64") or base.contains("x64")): return false
  if hasOsToken(base): return false
  if not hasAllowedSuffix(url): return false
  return true



proc filterAssets*(assets: seq[string], toolName: string): seq[string] =
  ## Positive filter for candidate assets; allow bare arch-only tool assets for post-processing
  for a in assets:
    if isChecksumLike(a): continue
    if hasAllowedSuffix(a) or looksLikeDownloadEndpoint(a) or looksLikeToolNamedAsset(a, toolName) or isBareArchOnlyAsset(a, toolName):
      let candidates = detectPlatformUnified(a, toolName)
      if candidates.len > 0 or isBareArchOnlyAsset(a, toolName):
        result.add(a)

proc getLatestAssetsGithub(repo, version, toolName: string): seq[string] =
  ## Get release assets from GitHub using api.github.com JSON.
  ## Accepts either a user-facing GitHub URL (https://github.com/owner/repo)
  ## or an API URL (https://api.github.com/repos/owner/repo/releases[...]).
  var apiUrl = ""
  let effectiveVersion = if version.len == 0: "latest" else: version
  if repo.startsWith("https://github.com"):
    let pfx = "https://github.com/"
    if repo.len > pfx.len:
      let tail = repo[pfx.len .. ^1]
      let segs = tail.strip(chars={'/'}).split('/')
      if segs.len >= 2:
        apiUrl = "https://api.github.com/repos/" & segs[0] & "/" & segs[1] & "/releases"
      else:
        return @[]
    else:
      return @[]
  elif repo.startsWith("https://api.github.com"):
    if repo.toLower().contains("/releases"):
      apiUrl = repo
    else:
      apiUrl = repo.strip(chars={'/'}) & "/releases"
  else:
    return @[]

  let body = fetch(apiUrl)
  var urls: seq[string] = @[]
  try:
    let node = parseJson(body)
    if node.kind == JArray:
      if effectiveVersion.toLower() == "latest":
        if node.len > 0:
          let rel = node[0]
          if rel.hasKey("assets"):
            for asset in rel["assets"]:
              if asset.hasKey("browser_download_url"):
                urls.add asset["browser_download_url"].getStr
      else:
        var chosen: JsonNode = nil
        for rel in node:
          var name = ""
          var tag = ""
          if rel.hasKey("name") and rel["name"].kind == JString: name = rel["name"].getStr
          if rel.hasKey("tag_name") and rel["tag_name"].kind == JString: tag = rel["tag_name"].getStr
          let v = effectiveVersion
          if name == v or tag == v or (name == "v" & v) or (tag == "v" & v) or ((v.startsWith("v")) and (name == v[1..^1] or tag == v[1..^1])):
            chosen = rel
            break
        if not chosen.isNil and chosen.hasKey("assets"):
          for asset in chosen["assets"]:
            if asset.hasKey("browser_download_url"):
              urls.add asset["browser_download_url"].getStr
    elif node.kind == JObject:
      # Supports /releases/latest or /releases/tags/<tag> API shape
      if node.hasKey("assets"):
        for asset in node["assets"]:
          if asset.hasKey("browser_download_url"):
            urls.add asset["browser_download_url"].getStr
  except:
    discard
  result = filterAssets(urls, toolName)

proc getLatestAssetsGeneric(repo, toolName: string): seq[string] =
  ## Get assets from generic repository
  let html = fetch(repo)
  for item in html.q.select("a"):
    let href = item.attr("href")
    if href.len > 0:
      let abs = (if href.startsWith("http"): href else: repo.strip(chars={'/'}) & '/' & href.strip(chars={'/'}))
      result.add abs
  result = filterAssets(result, toolName)

proc simplicityScore(url: string): int =
  ## Lower score means simpler asset (fewer qualifiers)
  var score = 0
  for q in QUALIFIER_TOKENS:
    if url.toLower().contains(q): score += 1
  return score

proc selectBestAssetForPlatform*(matches: seq[AssetMatch], platform: Platform): AssetMatch =
  ## Select the best asset for a specific platform
  let candidates = matches.filterIt(it.platform == platform)
  if candidates.len == 0:
    return AssetMatch(platform: platform, url: "", confidence: 0, toolName: "")

  # Sort by confidence (highest first), then by packagePenaltyScore (prefer generic binaries), then by simplicity, then by filename length (shortest preferred)
  let sorted = candidates.sortedByIt((-it.confidence, packagePenaltyScore(it.url), simplicityScore(it.url), extractFilename(it.url).len))
  return sorted[0]

proc getDLCandidates*(repo, version: string): InferredAssets =
  ## Main entry point for asset inference
  let repoUrl = repo.strip(chars={'/'})
  let toolName = extractToolName(repoUrl)

  # Get assets based on repository type
  let assets = block:
    if repoUrl.startsWith("https://github.com") or repoUrl.startsWith("https://api.github.com"):
      getLatestAssetsGithub(repoUrl, version, toolName)
    else:
      getLatestAssetsGeneric(repoUrl, toolName)

  if assets.len == 0:
    return InferredAssets(toolName: toolName, assets: @[])

  # Analyze each asset
  var allMatches: seq[AssetMatch] = @[]

  for asset in assets:
    let platforms = detectPlatformUnified(asset, toolName)
    for (platform, confidence) in platforms:
      allMatches.add(AssetMatch(
        platform: platform,
        url: asset,
        confidence: confidence,
        toolName: toolName
      ))



  # Select best asset for each platform
  var bestAssets: seq[AssetMatch] = @[]

  for platform in Platform:
    let best = selectBestAssetForPlatform(allMatches, platform)
    if best.confidence > 0:
      bestAssets.add(best)

  result = InferredAssets(
    toolName: toolName,
    assets: bestAssets.sortedByIt(-it.confidence)
  )

# Helper procs for getting specific platform assets
proc getAssetForCurrentPlatform*(inferred: InferredAssets): AssetMatch =
  ## Get the best asset for the current platform
  const currentPlatform = block:
    when defined(windows):
      when hostCPU == "amd64": WinX64
      elif hostCPU == "arm64": WinARM64
      else: {.error: "Unsupported Windows architecture".}
    elif defined(macosx):
      when hostCPU == "amd64": MacX64
      elif hostCPU == "arm64": MacARM64
      else: {.error: "Unsupported macOS architecture".}
    elif defined(linux):
      when hostCPU == "amd64": LinuxX64
      elif hostCPU == "arm64": LinuxARM64
      else: {.error: "Unsupported Linux architecture".}
    else:
      {.error: "Unsupported operating system".}

  for asset in inferred.assets:
    if asset.platform == currentPlatform:
      return asset

  # Return empty match if no suitable asset found
  return AssetMatch(platform: currentPlatform, url: "", confidence: 0, toolName: inferred.toolName)

proc getAssetForPlatform*(inferred: InferredAssets, platform: Platform): AssetMatch =
  ## Get the best asset for a specific platform
  for asset in inferred.assets:
    if asset.platform == platform:
      return asset

  return AssetMatch(platform: platform, url: "", confidence: 0, toolName: inferred.toolName)

# Legacy compatibility proc
proc getDLCandidatesLegacy*(repo, version: string): seq[string] =
  ## Legacy compatibility - returns just URLs for current platform
  let inferred = getDLCandidates(repo, version)
  let current = getAssetForCurrentPlatform(inferred)
  if current.confidence > 0:
    return @[current.url]
  return @[]
