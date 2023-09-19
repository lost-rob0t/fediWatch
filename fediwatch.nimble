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
requires "mycouch"
requires "cligen"

requires "https://github.com/lost-rob0t/fedi.git"
requires "https://github.com/lost-rob0t/starintel-doc.nim"
requires "https://github.com/lost-rob0t/starRouter.git"
