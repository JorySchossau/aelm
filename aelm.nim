import std/[json, sequtils, strutils, tables, strformat, os, osproc, sets, algorithm, streams]
from dl import syncDownload
from std/sugar import dup, collect
import zstd/decompress as zstdx
import zippy/ziparchives as zipx

const
  CONF_FILENAME = ".aelm.conf"
  CONF_MOD_FILENAME = ".aelm.mod.conf"

proc error(msg:string) =
  echo msg
  quit(1)

proc loadAelmModuleConf(path: string): JSonNode =
  if not dirExists path: error &"No aelm module '{path}' exists by that name"
  if not fileExists joinPath(path, CONF_MOD_FILENAME): error &"That does not seem like an aelm module. No {CONF_MOD_FILENAME} file found in {path}"
  let conf = parseFile(joinPath(path, CONF_MOD_FILENAME)){"aelm-mod-config"}
  if isNil conf: error &"Not an aelm module '{path}'"
  return conf

iterator aelmDirs(basepath: string): tuple[name, namever:string] =
  # return all immediate dirs of `basepath` with aelm.conf files in them
  var name, category, version, namever: string
  for dir in os.walkDir(basepath):
    if dir.kind == pcDir and existsFile(joinPath(dir.path, CONF_MOD_FILENAME)):
      name = dir.path.relativePath basepath.normalizedPath
      let conf = loadAelmModuleConf dir.path
      category = conf{"category"}.getStr(default="[missing]")
      version = conf{"version"}.getStr(default="[missing]")
      name = conf{"name"}.getStr(default="[missing]")
      namever = fmt"{category}@{version}"
      yield (name, namever)

proc doListAelmModules(path: seq[string]) =
  let pth = if path.len != 0: path[0] else: getCurrentDir()
  for module in pth.aelmDirs:
    echo &"{module.name} ({module.namever})"

proc placeholderDownloadModulesJson =
  # TODO replace better later
  const jsonContent = staticRead CONF_FILENAME
  CONF_FILENAME.writeFile jsonContent

proc refresh =
  echo "updating modules list from repository..."
  placeholderDownloadModulesJson()

proc doRefresh =
  refresh()

proc doInit =
  # TODO replace better later
  echo "creating aelm project"
  placeholderDownloadModulesJson()

proc loadAelmConf(): JsonNode =
  if not fileExists CONF_FILENAME:
    echo "Not an aelm project, run init or refresh?"
    quit(1)
  let cfg = parseFile(CONF_FILENAME){"aelm-config"}
  if isNil cfg: error &"corrupted {CONF_FILENAME}"
  return cfg

const aelmos = block:
  when defined(windows):
    "windows"
  elif defined(osx):
    "osx"
  elif defined(linux):
    "linux"
const cputype {.strdefine.} = ""
const aelmcpu = block:
  when cputype == "":
    {.error: "cputype must be defined at compile-time on CLI (x86_64 or arm)".}
  else:
    cputype

proc getCurrentOS(): string =
  when aelmcpu == "arm":
    aelmcpu & aelmos
  else:
    aelmos # we assume x86_64 as more common for json key legibility

proc sortVersions(versions: var seq[string]) =
  proc compareVersions(v1,v2:string):int =
    let
      s1 = v1.split('.')
      s2 = v2.split('.')
      minlength = min(s1.len, s2.len)
    for i in 0..<minlength:
      if s1[i].parseInt == s2[i].parseInt: continue
      elif s1[i].parseInt > s2[i].parseInt: return 1
      else: return 0
    return 0
  versions.sort(cmp=compareVersions)

proc getCategoriesAndVersions(js: JsonNode): Table[string, seq[string]]=
  const globalIgnoreKeys = toHashSet ["global"]
  const catIgnoreKeys = toHashSet "config setup url".split

  var catKeys = js.keys.toSeq.toHashSet
  catKeys = catKeys - globalIgnoreKeys
  let curOs = getCurrentOS()
  let categories = catKeys.toSeq.dup(sort)
  var versionKeys: HashSet[string]
  for category in categories:
    let jscat = js[category]
    versionKeys = jscat.keys.toSeq.toHashSet
    versionKeys = versionKeys - catIgnoreKeys
    for version in versionKeys.toSeq.dup(sortVersions).dup(reverse):
      result.mgetOrPut(category, newSeq[string]()).add version
  return result

proc mergeJson(js: JsonNode, other: JsonNode, overwrite: bool = true): JsonNode =
  if js.isNil and other.isNil: return
  if js.isNil and not other.isNil: return copy other
  if not js.isNil and other.isNil: return copy js
  var newNode = copy js
  for key in other.keys:
    if other[key].kind == JObject:
      if not js.hasKey key:
        newNode[key] = newJObject()
      newNode[key] = newNode[key].mergeJson(other[key], overwrite)
    elif overwrite or not js.hasKey key:
      newNode[key] = copy other[key]
  return newNode

proc getModuleJson(js: JsonNode, category, version: string): JsonNode =
  # json structure [category, version, os] with each deeper level
  # having optional overriding keys of config, setup, and url
  var url,config,setup: JsonNode = nil
  
  var catKeys = js.keys.toSeq.toHashSet
  const globalIgnoreKeys = toHashSet ["global"]
  catKeys = catKeys - globalIgnoreKeys
  if category notin catKeys: error &"Not a valid category '{category}'. Options are:\n" & join(catKeys.toSeq,"\n").indent(2)

  let jscat = js[category]
  const catIgnoreKeys = toHashSet "config setup url".split
  url = jscat{"url"}
  config = jscat{"config"}
  setup = jscat{"setup"}
  var versionKeys = jscat.keys.toSeq.toHashSet
  versionKeys = versionKeys - catIgnoreKeys
  let guessedVersion = if version != "latest": version else: dup(versionKeys.toSeq, sort)[0]
  if guessedVersion notin versionKeys: error &"Not a valid version '{guessedVersion}'. Options are:\n" & join(dup(versionKeys.toSeq, sort),"\n").indent(2)

  let jsver = jscat[guessedVersion]
  const verIgnoreKeys = toHashSet "config setup url".split
  if "url" in jsver: url = jsver["url"]
  if "config" in jsver: config = config.mergeJson jsver{"config"}
  if "setup" in jsver: setup = jsver["setup"]
  var osKeys = jsver.keys.toSeq.toHashSet
  osKeys = osKeys - verIgnoreKeys
  let curOs = getCurrentOS() # osx, linux, windows, armosx, armlinux
  if curOs notin osKeys: error &"This OS '{curOs}' not supported for {category}@{guessedVersion}. Options are:\n" & join(dup(osKeys.toSeq, sort),"\n").indent(2)
  
  let jsos = jsver[curOs]
  if "url" in jsos: url = jsos["url"]
  if "config" in jsos: config = config.mergeJson jsos{"config"}
  if "setup" in jsos: setup = jsos["setup"]
  jsos["url"] = url
  jsos["config"] = config
  jsos["setup"] = setup
  
  jsos["version"] = guessedVersion.newJString
  jsos["category"] = category.newJString
  
  return jsos

proc appCacheDir: string =
  let cacheDir = getCacheDir("aelm")
  discard existsOrCreateDir cacheDir
  return cacheDir

proc download(url: string, useCache: bool = true): string =
  # returns full path to downloaded file (or cached file)
  let
    filename = extractFilename url
    filepath = appCacheDir() / filename
  if not fileExists filepath:
    syncDownload(url, filepath)
  else:
    echo "(using cached installer)"
  return filepath

proc tarxUncompress(filepath, dstpath: string) =
  if not ".tar .gz .taz .tgz .bz2 .xz".split.anyIt(filepath.endsWith it):
    error &"Unrecognized compressed type for {filepath}"
  discard existsOrCreateDir dstpath
  let cmdresult = execCmdEx(&"tar xf {filepath} -C {dstpath}", options={poEvalCommand, poStdErrToStdOut, poUsePath})
  if cmdresult.exitCode != 0:
    error &"Could not extract '{filepath}' to destination '{dstpath}'"

# TODO rewrite decompression to use only zippy for zip (if it works), and zstd for zst, and CLI tar for all else
proc uncompress(filepath, dstpath: string) =
  const SUPPORTED_EXTENSIONS = ".zst .tar .gz .taz .tgz .xz .zip".split
  discard existsOrCreateDir dstpath
  var
    osfilepath = dup(filepath, normalizePath)
    osdstpath = dup(dstpath, normalizePath)
    resulting_file = osdstpath
  # first, un-zst if necessary
  if osfilepath.endsWith ".zst":
    let (_,filename,ext) = osfilepath.splitFile
    if ext in SUPPORTED_EXTENSIONS: echo &"uncompressing {filename}{ext} ..."
    let innerfile = appCacheDir() / filename # file, has ext
    var in_stream = newFileStream(osfilepath, fmRead)
    var out_stream = newFileStream(innerfile, fmWrite)
    zstdx.decompress(in_stream, out_stream)
    osfilepath = innerfile
  # extract any remaining file types
  let (_,filename,ext) = osfilepath.splitFile
  if ext in SUPPORTED_EXTENSIONS: echo &"uncompressing {filename}{ext} ..."
  case ext:
    of ".tar", ".gz", ".taz", ".tgz", ".bz2", ".xz":
      tarxUncompress(osfilepath, osdstpath)
      resulting_file = osdstpath # dir, has no ext
    of ".zip":
      zipx.extractAll(osfilepath, osdstpath)
      resulting_file = osdstpath # dir, has no ext
    else:
      error &"Unknown file extension '{ext}' of {filename}"

proc saveAelmModConf(js: JsonNode): JsonNode =
  # returns initial settings for the aelm mod conf file
  let am = newJObject()
  am["aelm-mod-config"] = copy js
  let conf = am["aelm-mod-config"]
  if not isNil js{"config", "bin"}:
    conf["bin"] = copy js{"config", "bin"}
  if not isNil js{"config", "envvars"}:
    conf["envvars"] = copy js{"config", "envvars"}
  conf.delete "config"
  return am

proc runAelmModConfSetupCommands(js:JsonNode) =
  let am = js["aelm-mod-config"]
  let setup = am["setup"]
  let replacements = [
    ("{cwd}", getCurrentDir()),
    ("{root}", am["root"].getStr.dup(normalizePath)),
    ("{name}", am["name"].getStr),
    ("{bin}", am["bin"].getStr.dup(normalizePath)),
    ("{version}", am["version"].getStr),
    ("{installer}", am["installer"].getStr.dup(normalizePath)),
  ]
  var tasks = collect:
    for item in setup.items:
      item.getStr
  if "{uncompress}" in tasks:
    tasks.keepItIf(it != "{uncompress}")
    uncompress(am["installer"].getStr.dup(normalizePath), am["root"].getStr.dup(normalizePath))
  # the tasks that remain are all valid shell commands
  for task in tasks.mitems:
    task = task.multiReplace(replacements)
  let cmdstring = tasks.join("; ")
  let cmdresult = execCmdEx(cmdstring, options={poEchoCmd, poStdErrToStdOut, poUsePath, poEvalCommand})
  if cmdresult.exitCode != 0:
    error cmdresult.output

proc addModule(category, version, destination: string) =
  let cfg = loadAelmConf()
  var guessedVersion, guessedDestination: string
  guessedVersion = if version.len == 0: "latest" else: version
  guessedDestination = if destination.len == 0: &"{category}-{guessedVersion}" else: destination
  let module = cfg.getModuleJson(category=category, version=guessedVersion)

  #if dirExists guessedDestination:
  #  error &"Directory '{guessedDestination}' already exists"

  let url = module["url"].getStr
  var filepath: string
  try:
    filepath = download url
  except Exception:
    error &"Failed to download {url}"

  let modconf = saveAelmModConf module
  modconf{"aelm-mod-config","root"} = (getCurrentDir() / guessedDestination).dup(normalizePath).newJString
  modconf{"aelm-mod-config","installer"} = filepath.expandFilename.newJString
  modconf{"aelm-mod-config","name"} = guessedDestination.newJString
  
  runAelmModConfSetupCommands modconf
  
  let aelmModConfName = guessedDestination.expandFilename / CONF_MOD_FILENAME
  writeFile(aelmModConfName, modconf.pretty)


proc doAddModule(args:seq[string]) =
  # expect up to 2 arguments
  if args.len < 1:
      error "Expected a category name. See 'aelm search' subcommand output."
  let namever = args[0]
  if args.len > 2:
      echo "Too many arguments."
      quit(1)
  let destination = if args.len == 2: args[1] else: ""
  let nameverSeq = namever.split('@')
  let category = nameverSeq[0]
  let version = if nameverSeq.len == 2: nameverSeq[1] else: ""
  addModule(category, version, destination)

proc doSearch(args:seq[string]) =
  # show all languages and versions
  # expect N arguments of format: cat[@ver]
  let cfg = loadAelmConf()
  let catvers = getCategoriesAndVersions cfg
  if args.len < 1:
    for category,versions in catvers.pairs:
      echo category
      echo versions.join("\n").indent(2)
  elif args.len >= 1:
    for arg in args:
      if '@' in arg:
        let
          subargs = arg.split('@')
          category = subargs[0]
          version = subargs[1]
        if version in catvers.getOrDefault(category, @[]):
          echo category
          echo &"  {version}"
      else: # no version specified
        let category = arg
        echo category
        echo catvers.getOrDefault(category, @[]).join("\n").indent(2)

proc doExec(args:seq[string]) =
  # first we process environment variables
  # concatenating ".*PATH" vars (PYTHONPATH, RUST_PATH, etc.)
  # preferring existing environment contents if it exists
  # We also set the PATH according to the module
  # then we run the executable command
  if args.len < 2:
    error "Need 2 arguments: <aelm-module> <command>\n  (quote command for complex commands with switches)"
  let name = args[0].strip(chars={DirSep})
  let cmd = args[1..^1].join(" ")
  let modcfg = loadAelmModuleConf(name)
  let replacements = [
    ("{cwd}", getCurrentDir()),
    ("{root}", modcfg["root"].getStr.dup(normalizePath)),
    ("{name}", modcfg["name"].getStr),
    ("{bin}", modcfg["bin"].getStr.dup(normalizePath)),
    ("{version}", modcfg["version"].getStr),
    ("{installer}", modcfg["installer"].getStr.dup(normalizePath)),
  ]
  # update PATH
  var newPath = modcfg["bin"].getStr.multiReplace(replacements).dup(normalizePath)
  when defined(windows):
    newPath.add ";"
  else:
    newPath.add ":"
  newPath.add os.getEnv("PATH","")
  os.putEnv("PATH", newPath)
  #echo os.getEnv("PATH")
  # set all other env vars
  let jsvars = modcfg{"envvars"}
  if not isNil jsvars:
    for key,js in jsvars.getFields:
      # concatenate var contents if variable name ends in PATH
      # otherwise prefer existing environment contents if exist
      var newValue: string
      newValue = js.getStr.multiReplace(replacements)
      if key.endsWith("PATH"):
        newValue = newValue & ":" & os.getEnv(key,"")
      else:
        newValue = if os.getEnv(key,"").len == 0: newValue else: os.getEnv(key)
      os.putEnv(key, newValue)
  #let exelocation = findExe("python3")
  #echo exelocation
  #let cmdresult = execCmdEx(cmd, options={poEvalCommand, poStdErrToStdOut, poUsePath})
  #echo cmdresult.output
  #quit(cmdresult.exitCode)
  let exitCode = execCmd(cmd)
  quit(exitCode)

const topLvlUsage = """${doc}Usage:
  $command {SUBCMD}  [sub-command options & parameters]
where {SUBCMD} is one of:
$subcmds

$command {-h|--help} or with no args at all prints this message.
$command --help-syntax gives general cligen syntax help.

Run "$command {help SUBCMD|SUBCMD --help}" to see help for just SUBCMD.
run "$command help" to get *comprehensive* help."""

when isMainModule:
  import cligen
  dispatchMulti(["multi", usage = topLvlUsage],
                [doListAelmModules, cmdName="list", doc="list all aelm modules in CWD", help={"path":"path for which to list aelm modules"}],
                [doInit, cmdName="init", doc="Initializes an aelm dir"],
                [doRefresh, cmdName="refresh", doc="Alias for init"],
                [doAddModule, cmdName="add", doc="Add a new environment or language"],
                [doSearch, cmdName="search", doc="Search environments and languages"],
                [doExec, cmdName="exec", doc="Execute a command in a specified existing environment or language module"],
                )
