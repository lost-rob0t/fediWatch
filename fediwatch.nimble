# Package

version     = "1.0.0"
author      = "nsaspy"
description = "Monitor Mastodon and emit StarIntel 0.9 documents"
license     = "AGPL-3.0-only"
srcDir      = "src"
bin         = @["fediWatch"]

# Dependencies

requires "nim >= 2.2.0"
requires "https://github.com/lost-rob0t/fedi#ac234e1848695532838a65a01ca5b1bfa9e8289e"
requires "https://github.com/lost-rob0t/starintel-doc.nim#b4124c586efa1393c1cf1afb94e10058cfb58b17"
requires "https://github.com/Q-Master/rabbitmq.nim#a09bd58087dcb1fa704259191c65a01e6fd9c0a1"

task test, "Run unit tests":
  exec "nim c -r --path:src tests/test_documents.nim"

task buildRelease, "Build release binary":
  exec "nim c -d:release --path:src src/fediWatch.nim"
