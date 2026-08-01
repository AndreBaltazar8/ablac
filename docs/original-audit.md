# Audit of `../abla-original`

Audit baseline: original commit `f14350c` on `master`.

The original repository is a roughly 4,900-line Kotlin prototype split into
ANTLR grammar, AST conversion, frontend execution, direct LLVM generation, and
a runner. It proves the core compile-time-execution idea, but it is not a safe
or complete compiler to extend in place.

## What is real and worth preserving

- Kotlin-like declarations, expression bodies, trailing lambdas, extension
  functions, annotations, nullable and pointer type syntax.
- Optional semicolons based on newline/comment boundaries.
- `#expression` compile-time execution and `compile`-only declarations.
- Compile-time interpretation of functions, arrays, objects, strings,
  conditionals, loops, and native calls.
- Imports implemented as a compiler-provided compile-time function.
- Compiler-context experiments that rename functions, replace bodies, inspect
  annotations, wrap functions, and add class methods.
- Direct C ABI declarations through `extern:"library"`.
- Basic direct LLVM output for functions, classes, arrays, lambdas, control
  flow, integer operations, and C calls.

All 25 original `.ab` example files are accepted by the new stage-0 parser.
This is a syntax baseline, not yet a claim that all programs execute.

## Accidental constraints and correctness gaps

### Grammar and diagnostics

- ANTLR errors are not converted into a compiler diagnostic model; AST
  conversion continues from parse contexts.
- Newline rules depend on reaching backward through hidden tokens.
- Identifiers are ASCII-only and malformed numeric separators are loosely
  accepted.
- The lexer declares booleans but the AST conversion/runtime coverage is
  incomplete.
- Several planned constructs shown in the README are not grammar productions,
  including inheritance, `try`/`catch`, and imports as declarations.

The replacement keeps newline tokens explicit, records half-open source spans,
and accumulates renderable diagnostics.

### Name and type analysis

- A single mutable global symbol table is shared by parallel compilation jobs.
- Symbols are resolved lazily from AST nodes and mutable backing fields.
- Duplicate declarations, overload sets, visibility, cycles, and most invalid
  shadowing are not checked.
- Type inference is a collection of local AST cases. Member access returns no
  inferred type, lambdas are partly hardcoded to `int`, and binary expressions
  use the right operand's type.
- The backend frequently casts types and symbols at runtime and throws generic
  exceptions or `NotImplementedError`.
- `int` is emitted as LLVM `i32`, null is also an `i32` zero, arrays are
  hardcoded to `i32`, and `when` storage is hardcoded to `i32`.

The replacement uses a module declaration pass, explicit scopes and overload
sets, canonical semantic types, constraint-based local inference, and a typed
IR that both compile time and runtime consume.

### Compile-time execution

- Compile-time values directly contain mutable AST nodes, Kotlin closures, JNA
  pointers, symbol objects, and execution scopes.
- Function calls mutate a `callInfo` field on the declaration itself. Recursive
  or concurrent calls can therefore interfere.
- Compiler reflection replaces methods in shared class symbol tables and
  mutates AST blocks in place without transactions or dependency invalidation.
- `compileExec.compiled` caches a result in the AST without recording its
  inputs, target, environment, imported content, or capabilities.
- Parallel imports can observe a mutable global graph in timing-dependent
  order.
- Native calls support only `void`, `int`, or pointer-like return handling and
  rely on JNA's host ABI.

The replacement VM owns target-independent values and call frames. Reflection
uses versioned handles and validates a transaction before committing it.
Capabilities and their observed inputs become part of compile-time cache keys.

### LLVM backend and runtime

- AST nodes carry backend state through external backing fields.
- Code generation and type discovery are coupled directly to LLVM C API
  objects.
- Runtime interpolated strings explicitly throw `TODO`.
- Objects use `LLVMBuildMalloc`; there is no destructor or garbage collector.
- Arrays are stack allocations without length metadata or bounds checks.
- Class layout contains a nominal vtable pointer, but virtual dispatch is not
  implemented.
- Nullable runtime behavior is special-cased for integers.
- Extern calls do not validate ABI-safe signatures and the `printf` examples
  rely on variadic-call accidents.
- The only "standard library" is a test resource defining placeholder classes
  and compiler-context interfaces. There is no shipped runtime library.
- Output is effectively fixed to `main.bc`; invoking/linking the platform
  toolchain is left to the user.

The replacement initially emits readable, deterministic C from lowered IR and
links a narrow runtime. Backend objects never live on syntax or semantic nodes.
An LLVM backend can later be added behind the same lowered-IR interface.

## Missing features to implement deliberately

The original README/TODOs and examples imply:

- complete primitive operators and comparisons;
- real strings and C-string adapters;
- full type checking and inference;
- safe class construction, inheritance, interfaces, virtual methods, and
  overrides;
- closures with captured values;
- nullable values for every applicable type;
- extension properties and cross-module extensions;
- generics with checked constraints;
- pointer operations and explicit ownership;
- memory management and weak references;
- `for`, ranges, and loop control;
- stable compiler reflection and code construction;
- deterministic modules/packages and library resolution;
- standard libraries for collections, text, I/O, filesystem, math, networking,
  threading, and coroutines;
- optional runtime patching/self-modification.

They are tracked as language milestones rather than copied as unchecked TODOs.
Runtime patching is intentionally deferred until the static ABI, reflection
model, and security boundaries are stable.
