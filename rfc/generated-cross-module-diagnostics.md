# RFC: Actionable diagnostics for generated cross-module code

- Status: Draft
- Date: 2026-08-03
- Scope: compiler module resolution, generated extensions, IR verification, and command-line diagnostics

## Summary

Generated code currently fails when an extension expression refers to a
function imported from another application module in a GitHub-package-backed
project. Equivalent code compiles when the function and extension expression
are placed in the same composition-root file.

The compiler does not explain that distinction. It reports aggregate parser
and IR counts without a source location, generated namespace, failing symbol,
or concrete invariant. The final `E_NATIVE_TOOLCHAIN` label is also misleading
because the observed failure happens inside Abla parsing, generated-code
resolution, or IR verification rather than in an external native tool.

This RFC proposes two related requirements:

1. Generated references must remain valid across module snapshots and package
   boundaries by using canonical declaration and type identities rather than
   transient handles.
2. Every compiler error increment must carry an actionable diagnostic and
   provenance back to either user source or the extension that generated it.

## Motivation

Abla deliberately allows libraries to transform programs during compilation.
That makes generated-code diagnostics part of the language's primary user
experience, not an optional debugging aid. A user should be able to answer all
of these questions from an ordinary failed build:

- Which source expression initiated the generated work?
- Which generated declaration or IR function failed?
- Which compiler invariant was violated?
- Was the failure in user code, an extension, semantic analysis, lowering, or
  an external toolchain?
- What is the most likely corrective action?

The current output answers none of them:

```text
ir.verification:1
LLVM compilation failed: 5 parser, 0 extension, 0 semantic, 7 total error(s)
error[E_NATIVE_TOOLCHAIN]: native toolchain failed with status 1
```

The phase counts also do not add up: `5 + 0 + 0` does not explain `7 total`.
That makes the summary unsuitable even for narrowing down the failing stage.

## Minimal reproduction

Create a project using the public Abla MVC package.

`abla.toml`:

```toml
name = "generated-module-reproduction"
version = "0.1.0"
entry = "app.ab"
```

`actions.ab`:

```abla
var counter = 0

fun counterView(value: int): MvcHtml = $mvcview
    <span id="counter">{value}</span>

fun increment(amount: int): MvcAction {
    counter = counter + amount
    replace("#counter", counterView(counter))
}
```

`app.ab`:

```abla
#import(github("AndreBaltazar8/abla-mvc"))
#import("actions.ab")

fun page(): MvcHtml = $mvcview
    <main>
        <span id="counter">0</span>
        <button onclick={increment(1)} update="#counter">Increment</button>
    </main>

fun main: int {
    val actions = mvcGeneratedActions()
    if (page().render().size > 0 && actions.intActions.size > 0) 0 else 1
}
```

Resolve and build it:

```sh
ablac package update --project .
ablac build app.ab -o build/app --no-cache
```

Observed output:

```text
ir.verification:1
LLVM compilation failed: 5 parser, 0 extension, 0 semantic, 7 total error(s)
error[E_NATIVE_TOOLCHAIN]: native toolchain failed with status 1
```

As a control, move `counter`, `counterView`, and `increment` into `app.ab`
above `page`. The application then compiles. The action signature and generated
MVC code are otherwise unchanged.

The production case that exposed this also included a client-annotated action.
It produced the same opaque failure when its action target lived in another
local module. Consolidating the small application into its composition root
allowed both the server action and generated WebAssembly action to compile.

## Expected behavior

Both layouts should compile. Importing a declaration from a local module must
not change whether a generated extension can resolve its function or result
type.

If the program cannot compile, output should identify the initiating
`onclick={increment(1)}` expression and the exact generated declaration or IR
invariant that failed. For example:

```text
error[E_GENERATED_REFERENCE]: generated action adapter could not resolve
`increment(int) -> MvcAction` across module `actions.ab`
  --> app.ab:6:26
   |
 6 | <button onclick={increment(1)} update="#counter">Increment</button>
   |                  ^^^^^^^^^^^^ extension request originated here
   |
   = generated namespace: abla_mvc_a_...
   = target declaration: actions.ab::increment
   = cause: result type identity did not survive module merge
```

The wording is illustrative. The important requirements are the stable error
code, source location, generated namespace, target declaration, failed
invariant, and correct phase classification.

## Likely failure boundary

This section is a hypothesis to guide investigation, not a claim of confirmed
root cause.

Abla MVC records an extension request from `mvcParseActionAttributes` and later
resolves its typed call target in `mvcFinalizeAction`. The target can come from
a declaration snapshot belonging to another imported module. The framework
already compares canonical function identities when checking annotations,
because reflected functions can arrive through different declaration
snapshots. Other generated-action checks still consume function and type
handles directly.

Likely failure modes include:

- `typedCallTarget` retaining a snapshot-local function handle that is invalid
  after module aggregation;
- a function result type handle being compared with a `MvcAction` handle from
  another snapshot even though both represent the same canonical type;
- a generated declaration retaining an index into its source module rather
  than a canonical declaration identity; or
- lowering rejecting such a declaration after the originating extension
  diagnostics have already been discarded.

The first investigation step should trace the target function identity, result
type identity, generated namespace, and declaration handle from extension
finalization through module aggregation, semantic analysis, and IR lowering in
both the failing two-file case and the successful one-file control.

## Diagnostic gaps

### Unexplained parser counts

The failed build reports five parser errors but emits no parser diagnostic.
Any path that increments a parser error counter must either emit a specific
diagnostic immediately or attach enough state for the caller to emit one.

### Incomplete IR verification output

The LLVM backend currently emits `ir.verification:N` and adds details only for
functions whose `verificationErrors` field is nonzero. Other program-level
lowering errors therefore produce only a count. Program-level verification
must carry named invariants and provenance too.

### Lost generated provenance

Generated extension requests already know their namespace, source identity,
and expression range. That provenance must survive all later stages. A failure
must not become an anonymous parser or IR count after module aggregation.

### Misclassified native-toolchain error

`E_NATIVE_TOOLCHAIN` should be reserved for failures from tools such as the
linker, Clang, `wasm-ld`, or process execution. An Abla parser, semantic, or IR
verification failure should retain its compiler-stage error code even when it
occurs during `ablac build`.

### Inconsistent totals

The summary must classify every error exactly once, or explicitly show an
additional category such as `IR`. The displayed categories must add up to the
displayed total.

## Proposal

### 1. Use canonical identities in generated requests

At extension finalization, record stable identities for referenced functions
and types. Do not persist a module-local integer handle as the only identity of
a generated reference.

During module aggregation and semantic analysis:

- resolve a function by canonical identity in the destination snapshot;
- compare result and parameter types by canonical type identity;
- diagnose missing, ambiguous, or incompatible resolutions at the extension
  request's source range; and
- include both the source module and destination module in the diagnostic.

Raw handles may remain an internal optimization, but they must be validated
against the canonical identity before use across a snapshot boundary.

### 2. Introduce a diagnostic invariant

Every increment to an error total must have exactly one primary diagnostic
record. A record should contain at least:

- stable error code;
- compiler phase;
- human-readable message;
- source identity and range when available;
- generated namespace and declaration when applicable;
- causal diagnostic or originating extension request; and
- optional corrective note.

If a stage cannot provide a specific reason, it must emit an explicit internal
fallback such as `E_IR_UNCLASSIFIED`, including the failed stage and available
provenance. Silent counter increments are not permitted.

### 3. Preserve diagnostic causes through the pipeline

Parser, staged extension, semantic, IR, backend, and toolchain diagnostics
should be accumulated as structured values until final rendering. String
concatenation can remain at the command-line boundary, but it should not be the
only representation while the compilation is in progress.

A generated-code error should form a causal chain:

```text
user expression
  -> extension request
  -> generated declaration
  -> semantic or IR failure
```

The CLI can render the final failure first and the originating request as a
note, while machine-readable consumers retain the complete chain.

### 4. Separate compiler and external-tool failures

Return a compiler failure directly when parsing, generated extension handling,
semantic analysis, or IR lowering has errors. Invoke the native toolchain only
after those stages succeed. Wrap only actual external-process failures in
`E_NATIVE_TOOLCHAIN`.

### 5. Make summaries derived from diagnostics

Compute phase counts and totals from the final diagnostic collection rather
than maintaining independently mutable counters. This makes mismatched totals
structurally difficult.

## Testing plan

Add focused tests for:

1. the two-file reproduction above using a locked package import;
2. the same action with a relative library import;
3. server and `@client` actions referenced from another local module;
4. a deliberately invalid cross-module action signature;
5. a generated declaration that fails semantic analysis;
6. a generated declaration that fails an IR invariant;
7. a program-level IR verification failure without a function-level error;
8. an actual external linker failure; and
9. summary arithmetic for every failure category.

Tests for failures should assert the stable error code, originating source
identity/range, target declaration where applicable, phase, and summary
counts—not merely that compilation returned nonzero.

## Acceptance criteria

This RFC is satisfied when:

- the two-file package-import reproduction compiles;
- generated server and client actions behave identically whether their targets
  are declared in the root file or an imported local module;
- every nonzero compiler error count has a rendered primary diagnostic;
- generated failures point back to their extension request;
- IR failures name a violated invariant or emit an explicit internal fallback;
- compiler failures are not labeled as native-toolchain failures; and
- displayed phase counts add up to the displayed total.

## Non-goals

- Redesigning the MVC action API.
- Requiring generated source text as the compiler's extension representation.
- Standardizing a final JSON diagnostic schema in this RFC.
- Changing package-lock or package-provider semantics.

Those may be addressed separately after generated references and diagnostic
provenance are reliable.
