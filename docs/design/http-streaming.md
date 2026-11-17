# Streaming bodies for `abla/http` (client and server): design

Status: proposal, before code. It follows `docs/design/http2-client.md` and `docs/design/http2-server.md`, which left bodies fully buffered on purpose.

## Goal and non-goals

Bodies that do not fit in memory, or that must start before they end, work over HTTP/1.1 and HTTP/2 with the same API and bounded memory:

- the client reads a response as it arrives (a large download written to disk, a server-sent event stream) and sends a request body that a producer makes as it goes (an upload from a file);
- the server reads a request body as it arrives and sends a response body as the handler produces it (a large file, SSE, a proxy).

Memory is bounded by the receiver's pace, not by the sender's: a consumer that stops taking bytes stops the sender after one window.

Non-goals, each its own change: automatic gzip of a streamed response (the buffered path keeps it), WebSocket (`abla/websocket` exists), server push, bidirectional gRPC-style call APIs (HTTP/2 can carry them, the API here does not promise them), streaming trailers (trailers stay at the end: `HttpAsyncCompletion.trailers()`, and the stream's END event carries them).

## What is buffered today (facts)

- Client: `HttpAsyncClient.request` takes the body as a `string` and completes with the whole response in an `HttpAsyncCompletion` (`maximumResponseBytes`, 8 MiB). `H2Client` already emits one DATA event per frame, but `abla/http/async` joins them. HTTP/2 receive credit goes out as DATA arrives (`H2Stream.owed`, batched at half a window), not as the caller takes it. The request body is `H2Stream.body` plus `bodyPosition`; `pump` sends it as the windows allow.
- Server: the handler is `(HttpRequest) -> HttpResponse` on the event loop's thread; the request body is whole before it runs (`maximumBodyBytes`, 1 MiB; 413 beyond) and the response is a whole string. `H2Server.respond` takes a whole body and `pump`s it under the client's windows and a 256 KiB output queue. HTTP/1.1 (`httpEventFrame`) decodes `chunked` request bodies but only whole.
- Both HTTP/1.1 and HTTP/2 already have the mechanisms a stream needs: HTTP/1.1 chunked framing and `Content-Length` (`abla/http/stream` has `httpChunkEncode`, `httpChunkEnd`, `httpDecodeChunked` and the SSE helpers `sseResponseHead`/`sseChunk`, as whole-string functions: no server keeps a response open and writes events to it today), HTTP/2 DATA with windows. What is missing is the API and credit tied to consumption.

## One idea: credit follows consumption

Everything below is one rule. Bytes the peer sends are counted against a window (HTTP/2) or a high-water mark (HTTP/1.1: the socket stops being read). The window is credited back **when the consumer takes the bytes**, not when they arrive. A consumer that never takes them stalls the peer after one window per stream; the memory held is at most that window per open stream (256 KiB with today's `INITIAL_WINDOW_SIZE`) plus the connection window.

The buffered API stays exactly as it is and is built on the same machinery: it takes every event at once and completes at END, so it is a streaming consumer that never pauses (`maximumResponseBytes` still applies).

## Client API (`abla/http/async`)

New methods, same client, same `step`:

    client.getStream(url, headers, timeout): int            // an id; the response arrives as stream events
    client.requestStream(method, url, headers, length = -1): int
                                                            // length -1: unknown (chunked on HTTP/1.1, END_STREAM at finishBody on HTTP/2)
    client.writeBody(id, chunk): int                        // bytes accepted (<= chunk.size); 0: the send side is full, wait for a WRITABLE event
    client.finishBody(id): void
    client.readStream(id, max): string                      // up to max bytes of the response body ("" when none waits); reading is what credits the peer
    client.streamPending(id): int                           // the bytes that wait
    client.takeStreamEvents(): array<HttpAsyncStreamEvent>   // HEADERS(status, headers) | READABLE | WRITABLE | END(trailers) | ERROR(message)
    client.cancelStream(id)                                 // RST_STREAM(CANCEL) on HTTP/2, closes the connection on HTTP/1.1; its last event is ERROR "cancelled"

- `readStream` is the consumption point (a change from the first draft, which returned DATA in the events: a pull per stream lets one stream pause while the others go on). READABLE is sent when bytes arrive for a stream that had none waiting: read until `readStream` returns "". The stream window is credited as the bytes are read (a WINDOW_UPDATE once half a window was), the connection window on arrival, so one stalled stream cannot stall the others; not reading is the pause and there is no `resume`. **END comes after the last response byte was read**: a caller that ignores a response body never sees END.
- `writeBody` is bounded: a stream's unsent request bytes never exceed one HTTP/2 stream window plus the output cap (`H2_OUTPUT_CAP`), or the socket buffer on HTTP/1.1. A caller that writes more than is accepted keeps the rest and writes it when WRITABLE comes. `H2Stream.body` becomes a chunk queue with a `finished` flag; the whole-string body of today is the case "one chunk, finished".
- Timeouts: the per-request timeout of the buffered API stays a total. A stream has an idle timeout (no event or accepted byte for N ms) and an optional total deadline. The default idle timeout is 30 s.
- HTTP/1.1: one stream per connection as now. The response is read as the socket delivers; reading stops (interest off) when the undelivered bytes pass 256 KiB and resumes when `readStream` drains them. A request with unknown length is sent `Transfer-Encoding: chunked`.
- `http2PingAfterIdleMilliseconds`, GOAWAY handling and the one-retry rule apply as for buffered requests; a stream that already delivered bytes is never retried (an ERROR event says so).

## Server API (`abla/http/event/tls`, `abla/http/h2/server`)

The buffered handler is untouched. Streaming is opt-in per route, so the router API is extended, not changed:

    router.stream(method, path, handler: HttpStreamHandler)

    interface HttpStreamHandler {
        fun onRequest(exchange: HttpStreamExchange): void      // headers are in; no body yet
        fun onData(exchange: HttpStreamExchange, chunk: string): bool   // false: pause (no credit until exchange.resume())
        fun onEnd(exchange: HttpStreamExchange, trailers: array<HttpHeader>): void
        fun onWritable(exchange: HttpStreamExchange): void     // the response side has room again
        fun onAbort(exchange: HttpStreamExchange, reason: string): void
    }

    class HttpStreamExchange   // request: method, path, query, headers, peer; response: below
        respond(status, headers, length = -1): bool            // length -1: chunked on HTTP/1.1, open-ended on HTTP/2
        write(chunk): int                                      // accepted bytes; 0: wait for onWritable
        finish(trailers = []): void
        resume(): void
        abort(code): void                                      // RST_STREAM / close

- Interface callbacks, not closures: an exchange is a resource that lives as long as its stream, and closures that capture it would need the ownership rules for captured resources; an interface object that the handler owns does not. This is the one decision I would like confirmed (see the end).
- Callbacks run on the event loop's thread and must not block, like the buffered handler.
- Credit: the DATA of an `onData` that returned true is credited when it returns; a handler that returns false holds the credit until `resume()`. A handler that never returns false never pauses (its own memory is its business).
- Response bounds: `write` accepts at most the stream's send window plus 256 KiB of queue per stream, and the connection's total queued output stays under `H2_MAX_OUTPUT_BYTES` (786432, the existing cap). `H2Server.respond`'s body string becomes a chunk queue with a `finished` flag, the same change as `H2Stream.body` on the client.
- Request bounds: a streaming route has `maximumStreamBodyBytes` (default 0 = no limit, set explicitly; the buffered route keeps 1 MiB and 413). The Rapid Reset, MadeYouReset and CONTINUATION budgets, `H2_MAX_BUFFERED_BODY_BYTES` (it counts bytes a handler has not taken: for a streaming route that is the bytes held while paused) and the output caps apply as they do.
- An idle stream (no byte either way for `idleTimeoutMilliseconds`) is reset; a handler that paused and never resumed is aborted by the same timer.
- HTTP/1.1: a streaming route's request body is passed to `onData` as it arrives (Content-Length or chunked decoded incrementally); `Connection: close` after an aborted exchange; keep-alive after a clean one.
- No automatic gzip for streamed responses; a handler that wants it compresses its own chunks (`abla/compression/gzip`).

## Memory and limits (to be measured and bound in `docs/networking.md`)

Per open stream: the existing ~3 KB, plus at most one window of undelivered bytes in each direction (256 KiB request + 256 KiB response in the worst case). 100 streams (the default maximum) is therefore bounded by about 50 MiB in the worst case and is far less in practice; `tools/measure-http2-memory.sh` gets a slow-consumer mode that proves the bound with `h2load`/`nghttp` clients that do not read.

## Tests

- Sans-IO, in process: `H2Client`/`H2Server` streaming (a window is not credited until the bytes are taken; a paused stream stalls the peer after exactly one window; a producer that writes faster than the window gets partial accepts; END with trailers; abort in each state). Mutation checks as for the existing server tests: each must fail with credit-on-arrival back in.
- Fuzz: `tools/http2-fuzz/fuzz.ab` gains stream operations (write, take, pause, resume, finish, abort in random order against a scripted peer).
- Interop: nghttpd, nghttp, h2load, curl and h2o (`tools/test-http2-h2o.sh`): a 100 MiB download consumed slowly with bounded RSS, an upload from a producer that outpaces the window, SSE kept open and cut by the client, `Expect: 100-continue` against a streaming route, a stalled consumer under the idle timeout.
- HTTP/1.1: the same against `openssl s_server`, curl `--http1.1` and the pure-TLS client of `tests/cases/http2/upload.ab`, including chunked in both directions.

## Order of work

1. `H2Client`: the request body as a chunk queue with finish (the buffered `request` is "one chunk, finished"); receive credit tied to a `take` call rather than arrival, with the buffered path taking at once. Unit tests, fuzz.
2. `abla/http/async`: the stream API over HTTP/2 and HTTP/1.1 (response streaming first, then request streaming); the buffered API reimplemented on it with identical results (the existing http2, tls-faults and http-async tests are the check).
3. `H2Server`: the response chunk queue and `HttpStreamExchange` for responses (`write`, `finish`, `onWritable`).
4. `H2Server`: request streaming (`onData`, pause and `resume`, `maximumStreamBodyBytes`).
5. `HttpsEventServer` and `abla/http/event`: HTTP/1.1 streaming on both sides (incremental chunked decode, chunked encode), `router.stream`.
6. Docs, the memory measurements and bounds, the release note.

Each step lands with its own tests and does not change a buffered result.

## Decisions I would like confirmed before step 3

1. Interface callbacks (`HttpStreamHandler`) rather than closures or a polling `takeEvents` on the server. A polling server API (`server.takeStreamEvents()`) would mirror the client and avoids resources in callbacks, but the handler would then need its own loop around the server; callbacks keep the existing "give the server a handler" shape.
2. `maximumStreamBodyBytes` default 0 (no limit) on streaming routes, against a large default such as 1 GiB. Unlimited is what a file upload route wants, and the route is opt-in; the idle timeout bounds a stall, not a slow steady upload.
3. No automatic gzip for streamed responses in the first release.

## What exists (client side) and what was measured

`H2Client` has `requestStream`, `writeBody`, `finishBody`, `takeData`, `pendingData` and the READABLE and WRITABLE events; `HttpAsyncClient` has the API above over HTTP/2 (HTTP/1.1 streaming and the server side are the later steps). `writeBody` returns 0 until the first WRITABLE event, which the client sends when the stream is attached to a connection. A streaming request is never retried and a streaming response is not bounded by `maximumResponseBytes` (the caller's pace and the window bound it).

`tools/test-http2-stream.sh` (h2o and nghttpd, over h2c and TLS): a 1 GiB download and a 1 GiB upload over h2c, 64 MiB each over TLS and a consumer that stops reading for 1.5 s, all byte-exact; an unread stream held at most one stream window (262144 bytes) of the peer's data; `writeBody` took less than it was offered (backpressure) during the upload; the client process' resident memory peaked at **about 70 MB in every run**, from 64 MiB to 1 GiB, so it does not grow with the transfer (the Abla heap's garbage, collected). The test limit is 128 MiB.

A bug found by that test and fixed with it: the client counted every WINDOW_UPDATE as a frame that carries nothing, and ended the connection (ENHANCE_YOUR_CALM) after 1000 in a row, which nghttpd's one-update-per-DATA-frame reached at 16 MiB of upload. A window update on a request that is still being sent no longer counts. This affected buffered uploads too (v0.2.61's `http2 = true` client and any upload over 16 MiB to such a server).
