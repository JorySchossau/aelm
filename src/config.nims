mode = ScriptMode.Silent

switch("define","release")
switch("define","danger")
switch("stackTrace") # better bug reports for +20kB
switch("gc","arc")
switch("define","ssl")
switch("opt","size")
switch("passL","-s")

setCommand "c"

when defined(windows):
  if buildCPU == "amd64": switch("define", "cputype=x86_64")
  else:
    echo "OS " & buildCPU & " not supported for windows"
    quit(1)

elif defined(linux) or defined(osx):
  switch("passC","-flto")
  if   buildCPU == "amd64": switch("define", "cputype=x86_64")
  elif buildCPU == "arm64": switch("define", "cputype=arm")
  else:
    echo "OS " & buildCPU & " not supported"
    quit(1)