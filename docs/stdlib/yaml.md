# YAML

`import "abla/yaml"` provides pure, bounded YAML configuration parsing on native,
Wasm and at compile time. It uses the YAML 1.2 Core schema. It is a configuration
subset, not a full YAML processor.

```abla
import "abla/yaml"

val result = yamlParse("accounts:\n  mail@example.com: {port: 993}\n")
// Always inspect result.succeeded before using result.value.
val port = result.value.get("accounts").get("mail@example.com").get("port").asInt()
```

`YamlParseResult` has `value`, `succeeded` and `error`. `YamlError` has `code`,
`message`, a zero-based UTF-8 `byteOffset`, and one-based `line`/byte `column`.
Diagnostics do not echo scalar contents, which may contain secrets.

## Values

`Yaml` has six kinds: null, string, number, boolean, sequence and mapping.
Construct them with `yamlNull`, `yamlString`, `yamlNumberText`, `yamlInteger`,
`yamlBoolean`, `yamlSequence`, `yamlMapping`, or `yamlObject` (string keys).
Treat a value and its arrays as immutable after construction.

`isNull/isString/isNumber/isBoolean/isSequence/isMapping`, `size`, `at`,
`get(string)`/`has(string)` and `getKey(Yaml)`/`hasKey(Yaml)` mirror the JSON API.
`get` returns null for a missing key; use `has` to distinguish a present null.
`at` uses the ordinary checked array index. Scalar accessors are `asString`,
`asBoolean`, `asInt`, `intAvailable`, and `asNumber`. A mismatched scalar getter
returns its empty/zero value. Mapping keys may be any scalar, including null;
string lookups match only string keys.

Numbers retain exact original `text`, `integer`, signed-64 `intValue` and
`intAvailable`. `canonical` is an exact decimal key identity, never an f64
rounding. Integers larger than int, non-finite `.inf`/`-.inf`/`.nan`, and decimal
exponents are preserved. `asInt` returns zero unless `intAvailable` is true.
`yamlNumberText` marks an invalid number with `numberValue.valid == false`.
Integer and floating keys differ (`1` and `1.0`), but equivalent spellings of
the same type (`10` and `0xA`, or `1.0` and `10e-1`) are duplicates.

Plain `null`/`~`, booleans, decimal/`0o`/`0x` integers and decimal floats resolve
according to Core. `yes`, `on`, dates, `0o9`, `+0xA` and `1_000` are strings.
Quoted, literal and folded scalars are always strings.

## Supported syntax and deliberate rejections

Block and flow mappings/sequences, scalar keys (implicit or `?` explicit),
plain/single/double-quoted scalars, multiline scalar folding, `|` and `>` with
indentation and chomping indicators, comments, anchors and aliases are supported.
Anchor names can be rebound; an alias uses its most recent preceding definition.
Input must be UTF-8. A leading BOM, `%YAML 1.2`, `---` and `...` are accepted.

The following produce explicit errors rather than guessed interpretations:

- All explicit tags and `%TAG` directives, including `!!str`.
- YAML 1.1, unknown directives, and multiple documents.
- Collection-valued mapping keys.
- Undefined, forward and cyclic aliases.
- The bare `<<` merge-key extension. Quoted `"<<"` is an ordinary string key.
- Duplicate scalar mapping keys.

Aliases share their closed value graph. Parsing charges each occurrence's full
expanded node, scalar-byte and depth cost before accepting it. Repeated nested
aliases therefore cannot bypass the expansion limits.

## Limits

Pass a `YamlLimits(...)` to `yamlParse(text, limits)`; defaults are:

| Limit | Default |
| --- | ---: |
| Input bytes | 1,048,576 |
| Physical nesting depth | 64 |
| Physical nodes | 100,000 |
| Bytes per scalar | 1,048,576 |
| Members per collection | 10,000 |
| Anchor definitions / alias occurrences | 1,000 each |
| Expanded nodes | 100,000 |
| Expanded scalar bytes | 8,388,608 |
| Bytes per numeric text | 1,024 |
| Parsing work budget | 20,000,000 |

Depth has a hard maximum of 256; other limits also have finite hard maxima
(`yamlLimitsValid`). Invalid limits fail explicitly. There is no unlimited-alias
preset. Number canonicalization is charged quadratic work before base conversion.
Source/CST helper types and functions in the implementation are not public API.

A local sanity check on equivalent 982,890-byte YAML and 982,891-byte JSON
sequences (8,000 strings, release build, one pinned CPU) measured median 13 ms
per YAML parse versus 5 ms for `abla/json`, over three alternating runs of ten
parses. Process peak RSS was about 53 MiB versus 15 MiB. These are sanity figures,
not portable performance guarantees; YAML also tracks anchors and expansion costs.

## Emission

`yamlEmit(value, options = YamlEmitOptions(), limits = yamlDefaultLimits())`
returns `YamlEmitResult(text, succeeded, error)`. Always check `succeeded`.
Failure returns empty text, never a partial document or a substituted `null`.

```abla
val encoded = yamlEmit(yamlObject(["password", "port"], [yamlString("secret"), yamlInteger(993)]))
```

Fresh output uses deterministic block layout, two spaces, LF, insertion-order
mapping entries, double-quoted strings and a final newline. It preserves exact
numeric text, including non-finite numbers. It emits `[]` and `{}` for empty
containers. This creates a fresh representation; it does not preserve input
comments, anchors or scalar styles. Aliases are emitted as bounded ordinary values.

`YamlEmitOptions(indent = 2, newline = "\n", finalNewline = true, flow = false)`
can select 1–8 spaces, LF or CRLF, a final newline, and flow collections. Invalid
options, malformed numeric values, invalid UTF-8, non-scalar/duplicate keys,
mismatched key/value arrays and exceeded limits fail explicitly. Constructed
cyclic graphs terminate at the depth limit. Do not mutate a value while emitting.
