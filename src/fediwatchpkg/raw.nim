## Bounded local full-response capture. No document model or broker is involved.
import std/[httpclient, httpcore, json, os, strutils, times, monotimes,
            uri, net, nativesockets, tables, algorithm, sysrand, posix, asyncdispatch, asyncstreams]
import fedi/instance

{.passL: "-lcrypto".}
proc opensslSha256(data: pointer, length: csize_t, digest: pointer): pointer
  {.importc: "SHA256", header: "<openssl/sha.h>".}
proc flock(fd, operation: cint): cint {.importc, header: "<sys/file.h>".}

const Format = "fediwatch.raw.v1"
const HeaderNames = ["content-type", "content-length", "content-encoding", "etag",
  "last-modified", "transfer-encoding", "retry-after", "x-ratelimit-limit", "x-ratelimit-remaining", "x-ratelimit-reset"]

type
  RawConfig = object
    output: string
    targets: seq[string]
    duration, requests, poll, timeout, limit: int
    maxResponse, maxArchive: int64
    local: bool
  HostState = object
    cursor: string
    nextAt: float
    failures: int
  RawSpool = object
    root, id, lastSource: string
    sequence, bytes: int64
    hosts: Table[string, HostState]
    lock: File

proc fail(message: string) {.noreturn.} =
  raise newException(ValueError, message)

proc digest(body: string): string =
  var value: array[32, byte]
  let data = if body.len == 0: nil else: unsafeAddr body[0]
  discard opensslSha256(data, csize_t(body.len), addr value[0])
  for item in value: result.add(toHex(item, 2).toLowerAscii())

proc timestamp(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'.'ffffff'Z'")

proc syncDirectory(path: string) =
  let fd = posix.open(path.cstring, O_RDONLY)
  if fd < 0: raiseOSError(osLastError())
  defer: discard posix.close(fd)
  if fsync(fd) != 0: raiseOSError(osLastError())

proc durableWrite(path, content: string) =
  let temporary = path & ".part"
  var file = open(temporary, fmWrite)
  try:
    setFilePermissions(temporary, {fpUserRead, fpUserWrite})
    file.write(content)
    file.flushFile()
    if fsync(cint(file.getFileHandle())) != 0: raiseOSError(osLastError())
  finally: file.close()
  moveFile(temporary, path)
  syncDirectory(path.parentDir)

proc numericId(value: string): bool =
  value.len > 0 and value.len <= 128 and (value.len == 1 or value[0] != '0') and value.allCharsInSet({'0'..'9'})

proc newer(a, b: string): bool =
  a.len > b.len or (a.len == b.len and a > b)

proc readConfig(path: string): RawConfig =
  let node = parseFile(path)
  if node.kind != JObject: fail("raw config must be an object")
  for key, value in node:
    if key notin ["output", "targets", "duration_seconds", "max_requests", "poll_seconds",
        "timeout_seconds", "limit", "max_response_bytes", "max_archive_bytes", "local"]:
      fail("unknown raw configuration field")
  result.output = node{"output"}.getStr()
  if result.output.len == 0: fail("raw output is required")
  if not node.hasKey("targets") or node["targets"].kind != JArray: fail("raw targets must be an array")
  for target in node["targets"]:
    if target.kind != JString: fail("raw targets must be strings")
    let host = target.getStr().toLowerAscii()
    when defined(rawFixture):
      let parsed = parseUri(host)
      if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.path notin ["", "/"] or
          parsed.username.len > 0 or parsed.password.len > 0 or parsed.query.len > 0 or parsed.anchor.len > 0:
        fail("fixture targets must be loopback HTTP origins")
      let origin = host.strip(chars={'/'})
    else:
      # Only explicit public DNS origins; no supplied paths, ports or credentials.
      if host.len > 253 or host.len == 0 or not host.allCharsInSet({'a'..'z', '0'..'9', '-', '.'}) or
          '.' notin host or host[0] == '.' or host[^1] == '.' or ".." in host or isIpAddress(host) or
          host.endsWith(".localhost") or host.endsWith(".local") or host.endsWith(".internal"):
        fail("raw targets must be public DNS hostnames without schemes, ports or paths")
      let origin = "https://" & host
    if origin notin result.targets: result.targets.add(origin)
  if result.targets.len == 0 or result.targets.len > 500: fail("use 1 to 500 explicit raw targets")
  template number(key: string, fallback, low, high: int64): int64 =
    block:
      let item = node{key}
      if item != nil and item.kind notin {JNull, JInt}: fail(key & " must be an integer")
      let value = item.getBiggestInt(fallback)
      if value < low or value > high: fail(key & " outside permitted bounds")
      int64(value)
  result.duration = int(number("duration_seconds", 300, 1, 86400))
  result.requests = int(number("max_requests", 500, 1, 100000))
  result.poll = int(number("poll_seconds", 30, 1, 3600))
  result.timeout = int(number("timeout_seconds", 10, 1, 60))
  result.limit = int(number("limit", 40, 1, 40))
  result.maxResponse = number("max_response_bytes", 8*1024*1024, 1, 64*1024*1024)
  result.maxArchive = number("max_archive_bytes", 256*1024*1024, 4096, 100*1024*1024*1024'i64)
  if node.hasKey("local") and node["local"].kind notin {JNull, JBool}: fail("local must be boolean")
  result.local = node{"local"}.getBool(true)

proc safeRoot(path: string): string =
  result = absolutePath(expandTilde(path)).normalizedPath()
  var ancestor = result
  while true:
    if symlinkExists(ancestor): fail("raw output must not use symlinks")
    if fileExists(ancestor / ".git" / "HEAD") or fileExists(ancestor / ".git"):
      fail("raw output must be outside Git checkouts")
    let parent = ancestor.parentDir
    if parent == ancestor or ancestor.len == 0: break
    ancestor = parent
  if result == "/": fail("raw output cannot be filesystem root")

proc openSpool(config: RawConfig): RawSpool =
  result.root = safeRoot(config.output)
  var missing: seq[string]
  var ancestor = result.root
  while not dirExists(ancestor):
    missing.add(ancestor)
    ancestor = ancestor.parentDir
  for index in countdown(missing.high, 0):
    createDir(missing[index])
    setFilePermissions(missing[index], {fpUserRead, fpUserWrite, fpUserExec})
    syncDirectory(missing[index].parentDir)
  for kind, path in walkDir(result.root):
    if kind in {pcLinkToFile, pcLinkToDir} or extractFilename(path) notin [".writer.lock", "spool.json", "spool.json.part", "captures"]:
      fail("raw output contains unrecognized entries")
  result.lock = open(result.root / ".writer.lock", fmAppend)
  setFilePermissions(result.root / ".writer.lock", {fpUserRead, fpUserWrite})
  if flock(cint(result.lock.getFileHandle()), 2 or 4) != 0:
    result.lock.close()
    fail("another raw writer is active")
  result.hosts = initTable[string, HostState]()
  createDir(result.root / "captures")
  setFilePermissions(result.root / "captures", {fpUserRead, fpUserWrite, fpUserExec})
  syncDirectory(result.root)
  if fileExists(result.root / "spool.json"):
    let identity = parseFile(result.root / "spool.json")
    if identity{"format"}.getStr() != Format: fail("unsupported raw spool format")
    result.id = identity["spool_id"].getStr()
    if result.id.len != 32 or not result.id.allCharsInSet({'0'..'9', 'a'..'f'}): fail("invalid spool identity")
    if identity{"local"}.getBool(not config.local) != config.local: fail("raw timeline scope changed; use a new spool")
  else:
    for item in urandom(16): result.id.add(toHex(item, 2).toLowerAscii())
    durableWrite(result.root / "spool.json", $(%*{"format": Format, "spool_id": result.id, "local": config.local}) & "\n")
  var manifests: seq[string]
  for kind, path in walkDir(result.root / "captures"):
    if kind != pcFile: fail("raw captures must be regular files")
    result.bytes += getFileSize(path)
    let name = extractFilename(path)
    let number = name.split('.')[0]
    if number.len != 20 or not number.allCharsInSet({'0'..'9'}): fail("unrecognized raw capture filename")
    result.sequence = max(result.sequence, parseBiggestInt(number))
    if path.endsWith(".json"): manifests.add(path)
    elif not (path.endsWith(".body") or path.endsWith(".part")): fail("unrecognized raw capture file")
  manifests.sort()
  for path in manifests:
    let record = parseFile(path)
    if record{"format"}.getStr() != Format or record["spool_id"].getStr() != result.id:
      fail("raw capture format or identity mismatch")
    let body = result.root / "captures" / extractFilename(path).replace(".json", ".body")
    # A committed receipt is trustworthy only with its matching original.
    if not fileExists(body) or getFileSize(body) > 64*1024*1024 or getFileSize(body) != record["bytes"].getBiggestInt() or
        digest(readFile(body)) != record["sha256"].getStr(): fail("raw original verification failed")
    let source = record["source"].getStr()
    var state = result.hosts.getOrDefault(source)
    let cursor = record{"cursor_after"}.getStr()
    if cursor.len > 0 and not numericId(cursor): fail("invalid raw checkpoint")
    state.cursor = cursor
    state.nextAt = record{"next_poll_at"}.getFloat()
    state.failures = record{"failures"}.getInt()
    result.hosts[source] = state
    result.lastSource = source
  result.bytes += getFileSize(result.root / "spool.json")

proc publicAddress(address: string): bool =
  let ip = parseIpAddress(address)
  if ip.family == IpAddressFamily.IPv4:
    let a = ip.address_v4
    return not (a[0] in [0'u8, 10, 127] or a[0] >= 224 or
      (a[0] == 169 and a[1] == 254) or (a[0] == 172 and a[1] in 16'u8..31'u8) or
      (a[0] == 192 and a[1] in [0'u8, 168]) or (a[0] == 100 and a[1] in 64'u8..127'u8) or
      (a[0] == 198 and a[1] in [18'u8, 19, 51]) or (a[0] == 203 and a[1] == 0))
  let a = ip.address_v6
  # Accept global-unicast 2000::/3 only, excluding the documentation prefix.
  (a[0] and 0xe0'u8) == 0x20'u8 and not (a[0] == 0x20 and a[1] == 0x01 and a[2] == 0x0d and a[3] == 0xb8)

proc checkPublicDns(origin: string) =
  when not defined(rawFixture):
    let address = getAddrInfo(parseUri(origin).hostname, Port(443), AF_UNSPEC, SOCK_STREAM, IPPROTO_TCP)
    defer: freeAddrInfo(address)
    var entry = address
    if entry == nil: fail("source DNS returned no addresses")
    while entry != nil:
      if not publicAddress(getAddrString(entry.ai_addr)): fail("source resolved to a non-public address")
      entry = entry.ai_next

proc cooldown(headers: HttpHeaders, status, poll: int): float =
  result = float(poll)
  let retry = headers.getOrDefault("retry-after").toString.strip()
  if retry.len > 0:
    try: result = max(result, parseFloat(retry))
    except ValueError:
      try: result = max(result, float(parseTime(retry, "ddd, dd MMM yyyy HH:mm:ss 'GMT'", utc()).toUnix) - epochTime())
      except TimeParseError: discard
  if headers.getOrDefault("x-ratelimit-remaining").toString.strip() == "0" or status == 429:
    let reset = headers.getOrDefault("x-ratelimit-reset").toString.strip()
    for format in ["yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'", "yyyy-MM-dd'T'HH:mm:sszzz"]:
      try:
        result = max(result, float(parseTime(reset, format, utc()).toUnix) - epochTime())
        break
      except TimeParseError: discard
    if status == 429: result = max(result, 60.0)
  if status in [401, 403, 404]: result = max(result, 86400.0)
  # Non-finite, malformed or extremely large headers must never make busy loops.
  if result != result or result < float(poll): result = float(poll)
  result = min(result, 7*86400.0)

type RawResponse = object
  body, error: string
  headers: HttpHeaders
  status: int
  complete: bool

proc fetchRaw(url: string, config: RawConfig, deadline: MonoTime): Future[RawResponse] {.async.} =
  result.headers = newHttpHeaders()
  let client = newAsyncHttpClient(userAgent="fediWatch/raw-v1 (+https://github.com/lost-rob0t/fediWatch)",
    maxRedirects=0, sslContext=newContext(verifyMode=CVerifyPeerUseEnvVars))
  defer: client.close()
  client.headers = newHttpHeaders({"Accept": "application/json", "Accept-Encoding": "identity"})
  let requestDeadline = min(deadline, getMonoTime() + initDuration(seconds=config.timeout))
  template timeoutMs(): int =
    max(1, int((requestDeadline-getMonoTime()).inMilliseconds))
  try:
    let request = client.get(url)
    if not await withTimeout(request, timeoutMs()): fail("request_timeout")
    let response = request.read()
    result.headers = response.headers
    result.status = int(response.code)
    # Nim 2.2's body parser recognizes only the exact lowercase chunked token.
    # Never label un-decoded framing as a complete entity body.
    let transfer = result.headers.getOrDefault("transfer-encoding").toString
    if transfer.len > 0 and transfer != "chunked":
      result.error = "unsupported_transfer_encoding"
      return
    let expected = result.headers.getOrDefault("content-length").toString
    if expected.len > 0 and parseBiggestInt(expected) > config.maxResponse:
      result.error = "response_too_large"
      return
    while true:
      if getMonoTime() >= requestDeadline: fail("request_timeout")
      let read = response.bodyStream.read()
      if not await withTimeout(read, timeoutMs()): fail("body_timeout")
      let (available, chunk) = read.read()
      if not available: break
      let remaining = int(config.maxResponse) - result.body.len
      result.body.add(chunk[0 ..< min(remaining, chunk.len)])
      if chunk.len > remaining:
        result.error = "response_too_large"
        return
    if expected.len > 0 and parseBiggestInt(expected) != result.body.len:
      result.error = "truncated_response"
      return
    result.complete = true
  except CatchableError as exc:
    # Do not persist exception text, which can contain headers or credentials.
    result.error = $exc.name

proc capture(config: RawConfig, spool: var RawSpool, source: string, deadline: MonoTime) =
  var state = spool.hosts.getOrDefault(source)
  let requestPath = publicTimelinePath(local=config.local, limit=config.limit, minId=state.cursor)
  let url = source & "/" & requestPath
  inc spool.sequence
  let stem = align($spool.sequence, 20, '0')
  let bodyPath = spool.root / "captures" / (stem & ".body")
  let observedAt = timestamp()
  var response: RawResponse
  try:
    checkPublicDns(source)
    response = waitFor fetchRaw(url, config, deadline)
  except CatchableError as exc:
    response.headers = newHttpHeaders()
    response.error = $exc.name
  let body = response.body
  let headers = response.headers
  let status = response.status
  let complete = response.complete
  let error = response.error
  # Persist even non-JSON, errors and partial responses, before any parsing.
  durableWrite(bodyPath, body)
  var nextCursor = state.cursor
  var parseState = "not_attempted"
  if complete and status == 200:
    try:
      let timeline = parseJson(body)
      if timeline.kind != JArray: fail("timeline_not_array")
      var candidate = state.cursor
      for post in timeline:
        if post.kind != JObject or not post.hasKey("id") or post["id"].kind != JString or not numericId(post["id"].getStr()):
          fail("invalid_timeline_cursor")
        let id = post["id"].getStr()
        if newer(id, candidate): candidate = id
      nextCursor = candidate
      parseState = "cursor_read"
    except CatchableError:
      parseState = "cursor_unavailable"
  if complete and status == 200 and parseState == "cursor_read": state.failures = 0
  else: state.failures = min(state.failures+1, 10)
  var delay = cooldown(headers, status, config.poll)
  if state.failures > 0: delay = max(delay, float(min(3600, config.poll * (1 shl state.failures))))
  state.nextAt = epochTime() + delay
  var retainedHeaders = newJObject()
  for name in HeaderNames:
    let value = headers.getOrDefault(name).toString
    if value.len > 0 and value.len <= 1024: retainedHeaders[name] = %value
  let record = %*{"format": Format, "spool_id": spool.id,
    "capture_id": spool.id & ":" & $spool.sequence, "sequence": spool.sequence,
    "observed_at": observedAt, "completed_at": timestamp(), "source": source,
    "url": url, "status": status, "headers": retainedHeaders,
    "body": "captures/" & stem & ".body", "sha256": digest(body), "bytes": body.len,
    "complete": complete, "error": error, "cursor_status": parseState,
    "cursor_before": state.cursor, "cursor_after": nextCursor,
    "next_poll_at": state.nextAt, "failures": state.failures}
  let metadata = $record & "\n"
  durableWrite(spool.root / "captures" / (stem & ".json"), metadata)
  spool.bytes += body.len + metadata.len
  # The durable manifest is the checkpoint; recovery replays these in sequence.
  state.cursor = nextCursor
  spool.hosts[source] = state
  spool.lastSource = source
  echo "raw capture ", spool.sequence, ": HTTP ", status, ", ", body.len, " bytes, complete=", complete

proc runRaw*(path: string): int =
  let config = readConfig(path)
  var spool = openSpool(config)
  defer: spool.lock.close()
  let deadline = getMonoTime() + initDuration(seconds=config.duration)
  var requests = 0
  while getMonoTime() < deadline and requests < config.requests:
    var progressed = false
    let previous = config.targets.find(spool.lastSource)
    let start = if previous < 0: 0 else: (previous+1) mod config.targets.len
    for offset in 0..<config.targets.len:
      let source = config.targets[(start+offset) mod config.targets.len]
      if getMonoTime() >= deadline or requests >= config.requests: break
      if spool.bytes + config.maxResponse + 65536 > config.maxArchive:
        echo "raw archive budget reached"
        return 0
      if spool.hosts.getOrDefault(source).nextAt > epochTime(): continue
      capture(config, spool, source, deadline)
      inc requests
      progressed = true
    if not progressed: sleep(100)
  echo "raw capture stopped after ", requests, " requests"
  return 0

proc rawMain*(): int =
  var path = getEnv("FEDIWATCH_RAW_CONFIG")
  if paramCount() > 0:
    if paramCount() != 2 or paramStr(1) != "--raw-config":
      stderr.writeLine("usage: fediWatchRaw --raw-config CONFIG.json")
      return 2
    path = paramStr(2)
  if path.len == 0:
    stderr.writeLine("set FEDIWATCH_RAW_CONFIG or use --raw-config CONFIG.json")
    return 2
  try: result = runRaw(path)
  except CatchableError as exc:
    stderr.writeLine("raw capture stopped: ", $exc.name)
    result = 1
