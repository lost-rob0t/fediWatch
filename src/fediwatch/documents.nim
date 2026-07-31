import std/[json, strutils, times, uri]

import checksums/sha2
import fedi
import starintel_doc


const
  ActorName* = "fediwatch"
  SoftwareVersion* = "1.0.0"


proc isoNow*(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")


proc stableId*(prefix, value: string): string =
  var hasher = initSha_256()
  hasher.update(value)
  result = prefix & "-" & $hasher.digest()


proc instanceDomain(instanceHost: string): string =
  parseUri(normalizeHost(instanceHost)).hostname.toLowerAscii()


proc fullAccountName(account: JsonNode, instanceHost: string): string =
  let username = account{"username"}.getStr("")
  let acct = account{"acct"}.getStr(username)
  if '@' in acct:
    result = acct
  else:
    result = acct & "@" & instanceDomain(instanceHost)


proc sourceObject(url, accessedAt: string): JsonNode =
  %*{
    "type": "api",
    "name": "Mastodon REST API",
    "url": url,
    "access_method": "https",
    "accessed_at": accessedAt
  }


proc envelope(dtype, id, dataset: string, data: JsonNode,
              sourceUrl: string, sourceTime = ""): JsonNode =
  let collectedAt = isoNow()
  var sources = newJArray()
  sources.add(sourceObject(sourceUrl, collectedAt))

  result = %*{
    "_id": id,
    "dataset": dataset,
    "dtype": dtype,
    "schema_version": SpecVersion,
    "version": 1,
    "date_added": collectedAt,
    "date_updated": collectedAt,
    "sources": sources,
    "evidence": newJArray(),
    "provenance": {
      "actor": ActorName,
      "collector": ActorName,
      "collector_type": "actor",
      "method": "mastodon-api",
      "tool": "fediWatch",
      "software_version": SoftwareVersion
    },
    "data": data
  }

  if sourceTime.len > 0:
    result["temporal"] = %*{
      "created_at": sourceTime,
      "observed_at": collectedAt
    }


proc userDocument*(account: JsonNode, dataset, instanceHost: string): JsonNode =
  let
    fullAccount = fullAccountName(account, instanceHost)
    accountUrl = account{"url"}.getStr(normalizeHost(instanceHost))
    accountId = account{"id"}.getStr("")
    createdAt = account{"created_at"}.getStr("")

  var externalIds = newJArray()
  if accountId.len > 0:
    externalIds.add(%*{
      "scheme": "mastodon-account-id",
      "value": accountId,
      "issuer": instanceDomain(instanceHost),
      "url": accountUrl
    })

  let fields =
    if not account{"fields"}.isNil and account{"fields"}.kind == JArray:
      account{"fields"}
    else:
      newJArray()

  let data = %*{
    "username": account{"username"}.getStr(""),
    "name": fullAccount,
    "display_name": account{"display_name"}.getStr(""),
    "platform": "fediverse",
    "url": accountUrl,
    "bio": account{"note"}.getStr(""),
    "image_url": account{"avatar"}.getStr(""),
    "misc": fields,
    "external_ids": externalIds
  }

  result = envelope(
    dtype = "user",
    id = stableId("user", fullAccount.toLowerAscii()),
    dataset = dataset,
    data = data,
    sourceUrl = accountUrl,
    sourceTime = createdAt
  )


proc postId*(status: JsonNode, instanceHost: string): string =
  stableId(
    "social-media-post",
    normalizeHost(instanceHost) & ":" & status{"id"}.getStr(
      status{"uri"}.getStr(status{"url"}.getStr("unknown"))
    )
  )


proc stringArray(node: JsonNode, objectField: string): JsonNode =
  result = newJArray()
  if node.isNil or node.kind != JArray:
    return

  for item in node.items:
    let value =
      if item.kind == JObject: item{objectField}.getStr("")
      elif item.kind == JString: item.getStr("")
      else: ""
    if value.len > 0:
      result.add(%value)


proc mediaArray(status: JsonNode): JsonNode =
  result = newJArray()
  let media = status{"media_attachments"}
  if media.isNil or media.kind != JArray:
    return

  for attachment in media.items:
    let url = attachment{"url"}.getStr(
      attachment{"preview_url"}.getStr("")
    )
    if url.len > 0:
      result.add(%url)


proc linkArray(status: JsonNode): JsonNode =
  result = newJArray()
  let cardUrl = status{"card"}{"url"}.getStr("")
  if cardUrl.len > 0:
    result.add(%cardUrl)


proc postDocument*(status, userDoc: JsonNode,
                   dataset, instanceHost: string): JsonNode =
  let
    sourceUrl = status{"url"}.getStr(
      status{"uri"}.getStr(normalizeHost(instanceHost))
    )
    createdAt = status{"created_at"}.getStr("")
    replyId = status{"in_reply_to_id"}.getStr("")
    editedAt = status{"edited_at"}.getStr("")

  var data = %*{
    "message_id": status{"id"}.getStr(""),
    "user": userDoc{"data"}{"name"}.getStr(""),
    "user_id": userDoc{"_id"}.getStr(""),
    "content": status{"content"}.getStr(""),
    "url": sourceUrl,
    "platform": "fediverse",
    "posted_at": createdAt,
    "is_reply": replyId.len > 0,
    "reply_count": status{"replies_count"}.getInt(0),
    "repost_count": status{"reblogs_count"}.getInt(0),
    "like_count": status{"favourites_count"}.getInt(0),
    "visibility": status{"visibility"}.getStr(""),
    "deleted": false,
    "media": mediaArray(status),
    "tags": stringArray(status{"tags"}, "name"),
    "mentions": stringArray(status{"mentions"}, "acct"),
    "links": linkArray(status)
  }

  if replyId.len > 0:
    data["reply_to"] = %stableId(
      "social-media-post", normalizeHost(instanceHost) & ":" & replyId
    )
  if editedAt.len > 0:
    data["edited_at"] = %editedAt

  let quote = status{"quote"}
  if not quote.isNil and quote.kind == JObject:
    let quoteId = quote{"id"}.getStr("")
    if quoteId.len > 0:
      data["quote_post_id"] = %stableId(
        "social-media-post", normalizeHost(instanceHost) & ":" & quoteId
      )

  result = envelope(
    dtype = "social-media-post",
    id = postId(status, instanceHost),
    dataset = dataset,
    data = data,
    sourceUrl = sourceUrl,
    sourceTime = createdAt
  )


proc relationDocument*(subjectId, predicate, objectId, dataset,
                       sourceUrl: string, sourceTime = ""): JsonNode =
  let data = %*{
    "subject": subjectId,
    "predicate": predicate,
    "object": objectId,
    "directed": true,
    "active": true,
    "confidence": 1.0,
    "source": ActorName
  }

  result = envelope(
    dtype = "relation",
    id = stableId("relation", subjectId & "\x1f" & predicate & "\x1f" & objectId),
    dataset = dataset,
    data = data,
    sourceUrl = sourceUrl,
    sourceTime = sourceTime
  )


proc normalStatusDocuments(status: JsonNode, dataset,
                           instanceHost: string): seq[JsonNode] =
  let user = userDocument(status{"account"}, dataset, instanceHost)
  let post = postDocument(status, user, dataset, instanceHost)
  let relation = relationDocument(
    subjectId = user["_id"].getStr,
    predicate = "authored",
    objectId = post["_id"].getStr,
    dataset = dataset,
    sourceUrl = post{"data"}{"url"}.getStr(normalizeHost(instanceHost)),
    sourceTime = status{"created_at"}.getStr("")
  )
  result = @[user, post, relation]


proc documentsForStatus*(status: JsonNode, dataset,
                         instanceHost: string): seq[JsonNode] =
  let reblog = status{"reblog"}
  if reblog.isNil or reblog.kind != JObject:
    return normalStatusDocuments(status, dataset, instanceHost)

  result = normalStatusDocuments(reblog, dataset, instanceHost)

  let
    booster = userDocument(status{"account"}, dataset, instanceHost)
    originalPostId = postId(reblog, instanceHost)
    sourceUrl = status{"url"}.getStr(
      status{"uri"}.getStr(normalizeHost(instanceHost))
    )

  result.add(booster)
  result.add(relationDocument(
    subjectId = booster["_id"].getStr,
    predicate = "reposted",
    objectId = originalPostId,
    dataset = dataset,
    sourceUrl = sourceUrl,
    sourceTime = status{"created_at"}.getStr("")
  ))


proc isStarIntel09Document*(document: JsonNode): bool =
  const required = [
    "_id", "dataset", "dtype", "schema_version", "version",
    "date_added", "date_updated", "sources", "evidence", "data"
  ]

  if document.isNil or document.kind != JObject:
    return false
  for key in required:
    if not document.hasKey(key):
      return false
  result = document["schema_version"].getStr == SpecVersion
