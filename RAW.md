# Local full-response logging

Raw mode is an opt-in local time-slice collector in the existing Nim FediWatch
application. It keeps complete public-timeline HTTP entity bodies before JSON
parsing, filtering or document projection. It does not require a running router,
canonical document validation, enrichment or graph construction.

## Run

Copy `config/raw.example.json`, set an output directory **outside every Git
checkout**, and explicitly list the public instance DNS hostnames to observe.
The example runs for at most five minutes / 100 requests / 256 MiB of retained
spool data, with a conservative per-instance cadence. The listed example host
is configuration, not a claim that its anonymous timeline is available.

```sh
nix build .#raw
./result/bin/fediWatchRaw --raw-config config/raw.example.json
```

The full actor exposes exactly the same implementation:

```sh
fediWatch --raw-config config/raw.example.json
# Alternatively set FEDIWATCH_RAW_CONFIG to the config file path.
```

Raw mode returns before the actor connects to StarRouter. Existing document mode
is unchanged when the raw option is absent. Raw mode supports anonymous public
API requests only. Do not put credentials into configuration or target URLs.

A native build (including a suitable Termux installation) needs Nim 2, a C
compiler and OpenSSL development headers/libraries. It uses only the public
Mastodon helper dependency, pinned to the same revision as the full actor:

```sh
git clone https://github.com/lost-rob0t/fedi.git ../fedi
git -C ../fedi checkout d6a3d7f7674e35677f5a529f9b0e8e332b198602
nim c -d:ssl --noNimblePath --path:../fedi/src --out:fediWatchRaw src/fediWatchRaw.nim
./fediWatchRaw --raw-config config/raw.example.json
```

The raw-only executable does not compile StarIntel document or ZeroMQ modules.
The Nix package is currently x86_64-linux; the native command is the portable
build route. A successful Linux fixture is not evidence of an Android run.

## What is captured

Each response has an unchanged `.body` file and a separate `.json` receipt.
Bodies are bytes after HTTP transfer framing is removed, not packet captures.
Content encoding is retained and recorded. Unsupported transfer encodings
(including non-lowercase chunked framing unsupported by Nim 2.2) are recorded
as incomplete empty captures with the original transfer-encoding header; they
never advance progress or masquerade as a complete entity body. `Accept-Encoding: identity` requests
uncompressed responses; the body is never reserialized. Non-JSON error pages,
unknown fields, HTML, null/false values, source timestamps and media links remain
untouched. Attachments, thumbnails and media bodies are **never fetched**.

Successful, failed and partial responses all receive a receipt. `complete=false`
means the response was interrupted, timed out, or exceeded the byte limit;
retained bytes are only a prefix, possibly empty. Such a response does not
advance the cursor. A JSON parsing failure does not undo its saved body.

Only source URL/origin, status and a small response-header allowlist are recorded.
Request headers, authentication, cookies and redirect locations are not logged.
Targets cannot contain paths, ports, IP literals, query strings or userinfo.
Production uses HTTPS with certificate verification, prechecks resolved addresses
for public ranges, and never follows redirects. It does not discover new hosts
or access authenticated/private timelines. Explicit configuration of a domain
remains a trust decision; DNS prechecks are not a network isolation boundary.

## Spool format: fediwatch.raw.v1

- `spool.json`: `format`, random `spool_id`, and `local` timeline scope.
- `captures/<20-digit sequence>.body`: original response bytes.
- `captures/<20-digit sequence>.json`: commit receipt and checkpoint.
- `.writer.lock`: prevents concurrent writers to the same spool.

Receipt fields are `format`, `spool_id`, `capture_id`, `sequence`, `observed_at`,
`completed_at`, `source`, `url`, `status`, `headers`, `body`, `sha256`, `bytes`,
`complete`, `error`, `cursor_status`, `cursor_before`, `cursor_after`,
`next_poll_at` and `failures`. `body` is relative to the spool root.

`observed_at` is the UTC request-start timestamp; `completed_at` records the
finished capture. Neither is a post's source timestamp. Future import/replay
must preserve both timestamps, `capture_id` and `sequence` unchanged and store
its ingestion time separately. Sequence is the deterministic tie-break within
one spool, including captures that share a timestamp. A capture ID is
`<spool_id>:<sequence>`. Repeated identical response bytes remain separate timed
observations; downstream content-addressed storage can deduplicate their bytes.

The receipt is a commit marker. The body is flushed, fsynced and atomically
renamed before parsing. The receipt is then flushed, fsynced and atomically
renamed; only afterward does in-memory progress advance. On restart, receipts
are verified against body SHA-256 and size and replayed in sequence to rebuild
per-origin progress. Orphan `.body`/`.part` files remain for inspection, count
against the disk budget and reserve their sequence, but cannot advance progress.
A corrupted committed body fails closed. A crash before the receipt can cause
at-least-once re-fetching, not a false committed checkpoint. No files are deleted.

## Bounds and availability

`duration_seconds`, `max_requests`, `max_response_bytes` and `max_archive_bytes`
bound run duration, request count, retained entity-body bytes and retained spool
bytes respectively. `max_response_bytes` is not an aggregate wire-byte or process
memory limit: Nim 2.2 buffers HTTP headers internally before exposing them and
may buffer incoming body chunks. A hostile fast server can therefore consume
more transport memory/bandwidth than the retained-body limit. This mode accepts
explicitly configured hosts; use process/network isolation when that matters.
A response slot is reserved conservatively against the
spool budget before each request. File I/O errors stop collection; progress is
not published for the failed write. The output is private to the local user.

Hosts are visited in rotating configuration order, each with independent next-request
time. Restart begins after the last committed configured origin, so repeated
one-request runs do not starve later hosts. One rate-limited host does not put all others to sleep. `Retry-After`,
rate-limit reset and remaining headers extend cooldown, including a 429 without
a remaining header. 401/403/404 suspend that origin for a day; other failures
use capped exponential backoff. Requests are sequential, so a slow host can
consume its bounded timeout before the next host runs. Persistent DNS resolution
may also depend on the operating system's resolver timeout.

`local=true` collects only local statuses from each configured instance. Setting
it false requests the server's broader public timeline. Changing this scope
requires a new spool so an old cursor cannot silently change meaning. The first
poll captures the current page; later polls use the greatest safely parsed
numeric status ID as `min_id`. IDs are read only after the full body is durable.
Unparseable IDs leave the cursor unchanged. This is a temporary observable
public-API time slice, not an assurance of exhaustive history, deleted-post
recovery, continuous streaming, or coverage of the whole Fediverse.

Mastodon supports up to 40 statuses per public-timeline page; public access is
instance-configurable and may require authentication. Empty results can also
mean the feed is disabled. See [timeline API](https://docs.joinmastodon.org/methods/timelines/)
and [rate limits](https://docs.joinmastodon.org/api/rate-limits/).

## Tests

`tests/raw_capture.py` drives real compiled executables against bounded local
HTTP fixtures: byte preservation, no media follow-up, resume, crash orphans,
corruption detection, malformed/un-normalizable JSON, rate limits, blocked hosts,
truncation, oversized fixed/chunked bodies, redirects, multi-host fairness and
configuration/output safety. Fixture-only loopback HTTP support is compiled
with `-d:rawFixture`; the production executable rejects those targets.

```sh
nix build .#raw
# Runs the raw fixture without schema validation or a broker.
```

The normal full-actor Nix/container gates still validate document mode separately.
No test implicitly launches broad live collection.
