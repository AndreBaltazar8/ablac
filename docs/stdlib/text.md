# Text, bytes and number formatting

The built-in `string` type has `size`, byte indexing, `slice` and `+`
([language.md](../language.md#strings)). Everything else about text is in
these modules:

| Import | What it gives you |
|---|---|
| `abla/text` | search, split, trim, replace, case, padding, joining; UTF-8 code points |
| `abla/bytes` | `ByteBuffer` for building large strings efficiently; byte slices; stable hashes |
| `abla/float/text` | `f64` to shortest text and back |

All three are pure Abla, work on every target, and work at compile time.

## `abla/text`: string helpers

```abla
import "abla/io"
import "abla/text"

fun main {
    val line = "  name=Ada Lovelace; role=analyst  "
    val trimmed = line.trim()
    println("[$trimmed]")
    for (field in trimmed.split("; ")) {
        val eq = field.indexOf("=")
        println("${field.slice(0, eq).uppercase()} -> ${field.slice(eq + 1, field.size)}")
    }
    println("${trimmed.startsWith("name")} ${trimmed.contains("Ada")} ${trimmed.lastIndexOf("a")}")
    println(textJoin(["a", "b", "c"], ", "))
    println("ab".repeat(3) + "|" + "7".padStart(3, "0") + "|" + "x".padEnd(3, ".") + "|")
    println("2024-01-02".replace("-", "/"))
}
// output:
// [name=Ada Lovelace; role=analyst]
// NAME -> Ada Lovelace
// ROLE -> analyst
// true true 26
// a, b, c
// ababab|007|x..|
// 2024/01/02
```

| Function | Result |
|---|---|
| `s.startsWith(prefix)`, `s.endsWith(suffix)`, `s.contains(needle)` | `bool` |
| `s.indexOf(needle, from = 0)`, `s.lastIndexOf(needle)` | byte position, or `-1` |
| `s.split(separator)` | the pieces between separators: `n` separators give `n + 1` pieces, empty ones included; an empty separator gives the whole string |
| `textJoin(parts, separator = "")` | the parts with the separator between them |
| `s.trim()`, `s.trimStart()`, `s.trimEnd()` | without ASCII whitespace at the ends |
| `s.replace(old, replacement)` | every occurrence replaced, left to right; an empty `old` replaces nothing |
| `s.uppercase()`, `s.lowercase()` | ASCII letters mapped; other bytes unchanged |
| `s.repeat(count)` | `count` copies |
| `s.padStart(length, pad = " ")`, `s.padEnd(length, pad = " ")` | padded to `length` bytes; a longer string is unchanged |
| `textAsciiEqualInsensitive(a, b)` | ASCII case-insensitive equality |

Positions and lengths are in bytes, matching `size` and `slice`. Case mapping
and trimming are ASCII-only, so UTF-8 text passes through unchanged.

## `abla/text`: Unicode

Strings are byte sequences. These functions read them as UTF-8, explicitly:

```abla
import "abla/io"
import "abla/text"

fun main {
    val word = "naïve"
    println("${word.size} bytes, ${word.codePointCount()} code points")
    println("${word.isValidUtf8()} ${word.codePointAt(2)} ${word.codePointSlice(1, 3)}")
    println(utf8Encode(233))
}
// output:
// 6 bytes, 5 code points
// true 239 aï
// é
```

| Function | Result |
|---|---|
| `s.isValidUtf8()` | rejects overlong encodings, surrogates, truncation and values above U+10FFFF |
| `utf8Info(s)` | `Utf8Info(valid, codePoints, errorOffset)` |
| `s.codePointCount()` | number of code points |
| `s.codePointAt(i)`, `s.codePointSlice(begin, end)` | by code-point position; a position past the end (or invalid UTF-8 before it) gives `-1` and `""` instead of panicking |
| `utf8ByteOffset(s, i)`, `utf8DecodeAt(s, offset)` | convert between code-point and byte positions; `utf8ByteOffset` is `-1` past the end (`i == codePointCount()` gives `size`) |
| `utf8Encode(scalar)` | the UTF-8 encoding of one code point; `""` for a negative value, a surrogate or one above U+10FFFF |

There are no locale-dependent operations and no large Unicode tables.

## `abla/bytes`: building strings

Concatenating in a loop copies the string each time. A `ByteBuffer` collects
pieces and joins them once:

```abla
import "abla/io"
import "abla/bytes"

fun main {
    val buffer = byteBuffer()
    buffer.appendText("id=")
    buffer.appendInt(42)
    buffer.appendText(", price=")
    buffer.appendFixed(1999, 2)
    println("${buffer.toText()} (${buffer.size()} bytes)")
}
// output:
// id=42, price=19.99 (18 bytes)
```

| Function | Effect |
|---|---|
| `byteBuffer()`, `bytes(text)` | an empty buffer, or one holding `text` |
| `appendText(text)`, `appendInt(n)`, `appendFixed(n, decimals)` | append text, an integer, or `n / 10^decimals` as a decimal |
| `appendByteValue(byte)`, `appendBuffer(other)` | append one byte, or another buffer |
| `size()`, `byteAt(i)`, `toText()` | inspect it |
| `slice(begin, end)` | a `ByteSlice` view tied to the buffer |
| `stableTextHash(text)`, `buffer.stableHash()` | a hash that is the same on every target and run |

`abla/float/text` adds `ByteBuffer.appendF64(value)`.

## `abla/float/text`: floats as text

`f64Text` writes the shortest decimal that reads back as exactly the same
value, the way JavaScript's `Number#toString` does. `f64Parse` reads decimal
text as the nearest `f64`, the way `Number()` and `JSON.parse` do. Importing
this module is also what lets a string template insert an `f64` or `f32`.

```abla
import "abla/io"
import "abla/float/text"

fun main {
    val x = f64Parse("1.5e-7")
    println("${f64Text(x)} ${f64Text(f64Parse("0.1") + f64Parse("0.2"))} ${f64Text(1e21)}")
    val bad = f64Parse("oops")
    println("${bad != bad} ${0.25}")
}
// output:
// 1.5e-7 0.30000000000000004 1e+21
// true 0.25
```

- `f64Text` gives `"NaN"`, `"Infinity"`, `"-Infinity"`, and `"0"` for both
  zeros. Whole numbers below 2^53 print without a decimal point.
- `f64Parse` accepts `"0.1"`, `"-12"`, `"1.5e-7"`, `"1E+21"`, `".5"`, `"5."`,
  `"Infinity"` and `"-Infinity"`, and returns NaN for anything else.
  `f64ParseRange(text, begin, end)` parses part of a string.
- The results are identical at compile time and at run time, on every
  target.
