# Package

version       = "0.2.0"
author        = "Jory Schossau"
description   = "AELM: Adequate Environment and Language Manager"
license       = "MIT"
srcDir        = "src"
bin           = @["aelm"]


# Dependencies
requires "nim >= 2.0.0"
requires "yaml >= 2.0.0"
requires "zstd >= 0.9.0"
#requires "https://github.com/joryschossau/nim_zstd#fix-mingw-cross-compile"
requires "zippy >= 0.10.11"
requires "puppy >= 2.1.0"
# for dlinfer.nim
requires "q >= 0.0.8"
requires "regex >= 0.23.0"
requires "zip >= 0.3.1"
