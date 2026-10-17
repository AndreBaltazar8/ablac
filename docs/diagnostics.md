# Diagnostics

This page explains how to read the compiler's error messages, and lists the
codes with what they mean and where the rule is explained.

## Reading a diagnostic

```text
error[E_SEMANTIC]: function.argument:add@60:i64:string
source[semantic]:main.ab:60:61
  --> main.ab:4:17
help: ...
```

- `error[CODE]` names the kind of problem. Codes are stable: tests and tools
  match on them, and so can you.
- For type, ownership and other semantic errors the code is `E_SEMANTIC`,
  and the first word of the message is a more precise dotted code
  (`function.argument`). The rest, separated by `:`, are details: here the
  callee `add`, the byte offset `60` of the argument, the expected type
  `i64` and the actual type `string`.
- `source[phase]:file:begin:end` locates it as a range of **byte offsets**
  in the file, for tools. The phase is `parser`, `semantic`, `eval` and so
  on. The `-->` line after it gives the same place as `file:line:column`
  (columns count characters, from 1); it is left out when the file can't be
  read, as for a generated module.
- `help:` lines, when present, suggest a fix.
- `context[...]` lines add the module or declaration involved.
- The last line counts the errors per phase:
  `LLVM compilation failed: 0 parser, 0 extension, 1 semantic, 0 IR, 1 total error(s)`.

Types are written in their canonical spelling: `int` is `i64`, a nullable
type is `nullable:T`, and a function type is `function:(i64)->i64`. An
expression whose type couldn't be worked out shows as `unknown`; such errors
usually follow from an earlier one.

When several errors are reported, fix the first one and build again: later
errors often follow from it.

> Known issue (being fixed by coordinator): a parse error should stop the
> build after the parser, so that only parse errors print. Today the later
> phases still run, so a parse error can be followed by `unknown`-type
> semantic errors and `E_IR_*`/`E_LLVM_*` errors (some printed before it).
> Fix the first `E_PARSE_*` error and ignore the rest.

## Parser: `E_PARSE_*`

A parse error stops the build after the parser, so a file with one reports
only its parse errors.

| Code | Message |
|---|---|
| `E_PARSE_EXPECTED_TOKEN` | expected token `X`, found `Y` |
| `E_PARSE_EXPRESSION` | expected an expression, found `X` |
| `E_PARSE_STATEMENT_SEPARATOR` | expected a newline, `;`, or `}` after statement |
| `E_PARSE_TOP_LEVEL_DECLARATION` | expected a top-level declaration or compile expression: statements must be inside a function |
| `E_PARSE_PARAMETER_SEPARATOR`, `E_PARSE_ARGUMENT_SEPARATOR`, `E_PARSE_ARRAY_SEPARATOR` | a missing `,` |
| `E_PARSE_UNCLOSED_DELIMITER` | an unclosed `(`, `[` or `{` |
| `E_PARSE_STRING_PART` | a malformed string or template |
| `E_PARSE_EXTENSION_RECEIVER` | an extension's receiver type isn't followed by `.name` (e.g. an unclosed `array<int`) |
| `E_PARSE_SAFE_CALL`, `E_PARSE_ELVIS` | Kotlin's `?.` or `?:`: Abla has neither; check `x != null` (which narrows a `val`) or write `if (x != null) x else fallback` |
| `E_PARSE_INVALID_ESCAPE` | an unknown backslash escape in a string, a `\x` without 2 hex digits, or a `\u` that isn't a Unicode code point ([language.md](language.md#lexical-structure)) |
| `E_PARSE_ASSIGNMENT_TARGET` | the left side of `=` can't be assigned |
| `E_PARSE_COMPOUND_ASSIGNMENT_TARGET` | the left side of `+=` etc. contains a call ([language.md](language.md#expressions-and-operators)) |
| `E_PARSE_TRAILING_LAMBDA_TARGET` | a trailing lambda after something that can't be called |
| `E_PARSE_CLASS_MEMBER` | a class body contains something other than a method |
| `E_PARSE_RESOURCE_DECLARATION` | `resource` before something other than `class` |
| `E_PARSE_ANNOTATION`, `E_PARSE_ANNOTATED_DECLARATION` | a duplicate annotation, or one not followed by a declaration |
| `E_PARSE_DEFER_BODY`, `E_PARSE_REGION_BODY`, `E_PARSE_SUSPENDING_BODY` | `defer`, `region`, `generator`, `task` or `thread` without a block |
| `E_PARSE_DECLARATION_BLOCK_*` | a malformed [declaration block](compile-time.md#declaration-blocks) |
| `E_PARSE_*_PROGRESS` | the parser couldn't continue at that point; see the previous error |

## Names, calls and types

| Code | Meaning |
|---|---|
| `identifier:<name>@<offset>` | no variable, parameter or declaration of that name is visible |
| `call.target:<name>` | no function of that name |
| `function.arity:<f>`, `method.arity:<T>.<m>`, `constructor.arity` | wrong number of arguments |
| `method.unknown:<T>.<m>` | `T` has no method `m` (a help line names the standard module to import when one declares it, e.g. `abla/text` for `string.trim`) |
| `function.argument:<f>@<offset>:<expected>:<actual>`, `method.argument`, `constructor.argument` | an argument of the wrong type |
| `function.result:<f>:<declared>:<actual>`, `method.result` | the body's value doesn't match the declared result type ([language.md](language.md#void-and-never)) |
| `return.type` | a `return` value doesn't match the result type. Known issue (being fixed by coordinator): it will name the function and both types (`return.type:<f>:<expected>:<found>`), with a help line when the value is a closure that changes its captures (declare the result `FnMut() -> T`) |
| `member:<Type>.<name>` | no such property or method; `member:nullable:...` means the receiver may be `null` |
| `local.initializer:<name>` | an initializer doesn't match the declared type |
| `assignment.type:<name>@<offset>` | an assigned value doesn't match the variable's type |
| `assignment.immutable`, `global.immutable`, `field.immutable`, `member.immutable` | assigning a `val` |
| `global.initialization-cycle:<a>-><b>->...<a>` | top-level initializers that depend on each other, directly or through functions ([language.md](language.md#values-and-variables)). Known issue (being fixed by ct-infer): not reported yet |
| `local.duplicate`, `local.shadows-parameter`, `local.uninitialized-type`, `local.uninitialized-val` | see [values and variables](language.md#values-and-variables) |
| `symbol.duplicate:<name>:<files>` | two declarations with the same name and parameter types |
| `call.overload-ambiguous`, `call.overload-no-match` | see [overloads](language.md#overloads-and-operator-functions) |
| `arithmetic.type@<offset>:<left>:<right>`, `bitwise.type`, `comparison.type`, `logical.type`, `unary.boolean` | operand types that don't fit the operator ([integers](language.md#integers)) |
| `string.interpolation:<type>` | a value a template can't insert ([strings](language.md#lexical-structure)) |
| `array.element-type`, `index.type`, `index.receiver` | array literal and indexing errors |
| `append.*`, `truncate.size`, `clear.arity`, `filledArray.*`, `slice.*` | array and string method errors ([arrays](language.md#arrays)) |
| `map.untyped`, `map.key-type`, `map.<method>.*` | [Map](language.md#maps) errors |
| `type.underlying`, `type.constructor-*` | [nominal type](language.md#nominal-types) errors |
| `if.condition`, `while.condition`, `do-while.condition`, `for.source`, `range.bound-type` | control-flow operands of the wrong type |
| `when.non-exhaustive`, `when.duplicate`, `when.else-last`, `when.else-duplicate`, `when.empty` | see [control flow](language.md#control-flow) |
| `break.outside-loop`, `continue.outside-loop`, `return.outside-function` | control transfer outside its construct |
| `E_NAMED_ARGUMENT_UNKNOWN`, `_DUPLICATE`, `_ORDER`, `_REQUIRED`, `_TARGET`, `_ARITY` | named-argument errors ([functions](language.md#functions)) |
| `native.trust:<f>` | calling a trusted function from untrusted code ([trusted code](language.md#trusted-native-implementations)) |
| `noinline.*`, `naked.*`, `section.*`, `wasmImport.*`, `inline-assembly.*` | misused [annotations](language.md#annotations) |
| `E_EXPORT_ANNOTATION`, `E_EXPORT_SIGNATURE_UNSUPPORTED`, `E_EXPORT_TARGET_CAPABILITY` | an export with a bad name or a signature the foreign ABI can't express |

```abla error
fun add(a: int, b: int): int = a + b

fun main: int = add(1, "two")
// error: function.argument:add
```

## Ownership and borrowing

`ownership.*`, `E_BORROW_CONFLICT`, `resource.*`, `move.*`, `shared.*`,
`weak.*`, `mutex.*` and `cell.*` codes are explained, with their usual fixes,
in [ownership.md](ownership.md#reading-ownership-diagnostics).
`E_DELEGATE_*` and `E_NOT_DELEGATED` are in
[language.md](language.md#diagnostics).

## Regions

| Code | Meaning |
|---|---|
| `region.result:<type>` | a region produces something other than a scalar |
| `region.escape:<how>` | a region-owned value is assigned, appended or stored outside the region |
| `region.control:<return/break/continue>` | a jump out of a region body |
| `region.call-retention:<f>`, `region.indirect-call-retention`, `region.parameter-retention`, `region.receiver-retention` | a call that may keep a region-owned value |
| `region.noescape-effect:<f>` | a function declared `noescape` that does keep an argument |

See [regions.md](regions.md).

## Generators, tasks and threads

`defer.*`, `generator.*`, `yield.*`, `await.*`, `task.*` and `thread.*` are
listed in [concurrency.md](concurrency.md#diagnostics).

## Compile time

| Code | Meaning |
|---|---|
| `E_EVAL_EXPRESSION` | a compile-time evaluation failed; the message names the expression, and a `source[eval]` record with its `-->` line gives its file, line and column |
| `E_EVAL_STEP_LIMIT` | an evaluation ran past the step limit |
| `compile.effect-denied`, `compile.capability-not-authorized`, `compile.capability-unknown` | [capabilities](compile-time.md#capabilities-files-environment-processes-network) |
| `compile.value-runtime:<name>` | run-time code reads a `compile val`/`compile var` |
| `compile.result: ...` | a `#` result that can't become a program value |
| `declaration.block.compile-only` | a declaration block in run-time code |
| `subparser.unknown:<name>` | `$name` is not registered by any imported module; the help names the usual import (`abla/json` for `$json`) |
| `E_EXT_SUBPARSER_REGISTRATION`, `E_EXT_SUBPARSER_COLLISION` | a bad or duplicate `$name` registration ([subparsers.md](subparsers.md)) |
| `E_SUBPARSER_INVOCATION`, `E_SUBPARSER_FAILURE` | a subparser handler failed or reported an error |
| `E_EXT_GENERATED_MODULE_REQUEST`, `E_EXT_GENERATED_SEMANTIC`, `E_EXT_GENERATED_PROVENANCE`, `E_EXT_NAMESPACE_*` | a generated module was rejected |
| `E_EXT_FINALIZER_RESULT`, `E_GENERATED_EXTENSION_FINALIZER` | an extension finalizer failed or returned the wrong thing |
| `E_EXT_FUNCTION_HANDLE_*`, `E_EXT_EXPRESSION_HANDLE_INVALID` | a reflection handle that is unknown, out of range or of the wrong kind ([compiler-api.md](compiler-api.md)) |
| `E_EXT_TYPED_QUERY_BEFORE_RESOLUTION`, `E_REACTIVE_*` | typed reflection asked too early, or an invalid lifted function |
| `E_COMPILER_TRANSFORM_*` | a `compiler.transform` handler or its body/annotation changes were rejected |
| `E_INDEPENDENT_MODULE_*` | a misused independent module ([programmable-builds.md](programmable-builds.md)) |
| `E_CONTRACT_CALL_NOT_CONSUMED` | a [contract](language.md#contract-imports) call left in the program |

## Modules and packages

| Code | Meaning |
|---|---|
| `E_NO_MAIN` | the entry module has no `fun main` |
| `E_IMPORT_NOT_FOUND` | an imported file doesn't exist; the message names the path it looked for |
| `E_IMPORT_UNQUALIFIED_AMBIGUOUS` | two unaliased imports expose the same name ([modules](language.md#modules-and-imports)) |
| `E_IMPORT_ALIAS_*` | alias errors: duplicate alias, module imported twice, unknown member, alias used as a value |
| `E_IMPORT_PROVIDER_*` | a source provider expression or its result is invalid ([packages.md](packages.md)) |
| `E_PACKAGE_*` | lockfile, fetch, cache, digest, cycle and capability errors of dependencies ([packages.md](packages.md)) |
| `E_NATIVE_LIBRARY_MANIFEST` | invalid `nativeLibraries` in `abla.toml` |

## Builds

| Code | Meaning |
|---|---|
| `E_BUILD_TARGET_*`, `E_BUILD_ARTIFACT_UNSUPPORTED` | an unknown target, artifact or target definition ([programmable-builds.md](programmable-builds.md)) |
| `E_BUILD_GRAPH_*`, `E_BUILD_PROGRAM_REQUEST`, `E_BUILD_OUTPUT`, `E_BUILD_IO` | a programmable build graph that is invalid or couldn't be published |
| `E_ARTIFACT_*` | artifact roots and slices ([programmable-builds.md](programmable-builds.md)) |
| `E_NATIVE_TOOLCHAIN` | the linker or another native tool failed |

## Internal errors

`E_IR_*`, `E_LLVM_*`, `E_COMPILER_UNCLASSIFIED` and `E_INTERNAL` come from
the later compiler stages. Every source mistake should be reported by an
earlier check, with its own code. So if you see one of these, it is a
compiler bug, whether or not another error came before it. Please report it
with the smallest program that shows it.

