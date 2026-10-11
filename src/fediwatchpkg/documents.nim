## Project observed Mastodon input into the StarLang-generated document contract.
import std/[json, md5, times]
import starintel_doc/canonical as canonical

proc checked(document: JsonNode): JsonNode =
  let resultCheck = canonical.validateDocument(document)
  if not resultCheck.ok:
    raise newException(ValueError, resultCheck.category & ": " & resultCheck.message)
  document

proc reference(dtype, id: string): JsonNode =
  %*{"schema": "org.starintel/core@1/" & dtype, "id": id}

proc platformTime(value: string): int64 =
  for format in ["yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'"]:
    try: return parseTime(value, format, utc()).toUnix
    except TimeParseError: discard
  raise newException(ValueError, "unsupported Mastodon timestamp: " & value)

proc parseUser*(user: JsonNode, dataset: string): JsonNode =
  if user.kind != JObject: raise newException(ValueError, "account must be an object")
  let username = user["username"].getStr()
  let url = user["url"].getStr()
  result = %*{"id": $toMD5(username & url), "dataset": dataset, "dtype": "user",
              "schemaVersion": "0.10.1", "username": username, "url": url,
              "platform": "fediverse", "raw": user.copy()}
  if user.hasKey("note"): result["bio"] = user["note"].copy()
  if user.hasKey("display_name"): result["displayName"] = user["display_name"].copy()
  if user.hasKey("id"): result["platformUserId"] = user["id"].copy()
  if user.hasKey("fields"): result["misc"] = user["fields"].copy()
  if user.hasKey("created_at") and user["created_at"].kind == JString:
    result["createdOnPlatformAt"] = %platformTime(user["created_at"].getStr())
  for mapping in [("followers_count", "followersCount"), ("following_count", "followingCount"),
                  ("statuses_count", "postCount"), ("locked", "private"), ("suspended", "suspended")]:
    if user.hasKey(mapping[0]): result[mapping[1]] = user[mapping[0]].copy()
  discard checked(result)

proc timelineDocuments*(status: JsonNode, dataset: string): seq[JsonNode] =
  if status.kind != JObject: raise newException(ValueError, "status must be an object")
  let user = parseUser(status["account"], dataset)
  let content = status["content"].getStr()
  let platformId = status["id"].getStr()
  let post = %*{"id": $toMD5(platformId), "dataset": dataset, "dtype": "socialmpost",
                "schemaVersion": "0.10.1", "content": content, "platform": "fediverse",
                "platformPostId": platformId, "user": reference("user", user["id"].getStr()),
                "raw": status.copy()}
  if status.hasKey("url") and status["url"].kind != JNull: post["url"] = status["url"].copy()
  if status.hasKey("created_at") and status["created_at"].kind == JString:
    post["publishedAt"] = %platformTime(status["created_at"].getStr())
  for mapping in [("replies_count", "replyCount"), ("reblogs_count", "repostCount"),
                  ("favourites_count", "likeCount"), ("sensitive", "sensitive")]:
    if status.hasKey(mapping[0]): post[mapping[1]] = status[mapping[0]].copy()
  if status.hasKey("tags"):
    var tags = newJArray()
    for tag in status["tags"]:
      if tag.kind == JObject and tag.hasKey("name"): tags.add(tag["name"].copy())
    post["hashtags"] = tags
  let relation = %*{"id": $toMD5(user["id"].getStr() & post["id"].getStr() & "owns"),
                    "dataset": dataset, "dtype": "relation", "schemaVersion": "0.10.1",
                    "source": reference("user", user["id"].getStr()),
                    "destination": reference("socialmpost", post["id"].getStr()),
                    "predicate": "org.starintel/core@1/owns", "note": ""}
  # Validate the whole observation before emitting any partial projection.
  result = @[checked(post), checked(user), checked(relation)]
