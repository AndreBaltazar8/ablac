# Networking

Abla's networking stack is source-level, bounded, and ownership-safe. The
current production socket backend issues Linux x86-64 system calls directly,
so TCP, UDP, HTTP, and WebSocket transports do not require a project-owned
socket shim. Hosted executables use Abla's normal value runtime.

## Socket model

`abla/net` exports:

- IPv4 and IPv6 socket addresses, any/loopback helpers, explicit IPv6 scope
  identifiers, and dual-stack listeners;
- affine `TcpListener`, `TcpConnection`, `UdpSocket`, and `SocketPoller`
  resources with deterministic cleanup and idempotent `close`;
- structured `SocketReadResult`, `SocketWriteResult`, `SocketPollResult`, and
  `UdpDatagram` results;
- bounded TCP connect/read deadlines and UDP receive deadlines; and
- an epoll-backed multi-socket readiness poller.

`abla/net/contracts` defines backend-neutral `NetworkError`,
`NetworkReadOutcome`, `NetworkWriteOutcome`, and `NetworkCancellation` values.
The raw and hosted transports adapt their platform results to this shared
contract. `readNetwork` and `writeNetwork` enforce monotonic end-to-end
deadlines and split waits into short poll slices, so cooperative cancellation
is observed without a separate interruption thread.

`abla/net/hosted` supplies the corresponding hosted resources with DNS-capable
connect/bind calls. Its runtime adapter selects epoll on Linux and kqueue on
macOS. This keeps the raw no-libc profile independent from libc while allowing
portable service code to opt into the operating system resolver.

An empty TCP read is no longer ambiguous when using the structured API:

```abla fragment
val incoming = connection.readWithTimeoutResult(65536, 5000)
if (incoming.hasData()) process(incoming.bytes)
else if (incoming.reachedEof()) connection.close()
else if (incoming.timedOut()) recordIdleConnection()
else reportNetworkError(incoming.errorCode)
```

The older `read`, `readWithTimeout`, and `write` conveniences remain available
for source compatibility. New services should use the result-bearing methods.

Resources close automatically on scope exit, early return, loop control, and
owned transfer. Calling `close` explicitly sets the descriptor to `-1`, making
subsequent cleanup a verified no-op.

## TCP and UDP

```abla build
import "abla/net"

fun main {
    val listener = tcpListenAddress(ipv4Loopback(8080))
    val connection = listener.accept()
    val request = connection.readWithTimeoutResult(65536, 5000)
    if (request.hasData()) connection.writeResult("response")
    connection.close()
    listener.close()
}
```

UDP preserves datagram boundaries and reports the source address:

```abla build
import "abla/net"

fun main {
    val socket = udpBindPort(8081)
    val datagram = socket.receiveFromWithTimeout(65507, 5000)
    if (datagram.received) socket.sendTo(datagram.bytes, datagram.source)
}
```

UDP binds to port 0 do not enable address reuse, including when requested
explicitly, so an OS-selected port is not shared with another socket. Explicit
nonzero server ports retain the requested reuse behavior.

`SocketPoller` owns one epoll descriptor. `watchDescriptor`,
`modifyDescriptor`, `unwatchDescriptor`, and `wait` expose readable, writable,
closed, and error readiness without giving the poller ownership of watched
sockets.

## Unix-domain streams

`unixSocketAddress(path)` selects a filesystem pathname; `unixAbstractAddress(name)`
selects Linux's abstract namespace. `unixListen(address, backlog)` returns a
`UnixListener`, whose `accept()` returns a `UnixConnection`; `unixConnect(address,
timeoutMilliseconds)` returns a connection. They use the same result, polling,
timeout, nonblocking and close operations as TCP. Negative descriptors report
errors, and nonblocking connect reports `-11` when a Unix listener's queue is full.

Paths are byte strings: filesystem paths must be nonempty, contain no NUL, and fit
107 bytes on Linux or 103 bytes on macOS. Abstract names can contain NUL and fit
107 bytes; macOS returns `EAFNOSUPPORT`. A listener neither removes an existing
pathname nor unlinks its pathname on close. Once all users have finished, its owner
can call `path(socketPath).remove()`. Abstract names disappear when their last
socket closes.

For a local HTTP daemon, `httpUnixClient("localhost", unixSocketAddress(socketPath))`
returns the same `HttpClient` as the IPv4 transport, including response limits and
an optional whole-exchange deadline.

Server-side `HttpRequest.peerAddress` is the accepted socket's IP address and port,
or null when no IP peer is available. The address has `address`, `port`, `family`
(4 or 6), and IPv6 `scopeId` fields. `X-Forwarded-For` and `CF-Connecting-IP`
remain untrusted headers and never populate this field.

## HTTP routing

`abla/http` separates routing from transport: a router maps a method and a
path pattern to a handler, and `dispatch` runs it for one request. The
same router serves `serveHttp(router, port)`, the event server below, or a
test that builds requests by hand:

```abla
import "abla/io"
import "abla/http"

fun showUser(request: HttpRequest): HttpResponse =
    httpText("user ${request.routeParameter("id")}, verbose=${request.queryParameter("verbose")}")

fun createUser(request: HttpRequest): HttpResponse =
    httpJson("{\"created\":\"${request.body}\"}", 201)

fun main {
    val router = httpRouter()
    router.get("/users/:id", showUser)
    router.post("/users", createUser)
    val first = router.dispatch(httpParseRequest("GET /users/42?verbose=1 HTTP/1.1\r\nHost: example\r\n\r\n"))
    println("${first.status} ${first.body}")
    val second = router.dispatch(httpPost("/users", "ada"))
    println("${second.status} ${second.header("Content-Type")} ${second.body}")
    val missing = router.dispatch(httpGet("/nowhere"))
    println("${missing.status} ${httpStatusReason(missing.status)}")
}
// output:
// 200 user 42, verbose=1
// 201 application/json {"created":"ada"}
// 404 Not Found
```

| Function | Purpose |
|---|---|
| `httpRouter(versionHeader = "Abla-Version")` | a router; `get`, `post`, `put`, `patch`, `delete`, `head`, `options`, `route(method, pattern, handler)` add routes; `:name` segments are parameters |
| `router.version("2025-01-01").get(...)` | a versioned route, chosen by the version header ([standard-library.md](standard-library.md#http-versioning)) |
| `router.dispatch(request)` | the response for one request (404 when no route matches) |
| `request.header(name)`, `routeParameter(name)`, `queryParameter(name)`, `parameter(name)` | request accessors (`""` when absent; header names are case-insensitive; `queryParameter` returns the raw, still percent-encoded text) |
| `request.queryParameterDecoded(name)` | the query value with `%XX` and `+` undone (`percentDecode` in query mode), or `null` when absent, empty or malformed |
| `request.path`, route parameters | the raw path and the raw text of each `:name` segment: not percent-decoded (`%2e%2e` and `%2f` stay as written), and `..`, `.` and empty segments (`//`) are not removed or collapsed, so `/a/../b` matches `/a/:x/b` with `x` = `..`. Decode with `percentDecode` and check the result (no `/`, `..` or NUL) before using a parameter as a file name or a key |
| `httpText(body, status = 200)`, `httpJson(body, status = 200)` | responses with a content type |
| `httpGet(path)`, `httpPost(path, body)`, `httpRequest(method, path, body, headers)` | build a request |
| `httpParseRequest(text)`, `httpParseResponse(text)`, `response.render()` | parse and render the wire format |
| `serveHttp(router, port)`, `serveHttpOnce`, `serveHttpOnListener` | serve over TCP, one request per connection, serially (persistent connections: `abla/http/event`) |
| `httpIpv4Client(authority, address, port, maximumResponseBytes, timeoutMilliseconds, deadlineMilliseconds)`, `httpsClient(host, port, maximumResponseBytes, timeoutMilliseconds, deadlineMilliseconds)` (from `abla/http/tls`), `client.send(request)` | send requests. `timeoutMilliseconds` bounds each read and write. The optional `deadlineMilliseconds` bounds the whole exchange. |

### Portable sockets: `abla/net/hosted`

`abla/net` speaks to the Linux kernel directly. `abla/net/hosted` offers the
same kind of resources on Linux and macOS, with host-name resolution:

```abla
import "abla/io"
import "abla/net/hosted"

fun main {
    val listener = hostedTcpListen("127.0.0.1", 0)       // port 0: any free port
    val client = hostedTcpConnect("127.0.0.1", listener.localPort())
    val server = listener.accept()
    client.writeResult("ping")
    println("server got ${server.readResult(1024).bytes}")
    server.writeResult("pong")
    println("client got ${client.readResult(1024).bytes}")
}
// output:
// server got ping
// client got pong
```

| Function | Result |
|---|---|
| `hostedTcpConnect(host, port, timeoutMilliseconds = 5000)` | a `HostedTcpConnection`; `host` may be a name |
| `hostedTcpListen(host = "::", port = 0, backlog = 128, dualStack = true)` | a `HostedTcpListener`, with `accept()` and `localPort()` |
| `connection.readResult(maximum)`, `readNetwork(...)` | a read result: `bytes` plus `hasData()`, `reachedEof()`, `wouldBlock()`, `failed()` |
| `connection.writeResult(text)`, `writeNetwork(...)` | a write result |
| `setNonblocking(enabled)`, `close()` | on connections and listeners |
| `hostedUdpBind(host = "::", port = 0, dualStack = true)` | a `HostedUdpSocket` |
| `hostedSocketPoller()` | readiness for many sockets: epoll on Linux, kqueue on macOS |

All of these are resources: they close when their owner goes away.

## WebSockets

`abla/websocket` contains a transport-independent RFC 6455 frame codec and an
affine TCP connection adapter. It implements:

- validated version-13 HTTP upgrades and SHA-1/Base64 accept calculation;
- canonical 7-, 16-, and 64-bit payload lengths;
- client masking, fragmentation, text/binary messages, and UTF-8 validation;
- ping/pong processing and close handshakes;
- bounded frame/message/input sizes; and
- path-aware `WebSocketRouter` handlers.

```abla build
import "abla/websocket"
import "abla/http"

fun echo(request: HttpRequest, var socket: WebSocketConnection): void {
    val message = socket.readMessage()
    if (message.available && message.kind == "text") {
        socket.sendText(message.payload)
    }
    return
}

fun main {
    val router = webSocketRouter()
    router.route("/rooms/:room", echo)
    serveWebSockets(router, 8080)
}
```

See [websocket-echo-server.ab](../examples/websocket-echo-server.ab) for a
complete echo service. Server peers must send masked frames.
`abla/websocket/client` obtains a fresh four-byte masking key from the bounded
`abla/random` secure-entropy facade.

`abla/websocket/json` adds bounded JSON text messages.
`abla/websocket/rpc` adds a method router with `id`, `method`, `params`,
`result`, and structured error envelopes. The RPC router is deliberately
separate from transport, allowing generated `@rpc` adapters to share dispatch
logic across HTTP, WebSockets, NATS, or local calls.

```abla
import "abla/io"
import "abla/json"
import "abla/websocket/rpc"

fun add(params: Json): Json = jsonInteger(params.getInt("a") + params.getInt("b"))

fun main {
    val rpc = webSocketRpcRouter()
    rpc.route("add", add)
    println(jsonStringify(rpc.dispatch($json {"id": 1, "method": "add", "params": {"a": 2, "b": 40}})))
    println(jsonStringify(rpc.dispatch($json {"id": 2, "method": "nope"})))
}
// output:
// {"id":1,"result":42}
// {"id":2,"error":{"code":"method_not_found","message":"RPC method was not found"}}
```

`rpc.serveNext(connection, ...)` reads one JSON message from a WebSocket
connection, dispatches it and sends the reply. `connection.sendJson(value)`
and `connection.readJson(limits, timeout)` come from `abla/websocket/json`.

For multiplexed services, `abla/websocket/event` owns all accepted connections
in one bounded epoll loop. It validates masking, UTF-8, fragmentation, ping,
pong, and close frames while enforcing per-message and pending-output ceilings.
Partial writes remain queued and readable interest is restored only after the
backlog drains.

### Connection-oriented server

`abla/websocket/server` is the multiplexed host for real-time services such as
authoritative game servers. Instead of mapping each message to a reply, it
assigns every connection a stable, never-reused integer id and surfaces
`request`, `open`, `message`, `close`, and plain `http` events through a queue.
`step(timeoutMilliseconds)` performs one bounded poll (accepts, reads,
heartbeat and deadline sweep, flush), so a fixed-step simulation interleaves
it with ticks and sends, broadcasts, or closes whenever it likes:

```abla fragment
import "abla/http"
import "abla/net"
import "abla/websocket/server"

val server = webSocketServer(
    ipv4Any(9001), WebSocketServerOptions(manualAdmission = true)
)
server.enableGracefulShutdown()
while (!server.shutdownRequested()) {
    server.step(millisecondsUntilNextTick())
    val events = server.takeEvents()
    var index = 0
    while (index < events.size) {
        val event = events[index]
        if (event.isRequest()) {
            if (tokenValid(event.query("at"))) server.accept(event.id)
            else server.reject(event.id, 401, "auth failed")
        } else if (event.isMessage()) handleInput(event.id, event.payload)
        else if (event.isClose()) removePlayer(event.id)
        else if (event.isHttp()) server.respond(event.id, httpJson(stats()))
        index = index + 1
    }
    runDueTicks(server) // sendBinary/broadcastEncoded snapshots
    server.flush()
}
server.drain()
```

Manual admission keeps an upgrade pending until `accept` or `reject`, which
may happen on a later step after asynchronous verification. Each id that was
surfaced receives exactly one close event, whichever side or timer ended it.
Outbound frames are corked per connection and written with one vectored
syscall by `flush` (and every `step`); `webSocketServerEncode` frames a shared
payload once for `broadcastEncoded`. The server answers pings and close
frames, pings quiet peers every `pingIntervalMilliseconds`, closes them after
`idleTimeoutMilliseconds`, terminates a peer whose send backlog exceeds
`maximumPendingBytes` (close code 1013), sets `TCP_NODELAY`, and sheds new
connections beyond `maximumConnections`. Descriptor and id lookups are O(1).
It runs on Linux epoll and on macOS through the Darwin kqueue adapter.

`tests/benchmarks/websocket-server-load.ab` with
`tools/websocket-load-client.ts` (Bun) measures a 20 Hz broadcast. On an Apple
Silicon laptop over loopback, 1000 sockets receiving a 1 KiB snapshot per tick
(20,000 frames and about 20 MiB per second) while sending 20,000 input
messages per second cost about 3.7 ms per tick for broadcast and flush and
kept the event loop about 8% busy.

#### TLS (`wss://` and `https://`)

`abla/websocket/server/tls` serves the same server over TLS. It is a second
import, beside `abla/websocket/server`, so that a plain server carries none of the TLS code. The TLS is
`abla/tls/pure`'s (a `TlsServerSession` per connection): no OpenSSL, no libc. Load one certificate chain and its private key (for example an ACME client's
`fullchain.pem` and `privkey.pem`) with `webSocketServerTls`, or from PEM text
with `webSocketServerTlsPem`, and pass the result as
`WebSocketServerOptions(tls = ...)`. Everything above works unchanged:
upgrades, manual admission, plain HTTP routes on the same port, frames, ping
and close, backpressure and partial writes. `descriptors[server.slotOf(id)]`
is still the peer's socket, so `linuxSocketAddress` reads its address.

```abla build
import "abla/io"
import "abla/websocket/server"
import "abla/websocket/server/tls"
import "abla/net"
import "abla/http"

fun main: int {
    val tls = webSocketServerTls("fullchain.pem", "privkey.pem")
    if (tls.error != "") {
        println(tls.error)
        return 1
    }
    val server = webSocketServer(ipv4Any(8443), WebSocketServerOptions(tls = tls))
    server.enableGracefulShutdown()
    while (!server.shutdownRequested()) {
        server.step(50)
        for (event in server.takeEvents()) {
            if (event.isMessage()) server.send(event.id, event.payload, event.binary)
            else if (event.isHttp()) server.respond(event.id, httpText("ok"))
        }
    }
    server.drain()
    0
}
```

The handshake is nonblocking and runs inside `step`, like everything else:
a client that connects and never finishes it holds only its own socket, and is
closed when `handshakeTimeoutMilliseconds` (the third argument, 5000 by
default) runs out, counted from the accept. A failed or timed-out handshake
closes only that socket; no event is surfaced for it (the connection never
reached the application), and `server.stats.tlsHandshakeFailures` counts it.
Connections negotiate TLS 1.2 or later with one certificate, or several chosen by SNI (`webSocketServerTlsPems`, docs/tls.md). A
configuration that failed to load has a non-empty `error`, and a server given
it closes its listener (`localPort()` is -1) rather than serve plaintext.

The TLS session sends with `MSG_NOSIGNAL`, so a write to a peer that has reset the socket
fails with `EPIPE` and only that connection closes, whichever thread drives the server.

### Nonblocking HTTP client

`abla/http/async` issues HTTP/1.1 and HTTPS requests from an event loop.
`request(method, url, headers, body, timeoutMilliseconds)` returns an id;
DNS (cached A records through `DnsAsyncResolver`, below), TCP connect, the abla/tls/pure
TLS session (peer, SNI and name verification, no OpenSSL), writes, and reads advance only
inside `step`. Finished requests come back from `takeCompletions()` as
`HttpAsyncCompletion` values with `id`, `status`, `headers`, `body`,
`error`, `elapsedMilliseconds`, `protocol` and `trailerList` fields.
Connections are kept alive and pooled per scheme, host, and port up to
`maximumConnectionsPerHost`; a request whose pooled connection was closed by
the peer is retried once on a fresh connection. Register `pollDescriptor()`
with `WebSocketServer.watchExternal` so a blocking server `step` wakes when a
reply arrives. `HttpAsyncOptions` sets `dnsTimeoutMilliseconds`,
`dnsCacheSeconds`, the name server (`nameserver`, `nameserverPort`; empty
reads `/etc/resolv.conf`), and the resolver's `dnsConfigurationPath` and
`dnsHostsPath`. A host that does not exist fails at once with `"dns name not
found"`:

```abla fragment
val http = httpAsyncClient()
server.watchExternal(http.pollDescriptor())
val grant = http.postJson(economyUrl, body, [HttpHeader("X-API-KEY", key)])
// each loop iteration, after server.step(...):
http.step(0)
val replies = http.takeCompletions()
```

#### HTTP/2

`HttpAsyncOptions` offers `h2` and `http/1.1` by ALPN on every `https://` connection (`http2` is **on by default**); when the server picks `h2` the connection speaks HTTP/2
(RFC 9113, HPACK RFC 7541, in `abla/http/h2`: the sans-IO `H2Client` and the HPACK codec), otherwise HTTP/1.1 exactly as before. Callers change nothing else:
`request`, `get`, `postJson`, `step` and `takeCompletions` are the same, and `HttpAsyncCompletion.protocol` says which protocol answered (`"h2"` or `"http/1.1"`).
`http2 = false` keeps HTTP/1.1 on every connection, as before the default changed. Plain `http://` is unchanged (HTTP/1.1; h2c only with `http2PriorKnowledge = true`, off by default). Watch for three differences when upgrading: response header names are lower case, one connection serves many requests (`maximumConnectionsPerHost` does not bound them), and trailers are in `trailers()`.

What changes with HTTP/2:

- Many requests to one origin share one connection (multiplexed streams): `maximumConnectionsPerHost` then only bounds the extra connections opened when a connection's
  stream limit is reached (`maximumStreamsPerConnection`, 100, and the server's `SETTINGS_MAX_CONCURRENT_STREAMS`, whichever is smaller). While an origin's protocol is not
  yet known (its first handshake is not done) only one connection is opened to it; the answer is remembered for `dnsCacheSeconds`.
- A deadline is per request: on expiry the stream is cancelled (`RST_STREAM(CANCEL)`) and the request completes with `"timeout"`; the connection and the other requests are
  untouched. A connection with no open streams for `idleTimeoutMilliseconds` is closed with `GOAWAY(NO_ERROR)`; one idle for `http2PingAfterIdleMilliseconds` is probed with a
  PING before a request uses it (no answer in five seconds: the connection is dropped and the request goes to a new one). A request the server did not process (`REFUSED_STREAM`,
  or beyond a `GOAWAY`'s last stream) is retried once on another connection.
- **Response header names are lower case** (HTTP/2 requires it; HTTP/1.1 keeps the server's case): `HttpAsyncCompletion.header(name)` compares names case-insensitively
  either way. **Trailers are kept** (decoded, counted against the header limits, lower-case names): `HttpAsyncCompletion.trailers()` returns them in order; it is
  empty for HTTP/1.1 (chunked trailers are not kept there). Responses are fully buffered (`maximumResponseBytes`), no push (`SETTINGS_ENABLE_PUSH = 0`), no priorities.
- Requests go out with `:method`, `:scheme`, `:authority` (host, with the port when it is not the scheme's), `:path`, then the caller's headers lower-cased minus `host`, `connection`,
  `keep-alive`, `proxy-connection`, `transfer-encoding` and `upgrade` (`te` only as `trailers`), and `content-length` for a body. `http2NeverIndex` names headers that HPACK never
  puts in its dynamic table (always so for `authorization`, `proxy-authorization`, `cookie` and `set-cookie`), against CRIME/BREACH-style leaks.
- `http2PriorKnowledge = true` speaks h2c (HTTP/2 over plain TCP, no upgrade) to every `http://` origin of the client; there is no `Upgrade: h2c`.
- Limits a peer cannot talk us out of (`abla/http/h2`): a frame over 16384 bytes, a header block over 128 KiB or over 32 CONTINUATION frames, a decoded header list over
  `maximumHeaderListBytes` (64 KiB), a field over 16 KiB or more than 256 fields, more than 100 acknowledgements owed, 1000 frames in a row that carry nothing, 10,000 control frames in a
  second (Rapid Reset, PING/SETTINGS floods), and a window overrun end the connection with the error code of RFC 9113 (`ENHANCE_YOUR_CALM` for the floods and the size limits); every request on
  it completes with an error that names the code. `tools/test-http2.sh` runs the tests and the interop (nghttpd, `h2load`, `openssl s_server`); `tools/test-http2-fuzz.sh` fuzzes the HPACK
  decoder and the `H2Client` from a seed.

`tools/bench-http2-client.sh` measures the client (and the servers) over HTTP/1.1 and HTTP/2: latency percentiles and total time for N parallel requests, against h2o,
`HttpsEventServer` and nghttpd. It found that the event servers did not set TCP_NODELAY on accepted sockets (an HTTP/2 response written as HEADERS and then DATA waited for the
peer's delayed ACK: 40 ms outliers, half the throughput at 8 and 32 parallel requests); they set it now (`TcpConnection.setNoDelay`, `tools/test-http-nodelay.sh`).
A server closes an HTTP/1.1 connection after `maximumRequestsPerConnection` requests (1000 by default; it was 100, which cost one handshake per 100 requests), and the next request then pays a TLS handshake (about 7 ms of CPU
with the pure-Abla X25519 and ECDSA; the first request of a connection is the tail of such a benchmark).

### HTTPS and HTTP/2 server

`abla/http/event/tls` is the HTTPS counterpart of `HttpEventServer` (the plain HTTP/1.1 event server, which has no TLS): the same handler or router
(`(HttpRequest) -> HttpResponse`), limits and responses, over TLS from `abla/tls/pure` (no OpenSSL), with HTTP/2 chosen by ALPN.

When the certificate or key cannot be loaded, `httpsEventServerTls` returns
`null`. Handle that before calling `httpsEventServer`, which serves plain TCP
when given a null TLS configuration.

```abla build
import "abla/http"
import "abla/http/event/tls"
import "abla/io"
import "abla/net"

fun main: int {
    val tls = httpsEventServerTls("fullchain.pem", "privkey.pem")
    if (tls == null) {
        println("Could not load the HTTPS certificate or key")
        return 1
    }
    val router = httpRouter()
    router.get("/", { request: HttpRequest -> httpText("hello") })
    val server = httpsEventServer(router, ipv4Any(443), tls)
    server.run()
}
```

Each connection handshakes without blocking (`handshakeTimeoutMilliseconds`, 5 s by default). With both protocols enabled, ALPN `h2` selects HTTP/2 and other connections use HTTP/1.1.
Without a TLS configuration the server speaks plain TCP: HTTP/1.1, and h2c with prior knowledge for a connection that begins with the HTTP/2 preface (there is no
`Upgrade: h2c`). For an HTTP/1.1-only TLS listener, set `http2 = false` both in `HttpsEventServerOptions` and when building the TLS configuration with `httpsEventServerTls`. Set `http1 = false` in the options for an HTTP/2-only port.
 A request that carries both `:authority` and `host` gets `host` set to the `:authority` value (RFC 9113 8.3.1), so a handler sees one origin; a request with only `:authority` gets `host` from it.
The handler runs once per request, and over HTTP/2 once per stream when the request is whole (END_STREAM), on the event loop's thread: nothing in the router API changes.
Ordinary routes buffer requests and responses. A request exceeding `maximumBodyBytes` receives 413 and the upload stops. A buffered response is sent as HEADERS and DATA under
the client's flow-control windows and a 256 KiB output queue; `connection`, `keep-alive`, `transfer-encoding`, `upgrade` and `host` response headers are dropped, names are
lower-cased, `content-length` is added, and a response with status 101 becomes a 500. Use `streamRoute` for streaming bodies and trailers.
`abla/http/h2/server` is the sans-IO `H2Server` underneath (`feed`, `takeRequests`, `respond`, `takeOutput`, `shutdown`), for an event loop of your own.

Limits a client cannot talk the server out of (each ends the connection with GOAWAY and the RFC 9113 error code, or resets the stream, and each has a test that fails with
the check removed): **Rapid Reset** (CVE-2023-44487): more than 200 RST_STREAM frames in a second end the connection with `ENHANCE_YOUR_CALM`, and a request reaches the handler only
when whole, so a stream reset earlier costs a header decode and nothing else; **CONTINUATION flood**: a header block is limited to 32 CONTINUATION frames and 128 KiB before it is
decoded, and decoded to 64 KiB, 256 fields and 16 KiB per field (an HPACK bomb is cut by the same limits); more than 100 concurrent streams are refused (`REFUSED_STREAM`);
1000 frames in a row that carry nothing, 10,000 control frames per second and more than 100 acknowledgements owed (PING, SETTINGS) end the connection; a frame over 16 KiB, a
window overrun, an unacknowledged SETTINGS for 10 s, and every violation RFC 9113 names a connection error for do too. Resets the server itself sends (a stream error: a zero WINDOW_UPDATE, a refused stream) count in the same 200-per-second budget, which closes the MadeYouReset hole (CVE-2025-8671). Memory per connection is bounded: output the client has not read (new streams are refused with 512 KiB queued, the connection ends past 768 KiB; response bodies wait for window and a 256 KiB queue), request bodies no handler has taken (8 MiB per connection, past which receive windows are not replenished), the 128 KiB header block and the 64 KiB decoded list, and 100 streams; a stream answered before its request ended (a 413) drops the rest of the request. Header names must be tokens in lower case, values have no NUL, CR or LF and no outer whitespace (RFC 9113 section 8.2.1), and `:path` starts with `/`. Conformance: h2spec 2.6.0 passes in strict mode (147 tests, over TLS and over
h2c); `tools/test-http2-server.sh` also runs our `H2Client`, curl, nghttp, h2load and live attacks against the server, and `tools/test-http2-fuzz.sh` fuzzes `H2Server`.

Memory of the HTTP/2 server, measured with `tools/measure-http2-memory.sh` (x86-64, 500 connections held at once, the server's own VmRSS): about **21 KB per idle h2c connection**,
about **3 KB per open stream** (a request whose HEADERS arrived and that is not finished), and about **280 KB of RSS per concurrent TLS connection** under h2load: most of that is the
handshake's garbage in the collector's heap (a second wave of 500 connections after the first closed grew RSS by 3 MB, so nothing leaks, and the live part per connection is far smaller;
size a TLS server by its peak concurrent handshakes, not by idle connections). The worst case one client can force, by the bounds above, is its own 100 streams, up to 8 MiB of request bodies,
768 KiB of unread output and a 128 KiB header block in progress: under 10 MiB per connection, which `maximumConnections` (1023 by default) multiplies.

### Streaming bodies (HTTP/1.1 and HTTP/2 client, HTTP/2 server)

Bodies that do not fit in memory, or that must start before they end, are streamed; the buffered APIs above are unchanged. The rule everywhere is that **receive credit follows consumption**:
an HTTP/2 stream window is credited as the caller takes the bytes (the connection window on arrival, so one stalled stream does not stall the others), and HTTP/1.1 stops reading the socket
while 192 KiB wait. A caller that stops taking stops the peer after one stream window (256 KiB), so memory is bounded by the receiver's pace.

**Client** (`abla/http/async`, HTTP/1.1 and HTTP/2): `getStream(url)` and `requestStream(method, url, headers, length)` (`length` -1: unknown, sent chunked or as END_STREAM) return an id;
`takeStreamEvents()` gives `HEADERS`, `READABLE` (bytes waiting: read until `readStream(id, max)` returns ""), `WRITABLE` (`writeBody(id, chunk)` takes up to 256 KiB unsent and returns how many; it takes 0
before the first WRITABLE), `END` (after the last response byte was read) and `ERROR`; `finishBody(id)`, `cancelStream(id)`, `streamPending(id)`. The timeout is an idle one (default 30 s). A streaming request
is never retried and a streamed response is not bounded by `maximumResponseBytes`.

**Server** (`abla/http/event/tls`, over HTTP/2 and HTTP/1.1): `server.streamRoute(method, path, handler, maximumStreamBodyBytes = 0)`
serves an exact path with an `HttpStreamHandler` (`onRequest`, `onData`, `onEnd`, `onWritable`, `onAbort`, called on the event loop's thread, never blocking). Each callback returns an `HttpStreamStep` (respond,
write, finish with trailers, pause or resume the request body, abort); `server.streamStep(id, step)` gives one from outside a callback (a producer). A route's body limit is `maximumStreamBodyBytes` (0: none; 413
when nothing was sent yet); **a handler that accumulates the body or an unbounded response is its own memory bound**, the server holds at most a stream window of request body and 256 KiB of response per exchange.
`exchange.room` is how many response bytes can be written now; what a handler writes past it is kept by the server and sent first. Use `HTTP_STREAM_PAUSE_FOR_ROOM` (pause the request only if the
write did not fit, resume by itself once it is out) for echoes and proxies, `wantWritable` for producers. Over HTTP/1.1 the request head is read as it arrives, the body is framed incrementally (Content-Length or chunked; `Expect: 100-continue` is answered at once), reading stops while the handler is paused, the response is Content-Length or chunked, and the next request of the connection waits until both bodies are done; the bound over HTTP/1.1 is the socket (the kernel's buffers, not the server's memory). No gzip is applied to a streamed response. An idle exchange ends with the connection's idle timeout (`onAbort`).

Measured (tools/test-http2-stream.sh, tools/test-http2-stream-server.sh; h2o, nghttpd, curl and our own client): 1 GiB downloads and uploads over h2c, 256 MiB echoed both ways at once, 64 MiB over TLS,
a consumer that stops reading and a request body nobody takes (the stream stalls after one window and the idle timeout ends it): byte-exact, an unread stream held at most one window, the client's resident
memory peaked at about 70 MB and the server's at about 100 MB in every run, from 16 MiB to 1 GiB (it does not grow with the transfer; the rest is the runtime's heap and its garbage). Two limits that
ended large transfers were fixed on the way: WINDOW_UPDATE frames on a request or response being sent no longer count as frames that carry nothing (1000 in a row ended an upload at 16 MiB and a download at
87 MB), and `HttpsEventServer` serves the decrypted bytes a TLS session still holds without waiting for the socket (a 1 MiB upload could stall).

### JSON Web Tokens

`abla/jwt` verifies compact JWS tokens signed with RS256 or ES256 against a
JSON Web Key Set. Keys are imported once from their JWK parameters; encoding,
key selection by `kid`, and `exp`/`nbf`/`iss`/`aud`/`sub` checks are Abla, and
the signatures are `abla/crypto`'s RSA and P-256 (no OpenSSL, no libc). `abla/jwt/remote` fetches
a JWKS over HTTPS, caches it for a day, and refetches at most once per
cooldown when a token names an unknown key:

```abla fragment
import "abla/jwt"
import "abla/jwt/remote"

val jwks = jwksCache("https://auth.example.com/.well-known/jwks.json")
val result = jwks.verify(token, JwtOptions(issuer = "Example"))
if (result.valid) admit(result.subject) else refuse(result.error)
```

| Function | Result |
|---|---|
| `jwtKeySet(jwksJson)` | a `JwtKeySet` from a JWKS document; `size()`, `hasKey(kid)` |
| `keySet.verify(token, JwtOptions(...))` | a `JwtVerification(valid, error, subject, kid, header, claims)` |
| `JwtOptions(issuer = "", audience = "", clockToleranceSeconds = 0, requireSubject = true, nowSeconds = -1, requireExpiration = true)` | the claims to enforce; a negative `nowSeconds` reads the clock; a token without `exp` is refused unless `requireExpiration = false` |
| `jwtDecodeUnverified(token)` | the claims as `Json`, **without** checking the signature: for logging only |
| `jwksCache(url, ...)`, `cache.verify(token, options)` | from `abla/jwt/remote`: a cached, refreshed remote key set |

## DNS and TLS

`abla/dns` encodes bounded A/AAAA queries and parses compressed response names
without recursive allocation or unbounded pointer traversal. Its resolvers
(the blocking one here, the nonblocking one below) look a name up the way a C
library's resolver does, without libc:

1. A literal address is itself.
2. `/etc/hosts` comes next: every line naming the host (as its name or an
   alias, compared without case) with an address of the type asked.
3. Then the first IPv4 `nameserver` of `/etc/resolv.conf` is asked for each
   candidate name in turn. A name ending in a dot is only itself; a name with
   at least `ndots` dots (`options ndots:N`, default 1) is tried as written
   first and then with each `search` domain; any other name with each search
   domain first and as written last. So in Kubernetes (`ndots:5`, `search
   <namespace>.svc.cluster.local svc.cluster.local cluster.local`) a short
   service name such as `redis` resolves.
4. An NXDOMAIN (from the server asked, for the name asked) or an answer
   without records of the type moves to the next candidate at once. When
   every candidate is NXDOMAIN the lookup fails with `nameNotFound` (error
   code 2) without waiting; when one had no records of the type it succeeds
   with no addresses. A timeout, another server error or a malformed reply
   ends the lookup.

`tcpConnectHost` connects to a literal address directly and otherwise tries
the AAAA, then the A results.

| Function | Result |
|---|---|
| `dnsResolveType(host, recordType, timeoutMilliseconds = 2000, server = "", serverPort = 53, configurationPath = "/etc/resolv.conf", hostsPath = "/etc/hosts")` | a `DnsResolution(addresses, succeeded, timedOut, errorCode, nameNotFound)` for type 1 (A) or 28 (AAAA); each `DnsAddress` has `family`, `address` and `ttlSeconds`. The timeout applies to each name asked; `server` replaces the configured name server |
| `dnsResolve(host, timeoutMilliseconds = 2000, server = "", ...)` | AAAA and A together, the AAAA addresses first; the same trailing parameters |
| `tcpConnectHost(host, port, timeoutMilliseconds = 5000)` | a `TcpConnection` to the first address that answers |
| `dnsParseConfiguration(text)`, `dnsReadConfiguration(path)` | a `DnsConfiguration(nameservers, search, ndots)` from resolv.conf text |
| `dnsCandidates(host, configuration)`, `dnsHostsLookup(hostsText, host, recordType)` | the names a lookup asks for, in order; the addresses a hosts file gives |
| `dnsQuery(host, recordType, identifier)`, `dnsParseResponse(...)`, `dnsResponseCode(reply, identifier, name)` | the wire codec, for custom resolvers |

Before hosts files and search domains were supported, the resolvers asked for the name exactly as written, did
not read `/etc/hosts`, and treated NXDOMAIN like any server error (the
blocking resolver failed with error code 74, the nonblocking one and
`HttpAsyncClient` waited for the timeout).

### Nonblocking resolution: `abla/dns/async`

`DnsAsyncResolver` keeps many queries in flight, each on its own nonblocking
UDP socket, and moves them only when asked, so an event loop resolves names
without stalling a tick. `start(host, recordType)` returns an id (`1` for A,
`28` for AAAA); `step(timeoutMilliseconds)` waits up to that long for replies
(never past the next resend or deadline) and returns at once when nothing is
in flight; `take(id)` returns the `DnsAsyncResult` once there is one. A
literal address, a name the hosts file lists, and a name that cannot be
queried finish inside `start`:

```abla
import "abla/io"
import "abla/dns/async"

fun main {
    // Nothing answers on port 9: the query times out.
    val dns = dnsAsyncResolver(DnsAsyncOptions(
        timeoutMilliseconds = 200, nameserver = "127.0.0.1", nameserverPort = 9
    ))
    val literal = dns.start("192.0.2.7", 1)
    val name = dns.start("unanswered.example", 28)
    println("pending ${dns.pending()}")
    while (dns.pending() > 0) dns.step(50)
    for (result in dns.takeResults()) {
        if (result.succeeded()) {
            println("${result.host}: ${result.resolution.addresses[0].address}")
        } else println("${result.host}: ${result.error}")
    }
}
// output:
// pending 1
// 192.0.2.7: 192.0.2.7
// unanswered.example: dns timeout
```

It resolves as `dnsResolveType` does: hosts file, candidate names, the first
IPv4 `nameserver` of `/etc/resolv.conf` unless `nameserver` is given. Each
candidate is asked under a random identifier and sent again every
`resendMilliseconds`; NXDOMAIN or no records moves to the next at once, and
NXDOMAIN for the last fails with `"dns name not found"`. Replies with another
identifier, another server error (SERVFAIL, REFUSED) or a malformed body are
ignored until a valid reply or the candidate's deadline (`timeoutMilliseconds`),
which ends the query with `"dns timeout"`. The configuration and the hosts
file are read once, at the first query that needs them.

| Call | Result |
|---|---|
| `dnsAsyncResolver(DnsAsyncOptions(timeoutMilliseconds = 3000, resendMilliseconds = 1000, nameserver = "", nameserverPort = 53, configurationPath = "/etc/resolv.conf", hostsPath = "/etc/hosts"))` | a `DnsAsyncResolver` |
| `dns.start(host, recordType = 1)` | the query's id. A literal address answers itself when its family matches (no addresses otherwise) |
| `dns.step(timeoutMilliseconds = 0)` | polls the in-flight sockets, reads replies, resends, and expires; the number of datagrams read |
| `dns.take(id)` | `DnsAsyncResult?`: `null` while in flight; otherwise `id`, `host`, `recordType`, `resolution` (a `DnsResolution`) and `error`, and `succeeded()` |
| `dns.takeResults()` | every finished result, in completion order |
| `dns.done(id)`, `dns.pending()` | whether a result is waiting; how many queries are in flight |
| `dns.cancel(id)`, `dns.close()` | abandon one query, or all of them (dropping the resolver closes too) |
| `dns.descriptors()`, `dns.descriptorOf(id)` | the in-flight sockets, to watch for reading in another poller |
| `dns.receive(descriptor)`, `dns.sweep(now)` | for that poller: read one reply from a readable socket (true when it finished its query, false when it moved on to the next candidate); resend and expire |

`error` is `""`, `"dns name not found"` (with `resolution.nameNotFound`),
`"dns timeout"` (with `resolution.timedOut`), `"dns invalid host"`, `"dns
socket failed"` or `"dns send failed"`. A finished query keeps
its socket until `take` (or `takeResults`, `cancel`) closes it, so a loop
that watches `descriptors()` in its own poller stops watching one when
`done(id)` says so, before taking it. `HttpAsyncClient` drives its resolver
that way, from its one poller.

`abla/http/tls`'s `httpsClientWithIdentityPem(host, certificatePem, keyPem, passphrase = "", caPath = "", port = 443, ...)` and `httpsClientWithIdentityPkcs12(host, der, password, caPath = "", port = 443, ...)` are `httpsClient` with mutual TLS. They keep the identity's bytes in the client and open them for each connection.

`abla/http/tls`, `abla/websocket/tls` and the Xtensa installer's HTTPS stream use `abla/tls/pure`, TLS written in
Abla with no OpenSSL and no libc: what it supports and refuses is in [TLS in Abla](tls.md). The rest of this section
describes the calls, which `abla/tls/pure` and `abla/tls/hosted` share.

Client connections of both modules enable peer verification, system trust, SNI, and hostname checks. An explicit
CA-file connector and certificate/private-key listener support local and private PKI deployments. `abla/http/tls` and
`abla/websocket/tls` provide the HTTPS and WSS client transports, over `abla/tls/pure`.

`ablac build` links OpenSSL for a program that uses `abla/tls/hosted`.
When linking an object emitted with `--emit object` by hand, add
`-lssl -lcrypto` to the link line. `abla/random/hosted` supplies
hosted secure random on Linux and macOS.

| Function | Result |
|---|---|
| `tlsConnect(host, port = 443, timeoutMilliseconds = 5000, readWriteTimeoutMilliseconds = 30000)` | a verified `TlsConnection`, with `read`, `write` and `close` |
| `tlsConnectWithCa(host, caPath, port, timeoutMilliseconds, readWriteTimeoutMilliseconds)` | the same, trusting the given CA file |
| `tlsClientIdentityFromPem(certificatePem, keyPem, passphrase = "")`, `tlsClientIdentityFromPkcs12(der, password)` | load a certificate, intermediates and matching private key for mutual TLS. `abla/tls/pure` returns `TlsIdentity` and `abla/tls/hosted` returns `TlsClientIdentity`. Both expose `identity.ok()` and `identity.error`. |
| `tlsConnectWithIdentity(host, identity, caPath, port, timeoutMilliseconds, readWriteTimeoutMilliseconds)` | as `tlsConnect`, presenting the identity, and trusting the CA file if given. Under TLS 1.3 a server's refusal of the certificate shows on the first read, since the handshake has already finished for the client |
| `tlsUpgrade(var connection, host, caPath = "", timeoutMilliseconds = 5000, readWriteTimeoutMilliseconds = 30000)` | start verified client TLS on an existing TCP or Unix connection; existing socket timeouts survive |
| `tlsUpgradeWithIdentity(connection, host, identity, ...)` | upgrade while presenting a client identity |
| `tlsServerUpgrade(connection, certificatePath, privateKeyPath, ...)` | server TLS on an accepted stream; loads certificate/key on each call, so prefer `tlsListen` for many TCP connections |
| `connection.setTimeouts(readMilliseconds, writeMilliseconds)` | replace the limits on an open connection (also on a `TcpConnection`); 0 waits as long as it takes |
| `tlsListen(certificatePath, privateKeyPath, host = "::", port = 443, ...)` | a `TlsListener`, with `accept(handshakeTimeoutMilliseconds = 5000, readWriteTimeoutMilliseconds = 30000)` |
| `webSocketServerTls(certificatePath, privateKeyPath, handshakeTimeoutMilliseconds = 5000)` | from `abla/websocket/server/tls`: a `WebSocketServerTls` for `WebSocketServerOptions(tls = ...)` ([TLS](#tls-wss-and-https)); `webSocketServerTlsPem` takes PEM text |
| `tlsAvailable()`, `tlsLastError()` | whether the backend is available and the calling thread's last TLS error. Availability is always true for pure TLS and checks the linked OpenSSL version for hosted TLS. |

Unix upgrades and ownership/deadline details are described in the [stdlib TLS guide](stdlib/security-and-dates.md#ablatlshosted-upgrading-streams).

`timeoutMilliseconds` bounds connecting and the handshake. The other limit bounds
each `read` and each `write` of the open connection, so a peer that goes quiet
costs one limit rather than a hung process, and it isn't a limit on the whole
exchange: a peer sending a little at a time can take longer. A read that times
out returns `""` and may be repeated, and `tlsLastError()` then says `TLS read
or write timed out` (after a closed connection it is empty). A write that
times out leaves the connection unusable.

`httpsClient` and `httpIpv4Client` use their one `timeoutMilliseconds` for all
of these, and `webSocketTlsClient` for everything except waiting for a frame, which
a quiet conversation can make as long as it likes.

`TlsConnection.handle` and `TlsListener.handle` contain native control pointers.
Only `-1` means failed or closed: use `handle == -1`, never a sign check.
A live Android heap pointer can be negative because its top byte is tagged.

A peer that resets the socket fails the operation that notices it. OpenSSL's
writes would raise `SIGPIPE`, so `TlsConnection` and `abla/http/async` hold the
signal around each OpenSSL call, and the thread's mask and the program's handler
are as they were afterwards: `app | head` still ends the way it did.

## Persistent HTTP and streaming

`abla/http/event` is a single-threaded, bounded HTTP/1.1 connection manager. It
supports keep-alive and pipelined requests, content-length and chunked request
bodies, HEAD, gzip negotiation, partial writes, connection/request ceilings,
and pending-output backpressure. It can dispatch either an `HttpRouter` or one
framework callback. On SIGTERM or explicit stop it closes the listener first,
prevents keep-alive reuse, flushes queued responses up to a configured drain
deadline, and force-closes stalled peers. The WebSocket event server performs
the equivalent bounded close-frame drain.

Choose it when connections should persist. `serveHttp`, `serveHttpOnce` and
`serveHttpOnListener` are blocking and serial: they answer one request per
connection and always send `Connection: close`, because a persistent
connection would hold their only thread while other peers waited to be
accepted. A service behind a proxy that wants to keep connections to its
origin open (a CDN, a load balancer) moves to
`httpEventServer(router, address, options).run()` with the same router and
handlers; `options` sets the connection ceiling (1023), header and body
limits (64 KiB, 1 MiB), the requests allowed on one connection (1000), the idle
timeout (30 s), the gzip threshold (256 bytes; a huge value turns gzip off)
and the drain time at SIGTERM. Handlers still run on the one loop thread, so
a handler that blocks holds every connection, as it does in the blocking
server.

A server that could not bind (the port is taken, the address is invalid, no permission) is still returned, with a
listener that has no descriptor: `server.listenError()` is 0 while it listens and otherwise the errno (98 for an address
already in use), and `run()` returns 1 at once instead of waiting on nothing. The same holds for `httpsEventServer` and
`webSocketEventServer`. Check it before serving when the port is not the kernel's choice (port 0).

The event server frames requests strictly, because a proxy in front may frame
them differently. HTTP/1.1 connections persist unless the request says
`Connection: close`; HTTP/1.0 connections close unless it says
`Connection: keep-alive`. A request line that is not `method target HTTP/1.x`
with a target starting `/` or `*`, a `Content-Length` together with
`Transfer-Encoding` (RFC 9112 6.1), an invalid chunk, or a body over the limit
is answered `400` and the connection closes. So is any framing that two readers
could read differently: an empty or non-numeric `Content-Length`, two that
differ, a `Transfer-Encoding` other than exactly `chunked` (`identity`, `gzip`,
`chunked, gzip`, or given twice), whitespace before a header's colon, a folded
line, a line without a colon, a bare LF or CR in a head line, and a byte in a
header name that is not a token character (`Content-Length\x0b:`,
`Content_Length:`). So is a request with more than one `Host` line or a `Host`
value that has a space, a comma or a control byte in it (RFC 9112 3.2: the
application and a proxy in front could read different hosts). A missing `Host`
is allowed on purpose, which RFC 9112 does not allow for HTTP/1.1. Other
repeated headers are not refused: `request.header(name)` returns the last line
of that name and `request.headers` has all of them, so an application that
reads a single-valued header such as `Authorization`, `Cookie` or `Content-Type`
sees what the last line says; behind a proxy that checks the first line, refuse
a request whose headers repeat one of them. One strict helper, `httpRequestFraming`,
decides it for the
event server, `httpReadRequest` and the WebSocket handshake. A client reading a
response refuses two `Content-Length`s that differ and stops reading at once. A body shorter than declared waits
for the rest and the idle timeout closes the connection without an answer; bytes
after a body of the declared length are the next request, never part of this
one. A blank line before the request line is not skipped (it is answered `400`). `tests/cases/modules/http-event.ab` runs each of these.

The idle timeout of the event servers (`HttpEventServerOptions.idleTimeoutMilliseconds`, 30 s) restarts on every byte received or written, so it does not end a
peer that trickles bytes (slowloris, a slow POST, a client that reads a large response a few bytes at a time). Three deadlines do:
`requestHeadTimeoutMilliseconds` (default 30 s) closes a connection whose request head is still incomplete that long after its first byte;
`requestTimeoutMilliseconds` (default 0, off) one whose whole request, body included, is not complete that long after its first byte;
`responseTimeoutMilliseconds` (default 0, off) one that has not taken a queued response that long after it was queued. A connection is closed without an answer.
The last two are off because a large upload or download on a slow link is legitimate; set them for the traffic you serve. Neither server limits connections
per client address: on an open network run it behind a proxy that does, and that enforces a minimum data rate. `HttpsEventServer` takes the same options
in its `base` options, for its HTTP/1.1 connections (HTTP/2 connections have their own idle and ping rules).

The steady-state HTTP path keeps only readable interest registered. A response
that fills the kernel send buffer enables writable interest exactly once, then
removes it after the pending output drains. Ordinary complete writes therefore
do not issue a poller-control syscall per request.

Linux services can scale that event loop over independent worker processes by
passing `reusePort = true` to `tcpListenAddress`, `tcpListenIpv6`, `tcpListen`,
`httpEventServer`, or `httpEventServerHandler`. Every worker binds the same
address and the kernel distributes new connections with `SO_REUSEPORT`; each
worker retains its own collector and failure boundary. This is the supported
parallel service model today. Native `thread` remains appropriate for bounded
jobs, but a permanently allocating server must not use threads as workers until
the managed collector can coordinate all thread root stacks.

```abla fragment
val server = httpEventServerHandler(
    handleRequest,
    ipv4Loopback(8080),
    reusePort = true
)
server.run()
```

`abla/http/stream` supplies chunk encoders and decoders, gzip responses, and
Server-Sent Events framing. The base HTTP client transparently recognizes
complete chunked responses, including HTTPS replies.

```abla
import "abla/http/stream"
import "abla/io"

fun main {
    print(serverSentEvent("first line\nsecond line", "update", "7").encode())
    println("chunk: ${httpChunkEncode("hello").size} bytes")
}
// output:
// event: update
// id: 7
// data: first line
// data: second line
//
// chunk: 10 bytes
```

`sseResponseHead()` starts an event stream response, and `sseChunk(event)`
frames one event as a chunk. `httpGzipResponse(request, response, minimumBytes)`
compresses a response when the client accepts gzip, and
`httpChunkedResponse(chunks, status, headers)` renders a complete chunked response from an array of strings.

## HTTP upgrade behavior

HTTP responses now preserve explicit `Connection` and `Content-Length`
headers. Status `101` emits neither a forced body length nor
`Connection: close`, allowing the TCP stream to transfer into the WebSocket
lifecycle. Ordinary HTTP responses retain their previous close-delimited
behavior.

## Deliberate boundaries

The raw `abla/net` facade remains Linux-specific so a libc-free binary never
silently acquires hosted dependencies; cross-platform programs select
`abla/net/hosted`. The bounded DNS client currently implements UDP A/AAAA with
compression pointers, but not DNSSEC, TCP fallback, IDNA, or a shared cache.
`abla/tls/pure` runs over the raw socket layer. Select `abla/tls/hosted`
when you want the OpenSSL backend.
HTTP/2 is a default-on (https) client feature of `abla/http/async` and a server feature of `abla/http/event/tls` (both above); HTTP/3/QUIC, proxy negotiation, and automatic reconnection remain
separate protocols rather than implicit behavior in the HTTP/1.1 APIs.

## Tests and benchmark

The conformance suite covers IPv4/IPv6 TCP loopback request/response and EOF,
UDP loopback/source preservation, DNS wire fixtures, typed errors,
read/write deadlines, cooperative cancellation, epoll and hosted readiness,
graceful HTTP/WebSocket draining, gzip round trips, chunked framing,
persistent pipelining,
SSE encoding, backpressure paths, RFC handshake
vectors, masked and extended frames, invalid UTF-8/control frames, fragmented
live messages, ping/pong, routed parameters, replies, and close handshakes.

Run the codec microbenchmark with:

```sh
make benchmark-network
```

Recent reference runs completed 20,000 encode/decode round trips of 256-byte
binary frames in roughly 100-120 ms. This is a development baseline, not a
cross-machine performance guarantee.
