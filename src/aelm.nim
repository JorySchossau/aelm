# TODO 
# * split out repo into separate config files
# * create github repo
# * create packages github repo
# * create commit hooks that update aggregation of files into one repo file
# * allow specify repo(s) when init

# arg parsing
import parseopt # cli parsing
from sequtils import concat, to_seq
from os import commandLineParams
# aelm
import macros # updateVarIfKeyOfSameName
import std/[json, sequtils, strutils, tables, strformat, os, osproc, sets, algorithm, streams]
from std/os import getHomeDir, createDir, getCurrentDir, setCurrentDir, setFilePermissions, walkDirRec, parentDir
from puppy import fetch, PuppyError
from std/rdstdin import readLineFromStdin # for stdin piping
import yaml/serialization, streams
from yaml import YamlParserError, YamlLoadingError
from terminal import styledWriteLine, resetStyle, fgGreen, fgYellow, fgRed, styleDim, styleBright
from dl import syncDownload
from dlinfer import InferredConfidence, InferredDownload, getDLCandidates
from std/sugar import dup, collect, `=>`
import zstd/decompress as zstdx
import zippy/ziparchives as zipx
when defined(windows):
  import std/registry


## TODO move to external cli lib
template registerArg(command:untyped, nargs:Natural = 0, allowMultiple:bool = false, aliases:openArray = new_seq[string]()) {.dirty.} =
  when not defined(`command`):
    let `command` :string = ""
  var
    `command _ args` {.used.} = new_seq[string]()
    `command _ enabled` = false
    `command _ args _ len` {.used.} = nargs
    `all _ command _ alias _ list`:seq[string] # [command, alias1, alias2, ...]
    `allows_multiple _ command _ captures` {.used.}:bool = allowMultiple
  if aliases.len > 0:
    `all _ command _ alias _ list` = concat(@[`command`.astToStr],to_seq(aliases))
  else:
    `all _ command _ alias _ list` = @[`command`.astToStr]

template captureArg(p:OptParser, command:untyped, control:untyped) {.dirty.} =
  if p.key in `all _ command _ alias _ list`:
    `command _ enabled` = true
    if `command _ args _ len` == 0:
      p.next()
      control
    elif `command _ args _ len` < 0:
      # consume all remaining args
      `command _ args` = p.remainingArgs()
      break
    elif `command _ args _ len` > 0:
      if not `allows_multiple _ command _ captures`:
        `command _ args`.setLen 0
      for capture_arg_i in 1 .. `command _ args _ len`:
        p.next()
        if p.kind == cmdEnd: break # assume we're using parseopt while loop convention
        if p.kind in {cmdShortOption, cmdLongOption}: break
        `command _ args`.add p.key
    # continue or break the outer capture loop
    # otherwise fallthrough when found an unexpected option
    if p.kind in {cmdShortOption, cmdLongOption}:
      continue
    p.next()
    control

## register all cli arguments
registerArg(list, nargs = 1, aliases = ["l","ls"])
registerArg(init, nargs = -1, aliases = ["refresh","i"])
registerArg(add, nargs = -1, aliases = ["a"])
registerArg(remove, nargs = 1, aliases = ["rm"])
registerArg(search, nargs = 1, aliases = ["s"])
registerArg(info, nargs = 1, aliases = ["inf"])
registerArg(exec, nargs = -1, aliases = ["x"])
registerArg(connect, nargs = -1, aliases = ["c"])
registerArg(disconnect, nargs = -1, aliases = ["d"])
registerArg(script, nargs = 1, aliases = ["sc"])
registerArg(package, nargs = 2, aliases = ["pkg","p"])
# I'm using long names and not advertising them in the help
# instead I'm relying on their aliases, which can contain '-'
# OPTIONS
registerArg(help, nargs = 1, aliases = ["h"])
registerArg(user)
registerArg(description)
registerArg(check_downloads, aliases = ["dl"])
registerArg(clearTheEntireCache, aliases = ["clear-cache"])
# `add` arguments
registerArg(ignore_system, aliases = ["ignore-system"]) # TODO what was this for?
registerArg(prefer_system, nargs = 1, aliases = ["prefer-system"])
#registerArg(not_module, nargs = 1, aliases = ["not"])

const
  CONF_FILENAME = ".aelm.yaml"
  CONF_MOD_FILENAME = ".aelm.mod.yaml"
  ScriptExtension = block:
    when defined(windows):
      ".bat"
    else:
      ""

const ACTIVATE_SCRIPT_LINUX = """
case ":${PATH}:" in
  *:"{bin}:"*)
    ;;
  *)
    ## prepend the path to be safe
    export PATH="{bin}:$PATH"
    ;;
esac
"""
const DEACTIVATE_SCRIPT_LINUX = """
case ":${PATH}:" in
  *:"{bin}:"*)
    ## remove the path
    substr="{bin}:"
    export PATH=${PATH/${substr}/}
    ;;
  *)
    ;;
esac
"""
const ACTIVATE_SCRIPT_WINDOWS = """
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "substr={bin};"
echo.!PATH! | findstr /C:"{bin};" 1>nul
if errorlevel 1 (
  rem not found in path. add to path.
  set NEWPATH=!substr!!PATH!
) else (
  rem do nothing / already activated
)
endlocal & path %NEWPATH%
"""
const DEACTIVATE_SCRIPT_WINDOWS = """
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "substr={bin};"
echo.!PATH! | findstr /C:"{bin};" 1>nul
if errorlevel 1 (
  rem do nothing. no module in path.
) else (
  rem found in path. remove from path.
  set NEWPATH=!PATH:%substr%=!
)
endlocal & path %NEWPATH%
"""
const ACTIVATE_SCRIPT_PS = """
$env:substr="{bin};"
if (${env:path}.contains("{bin};")) {
  # do nothing / already activated
} else {
  # not found in path. add to path.
  ${env:NEWPATH}="${env:substr}${env:path}"
}
${env:path}="${env:NEWPATH}"
"""
const DEACTIVATE_SCRIPT_PS = """
$env:substr="{bin};"
if (${env:path}.contains("{bin};")) {
  # found in path. remove from path.
  ${env:NEWPATH}=${env:path}.Replace("{bin};","")
} else {
  # do nothing. no module in path.
}
${env:path}="${env:NEWPATH}"
"""

type
  Download = object
    url {.defaultVal: "".}: string
    name {.defaultVal: "".}: string
    uncompress {.defaultVal: true.}: bool
  AelmModule = object
    # used only in module dir
    auto {.defaultVal: "".}: string
    testcmd {.defaultVal: "".}: string
    name {.defaultVal: "".}: string
    category {.defaultVal: "".}: string
    version {.defaultVal: "".}: string
    root {.defaultVal: "".}: string
    connections {.defaultVal: @[].}: seq[string] # used only in module config
    aelmscript {.defaultVal: "".}: string
    binpaths {.defaultVal: @[].}: seq[string]
    unavailable {.defaultVal: "".}: string
    prefer_system {.defaultVal: @[].}: seq[string]
    envvars {.defaultVal: initTable[string, string]().}: Table[string, string]
    downloads {.defaultVal: @[].}: seq[Download]
    presetup {.defaultVal: "".}: string
    setup {.defaultVal: "".}: string
    postsetup {.defaultVal: "".}: string
    description {.defaultVal: "".}: string
  AelmOS = object
    # usual overrides
    auto {.defaultVal: "".}: string
    root {.defaultVal: "".}: string
    testcmd {.defaultVal: "".}: string
    aelmscript {.defaultVal: "".}: string
    binpaths {.defaultVal: @[].}: seq[string]
    unavailable {.defaultVal: "".}: string
    prefer_system {.defaultVal: @[].}: seq[string]
    envvars {.defaultVal: initTable[string, string]().}: Table[string, string]
    downloads {.defaultVal: @[].}: seq[Download]
    presetup {.defaultVal: "".}: string
    setup {.defaultVal: "".}: string
    postsetup {.defaultVal: "".}: string
    description {.defaultVal: "".}: string
  AelmVersion = object
    linux {.defaultVal: nil.}: ref AelmOS
    osx {.defaultVal: nil.}: ref AelmOS
    windows {.defaultVal: nil.}: ref AelmOS
    armlinux {.defaultVal: nil.}: ref AelmOS
    armosx {.defaultVal: nil.}: ref AelmOS
    # usual overrides
    auto {.defaultVal: "".}: string
    root {.defaultVal: "".}: string
    testcmd {.defaultVal: "".}: string
    aelmscript {.defaultVal: "".}: string
    binpaths {.defaultVal: @[].}: seq[string]
    unavailable {.defaultVal: "".}: string
    prefer_system {.defaultVal: @[].}: seq[string]
    envvars {.defaultVal: initTable[string, string]().}: Table[string, string]
    downloads {.defaultVal: @[].}: seq[Download]
    presetup {.defaultVal: "".}: string
    setup {.defaultVal: "".}: string
    postsetup {.defaultVal: "".}: string
    description {.defaultVal: "".}: string
  AelmCategory = object
    versions {.defaultVal: initTable[string,AelmVersion]().}: Table[string,AelmVersion]
    # usual overrides
    auto {.defaultVal: "".}: string
    root {.defaultVal: "".}: string
    testcmd {.defaultVal: "".}: string
    aelmscript {.defaultVal: "".}: string
    binpaths {.defaultVal: @[].}: seq[string]
    unavailable {.defaultVal: "".}: string
    prefer_system {.defaultVal: @[].}: seq[string]
    envvars {.defaultVal: initTable[string, string]().}: Table[string, string]
    downloads {.defaultVal: @[].}: seq[Download]
    presetup {.defaultVal: "".}: string
    setup {.defaultVal: "".}: string
    postsetup {.defaultVal: "".}: string
    description {.defaultVal: "".}: string
  AelmRepo = Table[string, AelmCategory]

proc writeError(alert:string="",msg:string="") =
  stderr.writeLine ""
  styledWriteLine(stderr, fgRed, alert, resetStyle, msg)

proc writeSuccess(alert:string="",msg:string="") =
  stdout.writeLine ""
  styled_write_line(stdout, fgGreen, alert, resetStyle, msg)

proc writeWarning(alert:string="",msg:string="") =
  stdout.writeLine ""
  styledWriteLine(stdout, fgYellow, alert, resetStyle, msg)

proc aelmReplacementPairsFromAelmEnv(env: AelmModule):auto =
  # this list is passed to multiReplace when expanding
  # envvars, urls, paths, etc.
  result = [
    ("{cwd}", getCurrentDir()),
    ("{root}", env.root.dup(normalizePath)),
    ("{name}", env.name),
    ("{version}", env.version),
  ]

func normalizePathToWin(path: string): string =
  return path.replace('/','\\')

proc expandPlaceholders(env: var AelmModule) =
  let replacements = aelmReplacementPairsFromAelmEnv env
  env.presetup = env.presetup.multiReplace(replacements)
  env.setup = env.setup.multiReplace(replacements)
  env.postsetup = env.postsetup.multiReplace(replacements)
  env.testcmd = env.testcmd.multiReplace(replacements)
  for bin_i in 0..env.binpaths.high:
    env.binpaths[bin_i] = env.binpaths[bin_i].multiReplace(replacements).multiReplace(replacements).dup(normalizePath)
    when defined(windows): env.binpaths[bin_i] = env.binpaths[bin_i].normalizePathToWin
  for value in env.envvars.mvalues:
    value = value.multiReplace(replacements).dup(normalizePath)
    when defined(windows): value = value.normalizePathToWin
  for dl in env.downloads.mitems:
    dl.url = dl.url.multiReplace(replacements)
    dl.name = block:
      if dl.name.len == 0: extractFilename dl.url
      else: dl.name.multiReplace(replacements)

macro updateVars(envA: var untyped, envB: untyped, variables: varargs[untyped]): untyped =
  result = newStmtList()
  for v in variables: result.add quote do:
      if `envB`.`v`.len.bool: `envA`.`v` = `envB`.`v`

template update(a:var AelmModule, b: untyped) {.dirty.} =
  updateVars(envA=a, envB=b, binpaths, root, prefer_system, downloads, presetup, setup, postsetup, aelmscript, testcmd, envvars, description, auto, unavailable)

proc `$`(env: AelmModule): string =
  proc seqStringsToYaml(strings: seq[string], name: string, multiline: bool = true): string =
    if strings.len == 0: return
    let needsQuote = any(strings, proc (s:string):bool = (':' in s) or (s.startsWith '{'))
    if multiline:
      result.add &"{name}:\n"
      for line in strings:
        if ((':' in line) or (line.startsWith '{')) and "\n" notin line:
          result.add &"  - '{line}'\n"
        else:
          if "\n" in line:
            result.add "  - |\n"
            result.add line.indent(4)
          else:
            result.add &"  - {line}\n"
      result.add "\n"
    else:
      result.add &"{name}: ["
      if needsQuote:
        result.add strings.mapIt(&"'{it}'").join(", ")
      else:
        result.add strings.mapIt(&"{it}").join(", ")
      result.add "]\n"
  result = &"""
category: {env.category}
version: {env.version}
name: {env.name}
root: {env.root}
"""
  if env.binpaths.len.bool: result.add env.binpaths.seqStringsToYaml(name = "binpaths", multiline = false)
  if env.prefer_system.len.bool: result.add env.prefer_system.seqStringsToYaml(name = "prefer_system", multiline = false)
  if env.connections.len.bool: result.add env.connections.seqStringsToYaml(name = "connections", multiline = false)
  if env.envvars.len.bool:
    result.add "\nenvvars:\n"
    for key,value in env.envvars:
      result.add &"  {key}: '{value}'\n"
  if env.testcmd.len.bool: result.add &"testcmd: {env.testcmd}\n"
  result.add "\n# End of settings that still have an effect on this module."
  result.add "\n# The below information is included as a record of this module's origin.\n"
  result.add "\n"
  if env.auto.len.bool: result.add &"auto: {env.auto}\n"
  if env.downloads.len.bool:
    result.add "\ndownloads:\n"
    for dl in env.downloads:
      result.add &"  - url: {dl.url}\n"
      if dl.name.len.bool: result.add &"    name: {dl.name}\n"
      if not dl.uncompress: result.add &"    uncompress: {dl.uncompress}\n"
  result.add "\n"
  if env.presetup.len.bool:
      if "\n" notin env.presetup: result.add &"presetup: {env.presetup}\n"
      else: result.add &"presetup: |\n{env.presetup.indent(2)}\n"
  if env.setup.len.bool:
      if "\n" notin env.setup: result.add &"setup: {env.setup}\n"
      else: result.add &"setup: |\n{env.setup.indent(2)}\n"
  if env.postsetup.len.bool:
      if "\n" notin env.postsetup: result.add &"postsetup: {env.postsetup}\n"
      else: result.add &"postsetup: |\n{env.postsetup.indent(2)}\n"
  if env.aelmscript.len.bool: result.add &"aelmscript: |\n{env.aelmscript.indent(2)}\n"
  if env.description.len.bool: result.add &"description: |\n{env.description.indent(2)}\n"

proc getPackageTriplet(input: string): tuple[name, version, newname: string] =
  var str = input
  if str.count('@') > 1 or str.count(':') > 1:
    writeError("Error: ", &"'{str}' Only 1 '@' and 1 ':' allowed (name@version:newName)")
    quit(1)
  let locAt = str.find('@')
  let locColon = str.find(':')
  if str.count({'@',':'}) == 2 and locAt > locColon:
    writeError("Error: ", "Incorrect '@' and ':' placement. Should be (name@version:newName)")
  result.name = str.split('@')[0].split(':')[0]
  if '@' in str:
    result.version = str.split('@')[1].split(':')[0]
  if ':' in str:
    result.newname = str.split(':')[1]


proc loadAelmModule(path: string): AelmModule =
  if not dirExists path:
    writeError("Error: ", &"No aelm module '{path}' exists by that name")
    quit(1)
  if not fileExists joinPath(path, CONF_MOD_FILENAME):
    writeError("Error: ", &"That does not seem like an aelm module. No {CONF_MOD_FILENAME} file found in {path}")
    quit(1)
  var module: AelmModule
  try:
    var stream = newFileStream(path / CONF_MOD_FILENAME, fmRead)
    stream.load module
    close stream
  except IOError:
    writeError("Error: ", &"unable to read file '{path / CONF_MOD_FILENAME}'")
  except YamlConstructionError as e:
    writeError("Error: ", &"invalid yaml config structure for '{path / CONF_MOD_FILENAME}'")
    echo &"\nat or before line {e.mark.line}"
    writeWarning(&"{e.mark.line}:  {e.lineContent}")
    quit(1)
  except YamlLoadingError as e:
    writeError("Error: ", &"unable to load yaml for '{path / CONF_MOD_FILENAME}'")
    echo &"\nat or before line {e.mark.line}"
    writeWarning(&"{e.mark.line}:  {e.lineContent}")
    quit(1)
  return module

iterator aelmDirs(basepath: string): tuple[name, namever:string, connections:string] =
  # return all immediate dirs of `basepath` with aelm.conf files in them
  var name, category, version, namever, connections: string
  var connectionsList: seq[string]
  for dir in os.walkDir(basepath):
    if dir.kind == pcDir and fileExists(joinPath(dir.path, CONF_MOD_FILENAME)):
      name = dir.path.relativePath basepath.normalizedPath
      let module = loadAelmModule dir.path
      namever = fmt"{module.category}@{module.version}"
      connectionsList = module.connections
      connections = block:
        if connectionsList.len == 0: ""
        else: '[' & connectionsList.join(", ") & ']'
      yield (name, namever, connections)

proc readUserInstalledModules: HashSet[string] =
  let
    fileName = "activate" & ScriptExtension
    fileDir = getHomeDir() / ".aelm"
    filePath = fileDir / fileName
  if not fileExists filePath: return
  result = readFile(filePath) . splitLines . filterIt(it.len.bool) . mapIt(it.split()[1].splitPath.head.splitPath.tail) . toHashSet

proc writeUserInstalledModules(modules: HashSet[string]) =
  let fileName = "activate" & ScriptExtension
  let filePath = getHomeDir() / ".aelm" / fileName
  let callCommand = block:
    when defined(windows):
      "call "
    else:
      "source "
  var contents = modules . toSeq . mapIt(callCommand & getHomeDir() / ".aelm" / it / fileName) . join("\n")
  let previouslyInstalledModules = readUserInstalledModules()
  try:
    filePath.writeFile contents
  except [IOError]:
    writeError("Error: ", "Unable to write file '{filePath}'")
    quit(1)
  when defined(windows):
    # update registry
    const
      REGISTRY_LOCATION = """System\CurrentControlSet\Control\Session Manager\Environment"""
      REGISTRY_KEY = "Path"
    let uninstalledModules = previouslyInstalledModules - modules
    let newModules = modules - previouslyInstalledModules
    var paths = getUnicodeValue(REGISTRY_LOCATION, REGISTRY_KEY, HKEY_LOCAL_MACHINE).split(';')
    # uninstall old modules
    for moduleName in uninstalledModules.toSeq:
      let path = getHomeDir() / ".aelm" / moduleName
      var module = loadAelmModule path
      let replacements = aelmReplacementPairsFromAelmEnv module
      expandPlaceholders module
      for bin in module.binpaths:
        if bin in paths:
          let index = paths.find bin
          paths.delete index
    # install new modules
    for moduleName in newModules.toSeq:
      let path = getHomeDir() / ".aelm" / moduleName
      var module = loadAelmModule path
      let replacements = aelmReplacementPairsFromAelmEnv module
      expandPlaceholders module
      for bin in module.binpaths:
        if bin notin paths: paths.insert(bin, 0)
    let pathsAsString = paths.join(";")
    setUnicodeValue(REGISTRY_LOCATION, REGISTRY_KEY, pathsAsString, HKEY_LOCAL_MACHINE)
    echo pathsAsString

proc doList =
  if userEnabled: listArgs = @[getHomeDir() / ".aelm"]
  let pth = if listArgs.len != 0: listArgs[0] else: getCurrentDir()
  let modules = pth.aelmDirs.toSeq
  let maxNameLen = modules.foldl(max(a, b.name.len), 0)
  let maxNameVerLen = modules.foldl(max(a, b.namever.len), 0)
  # headings
  let (dirHeading, envverHeading, connectionsHeading) = ("Dir", "Env@Ver", "Connections")
  echo &"{dirHeading.alignLeft(maxNameLen)} {envverHeading.alignLeft(maxNameVerLen)} {connectionsHeading}"
  for module in modules:
    echo &"{module.name.alignLeft(maxNameLen)} {module.namever.alignLeft(maxNameVerLen)} {module.connections}"

proc appCacheDir: string =
  let cacheDir = getCacheDir("aelm")
  createDir cacheDir
  return cacheDir

proc download(url, destination, filename:string; useCache = true) =
  # returns full path to downloaded file (or cached file)
  if useCache:
    let filepath = appCacheDir() / filename
    if not fileExists filepath:
      syncDownload(url, filepath)
    else:
      echo "(using cached installer)"
    filepath.copyFileToDir destination
  else:
    let filepath = destination / filename
    syncDownload(url, filepath)

proc helperLoadAelmRepo(path: string): AelmRepo =
  var stream: FileStream
  try:
    if path.startsWith "http":
      let content = fetch path
      content.load result
    else:
      stream = newFileStream(path, fmRead)
      stream.load result
      close stream
  except PuppyError as e:
    writeError("Error: ", &"unable to download file '{path}'")
    quit(1)
  except IOError:
    writeError("Error: ", &"unable to access file '{CONF_FILENAME}'")
    quit(1)
  except YamlParserError as e:
    writeError("Error: ", &"invalid or unexpected yaml in '{CONF_FILENAME}'")
    echo &"\nat or before line {e.mark.line}"
    writeWarning(&"{e.mark.line}:  {e.lineContent}")
    quit(1)
  except YamlLoadingError as e:
    writeError("Error: ", &"invalid or unexpected yaml in '{CONF_FILENAME}'")
    echo &"\nat or before line {e.mark.line}"
    writeWarning(&"{e.mark.line}:  {e.lineContent}")
    quit(1)
  finally:
    if not isNil stream:
      close stream

proc doInit =
  const MAIN_REPO_URL = "https://github.com/JorySchossau/aelm-packages/releases/download/latest/aelm-repo.yaml"
  var filePath = block:
    if userEnabled: getHomeDir() / ".aelm" / CONF_FILENAME
    else: getCurrentDir() / CONF_FILENAME
  # main repo
  echo &"creating repository file {filePath}"
  echo &"fetching main repository {MAIN_REPO_URL}"
  var contents: string
  try:
    contents = fetch(MAIN_REPO_URL)
    filePath.writeFile contents
  except PuppyError as e:
    echo e.msg
    quit(1)
  # user repos
  var file: File
  for url in initArgs:
    echo &"fetching {url}"
    try:
      if url.toLower.startsWith "http": contents = fetch(url)
      else: contents = readFile url

      file = open(filePath, fmAppend)
      file.write contents
    except PuppyError as e:
      echo e.msg
      quit(1)
    except IOError as e:
      echo e.msg
      quit(1)
    finally:
      close file
  let repo = helperLoadAelmRepo filePath
  echo &"{repo.keys.toSeq.len} items in new repository"

proc loadAelmRepo(path = ""): AelmRepo =
  let filePath = block:
    if path.len.bool: path
    elif userEnabled: getHomeDir() / ".aelm" / CONF_FILENAME
    else: getCurrentDir() / CONF_FILENAME
  if (not fileExists filePath) and (not filePath.startsWith "http"):
    writeWarning("Warning: ", &"no repo file found at '{filePath}'")
    doInit()
  result = helperLoadAelmRepo filePath

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
    {.error: "cputype must be defined at compile-time on CLI (x86_64 or arm) ex: -d:cputype=x86_64".}
  else:
    cputype

proc getCurrentOS: string =
  when aelmcpu == "arm":
    aelmcpu & aelmos
  else:
    aelmos # we assume x86_64 as more common for json key legibility in aelm conf

proc sortVersions(versions: var seq[string]) =
  # sorts version strings, respecting formats: 0.1.2, v0.1.2, latest
  # sorts newer to older
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
  proc moveToEndIfExist(s: var seq[string], t: string) =
    if t in s: 
      s.add t
      s.delete s.find(t)
  var asciiVersions: seq[string]
  const NUMBERS = "0123456789"
  for i in countDown(versions.high,0):
    if versions[i][0] notin NUMBERS:
      asciiVersions.add versions[i]
      versions.delete i
  sort versions, cmp=compareVersions
  sort asciiVersions
  asciiVersions.moveToEndIfExist "stable"
  asciiVersions.moveToEndIfExist "latest"
  versions.add asciiVersions
  reverse versions

proc getCategoriesAndVersions(repo: AelmRepo): Table[string, seq[string]]=
  let categories = repo.keys.toSeq.dup(sort)
  for category in categories:
    let versionKeys = repo[category].versions.keys.toSeq
    for version in versionKeys.dup(sortVersions):
      result.mgetOrPut(category, newSeq[string]()).add version
  return result

proc getAelmModule(repo: AelmRepo, category, version: string): AelmModule =
  var env: AelmModule
  
  if category notin repo:
    writeError("Error: ", &"Not a valid category '{category}'. Options are:\n" & join(repo.keys.toSeq,"\n").indent(2))
    quit(1)

  # first opportunity for configuration variables in config
  env.update repo[category]
  env.category = category
  var versions = repo[category].versions.keys.toSeq
  # guess user meant latest version if none specified
  # default to highest versions
  sortVersions versions
  let guessedVersion = block:
    if version.len == 0: versions[0]
    else: version
  if guessedVersion notin versions:
    if versions.len == 0:
      writeError("Error: ", &"No versions defined for {category}")
      quit(1)
    else:
      writeError("Error: ", &"Not a valid version '{guessedVersion}'. Options are:\n" & join(versions,"\n").indent(2))
      quit(1)
  env.version = guessedVersion

  env.update repo[category].versions[guessedVersion]

  macro updateByOS(env: AelmModule, repoCatVersion: untyped): untyped =
    let os = ident getCurrentOS()
    result = newStmtList()
    result.add quote do:
      if isNil(`repoCatVersion`.`os`) and (not env.auto.len.bool):
        writeWarning("Warning: ", "module not available for this OS")
        quit(1)
      elif not isNil `repoCatVersion`.`os`:
        env.update `repoCatVersion`.`os`

  env.updateByOS repo[category].versions[guessedVersion]
  
  return env

proc tarxUncompress(filepath, dstDirPath: string) =
  if not ".tar .gz .taz .tgz .bz2 .xz".split.anyIt(filepath.endsWith it):
    writeError("Error: ", &"Unrecognized compressed type for {filepath}")
  createDir dstDirPath
  let cmdresult = execCmdEx(&"tar xf {filepath} -C {dstDirPath}", options={poEvalCommand, poStdErrToStdOut, poUsePath})
  if cmdresult.exitCode != 0:
    writeError("Error: ", &"Could not extract '{filepath}' to destination '{dstDirPath}'")

import zip/gzipfiles
proc getExtension(name: string): string =
  if name.endsWith ".tar.xz": ".tar.xz"
  elif name.endsWith ".tar.gz": ".tar.gz"
  elif name.endsWith ".tar.bz2": ".tar.bz2"
  elif name.endsWith ".tar.7z": ".tar.7z"
  elif name.endsWith ".tar.lz": ".tar.lz"
  elif name.endsWith ".tar.z": ".tar.z"
  else: name.splitFile[2]
proc hasSupportedExtension(name: string): bool =
  let ext = getExtension name
  case ext:
    of ".tar", ".taz",
      ".tar.xz", ".tar.gz", ".tar.bz2",
      ".tar.7z", ".tar.lz", ".tar.z",
      ".tgz", ".gz", ".zip":
      return true
    else:
      return false

# TODO rewrite decompression to use only zippy for zip (if it works), and zstd for zst, and CLI tar for all else
proc uncompress(filePath, dstPath: string) =
  const SUPPORTED_EXTENSIONS = ".zst .tar .gz .taz .tgz .xz .zip".split
  createDir dstPath
  var
    srcFilePath = dup(filePath, normalizePath)
    dstDirPath = dup(dstPath, normalizePath)
    dstFilePath: string
  # first, un-zst if necessary
  if srcFilePath.endsWith ".zst":
    let (_,mantissa,ext) = srcFilePath.splitFile
    if ext in SUPPORTED_EXTENSIONS: echo &"uncompressing {mantissa}{ext} ..."
    let innerfile = appCacheDir() / mantissa # file, has ext
    var in_stream = newFileStream(srcFilePath, fmRead)
    var out_stream = newFileStream(innerfile, fmWrite)
    zstdx.decompress(in_stream, out_stream)
    srcFilePath = innerfile
  ## TODO find out and use correct mantissa when deciding
  ## on gz process - currently broken maybe
  # extract any remaining file types
  let (_,mantissa,_) = srcFilePath.splitFile
  let ext = getExtension srcFilePath
  if ext in SUPPORTED_EXTENSIONS: echo &"uncompressing {mantissa}{ext} ..."
  case ext:
    of ".tgz", ".gz":
      let gzfilestream = newGzFileStream(srcFilePath)
      let content = gzfilestream.readAll
      close gzfilestream
      (dstDirPath / mantissa).writeFile content
    of ".tar", ".taz", ".bz2", ".xz",
       ".tar.xz", ".tar.gz", ".tar.bz2",
       ".tar.7z", ".tar.lz", ".tar.z":
         tarxUncompress(srcFilePath, dstDirPath)
    of ".zip":
      # extract to "extracted" then `move extracted/* extracted/..`
      try:
        zipx.extractAll(srcFilePath, dstDirPath / "extracted") # assume extract to bin for zip
      except ZippyError as e:
        if not e.msg.endsWith "already exists":
          writeError("Error: ", e.msg)
          quit(1)
      for item in walkDir(dstDirPath / "extracted"):
        if item.kind in {pcFile,pcLinkToFile}:
          moveFile(item.path, dstDirPath / item.path.extractFilename)
        elif item.kind in {pcDir,pcLinkToDir}:
          moveDir(item.path, dstDirPath / item.path.extractFilename)
      removeDir dstDirPath / "extracted"
    else:
      writeError("Error: ", &"Unknown file extension '{ext}' of {mantissa}")

proc addPathAndEnvvarsFromPath(dirName:string) =
  var env = loadAelmModule dirName
  let replacements = aelmReplacementPairsFromAelmEnv env
  
  # expand all placeholders
  expandPlaceholders env

  # validate fields
  if not all(@[env.category.len.bool, env.root.len.bool, env.name.len.bool, env.version.len.bool], proc (x:bool): bool = x):
    writeError("Error: ", &"invalid config structure for '{dirName}' (envvars,root,name,binpaths,version)")
    quit(1)
  # update PATH
  if env.binpaths.len.bool:
    for bin in env.binpaths:
      var newPath = bin.dup(normalizePath)
      newPath.add PathSep
      newPath.add os.getEnv("PATH","")
      os.putEnv("PATH", newPath)
  # update ENVVARS
  for key,value in env.envvars:
      # concatenate var contents if variable name ends in PATH
      # otherwise prefer existing environment contents if exist
      var newValue: string
      newValue = value
      if key.endsWith("PATH") and os.getEnv(key).len != 0:
        newValue = newValue & PathSep & os.getEnv(key)
      else:
        newValue = if os.getEnv(key,"").len == 0: newValue else: os.getEnv(key)
      os.putEnv(key, newValue)

proc getEnvCtorString(env: AelmModule, formatstr: string): string =
  for name,value in env.envvars:
      result.add formatstr % [name, value]
      #result.add &"set {name}={value}\n"
      #result.add &"export {name}=\"{value}\"\n"

proc getEnvDtorString(env: AelmModule, formatstr: string): string =
  for name in env.envvars.keys:
    result.add formatstr % [name]
      #result.add &"set {name}=\n"
      #result.add &"export {name}=\n"

proc runAelmSetupCommands(srcEnv: AelmModule) =
  var env = srcEnv
  let replacements = aelmReplacementPairsFromAelmEnv env
  expandPlaceholders env
  var tasks = splitLines(env.presetup & "\n" & env.setup & "\n" & env.postsetup).toSeq
  tasks.applyIt(it.strip)
  tasks = tasks.filterIt(it.len.bool).filterIt(not it.startsWith "#")
  addPathAndEnvvarsFromPath(env.root)
  # the tasks that remain are all valid shell commands
  echo "running setup commands..."
  for task in tasks: echo task
  if tasks.len == 0: return
  let cmdstring = block:
    when defined(windows): "powershell -c \"" & tasks.join("; ") & "\""
    else: tasks.join("; ")
  let result = execCmdEx(cmdstring, workingDir=env.root, options={poEvalCommand})
  if result.exitCode != 0:
    writeError("Error: ", &"Command failed '{cmdstring}'")
    echo result.output
    quit(1)

proc prepare(command: string): string =
  if command.startsWith "aelm": result = command.replace("aelm", getAppFilename())
  if command.startsWith "#": result = ""
  # propagate flags if an "add environment" command
  if command.len > 1 and command.split[1].startsWith "a":
    if ignoreSystemEnabled: result.add " --ignore-system"

proc runAelmScriptCommands(script: string, workingDir: string = "") =
  let aelmExe = getAppFilename()
  for line_i, line in script.splitLines.toSeq:
    var command = prepare line.strip
    if command.len == 0: continue
    var simplerCommand = command
    simplerCommand.removePrefix aelmExe.splitPath.head & DirSep
    echo simplerCommand
    # TODO add powershell  around command like we do for scripts
    let result = execCmdEx(command, workingDir=workingDir)
    if result.exitCode != 0:
      writeError("Error: ", &"aelmscript error")
      echo result.output
      writeWarning(&"line {line_i+1}: ", &"{line}")
      writeWarning(&"     {line_i+1}: ", &"({command})")
      quit(1)
    else:
      if result.output.strip.len.bool:
        echo result.output

proc runAelmScriptCommands(env: AelmModule) =
  if env.aelmscript.len == 0: return
  let
    replacements = aelmReplacementPairsFromAelmEnv env
    script = env.aelmscript.multiReplace(replacements)
  runAelmScriptCommands(script, env.root)

proc inferBinPathForName(path, name: string): string =
  var firstExecutablePath: string
  # try searching by guessing exe name is same as package category name
  for file in walkDirRec(path, yieldFilter={pcFile}, relative=true):
    if name == file.extractFilename:
      return fmt"{{root}}/{file.parentDir}".strip(chars={'/'})
    if fpUserExec in (path / file).getFilePermissions and firstExecutablePath.len == 0:
      firstExecutablePath = file
  # default to guess by assuming bin path == first executable file path
  return fmt"{{root}}/{firstExecutablePath.parentDir}".strip(chars={'/'})

proc runAelmDownloadsAndExpandAuto(env: var AelmModule) =
  let dirPath = env.root
  let replacements = aelmReplacementPairsFromAelmEnv env
  expandPlaceholders env
  var filePath: string
  var filename: string
  # process `auto` field
  if env.auto.len.bool:
    var inferrence: InferredDownload
    try:
      inferrence = getDLCandidates(env.auto, env.version)
    except PuppyError as e:
      writeError("Error: ", &"Unable to download {env.category}@{env.version}")
      echo e.msg
      quit(1)
    if inferrence.candidates.len == 0:
      writeError("Error: ", &"No download candidates found for '{env.auto}'")
      quit(1)
    let url = inferrence.candidates[0]
    let filename = url.splitPath.tail
    filePath = dirPath / filename
    let uncompressFlag = url.extractFilename.hasSupportedExtension
    try:
      download(url=url, destination=dirPath, filename=filename)
      env.downloads.add Download(url:url, uncompress:uncompressFlag)
    except Exception as e:
      writeError("Error: ", &"Failed to download {url}")
      echo       "       " & e.msg
      quit(1)
    if filename.hasSupportedExtension:
      uncompress(filePath, dirPath)
      let wasGzipped = filename.getExtension == ".gz"
      if wasGzipped:
        # assume gzipped file should be named {category}
        moveFile dirPath / filename.dup(removeSuffix(".gz")), dirPath / env.category
        (dirPath / env.category).setFilePermissions {fpUserExec}
      let inferredBinPath = inferBinPathForName(path=dirPath, name=env.category)
      env.binpaths = @[inferredBinPath]
    else:
      # TODO if no exename set?
      let newFilePath = dirPath / env.category
      if filePath.extractFilename != env.category:
        moveFile(filePath, newFilePath)
      env.downloads[^1].uncompress = false
      newFilePath.setFilePermissions {fpUserExec}
      env.binpaths = @["{root}"]
    return
  # process `downloads` field
  for dl in env.downloads:
    filename = block:
      if dl.name.len.bool: dl.name
      else: dl.name.splitPath.tail
    filePath = dirPath / filename
    try:
      download(url=dl.url, destination=dirPath, filename=filename)
    except Exception as e:
      writeError("Error: ", &"Failed to download {dl.url}")
      echo       "       " & e.msg
      quit(1)
    if dl.uncompress:
      uncompress(filePath, dirPath)
    else:
      setFilePermissions(filePath, {fpUserExec})

proc removeAelmDownloads(env: AelmModule) =
  let dirPath = env.root
  var filePath: string
  for dl in env.downloads:
    if not dl.uncompress: continue
    filePath = dirPath / dl.name
    try:
      removeFile filePath
    except OSError:
      writeError("Error: ",&"Could not remove file after using {filePath}")

proc addModule(desiredCategory, desiredVersion, destination: string, prefer_system: seq[string], repofile = "") =
  var
    repo: AelmRepo
    module: AelmModule
    resultingVersion: string
    resultingDestination: string
    category = desiredCategory
    version = desiredVersion

  # if repofile was provided, then load the first module in that file
  # otherwise assume we are using the global repo and must pay attention
  # to the specified category and version
  if repofile.len.bool:
    repo = loadAelmRepo(repofile)
    let catvers = getCategoriesAndVersions repo
    if catvers.keys.toSeq.len == 0:
      writeError("Error: ", "No categories defined for repo file")
      quit(1)
    let (discoveredCategory,discoveredVersions) = catvers.pairs.toSeq[0]
    if discoveredVersions.len == 0:
      writeError("Error: ", "No versions defined for repo file")
      quit(1)
    category = discoveredCategory
    version = discoveredVersions[0]
    module = repo.getAelmModule(category=category, version=version)
  else:
    repo = loadAelmRepo()
    module = repo.getAelmModule(category=category, version=version)

    # Unavailable
    if module.unavailable.len.bool:
      writeWarning("Unavailable for this OS:\n", module.unavailable)
      quit(1)
    
  # the resulting version might be latest if was blank
  # the resulting destination will be {category}@{resultingVersion} if was blank
  resultingVersion = module.version
  # if user did not specify destination,
  # Then in order: {category}, {category}@{version}, skip add if last one exists
  resultingDestination = block:
    if destination.len == 0:
      if dirExists category:
        writeWarning(&"{category} already exists, trying {category}@{resultingVersion}")
        &"{category}@{resultingVersion}"
      else: category
    else: destination

  echo &"Installing {category}..."

  module.root = (getCurrentDir() / resultingDestination).dup(normalizePath)
  module.version = resultingVersion
  module.name = resultingDestination

  if dirExists(module.root): return

  if userEnabled:
    resultingDestination = (getHomeDir() / ".aelm" / &"{category}@{resultingVersion}").dup(normalizePath)
    module.root = resultingDestination

  createDir resultingDestination

  proc prefer(preferences: seq[string]): bool =
    if ignoreSystemEnabled: return false
    for exeName in preferences:
      if findExe(exeName).len != 0:
        echo &"(module prefers using system's existing {exeName})"
        return true

  # write conf file (and and it can be referenced when running setup commands)
  expandPlaceholders module

  runAelmDownloadsAndExpandAuto module

  # write conf file (and and it can be referenced when running setup commands)
  expandPlaceholders module

  let aelmModConfName = resultingDestination / CONF_MOD_FILENAME

  # seed with our aelm conf
  if user_enabled: copyFile(getHomeDir() / ".aelm" / CONF_FILENAME, module.root / CONF_FILENAME)
  else: copyFile(CONF_FILENAME, module.root / CONF_FILENAME)

  if (prefer module.prefer_system) or (prefer prefer_system):
    module.binpaths = @[] # passthrough PATH bin var and use system's {exeName}
    module.downloads.setLen 0
    module.presetup = ""
    module.setup = ""
    module.postsetup = ""
    module.aelmscript = ""
    module.testcmd = ""
    module.envvars.clear
    module.description = ""
    writeFile aelmModConfName, $module
    return
  else:
    writeFile aelmModConfName, $module

  runAelmScriptCommands module
  
  runAelmSetupCommands module

  removeAelmDownloads module

  if module.binpaths.len.bool:
    # module activation
    var
      replacements = aelmReplacementPairsFromAelmEnv module
      activationFilename = ""
      deactivationFilename = ""
      scriptActivate = ""
      scriptDeactivate = ""
    when defined(windows):
      activationFilename = resultingDestination / "activate" & ".bat"
      deactivationFilename = resultingDestination / "deactivate" & ".bat"
      for bin in module.binpaths:
        scriptActivate.add ACTIVATE_SCRIPT_WINDOWS.replace(sub="{bin}", by=bin)
        scriptDeactivate.add DEACTIVATE_SCRIPT_WINDOWS.replace(sub="{bin}", by=bin)
      scriptActivate.add module.getEnvCtorString("set $#=$#\n")
      scriptDeactivate.add module.getEnvDtorString("set $#=\n")
      writeFile activationFilename, scriptActivate
      writeFile deactivationFilename, scriptDeactivate
      scriptActivate = ""
      scriptDeactivate = ""
      activationFilename = resultingDestination / "activate" & ".ps1"
      deactivationFilename = resultingDestination / "deactivate" & ".ps1"
      for bin in module.binpaths:
        scriptActivate.add ACTIVATE_SCRIPT_PS.replace(sub="{bin}", by=bin)
        scriptDeactivate.add DEACTIVATE_SCRIPT_PS.replace(sub="{bin}", by=bin)
      scriptActivate.add module.getEnvCtorString("$${env:$#}=\"$#\"\n")
      scriptDeactivate.add module.getEnvDtorString("$${env:$#}=\"\"\n")
      writeFile activationFilename, scriptActivate
      writeFile deactivationFilename, scriptDeactivate
    else:
      activationFilename = resultingDestination / "activate"
      deactivationFilename = resultingDestination / "deactivate"
      for bin in module.binpaths:
        scriptActivate.add ACTIVATE_SCRIPT_LINUX.replace(sub="{bin}", by=bin)
        scriptDeactivate.add DEACTIVATE_SCRIPT_LINUX.replace(sub="{bin}", by=bin)
      scriptActivate.add module.getEnvCtorString("export $#=\"$#\"\n")
      scriptDeactivate.add module.getEnvDtorString("export $#=\n")
      writeFile activationFilename, scriptActivate
      writeFile deactivationFilename, scriptDeactivate
    # add to user modules if --user enabled
    if userEnabled:
      var userModules = readUserInstalledModules()
      userModules.incl &"{category}@{resultingVersion}"
      writeUserInstalledModules userModules
      writeSuccess("Installed: ", &"Restart your shell to enable {category}@{resultingVersion}\n           Or type: source " & (getHomeDir() / ".aelm" / "activate"))

proc doInfo() =
  if infoArgs.len < 1:
    writeError("Error: ", "info command requires 1 package name")
    quit(1)
  let (category, version, newname) = infoArgs[0].getPackageTriplet
  let repo = loadAelmRepo()
  var module = repo.getAelmModule(category=category, version=version)

  # Unavailable
  if module.unavailable.len.bool:
    writeWarning("Unavailable for this OS:\n", module.unavailable)
    quit(1)
  
  let downloadString = module.downloads.mapIt( "- " & it.url).join("\n").indent(4)

  # TODO add provenance tracking to packages/repo files
  echo &"""

  Package: {module.category}
  Version: {module.version}

{module.description.indent(2)}

  Downloads
{downloadString}

"""

proc doSearch =
  # show all languages and versions
  # expect N arguments of format: cat[@ver]
  let cfg = loadAelmRepo()
  let catvers = getCategoriesAndVersions cfg
  if searchArgs.len < 1:
    for category,versions in catvers.pairs:
      echo category
      echo versions.join("\n").indent(2)
  elif searchArgs.len >= 1:
    let query = searchArgs[0]
    if descriptionEnabled:
      for category in catvers.keys:
        if query in cfg[category].description:
          echo category
          echo cfg[category].description.indent(2)
    else:
      if '@' in query:
        let
          subargs = query.split('@')
          category = subargs[0]
          version = subargs[1]
        echo category
        for knownVersion in catvers.getOrDefault(category, @[]):
          if knownVersion.startsWith version:
            echo &"  {knownVersion}"
      else: # no version specified
        for category in catvers.keys:
          if query in category:
            echo category
            echo catvers.getOrDefault(category, @[]).join("\n").indent(2)

proc doAdd =
  # if no Add arguments given, perform search instead
  if addArgs.len < 1:
    doSearch()
    quit(1)
  if prefer_systemEnabled and prefer_systemArgs.len == 0:
    writeError("Error: ", "--prefer-system 1 argument expected")
    quit(1)
  if prefer_systemEnabled and addArgs.len > 1:
    writeError("Error: ", "Use add command one name at a time to use --prefer-system")
    quit(1)
  # perform repo file additions if first argument is repo file
  # otherwise perform normal aelm add commands
  let repoFileSpecified = addArgs[0].fileExists or addArgs[0].startsWith("http")
  if repoFileSpecified:
    let prefer_system_list = prefer_systemArgs . join("") . replace(';',',') . split(',') . filterIt(it.len.bool)
    for filePath in addArgs:
      addModule("", "", "", prefer_system_list, repofile = filePath)
    quit(0)

  # default to normal aelm module add
  for (category, version, nickname) in addArgs.mapIt it.getPackageTriplet:
    let prefer_system_list = prefer_systemArgs . join("") . replace(';',',') . split(',') . filterIt(it.len.bool)
    addModule(category, version, nickname, prefer_system_list)

proc doRemove =
  # expect up to 2 arguments
  if removeArgs.len < 1:
    # no search arguments given, perform search instead
    doList()
    quit(1)
  let namever = removeArgs[0]
  if removeArgs.len > 2:
    writeError("Error: ", "Too many arguments.")
    quit(1)

  let fullPath = block:
    if userEnabled: getHomeDir() / ".aelm" / namever
    else: getCurrentDir() / namever
  # verify removal target is an aelm module
  discard loadAelmModule fullPath

  if userEnabled:
    var modules = readUserInstalledModules()
    modules.excl namever
    writeUserInstalledModules modules

  # always remove module dir AFTER updating installed modules above
  try:
    removeDir fullPath
    echo &"removed '{fullPath}'"
  except OSError:
    writeError("Error: ", &"removal failed for '{fullPath}'")
    quit(1)

proc doExec =
  # first we process environment variables
  # concatenating ".*PATH" vars (PYTHONPATH, RUST_PATH, etc.)
  # preferring existing environment contents if it exists
  # We also set the PATH according to the module
  # then we run the executable command
  if execArgs.len < 2:
    writeError("Error: ", "Need 2 arguments: <aelm-module> <command>\n       (quote command for complex commands with switches)")
  let
    envPath = execArgs[0].dup(normalizePath)
    envParentPath = envPath.splitPath.head
    env = loadAelmModule envPath
    cmd = block:
      when not defined(windows): execArgs[1..^1].join(" ")
      else: "powershell -c \"" & execArgs[1..^1].join(" ") & "\""
      #else: "cmd /c "          & execArgs[1..^1].join(" ")
  addPathAndEnvvarsFromPath envPath
  for connection in env.connections:
    addPathAndEnvvarsFromPath(envParentPath / connection)
  try:
    let result = execCmd(cmd)
    quit(0)
  except OSError as e:
    writeError("Error: ", e.msg)
    quit(1)

proc doConnect =
  if connectArgs.len <= 1:
    writeError("Error: ", &"Connect requires more arguments")
    quit(1)
  let
    allDirs = connectArgs
    dstDirs = connectArgs[1..^1]
    srcName = connectArgs[0].normalizedPath.splitPath.tail
  # validate directories
  var hadInvalidArguments = false
  for dir in allDirs:
    if (not dirExists dir) or (not fileExists (dir / CONF_MOD_FILENAME)):
      writeError("Error: ", &"'{dir}' is not a valid aelm environement")
      hadInvalidArguments = true
  if hadInvalidArguments:
    quit(1)
  # add srcName to each dstDir connection list
  for dstDir in dstDirs:
    var env = loadAelmModule dstDir
    if srcName notin env.connections:
      env.connections.add srcName
    let configFileName = dstDir / CONF_MOD_FILENAME
    writeFile configfileName, $env

proc doDisconnect =
  if disconnectArgs.len <= 1:
    writeError("Error: ", &"Disconnect requires more arguments")
    quit(1)
  let
    allDirs = disconnectArgs
    dstDirs = disconnectArgs[1..^1]
    srcName = disconnectArgs[0].normalizedPath.splitPath.tail
  # validate directories
  var hadInvalidArguments = false
  for dir in allDirs:
    if (not dirExists dir) or (not fileExists (dir / CONF_MOD_FILENAME)):
      writeError("Error: ", &"'{dir}' is not a valid aelm environement")
      hadInvalidArguments = true
  if hadInvalidArguments:
    quit(1)
  # remove srcName from each dstDir connection list
  for dstDir in dstDirs:
    var env = loadAelmModule dstDir
    env.connections.keepItIf(it != srcName)
    let configFileName = dstDir / CONF_MOD_FILENAME
    writeFile configfileName, $env

proc doClearCache =
  let cache = appCacheDir()
  let sizes = collect:
    for (kind,filePath) in walkDir cache:
      if kind == pcFile:
        getFileSize filePath
  let filecount = len sizes
  let total = sizes.foldl(a + b) div (1_024*1_024)
  removeDir cache
  if total < 1_024: echo &"{total} MB removed ({filecount} files)"
  else: echo &"{total div 1_024} GB removed ({filecount} files)"

proc doScript() =
  # error checking
  if scriptArgs.len < 1:
    writeError("Error: ", &"missing argument for path to script file.")
    quit(1)
  if not fileExists scriptArgs[0]:
    writeError("Error: ", &"script file '{scriptArgs[0]}' not found.")
    quit(1)
  echo &"running aelmscript {scriptArgs[0]}"
  let script = scriptArgs[0].readFile
  runAelmScriptCommands script

proc doCreatePackage =
  const contentTemplate = """
# example of all other optional fields - normally unnecessary 
# $name:
#   versions:
#     latest:
#       windows:
#         prefer_system: ['$name']
#         binpaths: ['{root}/bin']
#         downloads:
#           - url: https://...
#             name: file.zip
#             uncompress: true
#         setup: mv {root}/bin/win-$name.exe {root}/bin/$name.exe
#         testcmd: '{root}/bin/$name.exe --version'
#         envvars:
#           MYTOOL_LIB: '{root}/lib'
#         aelmscript: |
#           aelm add cmake
#           echo "finished with $name dependencies"
#         ...
#       linux:
#         ...

$name:
  # this name is guessed as the executable name for this package, too.
  description: |
    "The description is usually a quote from the software website,
     followed by an attribution of the software site & quote location."
    - https://some/place
  versions:
    # template only inclues a single version, but you can have many
    # the 'latest' or highest version number is used for inferrence when auto
    latest:
      # We can usually infer everything necessary from only a github repo url
      auto: https://github.com/someUser/someProject
"""
  let name = packageArgs[1]
  let content = contentTemplate % ["name", name]
  fmt"{getCurrentDir() / name}.aelm.yaml".writeFile content
  writeSuccess("Created package ", &"{getCurrentDir() / name}.aelm.yaml")

proc findExesInDir(path: string): seq[string] =
  for file in walkDirRec(path, {pcFile}):
    if fpUserExec in file.getFilePermissions:
      result.add file

proc testExesWithCommand(paths: seq[string], testcmd: string): bool =
  for exeFilePath in paths:
    const COMMON_COMMANDS = [" --version", " version", " --help"]
    let testCommands = block:
      if testcmd.len.bool: @[testcmd]
      else: COMMON_COMMANDS.mapIt(exeFilePath & it)
    for command in testCommands:
      let outcome = execCmdEx(command, workingDir = exeFilePath.parentDir)
      if outcome.exitCode == 0:
        return true

proc doCheckPackage =
  let name = packageArgs[1].dup(removeSuffix(".aelm.yaml")) & ".aelm.yaml"
  let path = getCurrentDir() / name
  if not fileExists path:
    writeError("Error: ", &"No file named '{name}'")
    quit(1)
  let repo = helperLoadAelmRepo path 
  stdout.styledWriteLine "Package format ", fgGreen, "OK"
  if checkDownloadsEnabled:
    let TestDir = appCacheDir() / "dltest"
    let catvers = getCategoriesAndVersions repo
    # prepare dltest dir
    try:
      removeDir TestDir
      createDir TestDir
    except OSError as e:
      writeError("Error: ", &"Could not clear or create directory '{TestDir}'")
      echo e.msg
      quit(1)
    for category,versions in catvers:
      for version in versions:
        echo &"checking downloads for {category}@{version}"
        var module = repo.getAelmModule(category=category, version=version)
        module.root = TestDir
        module.name = category
        expandPlaceholders module
        let aelmModConfName = TestDir / CONF_MOD_FILENAME
        writeFile aelmModConfName, $module
        runAelmDownloadsAndExpandAuto module
        expandPlaceholders module
        runAelmSetupCommands module
        # check DLs
        stdout.styledWriteLine &"{category}@{version} downloads ", fgGreen, "OK"
        # check binpaths
        var foundExe = not module.binpaths.len.bool
        var exeNames: seq[string]
        var exePaths: seq[string]
        for binpath in module.binpaths:
          if binpath.len == 0: continue
          let originalDir = getCurrentDir()
          setCurrentDir binpath
          if findExe(&"./{category}").startsWith("./"):
            foundExe = true
            exePaths.add (getCurrentDir() / category)
          if not foundExe:
            for exe in findExesInDir binpath:
              exePaths.add exe
              exeNames.add exe.extractFilename
          setCurrentDir originalDir
        if foundExe:
          stdout.styledWriteLine &"{category}@{version} binpaths ", fgGreen, "OK"
        elif exeNames.len.bool:
          stdout.styledWriteLine &"{category}@{version} binpaths ", fgGreen, "OK", " (", exeNames.join(","), ")"
        else:
          stdout.styledWriteLine fgYellow, &"{category}@{version} executables NOT FOUND in bin paths (maybe this is okay?)"
        # version test
        let testCommandSuccess = testExesWithCommand(exePaths, module.testcmd)
        if testCommandSuccess:
          stdout.styledWriteLine &"{category}@{version} exe test ", fgGreen, "OK"
        else:
          stdout.styledWriteLine &"{category}@{version} exe test ", fgRed, "FAILED"
    try:
      removeDir TestDir
    except OSError as e:
      writeError("Error: ", &"Could not clear directory '{TestDir}'")
      echo e.msg
      quit(1)

proc doPackage =
  if packageArgs.len < 2:
    writeError("Error: ", &"expected 2 arguments for package command.")
    echo "       aelm package create <name>"
    echo "       aelm package verify <name>"
    quit(1)
  case packageArgs[0].toLower:
    of "create","new","c","n": doCreatePackage()
    of "verify","ver","v","check","chk": doCheckPackage()
    else:
      writeError("Error: ", &"Unknown package subcommand '{packageArgs[0]}'")
      quit(1)

const HELPSTR = """
aelm - Adequate Environment and Language Manager

Usage:
  aelm [SUBCMD]  [options & parameters]
  aelm (no arguments triggers streaming script mode)
where [SUBCMD] is one of:
  help [SUBCMD]               (h) print help, or get help for another SUBCMD
  list                        (ls) list all aelm modules in CWD
  init [URIs...]              (i) Downloads default repo and others to CWD
    --user                    Downloads repo in home dir
  add <envname>[:newname]     (a) Add a new environment or language by name
                              or by specifying a single module .aelm.yaml
                              local or remote file.
    --prefer-system <name>,   Do not install if <name>s exists in PATH
    --user                    Install in home directory
    --ignore-system           Ignores and --prefer-system settings
  remove <envname@version>    (rm) Remove a environment or language
    --user                    Remove from home directory
  search <envname>[@version]  (s) Search environments and languages
    --description             Search description fields instead of names
  exec <envdir> <command>     (x) Execute a command in a specified env dir
                              or language module (ex: python --version)
  connect <env1> <env2>...    (c) Add path and env vars of envdir1 to envdir2
  disconnect <env1> <env2>... (d) Remove path and envvars of env1 from env2
  script <scriptfile>         (sc) Runs aelm commands (no `aelm` prefix)
  package                     (pkg,p)
    create <name>             (c,new,n) Create new blank package template
    verify <name>             (ver,v) Verify package integrity and syntax
      --dl                    Test all package downloads and check bin paths
  info <envname>[@version]    Show detailed package information

  refresh  alias of init

Options:
  -h --help       Show this screen
  --version       Show version
  --clear-cache   Clear the download cache

Examples:
  aelm help search
  aelm search python
  aelm add python:pylatest
  aelm exec pylatest python --version
  aelm add nim --user
"""
const HELPADD = """
add <envname>[@version][:newname] [options]
(aliases: a)
Add a new environment or language named <envname>
optionally of version @version.

example:
  aelm add python:py

Creates a new directory `py` in the current location,
and installs the latest python available into that location,
because no specific version was specified.

example:
  aelm add python@3.10.3
  aelm add python

The first command creates a new directory `python@3.10.3`
in the current location, and installs python 3.10.3 into that location.
The second command does the same thing, if 3.10.3 is latest available.

options:
  --prefer-system <name>,...
    name: Comma separated list of possibly installed executable names
          to check for and prefer instead of installing this module.
          Only functions when adding only 1 environment at a time.
    example: add cmake --prefer-system CMake,cmake

  --user
    Install persistently for the current user into $HOME/.aelm/
    Custom names (:newname) are ignored when using --user
    example: add cmake python --user
"""
const HELPREMOVE = """
remove <envname> [--user]
(aliases: rm)
Removes an environment or languaged named <envname>

example:
  aelm add python latestPython
  aelm remove latestPython
  aelm add python --user
  aelm remove python --user

options:
  --user
    removes an installation from $HOME/.aelm/
"""
const HELPLIST = """
list [directory]
(aliases: ls)
Lists all the aelm environments and languages in the current working directory.
Optionally, list aelm environments in a specific directory other than CWD.
"""
const HELPINIT = """
init [URIs...]
(aliases: refresh, i)
Downloads the latest repository information and stores it locally as .aelm.yaml
This file also acts as a flag so you know this is an aelm-capable directory.
Init is a separate step so you have the option to edit the file to your liking
or verify what will run. Multiple URIs can be specified on the local system
or remote http and they will be aggregated into the local repository.

options:
  --user
    Downloads the repository to the home directory
    %HOME%/.aelm/.aelm.yaml on windows
    ~/.aelm.aelm.yaml on other systems

  alias i
"""
const HELPSEARCH = """
search <envname>[@version]
(aliases: s)
Search the repository for a package,
optionally for a specific version.

example:
  aelm search python
  aelm search python@3.10.3
  aelm search python@3

options:
  --description
    Instead searches the package description field and shows matching descriptions
"""
const HELPINFO = """
info <envname>[@version]
(aliases: inf)
Show detailed information for an package.

example:
  aelm info python
"""
const HELPEXEC = """
exec <envdir> <command>
(aliases: x)
Executes the command <command> in the environment <envdir>

example:
  aelm add python@3.10.3 py310
  aelm exec py310 python -c "print('python works fine.')"
  aelm exec py310 pip install numpy
"""
const HELPCONNECT = """
connect <srcEnvDir> <targetEnvDir...>
(aliases: c)
Adds the exec path and env vars of <srcEnvDir> to <targetEnvDir>s, persistently.

example:
  aelm connect mypython mynim myzig

Enables mynim and myzig to "see" and run python in mypython.
Technically, the python path and env vars are added to the
mynim and myzig environments.

Note: you can only connect environments that share the same aelm initialization
(parent dir).
"""
const HELPDISCONNECT = """
disconnect <srEnvDir> <targetEnvDir...>
(aliases: d)
Removes the exec path and env vars of <srcEnvDir> from <targetEnvDir>s, persistently.

example:
  aelm disconnect mypython mynim myzig

Disables mynim and myzig from "seeing" the python environment.
Technically, the path and env vars of python are removed from
the other environments.
"""
const HELPSCRIPT = """
script <file>
(aliases sc)
Runs a collection of aelm commands in <file>, 1 per line.
This file can also contain system commands, 1 per line
in standard posix /forward/slash format for paths.
Windows compatibility relies on PowerShell (included since win7)

example:
  aelm script project-setup.as

project-setup.as contents:
aelm add python py
aelm add zig cpp
aelm connect cpp py
aelm exec py python --version
"""
const HELPPACKAGE = """
aelm package (create|verify) <name>
(aliases: pkg, p)

aelm package create <name>
(create aliases: c, new, n)
Creates a template aelm package named <name>.aelm.yaml

aelm package verify <name>
(verify aliases: ver, v, check, chk)
Attempts to load <name> as a package, inspecting for problems.

verify options:
  --dl
    Download all files for all versions and check:
      * extraction (if necessary)
      * bin paths hold the expected binaries
      * a test command passes (any of: version, --version, --help)
    You can override `testcmd` in yaml with full path and command
"""
const HELP_INDEX = {
  "":HELPSTR,
  "add":HELPADD,
  "list":HELPLIST,
  "init":HELPINIT,
  "remove":HELPREMOVE,
  "search":HELPSEARCH,
  "exec":HELPEXEC,
  "connect":HELPCONNECT,
  "disconnect":HELPDISCONNECT
  }.toTable

when isMainModule:
  # parse the command line options
  var p = initOptParser(commandLineParams())
  p.next()
  while true:
    case p.kind:
      of cmdEnd: break
      of cmdShortOption, cmdLongOption:
        p.captureArg help: break
        p.captureArg clearTheEntireCache: break
        p.captureArg user: continue
        p.captureArg prefer_system: continue
        p.captureArg ignore_system: continue
        p.captureArg description: continue
        p.captureArg check_downloads: continue
        p.captureArg prefer_system: continue
        writeError("Error: ",&"Unknown option '{p.key}'")
        quit(1)
      of cmdArgument:
        p.captureArg help: break
        p.captureArg init: continue
        p.captureArg list: break
        p.captureArg add: continue
        p.captureArg remove: continue
        p.captureArg search: continue
        p.captureArg info: break
        p.captureArg exec: break
        p.captureArg connect: break
        p.captureArg disconnect: break
        p.captureArg script: continue
        p.captureArg package: continue
        writeError("Error: ",&"Unknown command '{p.key}'")
        quit(1)
  if helpEnabled:
    if helpArgs.len > 0:
      if helpArgs[0] in HELP_INDEX:
        echo HELP_INDEX[helpArgs[0]]
        quit(0)
      else:
        writeError("Error: ",&"Unknown subcommand '{helpArgs[0]}'")
        quit(1)
    echo HELP_INDEX[""]
    quit(0)
  if initEnabled: doInit()
  if addEnabled: doAdd()
  if removeEnabled: doRemove()
  if execEnabled: doExec()
  if listEnabled: doList()
  if searchEnabled: doSearch()
  if infoEnabled: doInfo()
  if connectEnabled: doConnect()
  if disconnectEnabled: doDisconnect()
  if clearTheEntireCacheEnabled: doClearCache()
  if scriptEnabled: doScript()
  if packageEnabled: doPackage()

  # STDIN piping/streaming mode for aelmscript
  if commandLineParams().len == 0:
    var script: string
    var line: string
    while true:
      let readOK = readLineFromStdin("", line)
      if not readOK: break # (also ^C or ^D)
      if line.len == 0: continue
      script.add line
    runAelmScriptCommands script
