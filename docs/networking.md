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

`SocketPoller` owns one epoll descriptor. `watchDescriptor`,
`modifyDescriptor`, `unwatchDescriptor`, and `wait` expose readable, writable,
closed, and error readiness without giving the poller ownership of watched
sockets.

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
| `request.header(name)`, `routeParameter(name)`, `queryParameter(name)`, `parameter(name)` | request accessors (`""` when absent; header names are case-insensitive) |
| `httpText(body, status = 200)`, `httpJson(body, status = 200)` | responses with a content type |
| `httpGet(path)`, `httpPost(path, body)`, `httpRequest(method, path, body, headers)` | build a request |
| `httpParseRequest(text)`, `httpParseResponse(text)`, `response.render()` | parse and render the wire format |
| `serveHttp(router, port)`, `serveHttpOnce`, `serveHttpOnListener` | serve over TCP |
| `httpIpv4Client(...)`, `httpsClient(host, port, maxBytes, timeout)` (from `abla/http/tls`), `client.send(request)` | send requests |

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

`abla/websocket/server/tls` serves the same server over TLS. Load one
certificate chain and its private key (for example an ACME client's
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
Connections negotiate TLS 1.2 or later with one certificate (no SNI). A
configuration that failed to load has a non-empty `error`, and a server given
it closes its listener (`localPort()` is -1) rather than serve plaintext. Only
programs that import `abla/websocket/server/tls` link OpenSSL; a plain server
does not.

### Nonblocking HTTP client

`abla/http/async` issues HTTP/1.1 and HTTPS requests from an event loop.
`request(method, url, headers, body, timeoutMilliseconds)` returns an id;
DNS (cached A records through `DnsAsyncResolver`, below), TCP connect, the OpenSSL
handshake with peer/SNI/hostname verification, writes, and reads advance only
inside `step`, and finished requests come back from `takeCompletions` as
`HttpAsyncCompletion(id, status, headers, body, error, elapsedMilliseconds)`.
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

### JSON Web Tokens

`abla/jwt` verifies compact JWS tokens signed with RS256 or ES256 against a
JSON Web Key Set. Keys are imported once from their JWK parameters; encoding,
key selection by `kid`, and `exp`/`nbf`/`iss`/`aud`/`sub` checks are Abla, and
only the signature primitive uses OpenSSL libcrypto. `abla/jwt/remote` fetches
a JWKS over HTTPS, caches it for a day, and refetches at most once per
cooldown when a token names an unknown key:

```abla fragment
import "abla/jwt/remote"

val jwks = jwksCache("https://auth.example.com/.well-known/jwks.json")
val result = jwks.verify(token, JwtOptions(issuer = "Example"))
if (result.valid) admit(result.subject) else refuse(result.error)
```

| Function | Result |
|---|---|
| `jwtKeySet(jwksJson)` | a `JwtKeySet` from a JWKS document; `size()`, `hasKey(kid)` |
| `keySet.verify(token, JwtOptions(...))` | a `JwtVerification(valid, error, subject, kid, header, claims)` |
| `JwtOptions(issuer = "", audience = "", clockToleranceSeconds = 0, requireSubject = true, nowSeconds = -1)` | the claims to enforce; a negative `nowSeconds` reads the clock |
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

`abla/tls/hosted` dynamically loads OpenSSL 1.1 or 3 only when imported. Client
connections enable peer verification, system trust, SNI, and hostname checks.
An explicit CA-file connector and certificate/private-key listener support
local and private PKI deployments. `abla/http/tls` and `abla/websocket/tls`
provide HTTPS and WSS client transports. Hosted secure random is supplied by
`abla/random/hosted` on Linux and macOS.

| Function | Result |
|---|---|
| `tlsConnect(host, port = 443, timeoutMilliseconds = 5000)` | a verified `TlsConnection`, with `read`, `write` and `close` |
| `tlsConnectWithCa(host, caPath, port, timeout)` | the same, trusting the given CA file |
| `tlsUpgrade(var connection, host, caPath = "")` | start TLS on an existing TCP connection |
| `tlsListen(certificatePath, privateKeyPath, host = "::", port = 443, ...)` | a `TlsListener`, with `accept()` |
| `webSocketServerTls(certificatePath, privateKeyPath, handshakeTimeoutMilliseconds = 5000)` | from `abla/websocket/server/tls`: a `WebSocketServerTls` for `WebSocketServerOptions(tls = ...)` ([TLS](#tls-wss-and-https)); `webSocketServerTlsPem` takes PEM text |
| `tlsAvailable()`, `tlsLastError()` | whether OpenSSL could be loaded, and the last error |

## Persistent HTTP and streaming

`abla/http/event` is a single-threaded, bounded HTTP/1.1 connection manager. It
supports keep-alive and pipelined requests, content-length and chunked request
bodies, HEAD, gzip negotiation, partial writes, connection/request ceilings,
and pending-output backpressure. It can dispatch either an `HttpRouter` or one
framework callback. On SIGTERM or explicit stop it closes the listener first,
prevents keep-alive reuse, flushes queued responses up to a configured drain
deadline, and force-closes stalled peers. The WebSocket event server performs
the equivalent bounded close-frame drain.

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
    httpEventServerOptions(),
    true
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
frames one event as a chunk. `httpGzipResponse(request, response, minimum)`
compresses a response when the client accepts gzip, and
`httpChunkedResponse` streams a body in chunks.

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
TLS is hosted and OpenSSL-backed rather than part of the raw syscall target.
HTTP/2, HTTP/3/QUIC, proxy negotiation, and automatic reconnection remain
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
