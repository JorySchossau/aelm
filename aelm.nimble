# Package

version       = "0.1.0"
author        = "Jory Schossau"
description   = "AELM: Advanced Environment and Language Manager"
license       = "MIT"
srcDir        = "src"
bin           = @["aelm"]


# Dependencies
requires "nim >= 1.6.4"
requires "yaml >= 0.16.0"
requires "zstd >= 0.5.0"
requires "zippy >= 0.9.7"

switch("define","release")
switch("stackTrace")
switch("define","ssl")
switch("passL","-s")
switch("gcc","arc")
switch("opt","size")
when defined(linux) or defined(osx):
  if buildCPU == "amd64":
    switch("cputype", "x86_64")
  elif buildCPU == "arm64":
    switch("cputype", "arm")
  else:
    echo "OS " & buildCPU & " not supported"
    quit(1)
when defined(windows):
  if buildCPU == "amd64":
    switch("cputype", "x86_64")
  else:
    echo "OS " & buildCPU & " not supported for windows"
    quit(1)

#mode = ScriptMode.Silent
#task other, "Other task":
#  echo " >>>>>>>> other  <<<<<<<<<<<<<<<"
#
#task biuld, "Build task":
#  echo " >>>>>>>> build  <<<<<<<<<<<<<<<"

#task build, "Build AELM":
#  echo " >>>>>>>> build  <<<<<<<<<<<<<<<"
#  switch("define","release")
#  switch("stackTrace")
#  switch("define","ssl")
#  switch("passL","-s")
#  switch("gcc","arc")
#  switch("opt","size")
#  when defined(windows):
#    if buildCPU == "amd64":
#      switch("cputype", "x86_64")
#    else:
#      echo "OS " & buildCPU & " not supported for windows"
#      quit(1)
#    #selfExec "c -d:cputype=" & cputype & " -d:release --stackTrace:on -d:ssl -l:-s --gc:arc --opt:size src/aelm.nim"
#  elif defined(linux) or defined(osx):
#    switch("passC","-flto")
#    if buildCPU == "amd64":
#      switch("cputype", "x86_64")
#    elif buildCPU == "arm64":
#      switch("cputype", "x86_64")
#    else:
#      echo "OS " & buildCPU & " not supported"
#      quit(1)
#    #echo "nim c -d:cputype=" & cputype & " -d:release --stackTrace:on -d:ssl -l:-s -t:-flto --gc:arc --opt:size src/aelm.nim"
#    #selfExec "c -d:cputype=" & cputype & " -d:release --stackTrace:on -d:ssl -l:-s -t:-flto --gc:arc --opt:size src/aelm.nim"
