# HTTP/2 server for abla/http (design)

Status: 2026-11-15, before code. Builds on abla/http/h2 (frame helpers, HPACK) and the client in docs/design/http2-client.md. RFC 9113, RFC 7541.

## What exists, what changes

- `abla/http/event` (the epoll HTTP/1.1 server) is **plain TCP only**: it has no TLS. Only `abla/websocket/server` has a TLS path (a `WebSocketServerTls` record of callbacks over `abla/tls/pure/server`'s `TlsServerSession`, so that a program without TLS does not link the crypto).
  So "ALPN h2 on the TLS listener" first needs an HTTPS listener for the HTTP server. The existing event server's hot path (region, no-escape handlers, scatter/gather writes) is tuned for plain sockets and is left alone.
- **Router API: no change.** A handler is `(HttpRequest) -> HttpResponse` (or a `HttpRouter`), fully buffered both ways. HTTP/2 invokes it once per stream when the request is complete (END_STREAM), with the same `HttpRequest` (method, path, query, headers, body, peer address) and sends the `HttpResponse` as HEADERS + DATA. Streaming bodies, SSE, WebSocket upgrade (RFC 8441), push and trailers are out of scope; a response with status 101 on an h2 stream is a 500.

## Pieces

1. `abla/http/h2/server`: `H2Server`, the sans-IO connection state machine (server side), next to `H2Client`: `feed(bytes, now)`, `takeOutput()`, `takeRequests()` (complete requests, each with its stream id), `respond(stream, status, headers, body)`, `tick(now)`, `shutdown()` (GOAWAY with the last stream id, then drain). It reuses the frame constants, flow-control rules and the HPACK codec of `abla/http/h2`.
2. `abla/http/event/tls` (new): `HttpsEventServer`, an epoll server with the same options shape as `HttpEventServer` plus a TLS configuration (`httpsEventServerTls(certPath, keyPath)`; a `TlsServerConfig` with `alpn = ["h2", "http/1.1"]`). Per connection: handshake (nonblocking), then by ALPN: `h2` -> an `H2Server`; `http/1.1` or no ALPN -> HTTP/1.1 through the existing `httpEventFrame`/`httpEventResponse`. With no TLS configured it serves plain TCP and takes h2c with prior knowledge (a connection that starts with the HTTP/2 preface); there is no `Upgrade: h2c`.
3. `TlsServerSession.alpn()` in abla/tls/pure (the machine has it).

## Server stream state machine

Streams are client-initiated odd ids, strictly increasing; a HEADERS on a lower or equal id than the highest seen is PROTOCOL_ERROR. `idle -> open -> half-closed(remote) -> closed` as RFC 9113 section 5.1; a request is dispatched at END_STREAM; the response is queued under the flow-control windows and the output cap (backpressure: no handler runs while the connection's output queue is over the cap and the stream limit is full).
Request rules checked (stream errors, RST_STREAM PROTOCOL_ERROR): the pseudo-headers `:method`, `:scheme`, `:path` exactly once (`:authority` optional, `host` used when absent), none after a regular header, no response pseudo-headers, no uppercase names, no connection-specific headers (`te` only `trailers`), `content-length` must match the DATA, CONNECT is refused (501 is not needed: stream error REFUSED_STREAM... see below).

## Limits (the attack surface)

- **Rapid Reset (CVE-2023-44487, CVE-2023-39325)**: a client opens streams and resets them at once, so that the server has done work but the concurrent-stream limit never fills. Defences, all on by default: (a) work is not started for a stream before END_STREAM *and* the handler runs only when the request is whole, so a reset before that costs a HEADERS decode only; (b) a budget of RST_STREAM frames received per connection per second (default 200 sustained, burst 400): over it, GOAWAY(ENHANCE_YOUR_CALM); (c) streams reset by the client count against `SETTINGS_MAX_CONCURRENT_STREAMS` until their response work is done (a reset stream whose handler already ran still counts as open for the limit while its output is queued), as nginx's and Go's fixes do; (d) the generic "frames that carry nothing" counters of the client (1000 in a row, 10,000 per second).
- **CONTINUATION flood (CVE-2024-27983 family)**: the header block is bounded before decoding: 32 CONTINUATION frames, 128 KiB raw, decoded list 64 KiB / 256 fields / 16 KiB field (the same HPACK decoder limits), and the block is decoded only at END_HEADERS; over: GOAWAY(ENHANCE_YOUR_CALM). No other frame may interleave (PROTOCOL_ERROR).
- HPACK bomb, window-update/PING/SETTINGS/empty-DATA floods, SETTINGS_TIMEOUT (10 s), PING ACK budget (100 pending), a frame over 16384 = FRAME_SIZE_ERROR: as in the client.
- `SETTINGS_MAX_CONCURRENT_STREAMS` 100, `INITIAL_WINDOW_SIZE` 256 KiB (per-stream request body cap `maximumBodyBytes`, as HTTP/1.1), `MAX_HEADER_LIST_SIZE` 64 KiB, `ENABLE_PUSH` n/a (server never pushes; a client's PUSH_PROMISE is PROTOCOL_ERROR).
- Slow readers: a stream whose response is blocked on the client's window for longer than the idle timeout is reset; the connection idle timeout and `maximumConnections` apply to HTTPS as to HTTP.
- Graceful shutdown: GOAWAY(NO_ERROR, 2^31-1) first, then GOAWAY(last id) after one round trip (RFC 9113 section 6.8), streams in flight finish within the drain timeout.

## Conformance and tests

h2spec 2.6.0 (in the pinned nixpkgs; added to shell.nix) is the target: its generic, HPACK and RFC 9113 groups must all pass against a test server built on `HttpsEventServer` (h2c and TLS); skips (none intended) would be listed with the reason. Our `H2Client` runs against the same server (and against nghttpd's client `nghttp`), scripted-peer tests drive `H2Server` for every limit (each failing with its check removed), a fuzz target joins `tools/http2-fuzz`, and `h2load` loads it.

## Order

`H2Server` + scripted tests + fuzz; the h2spec harness over h2c; `HttpsEventServer` (TLS, ALPN, HTTP/1.1 path); h2spec over TLS, `H2Client` interop, h2load; docs.
