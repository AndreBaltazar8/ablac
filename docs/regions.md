# Scoped allocation regions

`region { ... }` runs a block whose allocations are all freed at once when
the block ends: no garbage collection, no per-object work. It suits work that
builds a lot of temporary data and keeps only a small answer, such as parsing
one request, compiling one expression or analysing one file. The compiler
checks that nothing allocated in the region is still reachable when the
memory is reused.

A region's result must be a scalar (`int`, `bool`, `f64`, ...), because
anything allocated inside it is about to be freed:

```abla error
fun main {
    val text = region {
        "a" + "b"
    }
}
// error: region.result:string
```

Nor can the block store a region-allocated value anywhere that outlives it:

```abla error
class Item(val name: string)

fun main {
    var saved = Item("outer")
    val n = region {
        saved = Item("inner")
        0
    }
}
// error: region.escape:assignment.saved
```

The rest of this page gives the complete rules.

> Known issue (being fixed by coordinator): a string built with `+` inside a region can currently be
> assigned to an outer variable without an error, and is corrupted when the
> memory is reused. Don't assign strings computed inside a region to outer
> variables.

## Why a checked form

The runtime can reclaim a whole allocation generation in constant time, but
a raw numeric checkpoint is not a safe lifetime model:
`memoryReset(checkpoint)` can invalidate an array, object, string or closure
while an ordinary binding still refers to it. The raw primitive therefore
remains an internal mechanism, and source code uses the checked lexical form.

## Surface

The source form is an expression-oriented lexical region:

```abla
import "abla/io"

class Document(val words: array<string>)

fun parseDocument(source: string): Document {
    val words: array<string> = []
    var start = 0
    var index = 0
    while (index <= source.size) {
        if (index == source.size || source[index] == 32) {
            if (index > start) words.append(source.slice(start, index))
            start = index + 1
        }
        index += 1
    }
    Document(words)
}

fun countWords(document: Document): int = document.words.size

fun main {
    val count = region {
        val document = parseDocument("scoped allocation regions reclaim memory")
        countWords(document)
    }
    println("$count words")
}
// output:
// 5 words
```

Everything `parseDocument` allocates (the `Document`, its array, the word
strings) belongs to the region and is reclaimed when it ends; only the integer
leaves it.

Entering the expression creates an affine allocation domain. Heap allocations
performed transitively by calls in the body belong to that domain. Normal
lexical destruction runs first; the region is reset only after every live
affine value in the body has been dropped. Nested regions close in LIFO order.

The body may produce an allocation-independent result (`void`, `bool`, numeric
or character scalar). Strings, arrays, objects, closures, `Shared`/`Weak`
handles, native pointers, and structural values containing any of them cannot
cross the boundary. A later explicit promotion operation may deep-copy a
supported immutable value into the parent region; silently retaining it is
never promotion.

## Escape rules

A region-owned value cannot be:

- returned, broken, or continued across the region boundary;
- assigned to a local declared outside the region;
- stored in an outer/global object field or array;
- captured by a closure that can leave the region;
- passed to a parameter or native declaration whose effect permits retention;
- placed in a `Shared` control block whose lifetime can outlive the region.

Reading an outer value is allowed. Writing an allocation-independent scalar to
an outer mutable binding is allowed. Mutating an outer heap object from a
region requires a proven non-retaining operation; this is deliberately based on
an inferred effect summary rather than on the spelling of the function.

Functions and methods carry a compact inferred region effect:

- which parameters may be retained in a result, receiver, global, or closure;
- whether the function writes heap-backed global state;
- whether a mutable receiver can retain a region-owned argument;
- for trusted/native functions, an explicit non-retention contract checked at
  the trusted boundary.

The current analyzer computes native-call retention, receiver retention, and
heap-parameter mutation to a call-graph fixed point. This catches both direct
stores and wrappers that forward an outer receiver or parameter to a retaining
method. Unknown foreign code is retaining by default. `noescape extern`
asserts that no Abla-managed argument survives the call; it does not grant
permission to perform unsafe work, so `trusted` remains an independent
capability boundary. A `noescape` contract on an Abla function or method is
checked against its inferred effects. These summaries become typed-module
interface data when separate compilation lands. `FnNoEscape(A) -> R` carries
the same non-retention guarantee through a function value. Ordinary named Abla
functions and non-capturing lambdas satisfy that slot when their bodies and
transitive calls prove them non-retaining; opaque callbacks remain
conservatively retaining.

## Control flow and staging

Early `return`, `break`, and `continue` need typed cleanup edges that drop the
region's affine values and reset exactly once. Until those edges are emitted and
verified, the first implementation rejects such exits from a region body.
Panics may terminate the process; recoverable exceptions require the same
cleanup edge before they can be introduced.

Compile-time and runtime regions use the same typing and escape rules. The
compile-time evaluator may reclaim its own graph representation differently,
but it cannot accept a program the native backend rejects. A compile-time region
cannot use filesystem, network, or process capabilities unless those effects
are independently granted.

## Adoption gate

The first production consumer is the REPL's transactional work. One expression
performs parsing, semantic analysis, IR construction, output consumption,
affine cleanup, and reset inside one region. The emitted text and JIT generation
are consumed and the ORC tracker is removed before reset; only scalar status
changes cross the boundary. Input buffering remains outside the region because
it deliberately persists unread bytes between expressions.

The baseline gate covers direct and transitive calls, outer locals, globals,
fields, arrays, receiver methods, control-flow exits, result escape, false
`noescape` contracts, nested compile-time/runtime regions, destruction before
reset, native/evaluator parity, and 128 bounded REPL JIT generations. Explicit promotion,
cleanup-bearing non-local exits, exceptions, and persistence of effect summaries
in separately compiled interfaces remain later extensions.
