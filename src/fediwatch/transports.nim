import std/[asyncdispatch, httpclient, httpcore, json, strutils]

import config, rabbitmq_bridge


type
  Emitter* = ref object
    transport: string
    batchSize: int
    retries: int
    httpUrl: string
    httpClient: AsyncHttpClient
    rabbitUrl: string
    exchangeName: string
    routingPrefix: string
    rabbit: RabbitPublisher


proc connectRabbit(emitter: Emitter) =
  if not emitter.rabbit.isNil:
    emitter.rabbit.close()
  emitter.rabbit = newRabbitPublisher(
    parseRabbitAddress(emitter.rabbitUrl),
    emitter.exchangeName
  )


proc newEmitter*(app: AppConfig): Future[Emitter] {.async.} =
  result = Emitter(
    transport: app.transport,
    batchSize: app.batchSize,
    retries: app.emitRetries,
    httpUrl: app.httpBulkUrl,
    rabbitUrl: app.rabbitUrl,
    exchangeName: app.rabbitExchange,
    routingPrefix: app.rabbitRoutingPrefix
  )

  case result.transport
  of "http":
    result.httpClient = newAsyncHttpClient(userAgent = "fediWatch/1.0.0")
    result.httpClient.headers = newHttpHeaders({
      "Accept": "application/json",
      "Content-Type": "application/json"
    })
    if app.httpToken.len > 0:
      result.httpClient.headers["Authorization"] = "Bearer " & app.httpToken
  of "rabbitmq":
    result.connectRabbit()
  else:
    raise newException(ValueError, "unsupported transport: " & result.transport)


proc jsonArray(documents: openArray[JsonNode]): JsonNode =
  result = newJArray()
  for document in documents:
    result.add(document)


proc emitHttp(emitter: Emitter, documents: openArray[JsonNode]) {.async.} =
  let response = await emitter.httpClient.request(
    emitter.httpUrl,
    httpMethod = HttpPost,
    body = $jsonArray(documents)
  )
  let body = await response.body

  if not response.code.is2xx:
    raise newException(IOError,
      "StarIntel bulk API failed with HTTP " & $response.code & ": " & body)

  if body.strip().len > 0:
    try:
      let report = parseJson(body)
      if report.kind == JObject and report{"failed"}.getInt(0) > 0:
        raise newException(IOError,
          "StarIntel bulk API partially rejected the batch: " & body)
    except JsonParsingError:
      discard


proc emitRabbit(emitter: Emitter, documents: openArray[JsonNode]) =
  for document in documents:
    let
      dtype = document{"dtype"}.getStr("")
      messageId = document{"_id"}.getStr("")
    if dtype.len == 0:
      raise newException(ValueError, "cannot publish a document without dtype")
    if messageId.len == 0:
      raise newException(ValueError, "cannot publish a document without _id")

    emitter.rabbit.publish(
      routingKey = emitter.routingPrefix & "." & dtype,
      body = $document,
      messageId = messageId,
      documentType = dtype
    )


proc emitChunk(emitter: Emitter, documents: openArray[JsonNode]) {.async.} =
  var attempt = 0
  while true:
    try:
      case emitter.transport
      of "http":
        await emitter.emitHttp(documents)
      of "rabbitmq":
        emitter.emitRabbit(documents)
      else:
        raise newException(ValueError,
          "unsupported transport: " & emitter.transport)
      return
    except CatchableError:
      if attempt >= emitter.retries:
        raise
      inc attempt
      if emitter.transport == "rabbitmq":
        emitter.connectRabbit()
      let delayMs = min(5000, 250 * (1 shl (attempt - 1)))
      await sleepAsync(delayMs)


proc emitBatch*(emitter: Emitter, documents: openArray[JsonNode]) {.async.} =
  var offset = 0
  while offset < documents.len:
    let stop = min(documents.len, offset + emitter.batchSize)
    await emitter.emitChunk(documents[offset ..< stop])
    offset = stop


proc close*(emitter: Emitter) {.async.} =
  if not emitter.httpClient.isNil:
    emitter.httpClient.close()
  if not emitter.rabbit.isNil:
    emitter.rabbit.close()
