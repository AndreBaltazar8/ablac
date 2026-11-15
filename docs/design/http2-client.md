# HTTP/2 for `abla/http/async` (client side): design

Status: proposal, 2026-11-15, before code. RFC 9113 (HTTP/2) and RFC 7541 (HPACK). Server side, h2c upgrade, push and priorities are out of scope.

## Goal and non-goals

- `HttpAsyncClient` stays as it is: same `request`, `get`, `postJson`, `step`, `takeCompletions`, same `HttpAsyncCompletion`. HTTP/2 is chosen by ALPN: an `https://`
  connection offers `h2, http/1.1`; if the server picks `h2` the connection is HTTP/2, else HTTP/1.1 as today. New behaviour is reached only through new optional
  `HttpAsyncOptions` fields.
- Many requests to one origin share one connection (multiplexed streams); `maximumConnectionsPerHost` is then a cap on extra connections opened when a connection's
  stream limit is reached, not the way concurrency is reached.
- Responses stay fully buffered (`maximumResponseBytes`, as now); no streaming API, trailers are kept: `HttpAsyncCompletion.trailers()` returns them (the client emits a TRAILERS event before END), no push (`SETTINGS_ENABLE_PUSH = 0`), no priorities.
- `http://` stays HTTP/1.1. h2c with prior knowledge exists but is off: `HttpAsyncOptions.http2PriorKnowledge = false`; when true every `http://` origin of that
  client is spoken to as h2c. There is no `Upgrade: h2c` (deprecated by RFC 9113).

## Layers

1. `abla/http/h2` (new, sans-IO like `abla/tls/pure`): frame codec, HPACK (`hpack` submodule), and `H2Client`, one connection's state machine. Bytes in (`feed`),
   bytes out (`takeOutput`), and a list of events out (`takeEvents`: response headers, data, end of stream, reset, goaway). No sockets, no clocks (the caller passes
   `now`), so it is testable in process against a scripted peer and fuzzable.
2. `abla/http/async` integrates it: a connection slot gets a protocol (1.1 or 2) and, for 2, an `H2Client`; requests keep their parts (method, authority, path,
   headers, body) instead of only a rendered HTTP/1.1 payload; the TLS session reads and writes the bytes `H2Client` produces and consumes.
3. `tlsSessionClient` gains `alpn` (default `[]`) and `TlsSession.alpn()` (the machine has `alpn()` already).

## The connection (`H2Client`)

States: `PREFACE` (client preface and our SETTINGS queued, nothing from the peer yet) -> `OPEN` (the peer's first frame, a SETTINGS, arrived; we ACK it) ->
`DRAINING` (a GOAWAY was received or sent: no new streams; closes when the last stream ends) -> `CLOSED` (error or EOF). The first frame from the peer must be SETTINGS
(else PROTOCOL_ERROR). We do not wait for it to send requests: the preface, our SETTINGS and the first HEADERS go out in one write after the TLS handshake.

We send at start: `ENABLE_PUSH=0`, `HEADER_TABLE_SIZE=4096`, `INITIAL_WINDOW_SIZE=262144`, `MAX_FRAME_SIZE=16384` (the default: not sent), `MAX_HEADER_LIST_SIZE=65536`
(advisory: we enforce it), `MAX_CONCURRENT_STREAMS` not sent (nothing is pushed to us), and a connection WINDOW_UPDATE to 1 MiB.

Per connection we keep: the peer's settings (as received, applied when seen), the connection send window and receive window, `lastStreamId` (highest we opened),
`peerLastStreamId` (from GOAWAY), the output queue, the HPACK encoder and decoder, a pending-ACK count, the stream table.

## Streams (client)

Ids are odd, increasing by 2; at 2^31-1 the connection takes no more streams (DRAINING) and a new connection opens. A stream:

| State | Entered by | Frames allowed |
|---|---|---|
| `IDLE` | not in the table (id above `lastStreamId` is idle) | any frame from the peer on an idle id: connection error PROTOCOL_ERROR |
| `OPEN` | we send HEADERS (no END_STREAM: a request body follows) | we send DATA/HEADERS(trailers); peer sends HEADERS/DATA/RST_STREAM/WINDOW_UPDATE |
| `HALF_CLOSED_LOCAL` | we send END_STREAM (HEADERS or last DATA) | peer sends HEADERS (final, after 1xx), DATA, trailers, RST_STREAM; we send WINDOW_UPDATE and RST_STREAM only |
| `HALF_CLOSED_REMOTE` | peer sends END_STREAM while we still send a body | we send DATA/RST_STREAM; the peer sends only WINDOW_UPDATE/RST_STREAM/PRIORITY; else STREAM_CLOSED (stream error) |
| `CLOSED` | both END_STREAM, or an RST_STREAM either way | see below |
| `RESET_LOCAL` (within `CLOSED`) | we sent RST_STREAM (timeout, oversize response, a stream error) | frames still arriving are dropped, but DATA still counts against the connection window (and is credited back); kept in a bounded set |

Receiving on a closed stream: within the bounded `RESET_LOCAL` set (128 entries, oldest dropped) frames are ignored; otherwise a frame other than PRIORITY/WINDOW_UPDATE/RST_STREAM
on a closed stream is STREAM_CLOSED (stream error, we answer RST_STREAM). PUSH_PROMISE anywhere is a connection error PROTOCOL_ERROR (we disabled it).

Response rules checked per stream (violations are stream errors, RST_STREAM PROTOCOL_ERROR, and the request completes with an error; the connection goes on): `:status` present exactly once,
before any regular header; no other pseudo-headers; no uppercase names; no connection-specific headers (`connection`, `keep-alive`, `proxy-connection`, `transfer-encoding`, `upgrade`); `te` only `trailers`;
1xx responses are skipped (an interim HEADERS must not end the stream); a final HEADERS may be followed by DATA and then optional trailers (HEADERS with END_STREAM and no pseudo-headers; decoded for HPACK state, counted
against the header limits, dropped); `content-length`, when present, must equal the DATA received (checked at END_STREAM); HEAD and 204/304 have no body.

## Requests we send

`:method`, `:scheme`, `:authority` (host, with the port when it is not the scheme's), `:path`, then the caller's headers lowercased, minus `host` (becomes `:authority`), `connection`, `keep-alive`,
`proxy-connection`, `transfer-encoding`, `upgrade` (dropped; `te` kept only as `te: trailers`), plus `content-length` for a body (the caller's wins) and a default `user-agent` only if the caller gave none (none by default, as now).
An empty body is HEADERS with END_STREAM; a body is HEADERS then DATA frames (at most the peer's `MAX_FRAME_SIZE`, within the stream and connection send windows), the last with END_STREAM. 100-continue is not
negotiated: the body is sent at once.

## HPACK and its limits

- **Decoder** (the dangerous side). One decoder per connection, fed header-block fragments as they arrive (HEADERS then CONTINUATION frames, which must follow immediately: anything else in between is a connection error PROTOCOL_ERROR), so memory is bounded by the limits, not by what the peer sends.
  - `HEADER_TABLE_SIZE` we advertise is 4096; a dynamic table size update above it is COMPRESSION_ERROR; table entries are accounted as name + value + 32 octets (RFC 7541 section 4.1), evicted from the oldest, never more than the cap.
  - Decoded header list size (sum of name + value + 32 per field, section 6.5.2 of RFC 9113) at most **64 KiB** per header block; one field at most 16 KiB; at most 256 fields. Over: connection error ENHANCE_YOUR_CALM after finishing to keep the HPACK table in step is impossible, so we send GOAWAY(ENHANCE_YOUR_CALM) and close (what nghttp2 and Go do): a block we cannot decode fully would desynchronize the table.
  - Raw block bytes (HEADERS + CONTINUATIONs) at most **128 KiB**, CONTINUATION frames at most **32** per block (the CONTINUATION flood class): over, the same GOAWAY.
  - Integer decoding refuses values that do not fit (more than 5 continuation octets), string lengths above the field cap are refused before reading them, Huffman decoding stops at the cap, padding longer than 7 bits or not all ones, and EOS in a string, are COMPRESSION_ERROR. Index 0 and indexes beyond the table are COMPRESSION_ERROR.
- **Encoder.** Dynamic table at most `min(peer's HEADER_TABLE_SIZE, 4096)`, with a table-size update sent when the peer's setting shrinks it. CRIME/BREACH-style leaks: a header is never added to the table if it is secret or
  attacker-influenced: `authorization`, `proxy-authorization`, `cookie`, `set-cookie`-class names and any header the caller names in `HttpAsyncOptions.http2NeverIndex` go out as literals *never indexed* (the 0001 pattern, which intermediaries must preserve); values of other headers shorter
  than 16 octets are indexed, longer ones sent as literals without indexing except for a small allow-list of stable names (`:authority`, `:scheme`, `user-agent`, `accept`, `accept-encoding`, `accept-language`, `content-type`). Huffman is used for a literal when it is shorter.

## Flow control

- Receive: stream window starts at our `INITIAL_WINDOW_SIZE` (256 KiB), connection window raised to 1 MiB. Data is moved into the response buffer as it arrives, so credit is returned when the DATA frame is consumed: a stream WINDOW_UPDATE once the credit owed reaches half the initial window, the connection one at a quarter of 1 MiB (never a WINDOW_UPDATE per frame: that is the window-update-flood amplifier). A peer that sends more than a window is FLOW_CONTROL_ERROR (stream error for a stream window, connection error for the connection window). A response over `maximumResponseBytes` is RST_STREAM(CANCEL) and "response too large".
- Send: the peer's connection and stream windows bound every DATA frame; `SETTINGS_INITIAL_WINDOW_SIZE` changes adjust all open streams' windows (they may go negative; sending resumes when positive); a window above 2^31-1 is FLOW_CONTROL_ERROR; a WINDOW_UPDATE of 0 is PROTOCOL_ERROR (stream or connection by id). Streams with pending body are served round-robin, one frame each, so one large upload cannot starve the others. Output we generate is capped at 256 KiB queued: past it no further DATA is produced until the socket drains (backpressure to the request bodies, not a growing buffer).

## Control frames, floods and errors

- SETTINGS: applied in order, ACKed (at most 100 ACKs/PING acks pending: past it ENHANCE_YOUR_CALM); our own SETTINGS must be ACKed within 10 s (SETTINGS_TIMEOUT otherwise); unknown settings ignored; invalid values (`ENABLE_PUSH` not 0/1, `MAX_FRAME_SIZE` outside 16384..16777215, `INITIAL_WINDOW_SIZE` above 2^31-1) are PROTOCOL_ERROR / FLOW_CONTROL_ERROR as the RFC says. We never raise our own `MAX_FRAME_SIZE`; a frame longer than 16384 is FRAME_SIZE_ERROR, a SETTINGS/PING/PRIORITY/RST_STREAM/WINDOW_UPDATE of the wrong length is FRAME_SIZE_ERROR, a frame on stream 0 that needs a stream (or the reverse) is PROTOCOL_ERROR.
- PING: answered with the ACK flag and the same 8 octets (queued, bounded as above); we send PING only for liveness (below).
- GOAWAY received: `peerLastStreamId`; streams above it were not processed and are requeued onto a new connection (a request is retried once, as for HTTP/1.1's stale connection, if it is idempotent or nothing was processed); streams at or below it finish or fail with "connection closed"; the connection is DRAINING and closes when the last stream ends. We send GOAWAY(NO_ERROR) when closing an idle connection and GOAWAY(error) before closing on a connection error; the debug data is empty (nothing about the peer reflected).
- RST_STREAM received: that stream's request completes with an error ("stream reset: CODE"); REFUSED_STREAM (or a stream above GOAWAY's last id) is retried on another connection once.
- Floods (Rapid Reset, PING/SETTINGS/empty-DATA/PRIORITY/WINDOW_UPDATE floods): a counter of frames that carried no useful payload (a control frame or an empty DATA without END_STREAM) since the last frame that did, and a budget of 10,000 control frames per second of connection life measured over a sliding second; past either (1,000 in a row, or the budget) GOAWAY(ENHANCE_YOUR_CALM) and close. The same counter structure `abla/tls/pure` uses for empty records and KeyUpdates.
- RST_STREAM we send: only for timeouts, oversize responses and stream errors; counted, but we are the client, so it does not reach the server-side Rapid Reset limits.
- Liveness: a connection idle longer than 30 s (option `http2PingAfterIdleMilliseconds`) gets a PING before a request uses it; no ACK within 5 s: the connection is dropped and the request goes to a new one (this replaces the HTTP/1.1 stale-connection retry for h2).
- Connection errors: error code from the table in RFC 9113 section 7, GOAWAY with the last stream id the peer opened (0: none), then close; every request on the connection completes with an error naming the code (except requeueable ones, above).

## Pool and request flow in `HttpAsyncClient`

- Origin key as now (`scheme://host:port`). New per-origin memory: `unknown`, `h2` or `h1`, set when the first TLS handshake of the origin finishes (ALPN). While `unknown`, only one connection is opened and further requests wait for it
  (so a burst to an h2 server opens one connection, not eight); after `h1` the old pool rules apply; after `h2`, requests are sent on an existing h2 connection of the origin that is not DRAINING and has open streams below `min(peer MAX_CONCURRENT_STREAMS, maximumStreamsPerConnection = 100)`;
  when none has room and fewer than `maximumConnectionsPerHost` exist, a new connection opens, else the request waits. The origin memory expires with the DNS cache entry (`dnsCacheSeconds`) so a server that stops speaking h2 is noticed.
- Deadlines are per request: on expiry an h2 request is RST_STREAM(CANCEL) and completes with "timeout", and the connection stays; an HTTP/1.1 request still closes its connection.
- `idleTimeoutMilliseconds` applies to an h2 connection with no open streams (GOAWAY NO_ERROR then close).
- TLS session resumption (`HttpAsyncOptions.sessions`) works unchanged (the ticket is bound to the ALPN protocol).
- Arrays: connection slots gain `connectionProtocol`, `connectionH2`; requests gain `requestMethods`, `requestHeaders`, `requestBodies`, `requestAuthorities`, `requestPaths` (the rendered HTTP/1.1 payload is built only when a request goes on an HTTP/1.1 connection); stream id <-> request index lives in `H2Client`.

## Options added (all defaulted; callers change nothing)

`http2: bool = false` (offer `h2`; off for one release so that callers opt in, then the default is revisited; the release notes say so), `http2PriorKnowledge: bool = false`, `maximumStreamsPerConnection: int = 100`, `http2NeverIndex: array<string> = []`, `http2PingAfterIdleMilliseconds: int = 30000`,
`maximumHeaderListBytes: int = 65536`. The hard limits above that are not options (header block 128 KiB, CONTINUATION 32, fields 256, windows, flood budgets) are constants in `abla/http/h2` so that a caller cannot weaken them by accident.

## Tests

1. HPACK: RFC 7541 appendix C (C.2 to C.6, with and without Huffman, request and response sequences), the Huffman table against every symbol, and the `http2jp/hpack-test-case` corpus (vendored subset with its commit), encoder round trip against the decoder, and the limits (bomb: many large literals, a table-size update storm, integer overflow, EOS in Huffman, truncated blocks) each with the check removed.
2. Frame codec and `H2Client` in process against a scripted peer (an Abla peer on the same codec): the preface, SETTINGS exchange and ACK, every state transition above, GOAWAY with requeue, RST_STREAM, flow control both ways (windows crossing zero, SETTINGS changing the initial window, WINDOW_UPDATE overflow), CONTINUATION flood, rapid-reset/PING/SETTINGS floods, wrong-length and wrong-stream frames, malformed responses. Every limit test fails with its check off (the mutation rule).
3. Fuzz: the frame and HPACK decoders under `tools/fuzz` style differential/robustness (never crash, never exceed the caps).
4. Interop: nghttpd and h2o from nix (both available: nghttp2 1.67, h2o) over TLS with ALPN, `h2load` for load and flow control against `nghttpd` (large bodies both ways, many concurrent streams, server-initiated GOAWAY with `nghttpd --max-concurrent-streams`/restart), `openssl s_server` for the ALPN fallback to HTTP/1.1; `HttpAsyncClient` end to end: 100 concurrent requests on one connection, mixed with HTTP/1.1 origins; the existing http/async and tls-faults tests unchanged and passing.
5. The standing rules: BoGo and the TLS tests do not change; tests print one line each; heavy runs in fair-flock slots.

## Order of work (no estimates)

1. `abla/http/h2/hpack` with its tests. 2. Frame codec and `H2Client` with the scripted-peer tests. 3. Integration in `abla/http/async` with ALPN in `tlsSessionClient`, then the pool changes. 4. Fuzz and the interop scripts (`tools/test-http2.sh`). 5. Docs (`docs/stdlib` http section) and the options table.

## Decisions (lead, approved)

- One connection first while an origin's protocol is unknown: accepted.
- Response header names arrive lowercase over h2 (HTTP/1.1 keeps the server's case) and trailers are returned by `HttpAsyncCompletion.trailers()` (first release: dropped, then kept).
- `http2` defaults to false for one release (callers opt in); noted in the release notes when it lands.
- The sans-IO `H2Client` has a fuzz target (`tools/http2-fuzz`) from the start, not at the end.
