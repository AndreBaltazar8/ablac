# RFC: Inferred lambda syntax for parser extensions

- Status: Draft
- Date: 2026-08-05
- Scope: compile-time parser-extension AST construction

## Summary

Add a parser-extension builder for an ordinary lambda whose parameter types
are inferred from its use site:

```abla
compile extern:"parser" fun syntaxInferredLambda(
    parameterNames: array<string>,
    body: SyntaxExpression,
    moving: bool
): SyntaxExpression
```

The builder creates the same syntax as a source lambda whose parameters omit
type annotations. It does not resolve names, choose types, or bypass ordinary
semantic and ownership checking.

## Motivation

`syntaxLambda` requires resolved compiler type handles. That API is useful in a
deferred generated-module finalizer, but a registered subparser runs during
initial parsing, before `compilerFindType` can return candidate-program type
handles.

Some embedded languages need to return a closure directly from the subparser.
For example, a declarative UI template can lower inline event bodies and its
view expression into one state-machine closure:

```abla
mobileRun($mobile
    <Screen>
        <Button onTap={count = count + 1}>Increment</Button>
    </Screen>
)
```

The expected `mobileRun` parameter type already provides the event and payload
types. Requiring the UI package to know compiler-internal type handles during
parsing is unnecessary and currently impossible. Generating a top-level
function later is not equivalent because it cannot preserve ordinary local
capture semantics.

This need is framework-neutral. Query, matcher, routing, parser-combinator, and
template extensions may also synthesize closures whose types should flow from
the surrounding call.

## Current behavior

Source lambdas permit omitted annotations:

```abla
apply({ value -> value + 1 })
```

The parser represents each omitted parameter type as `unknown`; semantic
analysis then applies the callable type expected by `apply`.

The public `syntaxLambda` builder instead accepts `array<int>` reflected type
handles and rejects invalid handles immediately. A subparser that calls
`compilerFindType` during initial parsing receives no valid handle, so it
cannot construct the equivalent source lambda.

## Proposed behavior

`syntaxInferredLambda` accepts:

- one valid generated-identifier name per parameter;
- an owned `SyntaxExpression` body; and
- a `moving` flag selecting ordinary or move-lambda syntax.

It produces `lambda.parameter` syntax with `type: unknown`, exactly like the
ordinary parser does for an unannotated parameter. All later rules remain
unchanged:

- the surrounding expression must provide enough context to infer types;
- unresolved or ambiguous types are normal semantic errors;
- capture analysis determines `Fn`, `FnMut`, or `FnOnce`;
- mutable/owned callable parameter modes remain enforced;
- region, effect, ownership, and IR validation still run; and
- the generated syntax retains the subparser invocation provenance.

The existing `syntaxLambda` API remains the explicit typed form for deferred
finalizers and other phases where reflected handles are available.

## Validation and limits

The compile-time evaluator rejects a request unless:

1. `parameterNames` is an array;
2. every element is a valid, non-reserved generated identifier;
3. names are unique;
4. `body` is a syntax handle owned by the current evaluation; and
5. `moving` is a boolean.

The existing evaluator instruction, collection, and syntax-node budgets apply.

## Non-goals

- Adding a UI, XML, mobile, or reactivity feature to the compiler.
- Inferring a lambda without an expected callable type when ordinary Abla
  could not infer it.
- Allowing parameter modes or generic declarations through this first API.
- Capturing compiler values or retaining parser cursors in runtime code.
- Skipping generated syntax validation.

## Acceptance tests

1. A subparser builds a one-parameter inferred lambda used as `Fn(int) -> int`.
2. A synthesized lambda captures an outer local and returns the expected value.
3. A synthesized mutating lambda is inferred as `FnMut` and can update a
   captured variable through a `var` callable parameter.
4. Invalid/duplicate parameter names fail during extension evaluation.
5. An unconstrained inferred parameter still fails ordinary semantic analysis.
