import starRouter
import starintel_doc except Message
import fedi
import json
import lrucache
import asyncdispatch
import httpcore
import httpclient
import deques, asyncdispatch
import times
import tables
import strformat
import strutils
import cligen
import md5
import std/[logging, options, net]
import fediwatchpkg/documents
from os import getEnv
type
  FediWatch = ref object
    client: AsyncFediClient
    config: Target
    lastMessage: string
    t: int64
  FediWatchConfig = object
    logpath: string
    logLevel: string
  ResourcePool*[T] = ref object
    resources: Deque[T]
    queuers: Deque[Future[T]]

  AsyncHttpClientPool* = ResourcePool[AsyncHttpClient]
proc dequeue*[T](pool: ResourcePool[T]): Future[T] =
  result = newFuture[T]("dequeue")
  if pool.resources.len == 0:
    pool.queuers.addLast result
  else:
    result.complete pool.resources.popFirst()

proc enqueue*[T](pool: ResourcePool[T], item: T) =
  if pool.queuers.len > 0:
    let fut = pool.queuers.popFirst()
    fut.complete(item)
  else:
    pool.resources.addLast(item)



proc verifiedHttpClient(userAgent = "fediWatch"): AsyncHttpClient =
  newAsyncHttpClient(userAgent=userAgent, sslContext=newContext(verifyMode=CVerifyPeerUseEnvVars))

proc observedFediClient(host: string, token = "", userAgent = "fediWatch"): AsyncFediClient =
  let client = verifiedHttpClient(userAgent)
  client.headers = newHttpHeaders({"Accept": "application/json", "Content-Type": "application/json"})
  if token.len > 0: client.headers["Authorization"] = "Bearer " & token
  AsyncFediClient(baseUrl: normalizeHost(host), hc: client)

proc newAsyncHttpClientPool*(size: int): AsyncHttpClientPool =
  result.new()
  for i in 1..size: result.enqueue(verifiedHttpClient())


const USER_AGENT =  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"


proc filterTarget(doc: proto.Message[Target]): bool =
  if doc.typ == EventType.newDocument:
    return doc.data.actor == "fediwatch"


# NOTE maybe the client should be set from a resource pool?
proc initAsyncFedi*(target: Target): AsyncFediClient =
  let token = target.options.get(newJObject()){"auth"}.getStr("")
  let ua = target.options.get(newJObject()){"ua"}.getStr(USER_AGENT)
  result = observedFediClient(host=target.target, token = token, userAgent=ua)


proc initFediWatch*(target: Target): FediWatch =
  result = FediWatch(lastMessage: "", config: target, client: initAsyncFedi(target))

proc parseFediuser*(user: string): (string, string) =
  result = splitAccount(user)


proc getHttpClient(pool: AsyncHttpClientPool): Future[AsyncHttpClient] {.async.} =
  var client = await pool.dequeue()
  return client


proc checkUser(client: AsyncHttpClient, username: string): Future[bool] {.async.} =
  let resp = await client.get(username.webfingerUser("https"))
  if resp.code == Http200:
    result = true


proc getUserInfo(client: AsyncFediClient, username: string): Future[JsonNode] {.async.} =
  result = await client.lookupAccount(username)



proc handleUser(routerClient: Client, httpClient: AsyncHttpClient,  checkCache: LruCache[string, bool], userCache: LruCache[string, JsonNode], target: Target, log: FileLogger) {.async.} =
  # Handles the incoming user targets
  var
    userExists = false
    fedi: AsyncFediClient
  # TODO insert debug log
  if checkCache.contains(target.target):
    userExists = checkCache[target.target]
  else:
    userExists = await httpClient.checkUser(target.target)

  # TODO insert debug log
  checkCache[target.target] = userExists

  let
    userData = parseFediuser(target.target)
    domain = userData[1]
    username = userData[0]
    # User exists, lets procced.
  if userExists:
    let url = fmt"https://{domain}"
    var resp: JsonNode
    if userCache.contains(target.target):
      resp = userCache[target.target]
    else:
      fedi = observedFediClient(host=url, token=target.options.get(newJObject()){"auth"}.getStr(""))
      resp = await fedi.getUserInfo(username)
      userCache[target.target] = resp
    let doc = parseUser(resp, target.dataset)
    await routerClient.emit(doc.newMessage(EventType.newDocument, routerClient.id, "user"))


proc processFeed(fw: FediWatch, routerClient: Client,  log: FileLogger) {.async.} =
  log.log(lvlInfo, fmt"getting timeline for: {fw.config.target}")
  let timeline = await fw.client.getTimeline(minId=fw.lastMessage)
  var posts = timeline.getElems
  log.log(lvlInfo, fmt"got {posts.len} posts for {fw.config.target}")
  for data in posts:
    let documents = timelineDocuments(data, fw.config.dataset)
    for document in documents:
      await routerClient.emit(document.newMessage(EventType.newDocument, routerClient.id, document["dtype"].getStr()))
    fw.lastMessage = data["id"].getStr("")

proc processTimelines(routerClient: Client, fw: seq[FediWatch], log: FileLogger, t: int64) {.async.} =
  var futures: seq[Future[void]]
  if now().toTime().toUnix() >= t:
    for client in fw:
      let fut = (client.processFeed(routerClient, log))
      futures.add(fut)
      yield fut
    for fut in futures:
      try:
         await fut
      except Exception:
         log.log(lvlError, getCurrentExceptionMsg())
proc userLoop(routerClient: Client, log: FileLogger) {.async.} =
  var
    routerClient = routerClient
    inbox = Target.newInbox(100)
    httpPool = newAsyncHttpClientPool(10)
    checkCache = newLruCache[string, bool](100)
    userCache = newLruCache[string, JsonNode](100)
    fedis: seq[FediWatch]
    log = log
  proc handleTarget(doc: proto.Message[Target]) {.async.} =
    let
      target = doc.data
      typ = target.options.get(newJObject()){"typ"}.getStr("")
    var client = await httpPool.getHttpClient()
    defer: httpPool.enqueue(client)
    case typ:
      of "User":
        await routerClient.handleUser(client, checkCache, userCache, target, log)
      of "Domain":
        fedis.add(initFediWatch(target))
    log.log(lvlInfo, fmt"Got Target type: {typ}")
    log.log(lvlInfo, fmt"Target:{target.target}")
  inbox.registerCB(handleTarget)
  inbox.registerFilter(filterTarget)
  var last = now().toTime().toUnix()
  Target.withInbox(routerClient, inbox):
    try:
      await processTimelines(routerClient, fedis, log, last)
      # Lets be kind, wait a second before sending another batch
      last = now().toTime().toUnix() + 1
    except Exception:
      log.log(lvlError, getCurrentExceptionMsg())

proc main(apiAddress: string = "tcp://127.0.0.1:6001", subAddress: string = "tcp://127.0.0.1:6000") =
  let level = parseEnum[Level](getEnv("FEDIWATCH_LOG_LEVEL", "lvlInfo"))
  var log = newFileLogger(filename=getEnv("FEDIWATCH_LOG", "fediWatch.log"), levelThreshold=level)
  log.log(lvlInfo, fmt"starRouter api address: {apiAddress}")
  log.log(lvlInfo, fmt"starRouter pub/sub address: {subAddress}")
  # TODO Limit topics to fediwatch or related object types.
  var client = newClient("fediwatch", subAddress, apiAddress, 10_000, @["fediwatch"])
  waitFor client.connect()
  echo "FediWatch connected to StarRouter"
  stdout.flushFile()
  waitFor client.userLoop(log)

when isMainModule:
  dispatch main


