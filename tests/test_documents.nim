import std/[json, strutils, unittest]

import fediwatch/[documents, rabbitmq_bridge]


proc account(id, username, domain: string): JsonNode =
  %*{
    "id": id,
    "username": username,
    "acct": username & "@" & domain,
    "display_name": username,
    "url": "https://" & domain & "/@" & username,
    "note": "bio",
    "avatar": "https://" & domain & "/avatar.png",
    "created_at": "2024-01-02T03:04:05.000Z",
    "fields": [
      {"name": "site", "value": "https://example.org"}
    ]
  }


proc status(id: string, author: JsonNode): JsonNode =
  %*{
    "id": id,
    "created_at": "2026-07-30T20:00:00.000Z",
    "edited_at": nil,
    "in_reply_to_id": "100",
    "content": "<p>Hello federation</p>",
    "visibility": "public",
    "uri": "https://social.example/users/alice/statuses/" & id,
    "url": "https://social.example/@alice/" & id,
    "replies_count": 2,
    "reblogs_count": 3,
    "favourites_count": 4,
    "account": author,
    "media_attachments": [
      {"url": "https://social.example/media/1.png"}
    ],
    "tags": [
      {"name": "nim", "url": "https://social.example/tags/nim"}
    ],
    "mentions": [
      {"acct": "bob@example.net"}
    ],
    "card": {
      "url": "https://example.org/article"
    },
    "quote": nil,
    "reblog": nil
  }


proc findByType(documents: openArray[JsonNode], dtype: string): JsonNode =
  for document in documents:
    if document["dtype"].getStr == dtype:
      return document
  result = newJNull()


suite "StarIntel 0.9 document generation":
  test "creates user, post, and authored relation":
    let documents = documentsForStatus(
      status("200", account("10", "alice", "social.example")),
      "fediverse",
      "https://social.example"
    )

    check documents.len == 3
    for document in documents:
      check isStarIntel09Document(document)
      check document["schema_version"].getStr == "0.9.0"
      check document["dataset"].getStr == "fediverse"

    let post = documents.findByType("social-media-post")
    check post.kind == JObject
    check post["data"]["tags"][0].getStr == "nim"
    check post["data"]["mentions"][0].getStr == "bob@example.net"
    check post["data"]["media"][0].getStr.endsWith("1.png")
    check post["data"]["reply_to"].getStr.startsWith("social-media-post-")

    let relation = documents.findByType("relation")
    check relation["data"]["predicate"].getStr == "authored"
    check relation["data"]["object"].getStr == post["_id"].getStr

  test "represents boosts as repost relations":
    let original = status(
      "300",
      account("10", "alice", "social.example")
    )
    var boost = status(
      "301",
      account("11", "bob", "social.example")
    )
    boost["reblog"] = original
    boost["content"] = %""

    let documents = documentsForStatus(
      boost,
      "fediverse",
      "https://social.example"
    )

    var postCount = 0
    var repostCount = 0
    for document in documents:
      if document["dtype"].getStr == "social-media-post":
        inc postCount
      if document["dtype"].getStr == "relation" and
          document["data"]["predicate"].getStr == "reposted":
        inc repostCount

    check postCount == 1
    check repostCount == 1


suite "RabbitMQ configuration":
  test "parses credentials, port, and encoded vhost":
    let address = parseRabbitAddress(
      "amqp://actor:p%40ss@rabbit.internal:5678/%2Fstarintel"
    )
    check address.host == "rabbit.internal"
    check address.port == 5678
    check address.username == "actor"
    check address.password == "p@ss"
    check address.vhost == "/starintel"
    check not address.tls

  test "uses standard RabbitMQ defaults":
    let address = parseRabbitAddress("amqp://localhost/")
    check address.port == 5672
    check address.username == "guest"
    check address.password == "guest"
    check address.vhost == "/"
    check not address.tls

  test "uses verified TLS for AMQPS":
    let address = parseRabbitAddress("amqps://rabbit.example/%2Fintel")
    check address.port == 5671
    check address.vhost == "/intel"
    check address.tls
