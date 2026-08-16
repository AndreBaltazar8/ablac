# JSON

`abla/json` provides one phase-safe JSON data model for runtime parsing,
compile-time evaluation, and `$json` literals. It has no HTTP or host-runtime
dependency.

```abla
import "abla/json"

val parsed = jsonParse("{\"name\":\"Abla\",\"versions\":[1,2.5e1]}")
if (parsed.succeeded) {
    val name = parsed.value.get("name").asString()
    val encoded = jsonStringify(parsed.value)
}
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
val result = jsonParse(source)
if (!result.succeeded) {
    val code = result.error.code
    val byte = result.error.byteOffset
}
```

`jsonParse` accepts the standard JSON grammar and valid UTF-8. It rejects
comments, trailing commas, leading plus signs, leading zeroes, incomplete
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

Every parse is bounded by `JsonLimits`. `jsonDefaultLimits()` returns:

| Limit | Default | Hard ceiling |
|---|---:|---:|
| input bytes | 1 MiB | 16 MiB |
| nesting depth | 64 | 256 |
| value nodes | 100,000 | 1,000,000 |
| decoded bytes per string | 1 MiB | 16 MiB |
| members per object | 10,000 | 100,000 |

Limits must be positive and no greater than the hard ceilings. Invalid limits
return `input_limit`. Duplicate keys are rejected by default. Setting
`rejectDuplicateKeys` to false preserves every member in source order;
`jsonStringify` emits them in that order and `get` observes the last matching
member.

## Forward-only reading and streaming encoding

Known-schema protocol code does not need to allocate a `Json` tree. An
`JsonObjectReader` walks the source once, decodes only requested strings, and
can retain a validated raw value slice:

```abla
val reader = jsonObjectReader(source)
reader.nextExpected("method")
val method = reader.readString()
reader.nextExpected("headers")
val headers = reader.readStringPairsRaw()
val valid = reader.finish()
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

For output, the single-pass `JsonEncoder` writes one validated stream without
building fragments or a dynamic tree:

```abla
val encoder = jsonEncoder()
encoder.beginObject()
encoder.key("ok")
encoder.boolean(true)
encoder.key("items")
encoder.beginArray()
encoder.string("one")
encoder.integer(2)
encoder.endArray()
encoder.endObject()
val encoded = encoder.finish()
```

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

`$json` constructs the same model directly and accepts standard integer,
fraction, and exponent forms:

```abla
val literal = $json {
    "answer": 42,
    "ratio": 1.5e-2,
    "large": 9223372036854775808
}
```

`$jsons` uses the same grammar and immediately returns the deterministic
serialized string. Its staged form is the concise choice for static protocol
fixtures and headers because validation and serialization both happen during
compilation:

```abla
val body = #$jsons {
    "event": "ready",
    "attempt": 1
}
```

`$json`, `#$json`, `$jsons`, `#$jsons`, `#jsonParse`, and `#jsonStringify` use
the same phase-safe implementation as runtime code. For the same tree,
compile-time and native serialization produce identical bytes.

## HTTP adapter

JSON policy is separate from the base HTTP transport:

```abla
import "abla/http/json"

val request = httpPostJson("/rpc", jsonObject(
    ["method"],
    [jsonString("ping")]
))
val response = httpJsonValue(jsonBoolean(true), 200)
val body = request.parseJson()
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
