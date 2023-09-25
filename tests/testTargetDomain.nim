
import starRouter
import cligen
import strformat
from starintel_doc import Target, newTarget
import asyncdispatch, json, jsony
proc echoUsername*[T](doc: Message[T]) {.async.} =
  echo doc.data.username
  echo doc.data.dataset

proc testFilter[T](doc: T): bool =
  result = true

proc send(client: Client, domain: string) {.async.} =
  let target = newTarget("fedi", fmt"https://{domain}", "fediwatch", options = %*{"typ": "Domain"})
  await client.emit(target.newMessage(EventType.target, client.id, "fediwatch"))
  await sleepAsync(15)

proc main(targetList: string = "instances.txt") =
  var client = newClient("targetDomain", "tcp://127.0.0.1:6000", "tcp://127.0.0.1:6001", 10, @[""])
  waitFor client.connect
  let f = open(targetList, fmRead)
  defer: f.close
  for line in f.lines:
    waitFor client.send(line)
dispatch main
