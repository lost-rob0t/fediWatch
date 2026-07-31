import std/asyncdispatch

import fediwatch/service


proc main() =
  try:
    waitFor run()
  except CatchableError:
    stderr.writeLine("fediWatch fatal: " & getCurrentExceptionMsg())
    quit(1)


when isMainModule:
  main()
