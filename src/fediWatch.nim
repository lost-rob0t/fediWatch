import starintel
import json, jsony
import mycouch
import fedi
import cligen
import os
import strutils
import times
import tables
import asyncdispatch
import httpclient
import shabbo
type
  FediWatch = object
    client: AsyncFediClient
    config: Target
# TODO load this from a settings and make it random
const USER_AGENT =  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
proc loadTargets*(db: CouchDBClient, database: string): seq[Target] =
  let resp = db.find("targets", %*{"selector":
                                    {"actor":
                                      {"$eq":"fediWatch"}}})
  echo $resp
  var r: seq[Target]
  for target in resp["docs"].getElems:
    var jdoc = target
    jdoc["id"] = target["_id"]
    r.add(target.to(Target))
  result = r
  echo r.len

proc initFediWatch(targets: seq[Target]): seq[FediWatch] =
  var r: seq[FediWatch]
  let proxy = getEnv("HTTP_PROXY")
  for target in targets:
    let token = target.options{"auth"}.getStr("")
    let ua = target.options{"ua"}.getStr(USER_AGENT)
    let client = newAsyncFediClient(host=target.target, token = token, userAgent=ua)
    r.add(FediWatch(config: target, client: client))
  result = r

proc getReplies(fediw: FediWatch, data: JsonNode): Future[Table[int64, JsonNode]] {.async.} =
  # Get replies in a recursive manner
  # Base case is no reply_to_id which will add the current data.
  var replies: Table[int64, JsonNode]
  replies[data["id"].getBiggestInt(0)] = data
  let replyId = data{"in_reply_to_id"}.getInt(0)
  if replyId != 0:
    let reply = await fediw.client.getStatus(replyId)
    replies[reply["id"].getBiggestInt()] = reply
    # Call this function again and add the results
    let rtable = await fediw.getReplies(reply)
    for key in rtable.keys:
      echo "adding replies!"
      replies[key] = rtable[key]
    replies[reply["id"].getBiggestInt()] = reply
  result = replies

proc getTimeline(fediw: FediWatch): Future[Table[int64, JsonNode]] {.async.} =
  var r: seq[JsonNode]
  let timeline = await fediw.client.getTimeline()
  var replies: Table[int64, JsonNode]
  for doc in timeline.getElems:
    let rtable = await fediw.getReplies(doc)
    for key in rtable.keys:
      replies[key] = rtable[key]
  result = replies


proc parseUser*(user: JsonNode, dataset: string): Username =
  let username = user["username"].getStr()
  let url = user["url"].getStr()
  var doc = newUsername(userName, platform = "fediverse", url)
  doc.bio = user["note"].getStr
  for extra in user["fields"].getElems:
    doc.misc.add(extra)
  doc.date_added = parseTime(user["created_at"].getStr, "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()).toUnix
  doc.date_updated = doc.date_added
  doc.dataset = dataset
  result = doc
proc parsePost*(data: JsonNode, dataset: string): SocialMPost  =
  let content = data["content"].getStr
  let user = data["account"].parseUser(dataset)
  let url = data["uri"].getStr
  var doc = user.newPost(content, url = url)

  for tag in data["tags"].getElems:
    doc.tags.add(tag.getStr)

  for media in data["media_attachments"].getElems:
    doc.media.add(media["url"].getStr)

  # TODO extract links

  doc.replyCount = data{"replies_count"}.getInt(0)
  doc.repostCount = data{"reblogs_count"}.getInt(0)
  doc.dataset = dataset
  doc.date_added = parseTime(data["created_at"].getStr, "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", utc()).toUnix
  doc.date_updated = doc.date_added
  result = doc
proc getPostsId*(posts: var Table[int64, JsonNode], key: int64): seq[JsonNode] =
  for value in posts.mvalues:
    if value{"in_reply_to_id"}.getBiggestInt() == key:
      result.add(value)

  
proc parsePosts*(posts: var Table[int64, JsonNode], docs: var Table[string, JsonNode], dataset: string)  =
  for key in posts.keys:
    var doc = posts[key].parsePost(dataset)
    # Base Case, there is no replyTo so we add it and delete the key
    if posts[key]{"reply_to_id"}.getBiggestInt(0) == 0:
      let replies = posts.getPostsId(key)
      for p in replies:
        doc.replies.add(p.parsePost(dataset)) # add it as a subobject
    var jdoc = %*doc
    jdoc{"_id"} = newJString(doc.id)
    jdoc.delete("id")
    if docs.hasKey(doc.id) != true:
      docs[doc.id] = jdoc

proc updateDoc(db: AsyncCouchDBClient, database: string, doc: JsonNode) {.async.} =
  var old: JsonNode
  var new = doc
  if doc["_rev"].getStr().len != 0:
    old = await db.getDoc(database, doc["_id"].getStr, doc["_rev"].getStr)
    defer: db.hc.close()
  else:
    old = await db.getDoc(database, doc["_id"].getStr)
    defer: db.hc.close()
  new["_rev"] = old["_rev"]
  let resp = await db.createOrUpdateDoc(database, new["_id"].getStr, new["_rev"].getStr, new)
  defer: db.hc.close()
proc insertDocs(db: AsyncCouchDBClient, docs: Table[string, JsonNode], database: string) {.async.} =
  var jdocs: seq[JsonNode]
  for doc in docs.keys:
    jdocs.add(docs[doc])
  try:
    let resp = await db.bulkDocs(database, %jdocs)
    defer: db.hc.close()
  except CouchDBError:
    # insert failed, try again but insert each one by itself
    try:
      for doc in jdocs:
        await db.updateDoc(database, doc)
        defer: db.hc.close()
    except CouchDBError:
      #ignore the error
      discard
    except ProtocolError:
      discard



proc mainLoop(clients: seq[FediWatch], couchHost, couchUser, couchPass, database: string, couchPort: int) {.async.} =
  var db: AsyncCouchDBClient
  try:
    echo "function loop login"
    db = newAsyncCouchDBClient(host=couchHost, port=couchPort)
    echo await db.cookieAuth(couchUser, couchPass)
  except CouchDBError as e:
    echo e.info
  var docs: Table[string, JsonNode]
  while true:
    for client in clients:
      try:
        client.client.hc = newAsyncHttpClient()
        var timeline = await client.getTimeline()
        defer: client.client.hc.close()
        timeline.parsePosts(docs, client.config.dataset)
      except FediError as e:
        echo e.info
        echo client.client.baseUrl
      except ValueError:
        discard
      except IOError as e:
        echo docs.len
        echo "connection error"
        echo client.client.baseUrl
        try:
          db = newAsyncCouchDBClient(host=couchHost, port=couchPort)
          echo await db.cookieAuth(couchUser, couchPass)
        except ProtocolError:
          echo "Couch error!"
        except OSError:
          echo "Error cant find Host: ", client.client.baseUrl
    if docs.len >= 10:
      echo "inserting"
      await db.insertDocs(docs, database)
      docs.clear
    await sleepAsync(300)

proc main()  =
  let
    host = getEnv("COUCH_HOST")
    user = getEnv("COUCH_USER")
    pass = getEnv("COUCH_PASS")
    port = getEnv("COUCH_PORT").parseInt
    targetdb = getEnv("COUCH_TARGETDB")
    database = getEnv("COUCH_DATABASE")
  var db: CouchDBClient
  try:
    echo "function main login"
    db = newCouchDBClient(host=host, port=port)
    echo user
    echo pass
    discard db.cookieAuth(user, pass)
  except CouchDBError as e:
    echo e.info
  discard db.cookieAuth(user, pass)
  let targets = db.loadTargets(database)
  var clients = initFediWatch(targets=targets)
  waitFor clients.mainLoop(host, user, pass, database, port)
main()
