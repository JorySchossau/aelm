#mode = ScriptMode.Silent

setCommand "c"

when defined(xwindows) and not defined(norecurse):
  setCommand ""
  echo "================================"
  echo "=  Cross-Compiling to Windows  ="
  echo "================================"
  switch("define", "cputype=x86_64")
  selfExec "c -f -d:cputype=x86_64 -d:xwindows -d:norecurse --os:windows -d:mingw --amd64.windows.gcc.path=zig/zig --amd64.windows.gcc.exe=gcc-win --amd64.windows.gcc.linkerexe=gcc-win -d:release -f -d:debug -l:-s -t:-flto -o:aelm.exe --opt:size src/aelm.nim"
  quit(0)

elif defined(windows) and not defined(xwindows) and not defined(norecurse):
  echo "=========================="
  echo "=  Compiling to Windows  ="
  echo "=========================="
  switch("cc","vcc")
  switch("define","norecurse")
  if buildCPU == "amd64": switch("define", "cputype=x86_64")
  else:
    echo "OS " & buildCPU & " not supported for windows"
    quit(1)

elif defined(linux) or defined(osx) and not defined(norecurse):
  echo "============================"
  echo "=  Compiling to Linux/OSX  ="
  echo "============================"
  when defined(m1):
    switch("define", "cputype=arm")
  elif buildCPU == "amd64": switch("define", "cputype=x86_64")
  elif buildCPU == "arm64": switch("define", "cputype=arm")
  else:
    echo "OS " & buildCPU & " not supported"
    quit(1)
