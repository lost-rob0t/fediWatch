import std/[asyncdispatch, json, os, sets]

import fedi
import starintel_doc

import config, documents, transports


type
  Logger = ref object
    file: File
    hasFile: bool

  Watcher = ref object
    target: WatchTarget
    client: AsyncFediClient
    sinceId: string
    accountId: string

  PollResult = object
    watcher: Watcher
    documents: seq[JsonNode]
    nextSinceId: string


proc newLogger(path: string): Logger =
  result = Logger()
  if path.len > 0:
    if not open(result.file, path, fmAppend):
      raise newException(IOError, "cannot open log file: " & path)
    result.hasFile = true


proc log(logger: Logger, level, message: string) =
  let line = isoNow() & " [" & level & "] " & message
  echo line
  if logger.hasFile:
    logger.file.writeLine(line)
    logger.file.flushFile()


proc close(logger: Logger) =
  if logger.hasFile:
    logger.file.close()


proc newWatcher(target: WatchTarget): Watcher =
  let host =
    if target.kind == wkAccount:
      let account = splitAccount(target.target)
      "https://" & account.domain
    else:
      target.target

  result = Watcher(
    target: target,
    client: newAsyncFediClient(
      host = host,
      token = target.token,
      proxy = target.proxy,
      userAgent = target.userAgent
    ),
    sinceId: target.sinceId
  )


proc fetchTimeline(watcher: Watcher): Future[JsonNode] {.async.} =
  case watcher.target.kind
  of wkInstance:
    result = await watcher.client.getTimeline(
      local = watcher.target.local,
      remote = watcher.target.remote,
      onlyMedia = watcher.target.onlyMedia,
      limit = watcher.target.limit,
      sinceId = watcher.sinceId
    )
  of wkAccount:
    if watcher.accountId.len == 0:
      let account = await watcher.client.lookupAccount(watcher.target.target)
      watcher.accountId = account{"id"}.getStr("")
      if watcher.accountId.len == 0:
        raise newException(ValueError,
          "Mastodon lookup returned no account id for " & watcher.target.target)

    result = await watcher.client.getStatuses(
      accountId = watcher.accountId,
      limit = watcher.target.limit,
      onlyMedia = watcher.target.onlyMedia,
      excludeReplies = watcher.target.excludeReplies,
      excludeReblogs = watcher.target.excludeReblogs,
      sinceId = watcher.sinceId
    )


proc poll(watcher: Watcher): Future[PollResult] {.async.} =
  result.watcher = watcher
  let timeline = await watcher.fetchTimeline()
  if timeline.kind != JArray:
    raise newException(ValueError,
      "Mastodon timeline response must be a JSON array")
  if timeline.len == 0:
    return

  result.nextSinceId = timeline[0]{"id"}.getStr("")
  if result.nextSinceId.len == 0:
    raise newException(ValueError,
      "Mastodon timeline response is missing the newest status id")

  for status in timeline.items:
    if status.kind != JObject:
      continue
    result.documents.add(documentsForStatus(
      status,
      watcher.target.dataset,
      watcher.client.baseUrl
    ))


proc uniqueDocuments(results: openArray[PollResult]): seq[JsonNode] =
  var seen = initHashSet[string]()
  for pollResult in results:
    for document in pollResult.documents:
      let id = document{"_id"}.getStr("")
      if id.len == 0:
        raise newException(ValueError, "generated document is missing _id")
      if id notin seen:
        seen.incl(id)
        result.add(document)


proc validateDocuments(documents: openArray[JsonNode], schema: JsonNode) =
  for document in documents:
    if not isStarIntel09Document(document):
      raise newException(ValueError,
        "generated document is missing required StarIntel 0.9 fields")

    if not schema.isNil:
      let checked = validateDocument(document, schema)
      if not checked.ok:
        raise newException(ValueError,
          "StarIntel schema validation failed for " &
          document{"_id"}.getStr("unknown") & ": " &
          checked.category & ": " & checked.message)


proc runCycle(watchers: openArray[Watcher], emitter: Emitter,
              schema: JsonNode, logger: Logger) {.async.} =
  var futures: seq[Future[PollResult]]
  for watcher in watchers:
    futures.add(watcher.poll())

  var results: seq[PollResult]
  for future in futures:
    try:
      let pollResult = await future
      results.add(pollResult)
    except CatchableError:
      logger.log("ERROR", getCurrentExceptionMsg())

  let batch = uniqueDocuments(results)
  if batch.len == 0:
    logger.log("INFO", "poll completed with no new documents")
    return

  validateDocuments(batch, schema)
  await emitter.emitBatch(batch)

  for pollResult in results:
    if pollResult.nextSinceId.len > 0:
      pollResult.watcher.sinceId = pollResult.nextSinceId

  logger.log("INFO", "emitted " & $batch.len & " unique documents")


proc run*() {.async.} =
  let app = await loadConfig()
  let logger = newLogger(app.logPath)
  var schema: JsonNode
  if app.schemaPath.len > 0:
    if not fileExists(app.schemaPath):
      raise newException(IOError,
        "StarIntel schema not found: " & app.schemaPath)
    schema = parseFile(app.schemaPath)

  let emitter = await newEmitter(app)
  var watchers: seq[Watcher]
  for target in app.targets:
    watchers.add(newWatcher(target))

  logger.log("INFO",
    "started with " & $watchers.len & " targets using " & app.transport)

  try:
    while true:
      try:
        await runCycle(watchers, emitter, schema, logger)
      except CatchableError:
        logger.log("ERROR", getCurrentExceptionMsg())
        if app.once:
          raise

      if app.once:
        break
      await sleepAsync(app.pollIntervalMs)
  finally:
    for watcher in watchers:
      watcher.client.close()
    await emitter.close()
    logger.close()
