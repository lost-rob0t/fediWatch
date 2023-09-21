# Package

version     = "0.3.0"
author      = "nsaspy"
description = "Watch the entire fediverse and emite starintel messages."
license     = "LGPL"
srcDir       = "src"
bin = @["fediWatch"]
# Deps

requires "nim >= 1.6.0", "mycouch", "cligen", "lrucache", "morelogging", "https://github.com/lost-rob0t/fedi.git", "https://github.com/lost-rob0t/starintel-doc.nim == 0.6.0", "https://github.com/lost-rob0t/starRouter.git"
