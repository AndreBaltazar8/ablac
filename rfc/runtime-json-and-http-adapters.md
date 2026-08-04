# RFC: Runtime JSON parsing, serialization, and opt-in HTTP adapters

- Status: Draft
- Date: 2026-08-04
- Scope: `abla/json`, `abla/http/json`, runtime/compile-time parity, bounded input handling, and HTTP convenience APIs

## Summary

`abla/json` currently provides a phase-safe `Json` tree and the `$json`
compile-time subparser, but it cannot parse JSON received at runtime or
serialize a `Json` value. Applications therefore construct JSON response bodies
with string interpolation and cannot safely consume a structured JSON request
without implementing a parser themselves.

This RFC proposes:

1. a strict, bounded `jsonParse(string) -> JsonParseResult` runtime API;
2. a standards-compliant `jsonStringify(Json) -> string` API;
3. the same behavior during compile-time evaluation and native execution;
4. structured parse failures with byte offsets and stable error codes; and
5. an optional `abla/http/json` module containing adapters between `Json` and
   `HttpRequest`/`HttpResponse`.

The HTTP adapter is separate so that `abla/http` keeps its current size and
dependency boundary. Importing the HTTP transport/router must not implicitly
import JSON.

## Motivation

JSON is already used by Abla's HTTP examples, ABI manifests, and proposed RPC
protocols, but the public runtime surface is incomplete. The current
pattern is equivalent to:

```abla
httpJson("{\"id\":\"${request.parameter("id")}\"}")
```

This is unsafe for arbitrary strings because interpolation does not perform
JSON escaping. It also encourages each framework to invent a parser, error
model, depth limit, duplicate-key policy, and Unicode behavior.

A standard implementation is required by mobile RPC, but it is not
mobile-specific. Command-line tools, HTTP services, configuration readers,
package providers, and compiler extensions all need the same phase-safe API.

## Current behavior

`stdlib/abla/json/entry.ab` currently defines:

- `Json` kinds for null, string, integer, Boolean, array, and object;
- constructors such as `ablaJsonString` and `ablaJsonObject`;
- `getString`, `getInt`, and `at`; and
- the `$json` embedded literal parser.

It does not define:

- a runtime parser;
- a serializer or string-escaping helper;
- a structured parse error;
- input/depth/node limits;
- duplicate-key behavior;
- complete JSON number behavior; or
- integration with HTTP request bodies.

`abla/http` deliberately does not import JSON. Its `httpJson(string, status)`
helper only labels an already encoded string as `application/json`.

## Goals

The implementation must:

- accept and emit valid UTF-8 JSON;
- implement the complete JSON string escape grammar;
- parse all standard JSON value forms, including fractional and exponent
  numbers;
- preserve integer precision and avoid silently rounding large values;
- return structured failures rather than panicking on untrusted input;
- reject trailing non-whitespace input;
- use explicit, bounded resource limits;
- behave identically in the compile-time evaluator and generated native code;
- serialize deterministically for a given `Json` tree; and
- keep JSON policy outside the base HTTP module.

## Non-goals

- Automatically deriving codecs for arbitrary Abla classes.
- Defining an RPC protocol.
- Adding JSON Schema validation.
- Providing a streaming/SAX parser in the first implementation.
- Requiring canonical JSON suitable for cryptographic signatures.
- Adding HTTP/2, TLS, compression, or content negotiation to `abla/http`.

Derived typed codecs and a streaming parser can build on this API in later
RFCs.

## Proposed data model

### JSON numbers

JSON numbers are not equivalent to an IEEE floating-point value or an Abla
`int`. Parsing through `f64` would corrupt large integer identifiers, while an
integer-only parser would reject valid JSON.

The `Json` representation should therefore preserve a validated number lexeme:

```abla
class JsonNumber(
    val text: string,
    val integer: bool,
    val intValue: int,
    val intAvailable: bool
)
```

The exact storage layout may differ, but these semantics are required:

- `text` preserves the validated JSON number's value without a lossy numeric
  conversion;
- `integer` reports whether the grammar contains no fraction or exponent;
- `intAvailable` reports whether conversion to Abla's signed `int` succeeds;
- `intValue` is meaningful only when `intAvailable` is true; and
- serialization never emits an invalid number.

The existing integer constructor and `getInt` convenience remain supported.
The internal `Json` layout may be changed while Abla is pre-release, but the
kind values exposed as public policy must be documented. A preferred direction
is one `number` kind rather than separate integer and decimal kinds, with
integer access expressed by `JsonNumber.intAvailable`.

### Parse result and error

Malformed or over-limit input returns a value, not a panic:

```abla
class JsonError(
    val code: string,
    val message: string,
    val byteOffset: int,
    val line: int,
    val column: int
)

class JsonParseResult(
    val value: Json,
    val succeeded: bool,
    val error: JsonError
)
```

When `succeeded` is true, `error.code` is empty. When false, `value` is a
well-formed JSON null sentinel and callers must inspect `error`.

Stable initial error codes are:

- `unexpected_end`;
- `unexpected_token`;
- `trailing_input`;
- `invalid_escape`;
- `invalid_unicode`;
- `invalid_number`;
- `duplicate_key`;
- `depth_limit`;
- `node_limit`;
- `string_limit`; and
- `input_limit`.

Messages are intended for diagnostics and may improve. Callers branch on the
code, not the message.

### Limits

Parsing always uses a limit value:

```abla
class JsonLimits(
    val maximumBytes: int,
    val maximumDepth: int,
    val maximumNodes: int,
    val maximumStringBytes: int,
    val maximumObjectMembers: int,
    val rejectDuplicateKeys: bool
)

fun jsonDefaultLimits(): JsonLimits
```

The ordinary default should be conservative and useful:

```text
maximumBytes          1 MiB
maximumDepth          64
maximumNodes          100,000
maximumStringBytes    1 MiB
maximumObjectMembers  10,000
rejectDuplicateKeys   true
```

Hard implementation ceilings prevent a caller from requesting unbounded
values. HTTP adapters may default to stricter limits.

Duplicate keys are rejected by default. Keeping the first or last value makes
security-sensitive interpretation depend on which component parsed the
document. An explicit relaxed option may preserve duplicates in source order,
but it must not be the default.

## Proposed `abla/json` API

The minimum public surface is:

```abla
fun jsonParse(
    source: string,
    limits: JsonLimits = jsonDefaultLimits()
): JsonParseResult

fun jsonStringify(value: Json): string
```

Useful tree accessors should be completed alongside it:

```abla
fun Json.isNull(): bool
fun Json.isString(): bool
fun Json.isNumber(): bool
fun Json.isBoolean(): bool
fun Json.isArray(): bool
fun Json.isObject(): bool

fun Json.asString(): string
fun Json.asBoolean(): bool
fun Json.asNumber(): JsonNumber
fun Json.asInt(): int
fun Json.intAvailable(): bool

fun Json.get(key: string): Json
fun Json.has(key: string): bool
fun Json.size(): int
fun Json.at(index: int): Json
```

Because the language does not yet have a standard generic `Result<T, E>`, the
explicit result class is appropriate for the first implementation. Accessors
that do not encode absence in their return type must have documented sentinel
behavior; typed codecs should prefer `has`/kind checks before access.

Constructors should gain short public names while retaining compatibility
aliases if needed:

```abla
fun jsonNull(): Json
fun jsonString(value: string): Json
fun jsonInteger(value: int): Json
fun jsonNumber(value: JsonNumber): Json
fun jsonBoolean(value: bool): Json
fun jsonArray(values: array<Json>): Json
fun jsonObject(keys: array<string>, values: array<Json>): Json
```

`jsonNumber` accepts only a `JsonNumber` previously validated by the parser or
a dedicated checked number constructor. It must not allow arbitrary invalid
text to reach `jsonStringify`.

## Parsing contract

The parser implements the JSON grammar, not Abla expression grammar. In
particular:

- only JSON whitespace bytes are skipped;
- comments and trailing commas are rejected;
- object keys must be strings;
- literals are exactly `true`, `false`, and `null`;
- number leading zeros, fraction digits, and exponent digits are checked;
- `NaN`, infinities, hexadecimal, and leading plus signs are rejected;
- unescaped control bytes below U+0020 are rejected;
- simple escapes and `\uXXXX` escapes are decoded;
- UTF-16 surrogate pairs in `\u` escapes are combined and lone surrogates are
  rejected;
- unescaped source text is validated as UTF-8; and
- any non-whitespace bytes after the first value produce `trailing_input`.

Offsets are byte offsets into the original Abla string. Line and column are
one-based for human diagnostics and are calculated without changing the byte
offset contract.

The implementation should be iterative where practical or explicitly check
depth before recursion. It must account for nodes and decoded string bytes
before allocation crosses the selected limit.

## Stringification contract

`jsonStringify` emits compact JSON with no insignificant whitespace.

- Object member order is the order stored by `Json.keys`/`Json.values`.
- Strings escape quotation mark, reverse solidus, and control characters.
- Valid non-ASCII UTF-8 may be emitted directly.
- Invalid UTF-8 in a string value is rejected before construction or causes a
  deterministic contained failure; it must never be emitted as JSON.
- Numbers use their validated representation and never locale-sensitive
  formatting.
- Arrays and objects enforce consistent key/value lengths.
- The same tree serializes to identical bytes in compile-time evaluation and
  native execution.

This is deterministic serialization, not a cryptographic canonicalization
standard. A future `jsonCanonicalize` API should cite and implement a specific
canonical JSON specification rather than changing `jsonStringify` silently.

## `$json` integration

`$json` continues to construct the same runtime model without first rendering
and reparsing text. It should accept the same standard number forms as
`jsonParse` and produce values that stringify equivalently.

These should agree:

```abla
val literal = $json {"answer": 42, "ratio": 1.5}
val parsed = jsonParse("{\"answer\":42,\"ratio\":1.5}")

jsonStringify(literal) == jsonStringify(parsed.value)
```

`#$json`, `#jsonParse`, and `#jsonStringify` must use the same implementation
semantics as runtime calls. No filesystem, environment, clock, random, or
network capability is required.

## Opt-in HTTP adapters

Add `stdlib/abla/http/json/entry.ab` with imports of `abla/http` and
`abla/json`. Do not add an `abla/json` import to `abla/http` itself.

The first adapter surface is:

```abla
fun HttpRequest.parseJson(
    limits: JsonLimits = httpJsonLimits()
): JsonParseResult

fun httpJsonValue(
    value: Json,
    status: int = 200,
    headers: array<HttpHeader> = []
): HttpResponse

fun httpPostJson(
    path: string,
    value: Json,
    headers: array<HttpHeader> = []
): HttpRequest
```

`httpJsonValue` sets:

```text
Content-Type: application/json; charset=utf-8
```

and serializes exactly once. An explicitly supplied conflicting Content-Type is
rejected or replaced according to one documented rule; it must not produce two
ambiguous Content-Type headers.

`httpPostJson` also sets `Accept: application/json` unless the caller already
supplied it. Header comparison uses HTTP's existing ASCII case-insensitive
logic.

`HttpRequest.parseJson` validates Content-Type by default. It accepts
`application/json` and media types with a `+json` suffix, ignoring parameters
case-insensitively where HTTP permits. A separate option may allow missing
Content-Type for trusted/internal callers. Unsupported content type returns a
stable `unsupported_media_type` adapter error without parsing the body.

The existing `httpJson(string, status)` remains available in `abla/http` as a
low-level already-encoded response helper. Its documentation should say that
the caller owns validation/escaping and should use `httpJsonValue` for a `Json`
tree.

The first RFC does not add automatic class decoding or route annotations.
Generated RPC adapters build and inspect `Json` explicitly or use a later typed
codec package.

### HTTP statuses used by adapters

JSON/RPC adapters need at least `400 Bad Request`, `409 Conflict`, `413 Payload
Too Large`, `415 Unsupported Media Type`, `422 Unprocessable Content`, and `429
Too Many Requests`, in addition to the existing success/authentication/server
statuses.

The current `httpStatusReason` falls back to `OK` for an unlisted status. That
can render a misleading line such as `HTTP/1.1 415 OK`. The HTTP module should
add the commonly used client/server reason phrases and use a neutral
`Unknown Status` fallback rather than `OK`. This is a small base-HTTP correction
and does not introduce a JSON dependency into `abla/http`.

## Error and panic policy

Malformed network input is ordinary data and must not panic. Limit failures are
also returned as `JsonParseResult` errors.

Programmer-invariant failures, such as constructing an object with different
key/value array lengths through an unsafe/internal path, may panic until Abla
has a standard result type. Public constructors should prevent those invalid
trees where possible.

HTTP adapters should provide a small helper for a safe generic client error,
but they must not automatically include parser messages or source bodies in a
production response.

## Performance expectations

The first parser may build a complete tree, but it should:

- scan input once apart from bounded Unicode/number validation;
- avoid repeated full-prefix concatenation;
- account allocations against ordinary Abla memory limits;
- use `ByteBuffer` or an equivalent bounded builder for serialization; and
- remain independent of libc and host-only APIs.

Benchmarks should include small RPC documents, a 1 MiB string/array document,
deep-but-valid nesting, duplicate-key rejection, and malformed inputs near the
end of the size limit.

## Diagnostics

Compile-time literal failures point to the `$json` source range. Runtime parse
failures use `JsonError` rather than compiler diagnostics.

Suggested compiler/test diagnostic codes are:

- `E_JSON_LITERAL` for invalid `$json` grammar;
- `E_JSON_LIMIT` for an invalid compile-time requested limit; and
- `E_HTTP_JSON_CONTENT_TYPE` when a compile-time-known adapter construction is
  invalid.

## Testing plan

Add tests for:

1. every JSON value and whitespace form;
2. integer boundaries, fractions, and exponents;
3. malformed numbers including leading zeros and incomplete exponents;
4. every escape and Unicode surrogate-pair case;
5. raw valid UTF-8 and invalid/overlong UTF-8;
6. embedded NUL represented through an escape;
7. duplicate keys and the selected relaxed policy if implemented;
8. every resource limit at the boundary and one byte/node beyond it;
9. trailing input and truncated documents;
10. parse/stringify/parse structural round trips;
11. `$json`, `#$json`, runtime parse, and native parity;
12. deterministic repeated serialization;
13. HTTP content type, status, extra headers, `Accept`, and body parsing;
14. `application/json`, `+json`, parameters, case, missing, and invalid media
    types; and
15. libc-free/native artifact reachability showing HTTP alone still does not
    retain JSON.

Fuzzing should compare acceptance with a standards-conforming reference parser
while allowing for the RFC's intentional duplicate-key rejection and hard
limits. Differential tests must compare parsed structure, not floating-point
rounding.

## Acceptance criteria

This RFC is complete when:

- `jsonParse` and `jsonStringify` are public and documented;
- valid standard JSON parses without lossy number conversion;
- malformed and over-limit input returns a structured error without panic;
- strings and Unicode pass compile-time/native parity tests;
- `$json` and runtime parsing share one documented data model;
- `abla/http/json` can safely parse a request and emit a JSON response;
- importing `abla/http` alone does not import or retain JSON; and
- all limits, duplicate-key behavior, number behavior, and ownership are
  covered by tests.

## Alternatives considered

### Put parsing and serialization in Abla Mobile

Rejected because JSON is a general standard-library concern and multiple
framework implementations would diverge on security and Unicode behavior.

### Add JSON directly to `abla/http`

Rejected because it violates the standard library's source-modular boundary
and makes every HTTP user pay for an unrelated representation.

### Support integers only

Rejected as the general `jsonParse` contract because fractional and exponent
numbers are valid JSON. Framework-specific codecs may still reject a number
that is not representable by their declared schema.

### Parse all numbers as `f64`

Rejected because it silently changes large integers and makes identifiers and
schema values unsafe.

### Return null on error

Rejected because it cannot distinguish valid JSON null from malformed input and
does not communicate where or why parsing failed.
