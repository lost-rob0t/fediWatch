# Package

version     = "0.2.0"
author      = "nsaspy"
description = "Parse and handle starintel docs"
license     = "MIT"
srcDir       = "src"
bin = @["fediWatch"]
# Deps

requires "nim >= 1.6.0"
requires "uuids >= 0.1.11"
requires "jsony"
requires "isaac"
requires "https://gitlab.nobodyhasthe.biz/nsaspy/starintel-doc-nim.git"
requires "mycouch"
requires "https://gitlab.nobodyhasthe.biz/nsaspy/fedi_nim.git"
requires "cligen"
requires "shabbo"
