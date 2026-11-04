# YAML

`import "abla/yaml"` provides pure, bounded YAML configuration parsing on native,
Wasm and at compile time. It uses the [YAML 1.2 Core schema](https://yaml.org/spec/1.2.2/#103-core-schema). It is a configuration
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
Input must be UTF-8. Non-printable non-C0 characters are accepted in quoted scalars and escaped on fresh output. A leading BOM, `%YAML 1.2`, `---` and `...` are accepted.

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
preset. Number canonicalization is charged quadratic work before base conversion. Implicit block keys and compact flow-pair keys are limited to 1,024 Unicode characters; explicit scalar keys can be longer.
Source/CST helper types and functions in the implementation are not public API.

A local sanity check on equivalent 982,890-byte YAML and 982,891-byte JSON
sequences (8,000 strings, release build, one pinned CPU) measured median 16 ms
per YAML parse versus 5 ms for `abla/json`, over three alternating runs of ten
parses. Process peak RSS was about 53 MiB versus 15 MiB. These are sanity figures,
not portable performance guarantees; YAML also tracks anchors and expansion costs.

## Emission

`yamlEmit(value, options = YamlEmitOptions(), limits = yamlDefaultLimits())`
returns `YamlEmitResult(text, succeeded, error)`. Always check `succeeded`.
Failure returns empty text, never a partial document or a substituted `null`.

```abla
import "abla/io"
import "abla/yaml"

fun main(): void {
    val encoded = yamlEmit(yamlObject(["password", "port"], [yamlString("secret"), yamlInteger(993)]))
    if (encoded.succeeded) print(encoded.text)
}
// output:
// "password": "secret"
// "port": 993
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

## Lossless documents and edits

Use `yamlParseDocument(text, limits)` when modifying an existing configuration.
Its result has `document`, `succeeded` and `error`. On success,
`document.value` gives the same values as `yamlParse`; `document.toText()` returns
**exactly** the original bytes, including comments, CRLF, quotes and EOF style.
The document keeps a concrete source model alongside its semantic values.

```abla
import "abla/io"
import "abla/yaml"

fun main(): void {
    val source = "accounts:\n  mail@example.com:\n    password: 'old'  # rotated yearly\n    port: 993\n"
    val parsed = yamlParseDocument(source)
    if (!parsed.succeeded) return
    val edits = parsed.document.edit()
    edits.set([
        yamlKey("accounts"), yamlKey("mail@example.com"), yamlKey("password")
    ], yamlString("new password"))
    val result = edits.finish()
    // Write result.document.toText() only if result.succeeded.
    if (result.succeeded) print(result.document.toText())
}
// output:
// accounts:
//   mail@example.com:
//     password: 'new password'  # rotated yearly
//     port: 993
```

Paths are arrays of typed parts: `yamlKey(string)` for a string mapping key,
`yamlValueKey(Yaml)` for another scalar key, and `yamlIndex(int)` for a sequence
index. Dots, slashes and email addresses are literal key characters, not path
syntax. An empty path selects the document root.

An editor provides boolean operations:

- `set(path, value)` replaces a value, or inserts an absent mapping leaf.
  A sequence index must already exist. `set([], value)` replaces the root.
- `insert(path, value)` requires an absent mapping key, or inserts at a sequence
  index from zero through its length.
- `remove(path)` removes an existing mapping entry or sequence element. Removing
  the last member leaves `{}` or `[]`, not null. Removing the root is rejected.
- `materialize(path)` replaces one alias occurrence with an anchor-free local
  copy before edits through that occurrence.

Parents must already exist and have the right kind; these operations do not
invent intermediate containers. No-op `set` retains the complete source.
Numeric no-op comparison includes numeric text, so setting decimal `10` over
hexadecimal `0xA` is an explicit spelling change.

Each operation applies bounded byte-range patches and reparses the result.
Untouched bytes stay exact. Scalar replacements retain plain/single/double or
literal/folded style where the requested value can be represented in that style;
otherwise they use escaped double quotes. Block scalars retain their header
comment. Inserted entries inherit block/flow layout, indentation, newline style
and existing key quote style. New collection values use flow form. Removing a
compact collection's first item can expand that collection onto continuation
lines. An insertion at EOF preserves the absence of a final newline.

Comments and whitespace outside the edited entry/subtree remain intact. Explicit
replacement or removal of an entire subtree may remove its interior comments;
change individual leaves when preserving those comments matters. Standalone gap
comments remain when entries are removed. Flow removals retain surrounding gaps
and comments while adjusting the required comma.

Reads resolve aliases. Editing **through** an alias is rejected until that
occurrence is explicitly materialized. Replacing/removing the alias occurrence
itself is local and allowed. Changing/removing an anchor definition, or replacing
a subtree containing one, is rejected while that definition has live aliases.
This includes edits to descendants of a referenced anchored container. Rebinding
an anchor name does not redirect earlier aliases. Materialization and all edits
remain subject to the ordinary expanded-size and parsing limits.

The first error is sticky. `finish()` returns either the validated final document
or **the original document** with an error, never a partially successful
transaction. A work budget bounds repeated reparsing within an editor. Inspect
`finish().succeeded` before writing. The library performs no filesystem I/O,
changes no file permissions, and has the same behavior natively, in Wasm and at
compile time.

`tests/cases/yaml/edit-phases.ab` contains a synthetic provision-mail example:
it changes an account's password, inserts a second account, preserves unrelated
configuration bytes and checks idempotence. It reads no real mailbox file or
secrets and does not depend on NovaKind.
