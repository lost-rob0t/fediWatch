import std/[asyncdispatch, httpclient, httpcore, json, os, strutils]

import fedi


type
  WatchKind* = enum
    wkInstance
    wkAccount

  WatchTarget* = object
    kind*: WatchKind
    target*: string
    dataset*: string
    token*: string
    proxy*: string
    userAgent*: string
    sinceId*: string
    local*: bool
    remote*: bool
    onlyMedia*: bool
    excludeReplies*: bool
    excludeReblogs*: bool
    limit*: int

  AppConfig* = object
    transport*: string
    pollIntervalMs*: int
    once*: bool
    batchSize*: int
    emitRetries*: int
    httpBulkUrl*: string
    httpToken*: string
    rabbitUrl*: string
    rabbitExchange*: string
    rabbitRoutingPrefix*: string
    schemaPath*: string
    logPath*: string
    targets*: seq[WatchTarget]


proc envBool(name: string, default: bool): bool =
  let value = getEnv(name).strip().toLowerAscii()
  if value.len == 0:
    return default
  case value
  of "1", "true", "yes", "on": true
  of "0", "false", "no", "off": false
  else:
    raise newException(ValueError, name & " must be a boolean")


proc envInt(name: string, default, minimum, maximum: int): int =
  let value = getEnv(name).strip()
  if value.len == 0:
    return default
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, name & " must be an integer")
  if result < minimum or result > maximum:
    raise newException(ValueError,
      name & " must be between " & $minimum & " and " & $maximum)


proc joinUrl(base, path: string): string =
  result = normalizeHost(base)
  var suffix = path.strip()
  while suffix.len > 0 and suffix[0] == '/':
    suffix.delete(0..0)
  result.add("/" & suffix)


proc normalizeOptions(options: JsonNode): JsonNode =
  result = newJObject()
  if options.isNil:
    return

  case options.kind
  of JObject:
    for key, value in options.pairs:
      result[key] = value
  of JArray:
    for item in options.items:
      if item.kind != JObject:
        continue
      let key = item{"key"}.getStr(item{"name"}.getStr(""))
      if key.len > 0 and item.hasKey("value"):
        result[key] = item["value"]
      else:
        for name, value in item.pairs:
          result[name] = value
  else:
    discard


proc parseTarget(node: JsonNode, defaultDataset: string): WatchTarget =
  if node.kind != JObject:
    raise newException(ValueError, "target entry must be a JSON object")

  let data =
    if node.hasKey("data") and node["data"].kind == JObject:
      node["data"]
    else:
      node

  let options = normalizeOptions(data{"options"})
  let targetType = data{"target_type"}.getStr(
    options{"typ"}.getStr(options{"type"}.getStr("instance"))
  ).toLowerAscii()

  result.kind =
    if targetType in ["user", "account"]: wkAccount
    else: wkInstance

  result.target = data{"target"}.getStr("").strip()
  if result.target.len == 0:
    raise newException(ValueError, "target entry is missing data.target")

  if result.kind == wkAccount:
    let account = splitAccount(result.target)
    result.target = account.username & "@" & account.domain
  else:
    result.target = normalizeHost(result.target)

  result.dataset = node{"dataset"}.getStr(
    data{"dataset"}.getStr(defaultDataset)
  )
  result.token = options{"auth"}.getStr(options{"token"}.getStr(""))
  result.proxy = options{"proxy"}.getStr(getEnv("HTTPS_PROXY", getEnv("HTTP_PROXY")))
  result.userAgent = options{"ua"}.getStr(DefaultUserAgent)
  result.sinceId = data{"since_id"}.getStr(options{"since_id"}.getStr(""))
  result.local = options{"local"}.getBool(false)
  result.remote = options{"remote"}.getBool(false)
  result.onlyMedia = options{"only_media"}.getBool(false)
  result.excludeReplies = options{"exclude_replies"}.getBool(false)
  result.excludeReblogs = options{"exclude_reblogs"}.getBool(false)
  result.limit = max(1, min(40, options{"limit"}.getInt(40)))

  if result.local and result.remote:
    raise newException(ValueError,
      "target " & result.target & " cannot set both local and remote")


proc appendTargets(result: var seq[WatchTarget], payload: JsonNode,
                   defaultDataset: string) =
  case payload.kind
  of JArray:
    for item in payload.items:
      result.add(parseTarget(item, defaultDataset))
  of JObject:
    if payload.hasKey("rows") and payload["rows"].kind == JArray:
      for row in payload["rows"].items:
        let item =
          if row.kind == JObject and row.hasKey("doc"): row["doc"]
          else: row
        result.add(parseTarget(item, defaultDataset))
    elif payload.hasKey("docs") and payload["docs"].kind == JArray:
      for item in payload["docs"].items:
        result.add(parseTarget(item, defaultDataset))
    else:
      result.add(parseTarget(payload, defaultDataset))
  else:
    raise newException(ValueError, "target payload must be an object or array")


proc fetchJson(url, token: string): Future[JsonNode] {.async.} =
  let client = newAsyncHttpClient(userAgent = "fediWatch/1.0.0")
  defer: client.close()
  client.headers = newHttpHeaders({"Accept": "application/json"})
  if token.len > 0:
    client.headers["Authorization"] = "Bearer " & token

  let response = await client.get(url)
  let body = await response.body
  if not response.code.is2xx:
    raise newException(IOError,
      "target request failed with HTTP " & $response.code & ": " & body)
  result = parseJson(body)


proc loadConfig*(): Future[AppConfig] {.async.} =
  let defaultDataset = getEnv("STAR_DATASET", "fediverse")
  let httpBaseUrl = getEnv("STARINTEL_HTTP_URL", "http://127.0.0.1:5000")

  result.transport = getEnv("FEDIWATCH_TRANSPORT", "http").strip().toLowerAscii()
  if result.transport in ["rabbit", "amqp"]:
    result.transport = "rabbitmq"
  if result.transport notin ["http", "rabbitmq"]:
    raise newException(ValueError,
      "FEDIWATCH_TRANSPORT must be http or rabbitmq")

  result.pollIntervalMs = envInt(
    "FEDIWATCH_POLL_INTERVAL_SECONDS", 60, 1, 86_400
  ) * 1000
  result.once = envBool("FEDIWATCH_ONCE", false)
  result.batchSize = envInt("FEDIWATCH_BATCH_SIZE", 500, 1, 500)
  result.emitRetries = envInt("FEDIWATCH_EMIT_RETRIES", 3, 0, 10)
  result.httpBulkUrl = getEnv(
    "STARINTEL_HTTP_BULK_URL", joinUrl(httpBaseUrl, "documents/bulk")
  )
  result.httpToken = getEnv("STARINTEL_HTTP_TOKEN")
  result.rabbitUrl = getEnv(
    "STARINTEL_RABBITMQ_URL", "amqp://guest:guest@127.0.0.1/"
  )
  result.rabbitExchange = getEnv("STARINTEL_RABBITMQ_EXCHANGE", "documents")
  result.rabbitRoutingPrefix = getEnv(
    "STARINTEL_RABBITMQ_ROUTING_PREFIX", "documents.ingest"
  )
  result.schemaPath = getEnv("STARINTEL_SCHEMA")
  result.logPath = getEnv("FEDIWATCH_LOG")

  let inlineTargets = getEnv("FEDIWATCH_TARGETS").strip()
  if inlineTargets.len > 0:
    result.targets.appendTargets(parseJson(inlineTargets), defaultDataset)

  let targetsFile = getEnv("FEDIWATCH_TARGETS_FILE").strip()
  if targetsFile.len > 0:
    if not fileExists(targetsFile):
      raise newException(IOError, "target file not found: " & targetsFile)
    result.targets.appendTargets(parseFile(targetsFile), defaultDataset)

  var targetsUrl = getEnv("FEDIWATCH_TARGETS_URL").strip()
  if targetsUrl.len == 0 and result.targets.len == 0:
    targetsUrl = joinUrl(httpBaseUrl, "targets/fediwatch")
  if targetsUrl.len > 0:
    let payload = await fetchJson(targetsUrl, result.httpToken)
    result.targets.appendTargets(payload, defaultDataset)

  if result.targets.len == 0:
    raise newException(ValueError,
      "no targets configured; set FEDIWATCH_TARGETS, FEDIWATCH_TARGETS_FILE, or FEDIWATCH_TARGETS_URL")
