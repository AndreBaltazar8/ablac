# UUIDs

`abla/uuid` provides UUIDv4 and UUIDv7 as specified in
[RFC 9562](https://www.rfc-editor.org/rfc/rfc9562.html). Both constructors
return `Uuid?`: `null` means the system's secure random source failed or is
unavailable; UUIDv7 also returns `null` when the realtime clock fails.

```abla
import "abla/uuid"
import "abla/io"

fun main {
    val id = uuidV7()
    if (id != null) println(id.toString())
}
```

| Operation | Result |
|---|---|
| `uuidV4()` | 122 random bits, with the version and variant set |
| `uuidV7()` | Unix milliseconds in the first 48 bits, then 74 random bits and the version and variant |
| `uuidParse(text)` | `Uuid?`; exactly 36 ASCII characters in hyphenated form, hexadecimal in either case |
| `uuidFromBytes(bytes)` | `Uuid?`; exactly 16 bytes, in network order |
| `id.toString()` or `uuidText(id)` | canonical lowercase hyphenated text |
| `id.toBytes()` | the 16 bytes in network order |
| `id.equals(other)` | compares bytes; class `==` compares object identity |

Parsing checks the form, not a particular version or variant, and accepts the
nil and max UUIDs. Use `uuidFromBytes` for checked byte construction; the
language's public `Uuid(bytes)` constructor can also be called directly, so a
caller must supply exactly 16 bytes. Formatting an invalid direct construction
returns an empty string.

UUIDv7 places the timestamp first, so values from different milliseconds sort
by time when the wall clock moves forward. This implementation draws fresh
random bits for every UUID; it has no counter and does **not** guarantee
monotonic order within a millisecond. The realtime clock can also move
backwards. UUIDs provide identifiers, not authorization tokens.

The current `abla/random` backend uses the operating-system CSPRNG where
supported. It reports failure on targets without that backend, including
Wasm and Xtensa; it does not fall back to weak randomness. The existing
nanosecond realtime API also cannot represent times beyond its signed range.
