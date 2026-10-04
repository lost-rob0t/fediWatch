# Package

version     = "0.3.0"
author      = "nsaspy"
description = "Watch the entire fediverse and emite starintel messages."
license     = "LGPL"
srcDir       = "src"
bin = @["fediWatch"]
# Deps

requires "nim >= 2.0.0"
requires "cligen"
requires "https://github.com/jackhftang/lrucache.git#1c2eede7e2fbe05b0498537a6f82be8063e093d6"
requires "https://github.com/lost-rob0t/fedi.git#d6a3d7f7674e35677f5a529f9b0e8e332b198602"
requires "https://github.com/lost-rob0t/starintel-doc.nim.git#827f2c072e9893561a1925c47f898458bafd6759"
requires "https://github.com/lost-rob0t/starRouter.git#20e5c9e8bf49660fd230d8e7306dd9209648f6e9"
