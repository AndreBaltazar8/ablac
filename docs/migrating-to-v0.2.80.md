# Migrating to v0.2.80

v0.2.80 closes several ways that ordinary code, request input or a
dependency could get past a safety boundary. Most programs build and run
as before. This page lists every change that can stop a build or change
what a program does, each with code that hits it and the fix. The
[release notes](https://github.com/AndreBaltazar8/ablac/releases) list
everything else.

| Change | What you may see | Section |
|---|---|---|
| Raw-memory classes are trusted-only | `native.trust:` build error | [1](#1-raw-memory-classes-are-made-by-their-factories) |
| Region stores need the region's own object | `region.` build error | [2](#2-a-region-stores-only-into-its-own-objects) |
| `$html` URL and event-handler checks | build error, or `about:invalid#abla-unsafe-url` in the page | [3](#3-html-checks-urls-and-event-handlers) |
| HTTP servers refuse bad headers and framing | a `500` and one line on standard error | [4](#4-http-servers-refuse-headers-and-framing-they-cannot-send) |
| A dependency imports only its own files | build error in a dependency | [5](#5-a-dependency-imports-only-its-own-files) |
| Shared `is` arms are narrowed | nothing breaks | [6](#6-shared-is-arms-see-a-nullable-subject-as-not-null) |
| abla-postgres authentication and `sslMode` | connection refused, or TLS where there was none | [7](#7-abla-postgres-password-authentication-and-sslmode) |
| abla-one session ids leave the URL | nothing, unless you wrote your own host script or proxy | [8](#8-abla-one-session-ids-leave-the-url) |

## 1. Raw-memory classes are made by their factories

`ByteBuffer`, `AesKey`, `AesGcmKey`, `RsaPrivateKey`, `Keccak`,
`LlvmOrcSession` and `LlvmOrcGeneration` hold state that their native code
trusts, such as an address, a size or a "closed" flag. Ordinary code could set that
state and make the native code write memory it doesn't own. Their
constructors and field writes are now trusted-only, as are
`cryptoWipeString` and `tlsWipe`, which could zero any string, including a
shared one.

Before, this built:

```abla error
import "abla/bytes"

fun main {
    val buffer = byteBuffer()
    buffer.staged = -16
    // error: native.trust:ByteBuffer.staged
}
```

**Fix:** make these values with their factories (`byteBuffer()`,
`aesGcmKeyOwner()`, `keccakSha3(rate)` and the other functions of each
module), and change them with their own methods:

```abla
import "abla/bytes"
import "abla/io"

fun main {
    val buffer = byteBuffer()
    buffer.appendText("total ")
    buffer.appendInt(42)
    println(buffer.toText())
}
// output:
// total 42
```

To wipe a secret, wipe the buffer or key that holds it with its own
functions instead of `cryptoWipeString` on a string. Code that really
manages this memory itself has to be a `trusted fun`, and a dependency
that defines trusted code needs a grant line in your manifest
([packages.md](packages.md)).

The pure TLS library follows the same rule for the secrets it wipes:

- `TlsClient` and `TlsServer` keep their key pairs, secrets and tickets
  private, set only by their own functions;
- `Sha256Stream`, `TlsStoredTicket`, `TlsTicketState` and
  `TlsIdentityKeys` are made only by the library: use `sha256Stream()`,
  the session cache, the ticket keys and the identity loaders;
- an identity's `wipe()`, and a key generation, clear only strings the
  library made, so a `TlsIdentity` built by hand has nothing of yours
  wiped.

## 2. A region stores only into its own objects

Inside `region { ... }`, a region's object could be stored into an object
that came from outside the region, such as the result of `Map.get` or a
function's result, and so outlive the region. A store into a receiver or a
retaining argument now needs that object to be surely the region's own: made in the region by a
constructor, a literal, a lambda or a task, or returned by a function that
returns only such objects. Two more cases are refused:

- a lambda made in the region storing its parameters out of it;
- a `for` loop variable over the region's array, including over
  `text.split(...)`, stored out of it.

Before, this built, and `keepers` kept a string freed with the region:

```abla error
import "abla/io"

class Keeper(val log: array<string>) {
    fun keep(value: string): void {
        this.log.append(value)
        return
    }
}

fun main {
    val keepers: Map<string, Keeper> = Map()
    keepers.set("k", Keeper([]))
    val n = region {
        val small = "region-" + "text"
        val target = keepers.get("k")
        if (target != null) target.keep(small)
        0
    }
    println("$n")
    // error: region.receiver-retention:Keeper.keep
}
```

**Fix:** let the region compute a scalar answer, and build and store what
must outlive it after the region:

```abla
import "abla/io"
import "abla/text"

class Keeper(val log: array<string>) {
    fun keep(value: string): void {
        this.log.append(value)
        return
    }
}

fun main {
    val keepers: Map<string, Keeper> = Map()
    keepers.set("k", Keeper([]))
    val words = region {
        "one two three".split(" ").size
    }
    val target = keepers.get("k")
    if (target != null) {
        target.keep("$words words")
        println(target.log[0])
    }
}
// output:
// 3 words
```

A region's result must be a scalar; see [regions.md](regions.md).

## 3. `$html` checks URLs and event handlers

A value from Abla in a URL attribute (`href`, `src`, `action`, ...) whose
scheme is `javascript:`, `vbscript:` or `data:` is now written as
`about:invalid#abla-unsafe-url`, however the scheme is spelled. A value
from Abla can no longer fill an event handler (`onclick`, ...) or an
iframe's `srcdoc`.

Before, this built and wrote the expression into the handler:

```abla error
import "abla/html"

fun button(code: string): Html = $html <button onclick={code}>Go</button>
// error: an Abla expression cannot fill the event handler attribute onclick
```

**Fix:** write the handler in the template and pass data through a
`data-` attribute. A URL that may come from a user keeps working when it
is `http:`, `https:` or relative, and is neutralised otherwise:

```abla
import "abla/html"
import "abla/io"

fun button(id: string): Html =
    $html <button data-id={id} onclick="pick(this.dataset.id)">Go</button>

fun link(target: string): Html = $html <a href={target}>Open</a>

fun main {
    println(button("7").render())
    println(link("/docs").render())
    println(link(" JavaScript:alert(1)").render())
}
// output:
// <button data-id="7" onclick="pick(this.dataset.id)">Go</button>
// <a href="/docs">Open</a>
// <a href="about:invalid#abla-unsafe-url">Open</a>
```

The ways past these checks are explicit:

- `ablaHtmlTrustedAttribute(name, value)`, or
  `HtmlAttribute(name, value, "", true)`, writes one attribute without
  them;
- `ablaHtmlRaw(markup)` inserts markup as it is;
- an `Html` value can be built with its constructor.

Use them only for values your program wrote or fully checked. See
[subparsers.md](subparsers.md#urls-and-event-handlers).

## 4. HTTP servers refuse headers and framing they cannot send

The HTTP servers (`serveHttp`, the event and HTTPS servers, chunked
responses and HTTP/2) wrote response headers as the program gave them, so
request input in a header could add headers or a second response. They
also sent a `Content-Length` or `Transfer-Encoding` the program set, so a
wrong one made the client read the rest of the body as the next response.
A response is now refused when:

- a header name is empty or not a token, or a value has CR, LF or NUL;
- a `Content-Length` is not the body's size, or there are two;
- it has a `Transfer-Encoding` header (the server frames the body).

A refused response is sent as a plain `500`, without its headers or body,
and one line goes to standard error. A HEAD response's `Content-Length`,
and a 1xx, 204 or 304's, is not compared. `httpChunkedResponse` refuses
framing headers from the caller, and a trailer that can't be sent closes
the chunked connection or resets the HTTP/2 stream.

```abla
import "abla/http"
import "abla/io"
import "abla/text"

fun main {
    val next = "/home\r\nSet-Cookie: admin=1"
    val redirect = HttpResponse(302, [HttpHeader("Location", next)], "")
    println("${httpResponseFieldsError(redirect.headers) != ""}")
    val sized = HttpResponse(200, [HttpHeader("Content-Length", "5")], "hi")
    println("${httpResponseFramingError(sized) != ""}")
    println("${HttpResponse(200, [], "hi").render().contains("Content-Length: 2")}")
}
// output:
// true
// true
// true
```

**Fix:** check a value from the request before you put it in a header, so
the user gets your own error rather than a `500`. Let the server write
`Content-Length` and `Transfer-Encoding`: leave them out of your headers. To
find refused responses, look for the server's line on standard error.

## 5. A dependency imports only its own files

A dependency could compile a file from anywhere on the build machine as
its own source: by an absolute import path, by `../` climbing out of its
copy, or through symbolic links. A module inside a dependency
(`.abla/packages/<name>/source` or `vendor/<name>`) may now import by path
only files under its own copy, judged on the path it wrote and on where
any link really leads (a loop, or more than 40 links, is refused). It can
still import other packages by name and the standard library. Your own
project's modules are not affected.

```abla fragment
// Inside a dependency: refused from v0.2.80
import "/home/me/shared/util.ab"
import "../../other-package/src/util.ab"

// Fix: a file of the same package, or the other package by name
import "util.ab"
import github("owner/other-package")
```

**Fix:** a package that needs another package's files names that package
as a dependency and imports it by name. A sibling path in your own
project, such as `import "../../abla-postgres/src/postgres.ab"`, still
works.

## 6. Shared `is` arms see a nullable subject as not null

An arm shared by several `is` patterns now treats a nullable subject as not
null, as a single `is` arm already did. Code that built before still builds and does
the same thing; code that needed a `!!` or a separate arm per class can drop
it:

```abla
import "abla/io"

sealed interface Shape {
    fun area(): int
}

class Rectangle(val width: int, val height: int) : Shape {
    fun area(): int = width * height
}
class Dot : Shape {
    fun area(): int = 0
}

fun describe(shape: Shape?): string = when (shape) {
    is Rectangle, is Dot -> "area ${shape.area()}"
    null -> "no shape"
}

fun main {
    println(describe(Rectangle(2, 5)))
    println(describe(null))
}
// output:
// area 10
// no shape
```

An arm that shares its body with `null` (`is Dot, null -> ...`) is still
not narrowed. See [language.md](language.md#interfaces).

## 7. abla-postgres: password authentication and `sslMode`

The [abla-postgres](https://github.com/AndreBaltazar8/abla-postgres)
package changes three defaults in the same release:

- **Password and MD5 authentication need a verified server.** A server
  whose `pg_hba.conf` says `password` or `md5` asks the client for the
  password itself, or for its MD5, and so can anyone who answers in its
  place. The client now answers only under `sslMode` `verify-ca` or
  `verify-full`, and otherwise refuses with an error that says so.
  SCRAM (`scram-sha-256`, PostgreSQL's default since version 14) never sends the password and is
  not affected.
- **`sslMode` defaults to `prefer`** (it was `disable`), as libpq's: with
  the `tls` subpath added, the client asks every server for TLS and uses
  it when offered.
- **A query's rows are bounded** by `maximumResultBytes`, 256 MiB by
  default: a larger result fails with an error naming the option, and the
  connection closes.

```abla fragment
// Best: move the server to scram-sha-256, or verify it.
val config = PgConfig("db.internal", 5432, "app", "app", password,
    sslMode = "verify-full", sslRootCert = "/etc/ssl/db-ca.pem")

// The old behaviour, for a trusted network only:
val legacy = PgConfig("127.0.0.1", 5432, "app", "app", password,
    passwordAuthentication = "always", sslMode = "disable")
```

`POSTGRES_PASSWORD_AUTHENTICATION` and `POSTGRES_SSLMODE` set the same
options from the environment. Code that rebuilds a `PgConfig` field by
field must copy the new fields too, or they reset to their defaults.

## 8. abla-one: session ids leave the URL

A live session id works like a password for its session. abla-one's page
used to send it as `?s=` in URLs, which proxies and access logs record.
It now sends it in an `X-One-Session` header (`/one/upload`,
`/one/cookies`) and as a `one-session.<id>` WebSocket subprotocol beside
`one-live` (`/one/live`). For one release the server still reads `?s=`
from earlier host scripts.

**Fix:** nothing, if you use abla-one's own host script. Otherwise:

- a proxy in front of the server must pass `X-One-Session` and
  `Sec-WebSocket-Protocol` through;
- a recovery store's `upload` reads the session with
  `oneLiveRequestSession(request)` instead of from the query;
- a host script of your own sends the header and the subprotocol, not
  `?s=`.

abla-one's web backends also stop a link to a `javascript:`, `vbscript:`
or `data:` URL (it opens nothing), and leave out a style value that could
end its rule, as `$html` does in [section 3](#3-html-checks-urls-and-event-handlers).
