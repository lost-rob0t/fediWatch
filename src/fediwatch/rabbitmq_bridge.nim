import std/[strutils, uri]

{.compile: "rabbitmq_bridge.c".}
{.passL: "-lrabbitmq".}


type
  RabbitAddress* = object
    host*: string
    port*: int
    username*: string
    password*: string
    vhost*: string
    tls*: bool

  RabbitPublisher* = ref object
    handle: pointer


proc bridgeConnect(host: cstring, port, useTls: cint,
                   username, password, vhost, exchange: cstring,
                   error: cstring, errorLength: csize_t): pointer
    {.importc: "fw_rabbit_connect", cdecl.}

proc bridgePublish(handle: pointer, routingKey, body, messageId,
                   documentType: cstring, error: cstring,
                   errorLength: csize_t): cint
    {.importc: "fw_rabbit_publish", cdecl.}

proc bridgeClose(handle: pointer)
    {.importc: "fw_rabbit_close", cdecl.}


proc parseRabbitAddress*(value: string): RabbitAddress =
  let
    parsed = parseUri(value.strip())
    scheme = parsed.scheme.toLowerAscii()
  if scheme notin ["amqp", "amqps"]:
    raise newException(ValueError,
      "STARINTEL_RABBITMQ_URL must use the amqp or amqps scheme")
  if parsed.hostname.len == 0:
    raise newException(ValueError,
      "STARINTEL_RABBITMQ_URL is missing a hostname")

  result.host = parsed.hostname
  result.tls = scheme == "amqps"
  result.port = if result.tls: 5671 else: 5672
  if parsed.port.len > 0:
    try:
      result.port = parseInt(parsed.port)
    except ValueError:
      raise newException(ValueError,
        "STARINTEL_RABBITMQ_URL contains an invalid port")
  if result.port < 1 or result.port > 65_535:
    raise newException(ValueError,
      "STARINTEL_RABBITMQ_URL port must be between 1 and 65535")

  result.username =
    if parsed.username.len > 0: decodeUrl(parsed.username)
    else: "guest"
  result.password =
    if parsed.password.len > 0: decodeUrl(parsed.password)
    else: "guest"

  var path = parsed.path
  while path.len > 0 and path[0] == '/':
    path.delete(0, 0)
  result.vhost =
    if path.len == 0: "/"
    else: decodeUrl(path)


proc newRabbitPublisher*(address: RabbitAddress,
                         exchange: string): RabbitPublisher =
  var error = newString(512)
  let handle = bridgeConnect(
    address.host.cstring,
    address.port.cint,
    address.tls.cint,
    address.username.cstring,
    address.password.cstring,
    address.vhost.cstring,
    exchange.cstring,
    error.cstring,
    error.len.csize_t
  )
  if handle.isNil:
    raise newException(IOError,
      "RabbitMQ connection failed: " & $error.cstring)
  result = RabbitPublisher(handle: handle)


proc publish*(publisher: RabbitPublisher, routingKey, body,
              messageId, documentType: string) =
  if publisher.isNil or publisher.handle.isNil:
    raise newException(IOError, "RabbitMQ publisher is not connected")

  var error = newString(512)
  let status = bridgePublish(
    publisher.handle,
    routingKey.cstring,
    body.cstring,
    messageId.cstring,
    documentType.cstring,
    error.cstring,
    error.len.csize_t
  )
  if status != 0:
    raise newException(IOError,
      "RabbitMQ publish failed: " & $error.cstring)


proc close*(publisher: RabbitPublisher) =
  if not publisher.isNil and not publisher.handle.isNil:
    bridgeClose(publisher.handle)
    publisher.handle = nil
