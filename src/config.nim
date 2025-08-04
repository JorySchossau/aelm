import yaml, streams
from yaml/parser import YamlParserError
from yaml/data import YamlLoadingError
import macros
import std/[json, sequtils, strutils, tables, strformat, os, osproc, sets, algorithm, streams]
from puppy import fetch, PuppyError
from terminal import styledWriteLine, resetStyle, fgGreen, fgYellow, fgRed, styleDim, styleBright

type
  Download* = object
    url* {.defaultVal: ""}: string
    name* {.defaultVal: ""}: string
    uncompress* {.defaultVal: true.}: bool
  AelmModule* = object
    # used only in module dir
    auto* {.defaultVal: ""}: string
    testcmd* {.defaultVal: ""}: string
    name* {.defaultVal: ""}: string
    category* {.defaultVal: ""}: string
    version* {.defaultVal: ""}: string
    root* {.defaultVal: ""}: string
    connections* {.defaultVal: @[]}: seq[string] # used only in module config
    aelmscript* {.defaultVal: ""}: string
    binpaths* {.defaultVal: @[]}: seq[string]
    unavailable* {.defaultVal: ""}: string
    prefer_system* {.defaultVal: @[]}: seq[string]
    envvars* {.defaultVal: initTable[string, string]()}: Table[string, string]
    downloads* {.defaultVal: @[]}: seq[Download]
    presetup* {.defaultVal: ""}: string
    setup* {.defaultVal: ""}: string
    postsetup* {.defaultVal: ""}: string
    description* {.defaultVal: ""}: string
  AelmOS* = object
    # usual overrides
    auto* {.defaultVal: ""}: string
    root* {.defaultVal: ""}: string
    testcmd* {.defaultVal: ""}: string
    aelmscript* {.defaultVal: ""}: string
    binpaths* {.defaultVal: @[]}: seq[string]
    unavailable* {.defaultVal: ""}: string
    prefer_system* {.defaultVal: @[]}: seq[string]
    envvars* {.defaultVal: initTable[string, string]()}: Table[string, string]
    downloads* {.defaultVal: @[]}: seq[Download]
    presetup* {.defaultVal: ""}: string
    setup* {.defaultVal: ""}: string
    postsetup* {.defaultVal: ""}: string
    description* {.defaultVal: ""}: string
  AelmVersion* = object
    linux* {.defaultVal: nil}: ref AelmOS
    osx* {.defaultVal: nil}: ref AelmOS
    windows* {.defaultVal: nil}: ref AelmOS
    armlinux* {.defaultVal: nil}: ref AelmOS
    armosx* {.defaultVal: nil}: ref AelmOS
    # usual overrides
    auto* {.defaultVal: ""}: string
    root* {.defaultVal: ""}: string
    testcmd* {.defaultVal: ""}: string
    aelmscript* {.defaultVal: ""}: string
    binpaths* {.defaultVal: @[]}: seq[string]
    unavailable* {.defaultVal: ""}: string
    prefer_system* {.defaultVal: @[]}: seq[string]
    envvars* {.defaultVal: initTable[string, string]()}: Table[string, string]
    downloads* {.defaultVal: @[]}: seq[Download]
    presetup* {.defaultVal: ""}: string
    setup* {.defaultVal: ""}: string
    postsetup* {.defaultVal: ""}: string
    description* {.defaultVal: ""}: string
  AelmCategory* = object
    versions* {.defaultVal: initTable[string,AelmVersion]()}: Table[string,AelmVersion]
    # usual overrides
    auto* {.defaultVal: ""}: string
    root* {.defaultVal: ""}: string
    testcmd* {.defaultVal: ""}: string
    aelmscript* {.defaultVal: ""}: string
    binpaths* {.defaultVal: @[]}: seq[string]
    unavailable* {.defaultVal: ""}: string
    prefer_system* {.defaultVal: @[]}: seq[string]
    envvars* {.defaultVal: initTable[string, string]()}: Table[string, string]
    downloads* {.defaultVal: @[]}: seq[Download]
    presetup* {.defaultVal: ""}: string
    setup* {.defaultVal: ""}: string
    postsetup* {.defaultVal: ""}: string
    description* {.defaultVal: ""}: string
  AelmRepo* = Table[string, AelmCategory]

proc writeError*(alert:string="",msg:string="") = 
  stderr.writeLine ""
  styledWriteLine(stderr, fgRed, alert, resetStyle, msg)

proc writeWarning*(alert:string="",msg:string="") = 
  stdout.writeLine ""
  styledWriteLine(stdout, fgYellow, alert, resetStyle, msg)

proc loadAelmRepo*(path: string): AelmRepo = 
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
    writeError("Error: ", &"unable to access file '{path}'")
    quit(1)
  except YamlParserError as e:
    writeError("Error: ", &"invalid or unexpected yaml in '{path}'")
    echo &"\nat or before line {e.mark.line}"
    writeWarning(&"{e.mark.line}:  {e.lineContent}")
    quit(1)
  except YamlLoadingError as e:
    writeError("Error: ", &"invalid or unexpected yaml in '{path}'")
    echo &"\nat or before line {e.mark.line}"
    writeWarning(&"{e.mark.line}:  {e.lineContent}")
    quit(1)
  finally:
    if not isNil stream:
      close stream

proc loadAelmModule*(path: string, confModFilename: string): AelmModule = 
  if not dirExists path:
    writeError("Error: ", &"No aelm module '{path}' exists by that name")
    quit(1)
  if not fileExists joinPath(path, confModFilename):
    writeError("Error: ", &"That does not seem like an aelm module. No {confModFilename} file found in {path}")
    quit(1)
  var module: AelmModule
  try:
    var stream = newFileStream(path / confModFilename, fmRead)
    stream.load module
    close stream
  except IOError:
    writeError("Error: ", &"unable to read file '{path / confModFilename}'")
  except YamlConstructionError as e:
    writeError("Error: ", &"invalid yaml config structure for '{path / confModFilename}'")
    echo &"\nat or before line {e.mark.line}"
    writeWarning(&"{e.mark.line}:  {e.lineContent}")
    quit(1)
  except YamlLoadingError as e:
    writeError("Error: ", &"unable to load yaml for '{path / confModFilename}'")
    echo &"\nat or before line {e.mark.line}"
    writeWarning(&"{e.mark.line}:  {e.lineContent}")
    quit(1)
  return module

macro updateVars*(envA: var untyped, envB: untyped, variables: varargs[untyped]): untyped = 
  result = newStmtList()
  for v in variables: result.add quote do:
      if `envB`.`v`.len.bool: `envA`.`v` = `envB`.`v`

template update*(a:var AelmModule, b: untyped) {.dirty.} = 
  updateVars(envA=a, envB=b, binpaths, root, prefer_system, downloads, presetup, setup, postsetup, aelmscript, testcmd, envvars, description, auto, unavailable)

proc `$`*(env: AelmModule): string = 
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
      if "\n" notin env.postsetup: result.add &"postsetup: |\n{env.postsetup.indent(2)}\n"
  if env.aelmscript.len.bool: result.add &"aelmscript: |\n{env.aelmscript.indent(2)}\n"
  if env.description.len.bool: result.add &"description: |\n{env.description.indent(2)}\n"