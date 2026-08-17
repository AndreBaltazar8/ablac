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

```abla
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

```abla
import "abla/net"

val listener = tcpListenAddress(ipv4Loopback(8080))
val connection = listener.accept()
val request = connection.readWithTimeoutResult(65536, 5000)
connection.writeResult("response")
connection.close()
listener.close()
```

UDP preserves datagram boundaries and reports the source address:

```abla
val socket = udpBindPort(8081)
val datagram = socket.receiveFromWithTimeout(65507, 5000)
if (datagram.received) socket.sendTo(datagram.bytes, datagram.source)
```

`SocketPoller` owns one epoll descriptor. `watchDescriptor`,
`modifyDescriptor`, `unwatchDescriptor`, and `wait` expose readable, writable,
closed, and error readiness without giving the poller ownership of watched
sockets.

## WebSockets

`abla/websocket` contains a transport-independent RFC 6455 frame codec and an
affine TCP connection adapter. It implements:

- validated version-13 HTTP upgrades and SHA-1/Base64 accept calculation;
- canonical 7-, 16-, and 64-bit payload lengths;
- client masking, fragmentation, text/binary messages, and UTF-8 validation;
- ping/pong processing and close handshakes;
- bounded frame/message/input sizes; and
- path-aware `WebSocketRouter` handlers.

```abla
import "abla/websocket"

fun echo(request: HttpRequest, var socket: WebSocketConnection): void {
    val message = socket.readMessage()
    if (message.available && message.kind == "text") {
        socket.sendText(message.payload)
    }
    return
}

val router = webSocketRouter()
router.route("/rooms/:room", echo)
serveWebSockets(router, 8080)
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

For multiplexed services, `abla/websocket/event` owns all accepted connections
in one bounded epoll loop. It validates masking, UTF-8, fragmentation, ping,
pong, and close frames while enforcing per-message and pending-output ceilings.
Partial writes remain queued and readable interest is restored only after the
backlog drains.

## DNS and TLS

`abla/dns` encodes bounded A/AAAA queries and parses compressed response names
without recursive allocation or unbounded pointer traversal. The raw resolver
uses a configured IPv4 nameserver from `/etc/resolv.conf`; `tcpConnectHost`
tries numeric literals first and then bounded AAAA/A results.

`abla/tls/hosted` dynamically loads OpenSSL 1.1 or 3 only when imported. Client
connections enable peer verification, system trust, SNI, and hostname checks.
An explicit CA-file connector and certificate/private-key listener support
local and private PKI deployments. `abla/http/tls` and `abla/websocket/tls`
provide HTTPS and WSS client transports. Hosted secure random is supplied by
`abla/random/hosted` on Linux and macOS.

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

```abla
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
