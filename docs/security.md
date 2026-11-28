# Security

What Abla checks for you, and what your program still has to do. Each section
links to the detailed rules. When a release fixes one of these checks, its
release notes say so, and the notes of the older releases it affects gain a
known-issue line with a workaround.

## Memory: no unsafe code outside `trusted`

Ordinary Abla code cannot read or write memory it doesn't own. An index outside
an array or string panics, objects are freed only when nothing reaches them,
and there is no `unsafe` block. Raw memory, pointers and native functions that
take addresses are declared `trusted`, and only a `trusted` function can use
them:

```abla error
import "abla/io"
import "abla/unsafe/memory"
import "abla/unsafe/memory/raw"

fun main {
    val buffer = nativeByteBuffer(8)
    println("${nativePointerAddress(buffer.address)}")
}
// error: native.trust:nativePointerAddress
```

The standard library's classes that own raw memory or a native handle
(`ByteBuffer`, the crypto keys, `Keccak`, the native buffers and cells, ...)
are made by their factories and changed only by their own methods:
constructing one or writing its fields from ordinary code is
`native.trust:<name>` too. Object addresses are internal to the runtime, and no
code outside it can take one.

**What you do:** a `trusted` function is where the safety argument lives, so
review every one your project defines: it must check what it is given before
it touches raw memory. A project's own `extern:"c"` declarations are unchecked
too: nothing checks what the native function does with its arguments.
Searching for `trusted` and `extern` finds all of them.
([language.md](language.md#trusted-native-implementations))

## Regions

`region { ... }` frees everything allocated in it when the block ends. The
compiler refuses any way a region's value could outlive it: as the result
(which must be a scalar), stored in an outer variable, object, array or map,
captured by a closure that can leave, or passed to a function that may keep it.
Foreign code is assumed to keep what it gets, unless it is declared
`noescape`.

```abla error
fun main {
    val text = region {
        "a" + "b"
    }
}
// error: region.result:string
```

**What you do:** nothing, as long as you don't declare `noescape` on a native
function that keeps its arguments. When the compiler refuses a store, move it
out of the region or make what it stores into a scalar.
([regions.md](regions.md#escape-rules))

## Dependencies

A dependency is fetched at the revision `abla.lock` pins and checked against
the lock's digest. The fetched tree is checked before use: no submodules,
nothing but files and symbolic links, bounded size and file count, and no
paths that git, a case-folding file system or Windows would read differently.
A dependency's imports stay inside its own copy: an import that leads out of
the package, through a symbolic link, an absolute path or `..`, is refused.
([packages.md](packages.md))

A dependency can't define `trusted` functions or `extern` declarations unless
the root project's `abla.toml` names it under
`[dependencyCompileCapabilities]` as `name = ["trusted.native"]`
(`E_PACKAGE_TRUSTED_DENIED` otherwise). Its compile-time capabilities must be
ones the root project grants (`E_PACKAGE_CAPABILITY_DENIED`).
([packages.md](packages.md#trusted-and-extern-code-in-a-dependency))

**What you do:** a dependency's run-time code runs with your program's rights.
Abla keeps it to safe code, but it can still read files or open connections
when your program runs, as your own code can. Review a dependency before you
add it to the lock, and treat a `trusted.native` line as letting its author
write unchecked native code into your program.

## Compile-time code

Compile-time code (`#...`, `compile fun`) runs inside the compiler, on the
machine of whoever builds the program, so it has no access to files, the
environment, processes or the network unless two things allow it: the
project's `abla.toml` lists the capability in `compileCapabilities`, and the
module asks for it with `#compilerGrant("name")`.

```abla error
import "abla/fs"
import "abla/compiler"

#compilerGrant("filesystem.read")

val greeting = #path("greeting.txt").readText()

fun main {
}
// error: compile.capability-not-authorized:filesystem.read
```

The editor's analysis service (`ablac analyze`) doesn't run your project's
compile-time code, so opening a project in an editor doesn't run it.

**What you do:** grant a capability only to a project whose compile-time code
you trust with it, and give `trusted.native` (native code at compile time)
the same care as at run time.
([compile-time.md](compile-time.md#capabilities-files-environment-processes-network))

## HTML: `$html`

`$html` escapes every text and attribute value that comes from Abla. A value
from Abla in a URL attribute (`href`, `src`, `action`, ...) whose scheme is
`javascript:`, `vbscript:` or `data:` is written as
`about:invalid#abla-unsafe-url`, however its scheme is spelled. A value from
Abla can't fill an event handler (`onclick`, ...) or an iframe's `srcdoc`:

```abla error
import "abla/html"

fun invalid(code: string): Html = $html <button onclick={code}>Go</button>
// error: an Abla expression cannot fill the event handler attribute onclick
```

A text hole inside `script`, `style` and the other raw-text elements is left
out when rendered. The ways past these checks are explicit:
`ablaHtmlRaw(markup)` inserts markup verbatim,
`ablaHtmlTrustedAttribute(name, value)` and `HtmlAttribute(name, value, "",
true)` write an attribute without the URL and handler checks, and an `Html`
value can be built directly. An audit searches for all four.

**What you do:** use the escape hatches only for markup and values your
program wrote or fully checked. CSS, and the names of tags and of computed
attributes, are not held to these checks: take them from your template, not
from input.
([subparsers.md](subparsers.md#urls-and-event-handlers))

## HTTP servers

The HTTP servers (`serveHttp`, the event and HTTPS servers, HTTP/2) never send
a response header whose name is not a token or whose value has a CR, LF or
NUL, since request input in such a header could add headers or a second
response. They send a plain `500` without the response's headers or body
instead:

```abla
import "abla/http"
import "abla/io"

fun main {
    val next = "/home\r\nSet-Cookie: admin=1"
    val response = HttpResponse(302, [HttpHeader("Location", next)], "")
    println("${httpResponseFieldsError(response.headers) != ""}")
    println("${response.render() == "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"}")
}
// output:
// true
// true
```

**What you do:** check a value from the request before you put it in a
header, so a user gets your error instead of a `500`. Authentication, sessions,
CSRF tokens and rate limits are your program's.
([networking.md](networking.md))

## TLS

`abla/tls/pure` verifies the server's certificate by default: the chain to the
system trust store (or a CA file), the host name in the subjectAltName (no
Common Name fallback), validity, key usage and name constraints. An empty host
name is refused rather than read as "don't check". The client asks for an OCSP
staple and refuses a certificate its staple says is revoked; a server that
sends no staple is still accepted, unless the certificate is must-staple or
the client requires one (`TlsClientConfig.revocation`). TLS 1.0 and 1.1, CBC and RSA key
exchange, renegotiation, compression and 0-RTT are refused. If
`SSL_CERT_FILE`, `SSL_CERT_DIR` or `NIX_SSL_CERT_FILE` is set, it is the whole
trust: an empty or missing one verifies nothing, rather than falling back to
the system's.

**What you do:** keep the system trust store current, and pass
`allowAnyHost = true` to the verifier only where any name is really meant.
([tls.md](tls.md))

## Releases

Every release since signing began ships `SHA256SUMS`, its signature
`SHA256SUMS.sig` and an SPDX bill of materials, and GitHub attests where each
asset was built. To check a download, put `SHA256SUMS`, `SHA256SUMS.sig` and
the assets in one directory and run:

```sh
tools/verify-release.sh --version vX.Y.Z DIR
```

It refuses a release without a signature, a signature that the key for that
release doesn't verify, a bill of materials of another release, and any asset
that isn't listed or doesn't match. `setup-abla` and the bootstrap scripts
check releases the same way.
([bootstrap.md](bootstrap.md))
