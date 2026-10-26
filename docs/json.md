# JSON

`abla/json` provides one phase-safe JSON data model for runtime parsing,
compile-time evaluation, and `$json` literals. It has no HTTP or host-runtime
dependency.

```abla
import "abla/io"
import "abla/json"

fun main {
    val parsed = jsonParse("{\"name\":\"Abla\",\"versions\":[1,2.5e1]}")
    if (parsed.succeeded) {
        println(parsed.value.get("name").asString())
        println("${parsed.value.get("versions").size()} versions")
        println(jsonStringify(parsed.value))
    }
}
// output:
// Abla
// 2 versions
// {"name":"Abla","versions":[1,2.5e1]}
```

## Values and numbers

`Json.kind` has these stable values:

| Kind | Meaning |
|---:|---|
| `0` | null |
| `1` | string |
| `2` | number |
| `3` | Boolean |
| `4` | array |
| `5` | object |

All JSON numbers use one `JsonNumber` representation. Its `text` field keeps
the validated source lexeme, so fractions, exponents, and integers larger than
Abla's signed `int` are never rounded. `integer` is true only when the lexeme
has neither a fraction nor an exponent. `intAvailable` reports whether the
number fits an Abla `int`; `intValue` is meaningful only in that case.

The public constructors are `jsonNull`, `jsonString`, `jsonNumber`,
`jsonNumberText`, `jsonInteger`, `jsonBoolean`, `jsonArray`, and `jsonObject`.
`jsonNumberText` validates its argument. Invalid UTF-8 strings, invalid number
text, and mismatched object key/value arrays produce the null sentinel rather
than an invalid tree. Arrays passed to array and object constructors become the
stored ordered children; normal Abla ownership rules apply to those values.

The kind predicates are `isNull`, `isString`, `isNumber`, `isBoolean`,
`isArray`, and `isObject`. Accessors deliberately have simple sentinel
behavior until the standard library has a generic result type:

- `asString()` returns `""` for a non-string;
- `asBoolean()` returns `false` for a non-Boolean;
- `asNumber()` returns an unavailable empty number for a non-number;
- `asInt()` returns `0` unless `intAvailable()` is true;
- `get(key)` returns JSON null when the key is absent;
- `size()` returns zero for scalar values; and
- `at(index)` uses the ordinary checked array-index behavior.

Use a kind predicate, `has`, or `intAvailable` when a sentinel could be
ambiguous.

## Strict parsing

```abla
import "abla/io"
import "abla/json"

fun main {
    val result = jsonParse("{\"a\": 1,}")
    if (!result.succeeded) {
        val error = result.error
        println("${error.code} at byte ${error.byteOffset}, line ${error.line} column ${error.column}")
    }
}
// output:
// unexpected_token at byte 8, line 1 column 9
```

`jsonParse` accepts the standard JSON grammar and valid UTF-8. It rejects
comments, trailing commas (which `$json` literals allow), leading plus signs, leading zeroes, incomplete
fractions or exponents, unescaped control bytes, lone UTF-16 surrogates,
duplicate object keys, and non-whitespace trailing input. Escaped surrogate
pairs are decoded to UTF-8. Error offsets count source bytes; line and column
are one-based.

On failure, `succeeded` is false, `value` is JSON null, and `error.code` is one
of:

- `unexpected_end`
- `unexpected_token`
- `trailing_input`
- `invalid_escape`
- `invalid_unicode`
- `invalid_number`
- `duplicate_key`
- `depth_limit`
- `node_limit`
- `string_limit`
- `input_limit`

Error messages are diagnostic text and may improve; branch on the code.

Every parse is bounded by `JsonLimits`. `jsonDefaultLimits()` returns
`jsonStandardLimits`:

| Limit | Default |
|---|---:|
| input bytes | 1 MiB |
| nesting depth | 64 |
| value nodes | 100,000 |
| decoded bytes per string | 1 MiB |
| members per object | 10,000 |

Each call's limits are its own: a caller parsing a large trusted document
raises bytes, nodes, strings and members as far as it needs. Limits must be
positive, and the depth at most 256, since parsing recurses per level; invalid
limits return `input_limit`. Duplicate keys are rejected by default. Setting
`rejectDuplicateKeys` to false preserves every member in source order;
`jsonStringify` emits them in that order and `get` observes the last matching
member. Setting `mergeDuplicateKeys` as well merges them as JavaScript's
`JSON.parse` does: a key keeps its first position and takes its last value.

`jsonPermissiveLimits` reads what `JSON.parse` reads: no byte, node, string or
member limit, nesting to depth 256, and duplicate keys merged:

```abla
import "abla/io"
import "abla/json"

fun main {
    val parsed = jsonParse("{\"a\":1,\"b\":2,\"a\":3}", jsonPermissiveLimits)
    println("${jsonStringify(parsed.value)} ${parsed.value.getInt("a")}")
}
// output:
// {"a":3,"b":2} 3
```

A reader (`jsonObjectReader(source, jsonPermissiveLimits)`) can't merge as it
goes: it gives every member as written, duplicates included, in source order.
Keeping the last value read for each key gives `JSON.parse`'s result.

## Forward-only reading and streaming encoding

Known-schema protocol code does not need to allocate a `Json` tree. An
`JsonObjectReader` walks the source once, decodes only requested strings, and
can retain a validated raw value slice:

```abla
import "abla/io"
import "abla/json"

fun main {
    val source = "{\"method\":\"GET\",\"headers\":[[\"accept\",\"text/plain\"]]}"
    val reader = jsonObjectReader(source)
    reader.nextExpected("method")
    val method = reader.readString()
    reader.nextExpected("headers")
    val headers = reader.readStringPairsRaw()
    val valid = reader.finish()
    println("$method $headers $valid")
}
// output:
// GET [["accept","text/plain"]] true
```

`nextExpected` is the order-sensitive fast path for canonical producers.
`nextExpectedRaw` is the still leaner form when the producer guarantees
ordinary unescaped UTF-8 field names; it compares the source bytes directly.
`next` supports ordinary member iteration when order is not known; consume its
current value with `readString`, `readRaw`, or `skip`. `readRaw` validates any
nested value without materializing it. `readStringPairsRaw` is a smaller fast
path for the common `[[name, value], ...]` protocol shape. Readers retain the
same input, UTF-8, depth, node, string, member, duplicate-key, and trailing-byte
checks as the tree parser.

Schema readers can also traverse nested data without rescanning a retained raw
slice. `readObject` and `readArray` return readers sharing the same forward
parser state. Object readers additionally expose `readInteger`,
`readNumber`, `readBoolean` and `readNull`; array readers use `next` with
`readString`, `readInteger`, `readNumber`, `readBoolean`, `readNull`,
`readObject`, `readArray`, `readRaw`, or `skip`, and both have `peek`. An array
reader's `readRaw` is the object reader's for the current element: its text as
the input spells it, whitespace around it skipped, nested values validated, and
`""` with the reader's error when the element is malformed or there is none.
Call `finishNested` before continuing in the parent and `finish` on the root
reader. The canonical
`nextExpectedRaw` path fuses compact `,"name":` tokens while preserving the
whitespace-aware diagnostic fallback.

```abla
import "abla/io"
import "abla/json"

fun main {
    val items = jsonArrayReader("[1, {\"a\": [2, 3]}, \"x\"]")
    while (items.next()) println(items.readRaw())
    println("${items.finish()}")
}
// output:
// 1
// {"a": [2, 3]}
// "x"
// true
```

Typed decoding of numeric data needs three more reads, on both readers.
`readNumber()` reads any JSON number (fraction and exponent included) as the
nearest `f64`, in place, without allocating; a malformed number fails with
`invalid_number` at the number, as `readInteger` does. `peek()` gives the
current value's kind without consuming it, with `Json.kind`'s codes (0 null,
1 string, 2 number, 3 boolean, 4 array, 5 object), or -1 when there is no
current value or the reader has failed. `readNull()` consumes a `null` and
returns true; for anything else it returns false and leaves the value to read:

```abla
import "abla/io"
import "abla/json"
import "abla/float/text"

class Sample(val id: int, val x: f64, val y: f64, val label: string)

fun main {
    val rows = jsonArrayReader(
        "[{\"id\":1,\"x\":-2.5e-1,\"y\":3,\"label\":null}," +
        "{\"id\":2,\"x\":0.1,\"y\":1E2,\"label\":\"edge\"}]"
    )
    val samples: array<Sample> = []
    while (rows.next()) {
        val row = rows.readObject()
        row.nextExpectedRaw("id")
        val id = row.readInteger()
        row.nextExpectedRaw("x")
        val x = row.readNumber()
        row.nextExpectedRaw("y")
        val y = row.readNumber()
        row.nextExpectedRaw("label")
        val label = if (row.readNull()) "-" else row.readString()
        row.finishNested()
        samples.append(Sample(id, x, y, label))
    }
    println("valid ${rows.finish()}")
    for (sample in samples) {
        println("${sample.id} ${f64Text(sample.x)} ${f64Text(sample.y)} ${sample.label}")
    }
    val value = jsonObjectReader("{\"v\":[1]}")
    value.next()
    println("kind ${value.peek()}")
}
// output:
// valid true
// 1 -0.25 3 -
// 2 0.1 100 edge
// kind 4
```

On an optimized build, decoding objects of 180 short numeric keys this way
(`tests/benchmarks/json-readers.ab`) costs about 70 ns per field with
`nextExpectedRaw` and `readNumber` (about 50 ns with `readInteger` on integer
data), against about 2 µs per field for `jsonParse`'s tree. `next()` costs
about twice as much (150–200 ns), since it decodes every key; rejecting
duplicate keys adds a hash-table lookup per key once an object has 16
members. Prefer `nextExpectedRaw` when the producer's key order is known.

For output, the single-pass `JsonEncoder` writes one validated stream without
building fragments or a dynamic tree:

```abla
import "abla/io"
import "abla/json"

fun main {
    val encoder = jsonEncoder()
    encoder.beginObject()
    encoder.encodedKey(#jsonEncodeString("ok"))
    encoder.boolean(true)
    encoder.key("items")
    encoder.beginArray()
    encoder.string("one")
    encoder.integer(2)
    encoder.endArray()
    encoder.endObject()
    println(encoder.finish())
}
// output:
// {"ok":true,"items":["one",2]}
```

For a static protocol key, `encodedKey(#jsonEncodeString("ok"))` (used for
`"ok"` above) moves quoting and UTF-8 validation to compile time. Dynamic or
untrusted keys continue to use `key`.

`key`, `string`, `integer`, `boolean`, `nullValue`, `beginObject`,
`beginArray`, `endObject`, and `endArray` enforce container state while writing.
The older `JsonEncoded` fragment constructors remain useful when composing
independently produced values. Both paths avoid handwritten JSON punctuation
and an intermediate dynamic object graph; LLVM can remove the DOM parser and
serializer when an application uses only the forward-only APIs.

## Serialization and literals

`jsonStringify` emits compact deterministic JSON. Object order is stored order,
number text is emitted losslessly, and strings escape quotes, backslashes, and
control bytes while retaining valid non-ASCII UTF-8. A manually forged invalid
kind, number, string, or object shape produces the contained fallback `"null"`;
invalid bytes are never emitted as JSON.

`$json` constructs the same model directly. Its keys and values are Abla
expressions:

```abla
import "abla/io"
import "abla/json"

class User(val name: string)

fun lookup(index: int): int = index * 10
fun tag(): string = "dynamic"

fun main {
    val user = User("ada")
    val count = 2
    val index = 3
    val literal = $json {
        "answer": 42,
        "ratio": 1.5e-2,
        "large": 9223372036854775808,
        "name": user.name,
        "next": count + 1,
        "item-$index": lookup(index),
        "tags": ["fixed", tag()],
    }
    println(jsonStringify(literal))
}
// output:
// {"answer":42,"ratio":1.5e-2,"large":9223372036854775808,"name":"ada","next":3,"item-3":30,"tags":["fixed","dynamic"]}
```

A value that starts with `{` or `[` is a JSON object or array; anything else
is an Abla expression. A number literal on its own keeps its source text, so
standard integer, fraction, and exponent forms, and integers beyond `int`, are
never rounded. String, Boolean, and `null` literals map directly. Any other
expression is converted by its type: `Json`, `string`, `int`, `bool`, `f64`,
`JsonNumber`, and arrays of `Json`, `string`, `int`, `f64`, or `bool`. An `f64`
is written as its shortest round-trip text (`f64Text`), the same bytes at
compile time and at run time; NaN and the infinities become `null`. A value of
any other type is a compile error at that value.

Keys must be strings; a key of another type is a compile error at that key.
A key repeated within one literal object is a compile error. Unlike JSON, an
object or array may end in a comma, as `"tags"` and the object above do, so a
literal written one member per line can add, remove, or reorder lines freely; a
comma with nothing before it (`[1,, 2]`, `{,}`) is a compile error. `$jsons`
reads the same grammar.

A value of another type is rejected with a help line listing the accepted
types.

```abla error
import "abla/json"

fun main {
    val document = $json {"name": "a", "name": "b"}
}
// error: duplicate key "name" in a $json object
```
An Abla expression that starts with `{` or `[` (a lambda or an array literal)
goes in parentheses. So does a top-level value followed by an operator that
should apply to the result: `($jsons count()) == expected`.

`$jsons` uses the same grammar and immediately returns the deterministic
serialized string. Its staged form is the concise choice for static protocol
fixtures and headers because validation and serialization both happen during
compilation:

```abla
import "abla/io"
import "abla/json"

fun main {
    val body = #$jsons {
        "event": "ready",
        "attempt": 1
    }
    println(body)
}
// output:
// {"event":"ready","attempt":1}
```

`$json`, `#$json`, `$jsons`, `#$jsons`, `#jsonParse`, and `#jsonStringify` use
the same phase-safe implementation as runtime code. For the same tree,
compile-time and native serialization produce identical bytes. Under `#`, the
value expressions run at compile time too, so they may call functions but not
read runtime locals.

## HTTP adapter

JSON policy is separate from the base HTTP transport:

```abla
import "abla/io"
import "abla/json"
import "abla/http/json"

fun main {
    val request = httpPostJson("/rpc", jsonObject(
        ["method"],
        [jsonString("ping")]
    ))
    val response = httpJsonValue(jsonBoolean(true), 200)
    val body = request.parseJson()
    println("${body.succeeded} ${body.value.get("method").asString()} ${response.status}")
}
// output:
// true ping 200
```

`HttpRequest.parseJson` accepts `application/json` and media types whose subtype
ends in `+json`; matching is ASCII case-insensitive and ignores parameters. A
missing or unsupported Content-Type returns `unsupported_media_type` without
parsing the body. `httpJsonLimits()` currently uses the standard conservative
limits.

`httpJsonValue` replaces every supplied Content-Type with exactly
`application/json; charset=utf-8`. `httpPostJson` does the same and adds
`Accept: application/json` only when the caller did not provide an Accept
header. Other headers retain their order.

The lower-level `abla/http` function `httpJson(string, status)` remains useful
when the body is already encoded and validated. Importing `abla/http` alone
does not import or retain `abla/json`.
