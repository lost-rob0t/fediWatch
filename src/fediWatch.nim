import starRouter
import starintel_doc except newMessage
import jsony
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
import morelogging
from logging import Level, LevelNames
from os import getEnv
import zmq
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



proc newAsyncHttpClientPool*(size: int): AsyncHttpClientPool =
  result.new()
  for i in 1..size: result.enqueue(newAsyncHttpClient())


const USER_AGENT =  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"


proc filterTarget(doc: proto.Message[Target]): bool =
  if doc.topic == "fediwatch":
    return true


# NOTE maybe the client should be set from a resource pool?
proc initAsyncFedi*(target: Target): AsyncFediClient =
  let token = target.options{"auth"}.getStr("")
  let ua = target.options{"ua"}.getStr(USER_AGENT)
  result = newAsyncFediClient(host=target.target, token = token, userAgent=ua)


proc initFediWatch*(target: Target): FediWatch =
  result = FediWatch(lastMessage: "", config: target, client: initAsyncFedi(target))

proc parseFediuser*(user: string): (string, string) =
  let data = user.split("@")
  result = (username: data[0], domain: data[1])


proc getHttpClient(pool: AsyncHttpClientPool): Future[AsyncHttpClient] {.async.} =
  var client = await pool.dequeue()
  defer: pool.enqueue client
  return client


proc checkUser(client: AsyncHttpClient, username: string): Future[bool] {.async.} =
  let resp = await client.get(username.webfingerUser("https"))
  if resp.status == Http200:
    result = true


proc getUserInfo(client: AsyncFediClient, username: string): Future[JsonNode] {.async.} =
  result = await client.lookupAccount(username)


proc parseUser*(user: JsonNode, dataset: string): User =
  let
    username = user["username"].getStr()
    url = user["url"].getStr()
  var doc = newuser(userName, platform = "fediverse", url)
  doc.bio = user["note"].getStr
  for extra in user["fields"].getElems:
    doc.misc.add(extra)
  doc.date_added = parseTime(user["created_at"].getStr, "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()).toUnix
  doc.date_updated = now().toTime().toUnix
  doc.dataset = dataset
  doc.setType()
  result = doc


proc handleUser(routerClient: Client, httpClient: AsyncHttpClient,  checkCache: LruCache[string, bool], userCache: LruCache[string, JsonNode], target: Target, log: FileLogger) {.async.} =
  # Handles the incoming user targets
  var
    accountID = 0
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
  if userExists == true:
    # TODO insert debug log
    let url = fmt"https://{domain}"
    var resp: JsonNode
    if userCache.contains(target.target):
      resp = userCache[target.target]
    else:
      fedi = newAsyncFediClient(host=url, token=target.options{"auth"}.getStr(""))
      resp = await fedi.getUserInfo(username)
      userCache[target.target] = resp
      accountId = resp["id"].getInt(0)
      var doc = newuser(resp["username"].getStr(""), domain, resp["url"].getStr(""))
      doc.dateAdded = resp["created_at"].getStr("").parseTime("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()).toUnix
      doc.upDateTime()
      doc.setType()
      for field in resp["fields"].getElems:
        doc.misc.add(field)
        doc.dataset = target.dataset
        # Send the User document off
      await routerClient.emit(doc.newMessage(EventType.newDocument, routerClient.id, "user"))
  # Remove so no leak.



proc processFeed(fw: FediWatch, routerClient: Client,  log: AsyncFileLogger) {.async.} =
  log.info fmt"getting timeline for: {fw.config.target}"
  let timeline = await fw.client.getTimeline(minId=fw.lastMessage)
  var posts = timeline.getElems
  log.info fmt"got {posts.len} posts for {fw.config.target}"
  for data in posts:
    var
      smPost = SocialMPost(dataset: fw.config.dataset)
      user = data["account"].parseUser(fw.config.dataset)

    let replyTo = data["in_reply_to_id"].getStr
    smPost.user = user.name
    smPost.content = data["content"].getStr
    smPost.date_added = parseTime(data["created_at"].getStr, "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()).toUnix
    smPost.date_updated = now().toTime().toUnix()
    smPost.makeMD5ID(data["id"].getStr(smPost.content))
    smPost.setType()
    if replyTo.len != 0:
      smPost.replyTo = $toMD5(replyTo)
    for media in data["media_attachments"].getElems:
      smPost.media.add(media["url"].getStr)
    for tag in data["tags"].getElems:
      let t = tag.getStr("")
      if t.len != 0:
        smPost.tags.add(t)
    # incase its not a int?
    var relation = newRelation(user.id, smPost.id, note = "", dataset=fw.config.dataset)
    relation.setType()
    fw.lastMessage = data["id"].getStr("")
    await routerClient.emit(smPost.newMessage(EventType.newDocument, routerClient.id, "SocialMPost"))
    await routerClient.emit(user.newMessage(EventType.newDocument, routerClient.id, "user"))
    await routerClient.emit(relation.newMessage(EventType.newDocument, routerClient.id, "Relation"))

proc processTimelines(routerClient: Client, fw: seq[FediWatch], log: AsyncFileLogger, t: int64) {.async.} =
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
         log.error(getCurrentExceptionMsg())
proc userLoop(routerClient: Client, log: AsyncFileLogger) {.async.} =
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
      typ = target.options{"typ"}.getStr("")
    var client = await httpPool.getHttpClient()
    case typ:
      of "User":
        await routerClient.handleUser(client, checkCache, userCache, target, log)
      of "Domain":
        fedis.add(initFediWatch(target))
    log.info(fmt"Got Target type: {typ}")
    log.info(fmt"Target:{target.target}")
    log.info(fmt"Target Options: {target.options}")
  inbox.registerCB(handleTarget)
  inbox.registerFilter(filterTarget)
  var last = now().toTime().toUnix()
  Target.withInbox(routerClient, inbox):
    try:
      await processTimelines(routerClient, fedis, log, last)
      # Lets be kind, wait a second before sending another batch
      last = now().toTime().toUnix() + 1
    except Exception:
      log.error(getCurrentExceptionMsg())

proc main(apiAddress: string = "tcp://127.0.0.1:6001", subAddress: string = "tcp://127.0.0.1:6000") =
  let level = parseEnum[Level](getEnv("FEDIWATCH_LOG_LEVEL", "lvlInfo"))
  var log = newAsyncFileLogger(filename_tpl=getEnv("FEDIWATCH_LOG", "$appname.$y$MM$dd.log"), flush_threshold=level)
  log.info fmt"starRouter api address: {apiAddress}"
  log.info fmt"starRouter pub/sub address: {subAddress}"
  # TODO Limit topics to fediwatch or related object types.
  var client = newClient("fediwatch", subAddress, apiAddress, 10_000, @[""])
  client.connect()
  waitFor client.userLoop(log)

when isMainModule:
  dispatch main


