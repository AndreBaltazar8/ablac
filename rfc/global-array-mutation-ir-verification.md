# Bug RFC: Support Mutable Global Arrays Through Verified IR

- Status: Implemented single-thread baseline (typed globals and verified mutation)
- Affects: self-hosted semantic lowering, ownership analysis, and IR diagnostics
- Discovered by: Abla MVC server-side session storage

## Summary

Appending to an array that is stored in global state passes parsing and semantic
analysis but produces invalid IR. Compilation fails late with an opaque
`ir.verification` count and no source location.

The failure occurs both for a directly declared global array and for an array
field reached through a global object. Reading a preinitialized global array and
mutating a field of an object already inside it both compile successfully. A
local array also supports `append`, so the unsupported boundary is specifically
structural mutation of a global-reachable array.

Global mutable collections are needed for ordinary long-lived services such as
HTTP session stores, registries, caches, metrics, connection tables, and job
queues. The compiler should either support this operation with defined
ownership/concurrency semantics or reject it during semantic analysis with a
precise diagnostic. It must not reach invalid IR.

## Minimal reproduction: direct global array

```abla
val items: array<int> = []

fun main: int {
    items.append(7)
    if (items.size == 1) 0 else 1
}
```

Compile with:

```sh
ablac build global-array.ab -o build/global-array --no-cache
```

Observed output:

```text
ir.verification:2
LLVM compilation failed: 0 parser, 0 semantic, 4 total error(s)
native toolchain failed with status 1
```

## Minimal reproduction: array inside global object

```abla
class Item(val value: int)
class Store(val items: array<Item>)

val state: Store = Store([])

fun main: int {
    state.items.append(Item(7))
    if (state.items.size == 1) 0 else 1
}
```

This produces the same late IR verification failure.

Introducing a local alias does not avoid the problem:

```abla
val localItems = state.items
localItems.append(Item(7))
```

It also produces `ir.verification:2`.

## Boundary checks

The following related operations compile successfully today.

### Read a preinitialized global array

```abla
class Item(val value: int, var active: bool)
class Store(val items: array<Item>)

val state: Store = Store([Item(7, true)])

fun main: int = if (state.items[0].value == 7) 0 else 1
```

### Mutate an object already stored in the array

```abla
fun main: int {
    state.items[0].active = false
    if (!state.items[0].active) 0 else 1
}
```

### Append to a local array

```abla
fun main: int {
    val items: array<int> = []
    items.append(7)
    if (items.size == 1) 0 else 1
}
```

These boundary results indicate that global initialization, global array reads,
indexing, and ordinary object-field mutation already work. The failing case is
array structural mutation after loading a global-reachable value.

Reassigning a mutable global array also currently fails without a useful
diagnostic:

```abla
var items: array<int> = []

fun main: int {
    items = [7]
    0
}
```

That case should be covered by the same global compound-state policy, even if
its correct ownership operation differs from in-place `append`.

## Expected behavior

If global arrays are supported, `append` should mutate the one persistent array
owned by the global binding and the appended element should be visible to later
requests and function calls.

The language contract must make clear whether:

- `val items: array<T>` makes the binding immutable while retaining the array's
  supported interior mutability;
- `var items: array<T>` additionally permits replacing the complete array;
- reading a global compound value borrows, shares, or copies its storage;
- a local alias refers to the same global array;
- appended owned/resource values transfer ownership into process-lifetime
  storage; and
- synchronized access is required when concurrency arrives.

The current behavior of local arrays suggests that `val` prevents rebinding but
does not prohibit supported array methods. Global and local bindings should use
the same rule unless the difference is explicit and diagnosed.

## Likely compiler area

The frontend recognizes the types and accepts the calls, so this is not an HTML,
MVC, parser, or method-resolution issue. The failure appears after lowering,
when `global.load`, `field.get`, and `array.append` must preserve one valid SSA
definition and the intended ownership/alias relationship.

The investigation should inspect:

- lowering of `array.append` when its receiver originates at `global.load`;
- result numbering and operand dominance for the emitted variadic instruction;
- whether loading an affine or mutable compound global needs a distinct borrow
  operation rather than an ordinary value load;
- the runtime representation used when an append grows and replaces array
  backing storage; and
- propagation of a possibly changed array payload back through a global or
  object field.

The last point is important: if append growth returns or installs a new backing
allocation, mutating a temporary loaded value must not leave the global pointing
at obsolete storage.

## Proposed implementation contract

Introduce explicit IR semantics for access to mutable global compound state.
Exact opcode names are open, but the model must distinguish:

1. loading a scalar/global value;
2. borrowing global-owned compound storage for a read;
3. borrowing it mutably for an in-place operation; and
4. replacing the global value and ending the old value's lifetime.

For an append through a field:

```text
global mutable borrow -> field mutable borrow -> array append
```

must remain connected to the owning global place. Lowering it as disconnected
value copies is insufficient when the array representation changes during
growth.

If the ownership/place representation needed for this is not available yet,
semantic analysis should temporarily reject the call before lowering:

```text
global.compound-mutation-unsupported: appending to global array `items` is not
yet supported
```

That diagnostic should point to `.append`, explain the affected global root,
and avoid emitting invalid IR.

## Concurrency policy

Fixing the current single-threaded runtime behavior does not require silently
promising data-race safety. The initial contract may state that ordinary mutable
global state is valid only in a single-threaded program or executor.

Before parallel request handling is introduced, the language should require an
explicit synchronized/shared wrapper or reject unsynchronized global mutation.
This is compatible with implementing correct single-threaded global array
semantics now.

## Diagnostics

`ir.verification:2` is not sufficient as a user-facing compiler error. An IR
verifier failure indicates a compiler defect after a semantically accepted
program, not a source mistake.

Verifier failures should provide, in debug/compiler-test output:

- function name;
- failed invariant, such as duplicate definition, missing definition,
  dominance, lifetime, or terminator;
- instruction index and rendered instruction; and
- originating source span or lowering provenance when available.

Release diagnostics may remain concise, but they should include a stable bug
code and tell the user that the compiler generated invalid IR.

## Acceptance criteria

Add independent compile-and-run regressions covering:

1. append to a direct global `array<int>`;
2. append to an array field of a global object;
3. append through a local alias of that field;
4. repeated appends that force backing-storage growth;
5. read-after-append from a later function call;
6. append of class instances and subsequent mutable field access;
7. replacement of a `var` global array, if supported;
8. a compile-time diagnostic for any operation intentionally unsupported; and
9. native LLVM, ORC `run`, and generated-C parity.

The Abla MVC integration test should maintain at least two simultaneous session
records in a global array, authenticate each independently, invalidate one, and
confirm the other remains valid.

No accepted source program may finish semantic analysis and then fail only as
an anonymous IR verification count.

## Current application workaround

The MVC demonstration uses one set of scalar globals for its one demo account.
A successful login rotates the single active session. This preserves secure
random tokens, server-side expiry, and logout invalidation, but deliberately
allows only one active demo session at a time.

Once global mutable arrays are fixed, the session store can become
`array<MvcSession>` without changing the cookie or controller API.
