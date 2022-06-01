# Package

version       = "0.1.0"
author        = "Jory Schossau"
description   = "AELM: Adequate Environment and Language Manager"
license       = "MIT"
srcDir        = "src"
bin           = @["aelm"]


# Dependencies
requires "nim >= 1.6.4"
requires "yaml >= 0.16.0"
requires "zstd >= 0.6.0"
#requires "https://github.com/joryschossau/nim_zstd#fix-mingw-cross-compile"
requires "zippy >= 0.9.7"
requires "puppy >= 1.5.3"
