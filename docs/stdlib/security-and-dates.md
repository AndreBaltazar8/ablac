# Hashing, encoding and dates

| Import | What it gives you |
|---|---|
| `abla/crypto` | SHA-256, SHA-1, MD5, HMAC-SHA-256, PBKDF2, Base64, hexadecimal, constant-time comparison |
| `abla/date` | UTC calendar dates, ISO 8601 and HTTP dates |
| `abla/jwt`, `abla/jwt/remote` | JSON Web Token verification ([networking.md](../networking.md)) |

Both modules are pure Abla: they work on every target and at compile time.

## `abla/crypto`

The hash functions return the **raw digest bytes**, not text. Wrap them in
`hexEncode` (or `base64Encode`) to print or compare them as text:

```abla
import "abla/io"
import "abla/crypto"

fun main {
    println(hexEncode(sha256("abc")))
    println(hexEncode(hmacSha256("key", "message")))
    val encoded = base64Encode("hello, world")
    println("$encoded -> ${base64Decode(encoded)}")
    println("${sha256("abc").size} bytes; equal: ${constantTimeEquals("token", "token")}")
}
// output:
// ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
// 6e9ef29b75fffc5b7abae527d58fdadb2fe42e7219011976917343065f58ed4a
// aGVsbG8sIHdvcmxk -> hello, world
// 32 bytes; equal: true
```

| Function | Result |
|---|---|
| `sha256(data)`, `sha1(data)`, `md5(data)` | raw digest bytes (32, 20 and 16 bytes) |
| `hmacSha256(key, message)` | raw 32-byte MAC |
| `pbkdf2Sha256(password, salt, iterations)` | a raw 32-byte derived key |
| `base64Encode(data)`, `base64Decode(text)` | standard Base64 with padding |
| `hexEncode(data)` | lowercase hexadecimal |
| `constantTimeEquals(a, b)` | equality that takes the same time wherever the inputs differ; use it to compare secrets |
| `binaryXor(a, b)` | bytewise XOR of two equal-length strings |

SHA-1 and MD5 are there for protocols that require them (WebSocket
handshakes, legacy checksums), not for security.

## Dates: `abla/date`

Times are `int` milliseconds since 1970-01-01T00:00:00Z. A `UtcDate` is
that time split into calendar fields, in the proleptic Gregorian calendar,
without leap seconds:

```abla
import "abla/io"
import "abla/date"

fun main {
    val ms = utcMilliseconds(2024, 2, 29, 13, 5, 9)
    val date = utcDate(ms)
    println("${date.iso8601()} weekday ${date.weekday}, day ${date.dayOfYear()} of the year")
    println(httpDate(ms))
    val parsed = utcIso8601Parse("2024-02-29T13:05:09.000Z")
    if (parsed != null) println("round trip: ${parsed == ms}")
    println("${utcIso8601Parse("not a date") == null} ${dateLeapYear(2100)} ${dateDaysInMonth(2024, 2)}")
}
// output:
// 2024-02-29T13:05:09.000Z weekday 4, day 60 of the year
// Thu, 29 Feb 2024 13:05:09 GMT
// round trip: true
// true false 29
```

| Function | Result |
|---|---|
| `utcMilliseconds(year, month, day, hour = 0, minute = 0, second = 0, millisecond = 0)` | the time of a civil date |
| `utcDate(milliseconds)` | a `UtcDate(year, month, day, hour, minute, second, millisecond, weekday)`: month 1-12, day 1-31, weekday 0 (Sunday) to 6 |
| `date.milliseconds()`, `date.dayOfYear()` | back to a time; the day number (1-366) |
| `date.isoDate()`, `date.isoTime()`, `date.iso8601()`, `utcIso8601(ms)` | `2024-02-29`, `13:05:09.000`, `2024-02-29T13:05:09.000Z` |
| `date.httpDate()`, `httpDate(ms)` | `Thu, 29 Feb 2024 13:05:09 GMT` |
| `utcIso8601Parse(text)`, `httpDateParse(text)` | `int?`: the time, or `null` for invalid text |
| `dateLeapYear(year)`, `dateDaysInMonth(year, month)`, `dateWeekdayName(weekday)`, `dateMonthName(month)` | calendar facts |

The current time comes from `utcNow()` in `abla/process/time`
([system.md](system.md#time-ablaprocesstime)).
