## Dependency-light entrypoint for the same raw mode used by fediWatch.
import fediwatchpkg/raw
when isMainModule:
  quit(rawMain())
