import starintel_doc
import json, jsony
import mycouch
import fedi
import cligen
import os
import strutils
import times
import tables
import asyncdispatch
import threadpool
type
  FediWatch = object
    client: FediClient
    config: BookerTarget
# TODO load this from a settings and make it random
const USER_AGENT =  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/108.0.0.0 Safari/537.36"
proc loadTargets*(db: CouchDBClient, database: string): seq[BookerTarget] =
  let resp = db.find("targets", %*{"selector":{"actor":{"$eq":"fediWatch"}}})
  echo $resp
  var r: seq[BookerTarget]
  for target in resp["docs"].getElems:
    var jdoc = target
    jdoc["id"] = target["_id"]
    r.add(target.to(BookerTarget))
  result = r
  echo r.len

proc initFediWatch(targets: seq[BookerTarget]): seq[FediWatch] =
  var r: seq[FediWatch]
  let proxy = getEnv("HTTP_PROXY")
  for target in targets:
    let token = target.options{"auth"}.getStr("")
    let ua = target.options{"ua"}.getStr(USER_AGENT)
    let client = newFediClient(host=target.target, token = token, userAgent=ua)
    r.add(FediWatch(config: target, client: client))
  result = r

proc getReplies(fediw: FediWatch, data: JsonNode): Table[int64, JsonNode]  =
  # Get replies in a recursive manner
  # Base case is no reply_to_id which will add the current data.
  var replies: Table[int64, JsonNode]
  replies[data["id"].getBiggestInt(0)] = data
  let replyId = data{"in_reply_to_id"}.getInt(0)
  if replyId != 0:
    let reply = fediw.client.getStatus(replyId)
    replies[reply["id"].getBiggestInt()] = reply
    # Call this function again and add the results
    let rtable = fediw.getReplies(reply)
    for key in rtable.keys:
      echo "adding replies!"
      replies[key] = rtable[key]
    replies[reply["id"].getBiggestInt()] = reply
  result = replies

proc getTimeline(fediw: FediWatch): Table[int64, JsonNode] =
  var r: seq[JsonNode]
  let timeline = fediw.client.getTimeline()
  var replies: Table[int64, JsonNode]
  for doc in timeline.getElems:
    let rtable = fediw.getReplies(doc)
    for key in rtable.keys:
      replies[key] = rtable[key]
  result = replies


proc parseUser*(user: JsonNode, dataset: string): BookerUsername =
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
proc parsePost*(data: JsonNode, dataset: string): BookerSocialMPost  =
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


proc insertDocs(db: CouchDBClient, docs: var Table[string, JsonNode], database: string) =
  var jdocs: seq[JsonNode]
  for doc in docs.mvalues:
    jdocs.add(doc)
  try:
    let resp = db.bulkDocs(database, %jdocs)
  except CouchDBError:
    # insert failed, try again but insert each one by itself
    try:
      for doc in jdocs:
        let resp = db.createDoc(database, doc)
    except CouchDBError:
      #ignore the error
      discard
proc mainLoop(client: FediWatch, couchHost, couchUser, couchPass, database: string, couchPort: int): void {.thread.} =
  echo client.client.baseUrl
  var db = newCouchDBClient(host=couchHost, port=couchPort)
  echo db.cookieAuth(couchUser, couchPass)
  var docs: Table[string, JsonNode]
  var error = false
  while error != true:
    try:
      var timeline = client.getTimeline()
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
      db = newCouchDBClient(host=couchHost, port=couchPort)
      echo db.cookieAuth(couchUser, couchPass)
    except OSError:
      echo "Error cant find Host: ", client.client.baseUrl
      error = true # stop connecting
    if docs.len == 100:
      db.insertDocs(docs, database)
      docs.clear
    sleep(300)
proc main()  =
  var db = newCouchDBClient(host=getEnv("COUCH_HOST"), port=getEnv("COUCH_PORT").parseInt)
  discard db.cookieAuth(getEnv("COUCH_USER"), getEnv("COUCH_PASSWORD"))
  let targets = db.loadTargets(getEnv("COUCH_TARGETDB"))
  let database = getEnv("COUCH_DATABASE")
  var clients = initFediWatch(targets=targets)
  for client in clients:
    spawn mainLoop(client, getEnv("COUCH_HOST"), getEnv("COUCH_USER"), getEnv("COUCH_PASSWORD"), database, getEnv("COUCH_PORT").parseInt)
  sync()
main()
