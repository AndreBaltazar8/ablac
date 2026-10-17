# Compile-time subparsers

Status: working staged implementation. Abla-defined handlers, transactional
registration, opaque token/raw-source cursors, bounded parser stacking, and
syntax builders are implemented. The JSON and HTML providers are both written
in Abla and contain no privileged provider logic in stage 0.

## Invocation and phases

An embedded expression begins with `$` and a registered parser name:

```abla
import "abla/io"
import "abla/json"
import "abla/html"

fun main {
    val count = 1
    val document = $json {"testKey": "value"}
    val view = $html <div>{count + 20}</div>
    val frozen = #$json {"answer": 42}
    val encoded = #$jsons {"answer": 42}
    println("${document.get("testKey").asString()} ${frozen.getInt("answer")} $encoded ${view.tag}")
}
// output:
// value 42 {"answer":42} div
```

The named subparser always runs during compilation because it extends the
source grammar. It returns an ordinary typed Abla expression. That returned
expression is phase-neutral: it executes at runtime in the first two examples
and in the shared compile VM under `#` in the third. A handler must not smuggle
compile-only host values into runtime IR.

The `$json` provider uses the same [JSON model](json.md) as `jsonParse`. It
accepts integer, fractional, and exponent number forms without converting them
through floating point, including across formatted multi-line literals. Other
keys and values are handed back to the base parser as Abla expressions. The
companion `$jsons` provider delegates to that grammar and wraps the resulting
tree in deterministic `jsonStringify`; `#$jsons` therefore leaves a validated
static string in the runtime program.

## Writing a subparser

A subparser is a `compile fun` that takes a `ParserCursor` and returns a
`SyntaxExpression`, the expression that replaces `$name ...` in the
program. Register it with a top-level `#compilerRegisterSubparser("name",
handler)`. From then on, the module (and every module that imports it) can
write `$name`:

```abla
import "abla/io"
import "abla/text"
import "abla/compiler/parser"

// $twice(expression): hand the inside back to the Abla parser, double it.
compile fun parseTwice(cursor: ParserCursor): SyntaxExpression {
    parserExpect(cursor, "(")
    val inner = parserParseAblaExpression(cursor)
    parserExpect(cursor, ")")
    syntaxBinary("*", inner, syntaxInteger(2))
}

// $shout[any text]: read raw source text, upper-case it at compile time.
compile fun parseShout(cursor: ParserCursor): SyntaxExpression {
    parserRawExpect(cursor, "[")
    val text = parserRawTakeUntil(cursor, "]")
    parserRawExpect(cursor, "]")
    syntaxString(text.uppercase() + "!")
}

// $squares 4: build the array literal [1, 4, 9, 16].
compile fun parseSquares(cursor: ParserCursor): SyntaxExpression {
    parserRawSkipWhitespace(cursor)
    val digits = parserRawTakeUntil(cursor, " \n)],;")
    var count = 0
    for (d in digits) {
        if (d < 48 || d > 57) parserFail(cursor, "expected a number after \$squares")
        count = count * 10 + d - 48
    }
    val items: array<SyntaxExpression> = []
    for (i in 1..count) items.append(syntaxInteger(i * i))
    syntaxArray(items)
}

#compilerRegisterSubparser("twice", parseTwice)
#compilerRegisterSubparser("shout", parseShout)
#compilerRegisterSubparser("squares", parseSquares)

fun main {
    val n = 20
    println("${$twice(n + 1)}")
    println($shout[hello, world])
    val table = $squares 4
    println("${table.size} ${table[3]}")
}
// output:
// 42
// HELLO, WORLD!
// 4 16
```

The cursor starts right after the name. A handler reads the source in one
of two ways:

- **Tokens**, as the Abla lexer sees them: `parserAt`, `parserConsume`,
  `parserExpect`, `parserCurrentText`, and `parserTextAhead(cursor, n)` to
  look ahead without consuming. `parserParseAblaExpression` parses one whole
  Abla expression, which may itself contain other `$name` subparsers.
- **Raw bytes**, for text that isn't Abla: `parserRawAt`, `parserRawConsume`,
  `parserRawExpect`, `parserRawTakeUntil(cursor, delimiterBytes)`,
  `parserRawTakeUntilText(cursor, delimiter)`, `parserRawTakeName`,
  `parserRawTakeSymbol`, `parserRawSkipWhitespace`, `parserRawEnd`, and
  `parserRawPosition` for spans.

It builds its result with the `syntax*` builders: `syntaxInteger`,
`syntaxString`, `syntaxBoolean`, `syntaxNull`, `syntaxIdentifier`,
`syntaxBinary`, `syntaxArray`, `syntaxCall`, `syntaxMember`, `syntaxIndex`,
`syntaxIf`, `syntaxBlock`, `syntaxLocal`, `syntaxVariable`, `syntaxAssign`,
`syntaxReturn`, `syntaxLambda` and `syntaxInferredLambda`. A syntax handle
is consumed when it is put into another node.

`parserFail(cursor, message)` reports an error at the cursor. The build
stops with that message:

```abla error
import "abla/compiler/parser"

compile fun parseOne(cursor: ParserCursor): SyntaxExpression {
    parserRawSkipWhitespace(cursor)
    if (parserRawTakeName(cursor) != "one") parserFail(cursor, "expected the word one")
    syntaxInteger(1)
}

#compilerRegisterSubparser("one", parseOne)

fun main: int = $one two
// error: E_SUBPARSER_FAILURE
// error: expected the word one
```

The returned expression is ordinary, phase-neutral Abla. `$twice(n + 1)`
runs at run time, and `#$twice(20)` would run at compile time. The handler
itself always runs at compile time, with compile-time rules: it may use
`compile val` state, and it needs [capabilities](compile-time.md#capabilities-files-environment-processes-network)
to read files or the environment.

## Registration staging

Parser providers are ordinary modules. Registration is an explicit top-level
compile expression in the module prelude:

```abla fragment
#compilerRegisterSubparser("json", parseJson)
```

Stage 0 proceeds in dependency order:

1. parse the base-language prefix up to the first unknown `$name`;
2. discover and load imports visible in that prefix;
3. resolve, type, lower, verify, and execute its compile expressions;
4. validate all pending registrations and publish them as one staging unit;
5. restart parsing, repeating until the complete module is available.

Imports may provide parsers to consumers. A module may use its own parser only
after its registration expression. Registration cycles are diagnostics.
Duplicate or invalid registrations reject the staging unit without publishing
its handlers. Staging is limited to 32 rounds, and parser nesting to 64 frames.

## Cursor contract

The Abla API receives one opaque cursor positioned immediately after the parser
name. A handler may:

- inspect and consume named base-language tokens or exact raw source text;
- read the current token text, or an upcoming token's text without
  consuming it (`parserTextAhead`);
- skip raw whitespace, read raw names, and consume text up to delimiters;
- construct owned syntax with integer, string, Boolean, null, identifier,
  binary, array, member/index, call, conditional, local, return, and block
  builders;
- suspend itself and ask the base parser to parse one Abla expression;
- invoke another registered subparser through that base-parser hand-off;
- return one expression at the cursor position handed back to its caller.

The compiler owns source text and AST nodes. Handlers receive stable handles,
not C++ pointers. Syntax handles are consumed when inserted into another node
and cannot escape into runtime IR.

Read-only `syntaxKind`, `syntaxText`, `syntaxChildCount`, `syntaxChild`,
`syntaxBegin`, and `syntaxEnd` operations expose structure and precise source
spans without exposing mutable compiler objects. A handler may record the
handle as an extension request with an Abla finalizer. That finalizer inspects
function signatures and eligibility through `abla/compiler`, returns either a
bounded compatibility virtual module or an owned generated-AST builder, and the
compiler validates the complete candidate atomically.

Typed inspection covers direct and member calls, receiver and ordered argument
types, enclosing parameters/preceding locals, canonical method identities,
parameter names, and class fields. Compiler-owned resolved-call builders accept
those handles and preserve the selected target as provenance instead of asking
an extension to synthesize a source name. Receiver-less construction from an
inherent-method handle is rejected transactionally.

Finalizers can create an owned `GeneratedModuleBuilder`, add functions and
values from syntax/type handles, and finish it as the virtual-module result.
Internal declarations receive compiler-assigned deterministic names checked
against user and sibling declarations. A deliberately source-visible adapter
uses `compilerGeneratedExportFunction`, which rejects collisions rather than
renaming user-visible API. The MVC-style adapter gate generates a resolved
inherent-method call inside a builder-owned conditional, a typed nullable
generated value, an internal helper, and one explicit export without the
extension assembling source text. Invalid handles and export collisions leave
the candidate unchanged.

`compilerRecordGeneratedExtensionRequest` keeps the builder as AST rather than
rendering and reparsing it. Every published declaration carries the extension
namespace and originating expression span; semantic diagnostics include that
origin trace. The complete builder payload is validated before any declaration
is appended. The older string-returning request remains as a compatibility
path for existing providers.

Recursive providers may record a parsed expression and then return a different
synthesized tree, such as HTML attribute and child arrays. The compiler retains
the immutable request node in a semantic-only set, so its direct-call target,
argument bindings, conversions, and result handle remain available even when
the node is absent from runtime output. Finalizers resolve against the complete
provider-visible declaration set, including imported helper functions. Use
`parserSourceIdentity(cursor)` plus the expression span for a request namespace
that distinguishes otherwise identical imported modules. Request and finalizer
invariant diagnostics include that identity, namespace, and source span.
Resolved function and type handles use compilation-wide canonical identities,
so a generated adapter can retain a target declared in a relative module or a
locked package without depending on a transient per-module declaration index.

Checkpoint/restoration, explicit-span diagnostics, populated generic
substitutions, richer UTF-8 operations, and lazy tokenization remain future API
layers. Deferred requests already receive compact post-resolution call maps
with argument/default/conversion bindings. Compiler-owned generated
declaration references already carry unforgeable hygiene marks. The raw operations are
enough for embedded text containing bytes that are not Abla tokens, while the
base parser remains responsible for `{...}` hand-offs.

### Target assembly providers

Architecture packages can use the same mechanism to own assembly syntax. A
provider such as `$xtensa` parses register operations or instruction blocks and
returns calls to generic typed compiler boundaries:

```abla fragment
trusted noescape extern:"inline-assembly" fun assemblyReadU32(
    template: string,
    constraints: string
): u32

compile fun parseXtensa(cursor: ParserCursor): SyntaxExpression {
    syntaxCall(
        "assemblyReadU32",
        [syntaxString("rsr.intenable $0"), syntaxString("=a")]
    )
}

#compilerRegisterSubparser("xtensa", parseXtensa)
```

`ablac` validates literal templates and constraints plus scalar operand and
result types, but it does not enumerate architecture instructions or
registers. Adding an operation therefore changes only the architecture
package. The package may expose normal Abla functions or a richer
`$architecture` grammar while both lower to ordinary LLVM inline assembly.

Whole ABI leaves put the generic `@naked` annotation on an ordinary Abla
function whose sole expression calls the same `extern:"inline-assembly"`
boundary. `@naked` is a function code-generation property: it is independent
from the architecture provider and from `@export` or other linkage policy. A
naked body accepts no assembly value operands and owns the complete prologue,
return convention, and return instruction. It is intended for context-switch
and interrupt leaves, not individual instructions.

## Parser stack and safety

Subparsers form an explicit stack. Stage 0 enforces a depth limit of 64 and the
shared compile VM bounds execution. Every successful frame returns control at
one unambiguous token position.

HTML interpolation illustrates the stack:

```text
Abla parser
  -> html parser after `$html`
       -> Abla expression parser after `{`
            -> another `$name` parser if requested
       <- html parser at matching `}`
  <- Abla parser after the closing HTML node
```

Braces belong to the HTML provider in this context; the provider explicitly
delegates their contents to Abla. JSON strings and HTML text do not accidentally
activate base-language syntax.

## Determinism and caching

A registry is part of the module parse cache key. Its fingerprint includes the
provider module content, compiled handler IR, compiler API version, granted
capabilities, and transitive parser dependencies. Handlers are deterministic by
default. Filesystem, environment, process, clock, randomness, and network access
require declared capabilities. Filesystem reads have the first deterministic
provider contract: the source request and entry manifest are intersected before
handler evaluation, and every observed path/content pair is journaled. Other
ambient providers remain uncached until they gain equivalent contracts.

The persistent frontend snapshot retains returned syntax and dependency
fingerprints and revalidates journaled files before reuse. The native object
cache stores bounded dual content identities and treats malformed or changed
records as misses.

## Bootstrap API direction

The public `abla/compiler/parser` module exposes `ParserCursor` and
`SyntaxExpression` handles, token/raw operations, base-expression re-entry,
syntax builders, diagnostics, and registration. `$json` and `$html` are
ordinary Abla providers. Both return calls into phase-safe standard-library
models and pass VM/generated-C parity, including `#$name` frozen values.

The self-hosted compiler now uses the same public model. Its staged parser
discovers ordinary `#compilerRegisterSubparser` actions in source order,
executes compile handlers through the Abla evaluator, records owned expansion
ranges, and reparses the base source with those expressions installed. The
stage-1/stage-2 gates cover a syntax-building provider, a nested provider stack
loaded through an import, and the production JSON and HTML providers under
both `$name` and `#$name`.
