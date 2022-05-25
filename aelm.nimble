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
requires "zstd >= 0.5.0"
requires "zippy >= 0.9.7"
