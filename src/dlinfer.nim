import q, xmltree
from puppy import fetch
from os import fileExists, extractFilename, findExe
from strutils import strip, contains, join, endsWith, startsWith
from sequtils import mapIt, filterIt, keepItIf
from strformat import `&`
from regex import re2, match, Regex2

# This section defines the regex patterns used to identify the correct download asset
# for a given operating system and architecture from a list of release assets.
# The patterns are designed to be easily extensible to support new platforms.

# OS-specific patterns
const
  # Windows: Matches "win" or "windows" (case-insensitive)
  WIN_REGEX = re2(".*(?i)([^r]win|windows).*")
  # macOS: Matches "darwin", "macos", or "osx" (case-insensitive)
  MAC_REGEX = re2(".*(?i)(darwin|mac.?os|osx).*")
  # Linux: Matches "linux" (case-insensitive), excludes "android"
  NIX_REGEX = re2(".*(?i)(linux).*")
  NIX_EXCLUDE_REGEX = re2(".*(?i)(android).*")
  # AppImage: Prioritized for Linux
  APPIMAGE_REGEX = re2(""".*\.appimage$""")

# Architecture-specific patterns
const
  # x86-64: Matches "x64", "amd64", or "x86_64" (case-insensitive)
  X64_REGEX = re2(".*(?i)(x64|amd64|x86(-|_)?64).*")
  # ARM64: Matches "arm64", "armv8", or "aarch64" (case-insensitive)
  ARM64_REGEX = re2(".*(?i)(arm64|armv8|aarch64).*")

type OS {.pure.} = enum
  win
  mac
  nix

type Pattern = object
  positive, negative, priority: Regex2

const MatchByOS = [
  Pattern( # win
    positive: WIN_REGEX
    ),
  Pattern( #nix
    positive: MAC_REGEX
    ),
  Pattern( #mac
    positive: NIX_REGEX,
    negative: NIX_EXCLUDE_REGEX, #mac
    priority: APPIMAGE_REGEX
    )
]

type Arch {.pure.} = enum
  x64
  arm64

const MatchByArch = [
  Pattern(positive: X64_REGEX),
  Pattern(positive: ARM64_REGEX)
]

type InferredConfidence* = enum
  icHigh
  icMedium
  icLow

type InferredDownload* = object
  candidates*: seq[string]
  confidence*: set[InferredConfidence]

proc matchesOS(asset: string, confidence: static InferredConfidence): bool =
  const thisOS = block:
    when defined(windows): OS.win
    elif defined(macosx): OS.mac
    elif defined(linux): OS.nix
    else: {.error: &"OS {hostOS} unsupported".}
  when confidence == icHigh:
    if asset.match(MatchByOS[thisOS.int].priority) and not asset.match(MatchByOS[thisOS.int].negative):
      return true
  elif confidence in {icMedium,icLow}:
    if asset.match(MatchByOS[thisOS.int].positive) and not asset.match(MatchByOS[thisOS.int].negative):
      return true

proc matchesArch(asset: string): bool =
  const thisArch = block:
    when hostCPU == "amd64": Arch.x64
    elif hostCPU == "arm64": Arch.arm64
    else: {.error: &"arch {hostCPU} unsupported".}
  if asset.match(MatchByArch[thisArch.int].positive): return true

proc getLatestAssetsGithub(repo, version: string): seq[string] =
  let html = fetch(&"{repo}/releases/{version}")
  for item in html.q.select("div svg.octicon + a"):
    result.add "https://github.com" & item.attr("href")
  result.keepItIf((not it.endsWith ".sha256") and (not it.endsWith ".sha256sum") and (not it.endsWith ".deb") and (not it.endsWith ".rpm") and (not it.endsWith ".apk") and ("archive/refs/tags" notin it))

proc getLatestAssetsGeneric(repo: string): seq[string] =
  let html = fetch(repo)
  for item in html.q.select("a"):
    result.add repo & '/' & item.attr("href")
  result.keepItIf((not it.endsWith ".sha256") and (not it.endsWith ".sha256sum") and (not it.endsWith ".deb") and (not it.endsWith ".rpm") and (not it.endsWith ".apk") and (it.extractFilename.contains('.')))

proc getDLCandidates*(repo, version: string): InferredDownload =
  let url = repo.strip(chars={'/'})
  const GH = "https://github.com"
  const GEA = "https://gitea.com"
  let assets = block:
    if url.startsWith GH: getLatestAssetsGithub url, version
    else: getLatestAssetsGeneric url
  for asset in assets:
    let filename = extractFilename asset
    if filename.matchesOS(icHigh) and filename.matchesArch:
      result.candidates.add asset
      result.confidence.incl icHigh
  if icHigh in result.confidence: return
  for asset in assets:
    let filename = extractFilename asset
    if filename.matchesOS(icMedium) and filename.matchesArch:
      result.candidates.add asset
      result.confidence.incl icMedium
  if icMedium in result.confidence: return
  for asset in assets:
    let filename = extractFilename asset
    if filename.matchesOS(icLow):
      result.candidates.add asset
      result.confidence.incl icLow
