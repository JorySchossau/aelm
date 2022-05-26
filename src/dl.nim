from puppy import fetch, PuppyError

proc syncDownload*(url, file: string) =
  echo "downloading " & url
  echo "saving to " & file
  try:
    let content = fetch(url)
    file.writeFile content
  except PuppyError as e:
    echo e.msg
    quit(1)

when isMainModule:
  if os.paramCount() != 2:
    quit "Usage: dl <url> <file>"
  else:
    syncDownload(os.paramStr(1), os.paramStr(2))
