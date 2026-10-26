# The Abla language

This is the reference for the Abla language: what each construct means, its
rules, and the diagnostics you get when a rule is broken. Every example on
this page is a complete program that the documentation tests compile and
run, with its output.

Larger topics have their own pages:

- [ownership.md](ownership.md): who may change a value and who cleans it
  up (`var`/`own` parameters, `move`, resources, borrows, `Shared`, `Mutex`)
- [compile-time.md](compile-time.md): running code during compilation (`#`,
  `compile fun`, `compile val`, capabilities)
- [concurrency.md](concurrency.md): `defer`, generators, tasks and threads
- [regions.md](regions.md): scoped allocation with `region { ... }`
- [compiler-api.md](compiler-api.md) and [subparsers.md](subparsers.md):
  extending the compiler

Contents: [design rules](#design-rules) ·
[programs](#programs) · [lexical structure](#lexical-structure) ·
[values and variables](#values-and-variables) · [types](#types) ·
[functions](#functions) · [classes](#classes) ·
[delegated bindings](#delegated-bindings) ·
[overloads and operators](#overloads-and-operator-functions) ·
[expressions](#expressions-and-operators) ·
[control flow](#control-flow) · [ownership](#ownership-and-resources) ·
[regions](#scoped-allocation-regions) · [memory](#memory-management) ·
[compile time](#compile-time-execution) ·
[transactions](#transactions) · [modules](#modules-and-imports) ·
[annotations](#annotations) ·
[trusted and native code](#trusted-native-implementations)

## Design rules

1. Compile time and runtime use the same language and library model.
2. Compile-time effects are explicit at the call site with `#`.
3. Source is expression-oriented and semicolons are optional.
4. Diagnostics identify a source span and explain the expected construct.
5. The compiler output and module graph are deterministic.
6. Native access is capability-based and isolated in declared modules.
7. Compiler reflection uses stable handles rather than mutable implementation
   objects.

## Programs

A program is a module with a `fun main`. `main` takes no parameters. If it
returns an `int`, that is the process exit status; without a result type
(or with `: void`) the program exits with 0. Printing comes from the
standard library's `abla/io`:

```abla
import "abla/io"

fun main: int {
    println("Hello, world!")
    3
}
// output:
// Hello, world!
// exit: 3
```

- `ablac build hello.ab -o hello` builds an executable; `ablac run hello.ab`
  compiles and runs it in one step ([toolchain.md](toolchain.md)).
- A module without `main` can't be built on its own (`E_NO_MAIN`); it is
  imported by others.
- Command-line arguments come from `abla/process`
  (`processArgumentCount()`, `processArgument(i)`).
- `exit(code)` from `abla/process/exit` ends the program immediately.
  `panic(message)` prints the message and a stack trace and exits with
  status 101. The runtime panics the same way, with the reason, on a division
  by zero, an index out of bounds or, in a native executable, a stack
  overflow (`panic: stack overflow`).

```abla
import "abla/io"
import "abla/process/exit"

fun check(n: int): int {
    if (n < 0) panic("negative input: $n")
    n
}

fun main: int {
    println("${check(2)}")
    if (check(1) == 1) exit(7)
    0
}
// output:
// 2
// exit: 7
```

## Lexical structure

**Source and identifiers.** Source is UTF-8. Identifiers are ASCII letters,
digits and `_`, not starting with a digit. Unicode identifiers are reserved
for a later version.

**Comments.** `// to end of line` and `/* block */`. Block comments nest.

**Keywords.** These are reserved everywhere: `await`, `break`,
`class`, `compile`, `continue`, `defer`, `do`, `else`,
`extern`, `false`, `for`, `fun`, `generator`, `if`, `import`, `in`,
`interface`, `noescape`, `null`, `resource`, `return`, `task`, `thread`,
`true`, `trusted`, `until`, `val`, `var`, `when`, `while`, `yield`. These
are keywords only in one position and ordinary identifiers elsewhere:
`by` (after a binding's name), `own` (before a parameter name), `region`
(before `{`), `operator` (before `fun`), `type` (at the start of a
declaration), `move` (before `{`).

**Statements.** A newline ends a statement where a statement can end. `;`
separates statements explicitly and is never required. A line that starts
with a binary `+` or `-` followed by a space, or with `.`, continues the
expression on the line above:

```abla
import "abla/io"

fun main {
    val total = 1 +
        2
    val adjusted = 10
        - 4
    val prefix = "abcdef"
        .slice(0, 3)
    val x = 1; val y = 2
    println("$total $adjusted $prefix ${x + y}")
}
// output:
// 3 6 abc 3
```

A sign glued to a number at the start of a line (`-1`) begins a new
statement, so `if (found) return i` followed by `-1` on the next line returns
`-1` from the function rather than computing `i - 1`.

**Integer literals** are decimal or hexadecimal (`0x2a`), with optional `_`
between digits (`1_000_000`). **Floating literals** need a fractional part or
an exponent (`1.5`, `2e3`, `1.25e-2`) and have type `f64`. There are no
character literals: `"abc"[1]` is the byte value `98`.

**Strings** are written `"..."` and may span lines. They hold bytes, and
the source text is UTF-8. Escapes: `\n`, `\r`, `\t`, `\b`, `\0` (the zero
byte), `\"`, `\'`, `\\`, `\$`, `\xHH` (any one byte), and `\uXXXX` or `\u{H}`
to `\u{HHHHHH}` (a Unicode code point, stored as its UTF-8 bytes; surrogates
`D800`-`DFFF` and values above `10FFFF` aren't code points). Any other
backslash sequence is an error (`E_PARSE_INVALID_ESCAPE`): write `\\` for a
backslash. `$name` and `${expression}` insert values:

```abla
import "abla/io"

fun main {
    val name = "Abla"
    val count = 3
    println("$name has ${count + 1} letters")
    println("price: \$5, tab:\t|, hex: \x41, unicode: \u00e9 \u{1F600}")
    println("two
lines")
    println("con" + "cat")
}
// output:
// Abla has 4 letters
// price: $5, tab:	|, hex: A, unicode: é 😀
// two
// lines
// concat
```

`$name` takes the longest identifier after the `$` and nothing more, so
`"$a.b"` inserts `a` followed by the text `.b`; use `${a.b}` for a member.
A `$` that isn't followed by a letter, `_` or `{` is ordinary text (`"$5"`,
`"cost: $"`), and `\$` always is.

A template may insert strings, integers of any width (in decimal, a `u64`
unsigned), a `char` (as its character), a nominal scalar (as the value it
wraps), `bool`, and `f64`/`f32` (with `import "abla/float/text"`; without it
the error says so). Other types are `string.interpolation:<type>`.
A nullable value must be checked for `null` first
(`string.interpolation:nullable:...`). A template made only of literal text
and top-level `val`s holding such strings is folded into one constant at
compile time.

## Values and variables

`val` declares a binding that is assigned once; `var` one that can be
reassigned. The type comes from the initializer unless you write it:

```abla
import "abla/io"

val greeting = "hello"
var visits = 0

fun visit(): void {
    visits += 1
    return
}

fun main {
    val limit: int = 3
    var answer: int
    if (limit > 2) answer = 42 else answer = 0
    visit()
    visit()
    println("$greeting $visits $answer")
}
// output:
// hello 2 42
```

- A typed local `var` may be declared without a value (`var answer: int`).
  Every path must then assign it before it is read. An untyped declaration
  without a value (`local.uninitialized-type`) and a `val` without a value
  (`local.uninitialized-val`) are rejected.
- Assigning a `val` is `assignment.immutable` (`global.immutable` at the
  top level); assigning a `val` property is `field.immutable`.
- Top-level `val`/`var` are initialized before `main` runs, in dependency
  order: a global whose initializer reads another global, directly or
  through the functions and methods it calls, in this module or another, is
  initialized after it. Among globals ready at the same time the earliest
  declared goes first, so independent globals keep declaration order. A
  cycle (`val a = b + 1` with `val b = a + 1`, also through functions or
  across modules) is a compile error, `global.initialization-cycle:a->b->a`,
  at run time and under `#` alike, so no initializer can see a global that
  isn't initialized yet. Code in a lambda counts for the initializer it is
  written in, since it may run there.
- A local lives from its declaration to the end of its block. A local in a
  nested block may shadow an outer local, a parameter or a field; the outer
  one is visible again after the block, including to closures that captured
  it. A parameter or local always shadows a global of its name, of this
  module or any other: the standard library's `cell` parameter stays itself
  in a program with a global `val cell`.
- Two locals of one block can't share a name (`local.duplicate`), and a
  function's or lambda's body can't redeclare one of its parameters
  (`local.shadows-parameter`).

```abla
import "abla/io"

val greeting = "$salutation, $name"   // initialized after both
val salutation = "Hello"
val name = pick()
fun pick(): string = names[1]          // `name` needs `names` first
val names = ["Ada", "Grace"]

fun main {
    println(greeting)
}
// output:
// Hello, Grace
```

```abla error
val a = b + 1
val b = twice(a)
fun twice(n: int): int = n * 2
fun main: int = a
// error: global.initialization-cycle:a->b->a
```

```abla
import "abla/io"

fun scaled(width: int, flag: bool): int {
    var result = width
    if (flag) {
        val flag = 2          // shadows the parameter inside this block
        result = width * flag
    }
    if (flag) result else 0   // the parameter again
}

fun main {
    println("${scaled(21, true)}")
}
// output:
// 42
```

## Types

| Type | Values |
|---|---|
| `bool` | `true`, `false` |
| `i8`, `i16`, `i32`, `i64` | signed integers; `int` is `i64` |
| `u8`, `u16`, `u32`, `u64` | unsigned integers |
| `f32`, `f64` | IEEE floating point; literals are `f64` |
| `char` | a byte-sized character code |
| `string` | immutable UTF-8 text, indexed by byte |
| `array<T>` | a growable sequence |
| `Map<K, V>` | a hash map with `string` or `int` keys |
| `T?` | `T` or `null` |
| `(A, B) -> R` | a function; see [functions](#functions) |
| `void` | no value: the type of an empty block |
| `never` | no value ever: the type of a call that doesn't return |
| `any` | any value (used by low-level code) |
| `T*` | a native pointer, only in [trusted code](#trusted-native-implementations) |

Classes, interfaces and nominal `type`s add named types, and the standard
library adds `Task<T>`, `Thread<T>`, `Generator<T>`, `Cell<T>`, `Shared<T>`,
`Weak<T>`, `Mutex<T>` and `Borrow<T>`.

### Integers

Arithmetic and bitwise operators require both operands to have the same
integer type. Fixed-width `+`, `-` and `*` wrap around at their width;
division rounds toward zero and `%` takes the sign of the dividend. To mix
widths, convert explicitly with the type's name: `u32(value)`, `i16(value)`.
Narrowing keeps the low bits; widening sign-extends a signed source and
zero-extends an unsigned one. No conversion allocates.

```abla
import "abla/io"

fun main {
    val small = u8(250) + u8(10)
    println("$small ${i8(200)} ${u32(-1)}")
    println("${-7 / 2} ${-7 % 3} ${9223372036854775807 + 1}")
    println("${1 << 4} ${-8 >> 1} ${-8 >>> 60} ${5 & 3} ${5 | 3} ${5 ^ 3} ${~0}")
}
// output:
// 4 -56 4294967295
// -3 -1 -9223372036854775808
// 16 -4 15 1 7 6 -1
```

- Division or remainder by zero panics with `division by zero` (exit status
  101, like [`panic`](#programs)); under `#` it is the compile-time error
  `E_EVAL_DIVISION_BY_ZERO`. A divisor that is always zero (a `0` literal, or
  a constant expression or top-level `val` that comes to 0) is the error
  `division.zero`. The one quotient too large for its type, the smallest
  signed value divided by `-1`, wraps to itself, and its remainder is 0.
  Unsigned types divide unsigned. The same holds at every width and at
  compile time.

```abla
import "abla/io"

fun main {
    val smallest = -9223372036854775807 - 1
    println("${smallest / -1} ${smallest % -1} ${i8(-128) / i8(-1)}")
    val none = smallest - smallest
    println("${7 / none}")      // panic: division by zero
}
// output:
// -9223372036854775808 0 -128
// exit: 101
```

- `>>` is arithmetic for signed types and logical for unsigned ones; `>>>`
  is always logical. A shift count may have any integer type. A count that
  is negative or at least the width gives zero.
- Mixing types (`f64 + int`, `string + int`) is `arithmetic.type`. Mixing
  bit-operation types is `bitwise.type`.

- An `int` argument for a parameter of a narrower type (`u8`, `i32`, ...) of
  a function, method or constructor is `integer.narrowing`: write `u8(value)`
  to keep the low bits. An integer literal that fits, or an `if` of such
  literals, needs no conversion (`take(200)`).

### Floating point

`f64` is the default. `abla/float` converts between integers and floats
(`f64FromInt`, `f64ToInt`, `f64ToF32`, `f32ToF64`, ...) and to and from bit
patterns. `abla/math` has `sqrt`, `pow`, `sin`, `floor`, `mathPi` and the
rest. `abla/float/text` prints shortest round-trip text and is needed to
put a float in a template:

```abla
import "abla/io"
import "abla/float"
import "abla/float/text"
import "abla/math"

fun main {
    val r = 2.5
    val area = mathPi * r * r
    println(f64Text(area))
    println("${f64ToInt(floor(area))} ${f64FromInt(3) / 2.0}")
    val small: f32 = f64ToF32(0.1)
    println(f64Text(f32ToF64(small)))
}
// output:
// 19.634954084936208
// 19 1.5
// 0.10000000149011612
```

Both operands of float arithmetic must have the same width. A float to
integer conversion (`f64ToInt`, `f32ToI32`, `f32ToU32`) truncates toward zero
and saturates: a value beyond the integer type gives its smallest or largest
value, and NaN gives 0, on every target. Floats work at compile time too, with
identical results. The sign and payload bits of a NaN produced by arithmetic
are unspecified and may differ between compile time and run time.

### Strings

A `string` is immutable UTF-8. `size` is its length in bytes; `text[i]` is
the byte at `i` as an `int`; `slice(begin, end)` copies a byte range; `+`
concatenates two strings. `for (b in text)` iterates over the bytes. An
index or a range outside the string panics, like an array index
(`slice 3..10 out of bounds for string of size 5`). `<`, `<=`, `>` and `>=`
compare strings byte by byte (lexicographically, so a prefix comes first and
`"Z" < "a"`), the same at run time and at compile time:

```abla
import "abla/io"

fun main {
    println("${"apple" < "banana"} ${"app" < "apple"} ${"Zebra" < "apple"} ${"b" >= "b"}")
}
// output:
// true true true true
```

`abla/text` adds the usual helpers (`split`, `trim`, `startsWith`,
`indexOf`, `replace`, ...) and code-point access; see
[standard-library.md](standard-library.md).

### Arrays

```abla
import "abla/io"

fun main {
    val words = ["a", "b"]
    words.append("c")
    val grid = filledArray(3, 0)
    grid[1] = 5
    println("${words.size} ${grid[1]} ${grid.size}")
    words.truncate(1)
    println("${words.size} ${words[0]}")
    words.clear()
    val empty: array<int> = []
    println("${words.size} ${empty.size}")
}
// output:
// 3 5 3
// 1 a
// 0 0
```

- An array literal takes the type expected of it: a typed local or
  top-level value, a function's result or `return`, an argument of a
  top-level function or constructor, or a store into a receiver of known
  type (`xs.append(v)`, `xs[i] = v`, `m.set(k, v)`, `x = v`, `o.field = v`,
  a method's argument), declared or inferred: `val rows = makeRows()` then
  `rows.append([null])` makes `[null]` the element type `makeRows` gives
  `rows`. That type's element type flows into
  nested literals and lambdas, and `null` fits a `T?` element
  (`val rows: array<array<int?>> = [[1, null], []]`). Without such a type,
  the elements must share one, `[]` and `null` taking the others'
  (`[[1], []]` is an `array<array<int>>`, `["x", null]` an
  `array<string?>`); otherwise it is `array.element-type`.
- An empty literal needs an expected type, or names it: `array<int>()` is
  `[]` as an `array<int>`, usable wherever an expression goes
  (`val names = array<string>()`, `total(array<int>())`).
- `append(value)` adds at the end, `truncate(n)` keeps the first `n`
  elements (all of them when `n` is at least the size), `clear()` removes
  all, and `filledArray(count, value)` creates a filled array.
- Reading or writing outside the array panics (exit status 101) with the
  reason, such as `index 5 out of bounds for array of size 3`; so do a
  negative count to `truncate` (`truncate to a negative size (-1)`) and to
  `filledArray` (`filledArray with a negative size (-2)`). Under `#`
  the same text is a compile-time error (`E_EVAL_OUT_OF_BOUNDS`). The same
  holds for a string index or slice.
- Changing an array you received as a parameter needs a `var` parameter
  ([ownership.md](ownership.md#parameters-borrow-var-and-own)). An array of
  resources owns its elements.

```abla
import "abla/io"

fun makeRows() {
    val rows: array<array<string?>> = []
    rows
}

fun main {
    val rows = makeRows()         // inferred: array<array<string?>>
    rows.append([null])           // an array<string?>
    rows.append([null, "b"])
    println("${rows.size} ${rows[0][0] == null} ${rows[1].size}")
}
// output:
// 2 true 2
```

```abla
import "abla/io"

fun main {
    val xs = [1, 2, 3]
    xs.truncate(10)          // keeps all three
    println("${xs.size}")
    println("${xs[5]}")      // panics: index 5 out of bounds for array of size 3
}
// output:
// 3
// exit: 101
```

The reason goes to standard error: `panic: index 5 out of bounds for array
of size 3`.

### Maps

`Map<K, V>` is a built-in hash map with `string` or `int` keys. Its type
must be declared where it is created, or named by the constructor:
`Map<string, int>()` is `Map()` as a `Map<string, int>`:

```abla
import "abla/io"

fun main {
    val ages: Map<string, int> = Map()
    ages.set("ada", 36)
    ages.set("alan", 41)
    val age = ages.get("ada")              // int?
    if (age != null) println("ada is $age")
    println("${ages.has("alan")} ${ages.remove("alan")} ${ages.size}")
    for (name in ages.keys()) println("key $name")
}
// output:
// ada is 36
// true true 1
// key ada
```

`get` returns `V?`; `remove` returns whether the key was present; `keys()`
and `values()` return arrays in insertion order; `clear()` empties the map.
A map without a declared type is `map.untyped`, other key types are
`map.key-type`, and a constructor type that isn't `Map<K, V>` is `map.type`.

### Nullable types

`T?` holds a `T` or `null`. A nullable value can't be used as a `T` until
the compiler can see it isn't `null`. Checking a `val` or a parameter
narrows it on the path where the check holds, and after an `if` whose
branch leaves the block (`return`, `break`, `continue`, or a call of type
`never` such as `panic(…)`, alone or ending the branch's block):

```abla
import "abla/io"

class Node(val value: int, val next: Node?)

fun describe(node: Node?): string {
    if (node == null) return "missing"
    "found ${node.value}"            // `node` is a Node here
}

fun sum(start: Node?): int {
    var total = 0
    var current = start
    while (current != null) {
        val node = current           // a `val` copy can be narrowed
        if (node != null) {
            total += node.value
            current = node.next
        }
    }
    total
}

fun main {
    val list = Node(1, Node(2, Node(3, null)))
    println(describe(list.next))
    println(describe(null))
    println("${sum(list)}")
}
// output:
// found 2
// missing
// 6
```

- `x != null` and `null != x` narrow the true branch; `==` narrows the false
  branch. `!`, and the guaranteed paths of `&&` and `||`, carry the facts
  through.
- Only `val` locals and parameters are narrowed. A `var` and a field read
  through an object are not, because an assignment could invalidate the
  check: copy them into a `val`, as `sum` does.
- Using a nullable value as non-null is an error that names the type, such
  as `member:nullable:Node.value` or `arithmetic.type@..:nullable:i64:i64`.
- In a `when` whose subject is a nullable `val` or parameter, the arms after
  a `null ->` arm see the non-null type.
- `a?.b` and `a ?? b` handle a nullable value in one expression; see
  [null-safe operators](#null-safe-operators).

For example (an arm sharing the `null` arm's body, as in `"b", null -> ...`,
is not narrowed):

```abla
import "abla/io"

fun label(name: string?): string = when (name) {
    null -> "nobody"
    else -> "${name.size} letters"
}

fun main {
    println("${label(null)}, ${label("Ada")}")
}
// output:
// nobody, 3 letters
```

### Null-safe operators

`a?.b` reads `b` from `a` only when `a` isn't `null`, and is `null`
otherwise. `a ?? b` is `a`'s value when it isn't `null`, and `b` otherwise:

```abla
import "abla/io"

class Node(val value: int, val next: Node?, val name: string?)

fun Node.plus(n: int): int = this.value + n

fun second(list: Node?): int = list?.next?.value ?? 0

fun firstValue(node: Node?): int {
    val value = node?.value ?? return -1   // leave the function on null
    value * 10
}

fun main {
    val list = Node(1, Node(2, null, "two"), null)
    val none: Node? = null
    println("${second(list)} ${second(none)}")
    println("${list.next?.name?.size ?? 0} ${list.name ?? "anonymous"}")
    println("${none?.plus(5) ?? -1} ${firstValue(list)} ${firstValue(none)}")
}
// output:
// 2 0
// 3 anonymous
// -1 10 -1
```

- After `?.`, the rest of the postfix chain (member reads, calls, indexing,
  further `?.`) runs only when the receiver isn't `null`, and the whole chain
  is `null` otherwise: `a?.b.c` is `a.b.c` or `null`, and a skipped call
  evaluates none of its arguments. Parentheses end the chain: `(a?.b).c`
  reads `c` from a nullable value, which is `member:nullable:...`.
- The type of `a?.chain` is the chain's type made nullable; a chain ending in
  a `void` call is a `void` statement (`node?.close()`).
- `a ?? b` evaluates `b` only when `a` is `null`. Its type is `a`'s non-null
  type when `b` has that type, and nullable when `b` is nullable or `null`.
  `b` must have `a`'s type (`null-default.type:<T>:<U>`); an integer literal
  is an `int`, so write `i32(0)` for an `i32` default.
- `??` groups to the right (`a ?? b ?? c` is `a ?? (b ?? c)`). It binds more
  loosely than arithmetic and ranges and more tightly than comparisons:
  `a ?? 1 + 2` is `a ?? (1 + 2)`, and `a ?? 0 < n` is `(a ?? 0) < n`.
- The right side of `??` may be `return`, `break` or `continue`, which leave
  as an `if` branch does: `val x = y ?? return`.
- Each side is evaluated at most once, left to right. The left side must be
  able to be `null`: `?.` on a value that can't be is `safe-call.non-null:<T>`
  (use `.`), and `??` after one is `null-default.non-null:<T>`.
- A line may start with `?.` or `??`, continuing the expression above.
- `a?.b` is not a place: `a?.b = x` is `E_PARSE_ASSIGNMENT_TARGET`. Check
  `a != null` on a `val`, then assign through `.`.
- Ownership: `a ?? b` hands `a`'s value on, so a resource on the left must be
  given away, as `move(t) ?? Ticket(0)` (`ownership.move-required` otherwise).
  `a?.b` reads through a parameter or a `val` in place; any other receiver (a
  call's result, a `var`, a field) is read once into a hidden `val`, so a
  fresh resource is dropped after the chain, and a resource in a `var` or a
  field can't be the receiver.
- Both behave the same at compile time.

```abla error
fun main {
    val count = 3
    val shown = count ?? 0
}
// error: null-default.non-null:i64
```

### Nominal types

`type Name = underlying` declares a distinct name for a primitive type. It
costs nothing at run time, but the compiler keeps the two apart:

```abla
import "abla/io"

type UserId = int

fun UserId.next(): UserId = UserId(this + 1)
fun idNumber(id: UserId): int = id

fun main {
    val id = UserId(41)
    val raw: int = id
    println("user ${idNumber(id.next())} $id")
    println("${raw + 1}")
}
// output:
// user 42 41
// 42
```

- `UserId(41)` converts an `int` to a `UserId`. An `int` is not accepted
  where a `UserId` is required (`function.argument:...:UserId:i64`).
- The other direction is implicit: a `UserId` is accepted where an `int` is,
  as an argument, a typed local, a result, an operand or in a string
  template. Arithmetic produces the underlying type, so wrapping the result is
  explicit.
- Inside an extension of a nominal type, `this` is the underlying value.
- `type` is a keyword only at the start of a declaration.

### Function types

`(A, B) -> R` is a function taking `A` and `B` and returning `R`;
`T.(A) -> R` is one with a receiver. Parameter modes are part of the type:
`(var: Counter) -> int` and `(own: Ticket) -> int` differ from
`(Counter) -> int`. `Fn`, `FnMut`, `FnOnce` and `FnNoEscape` describe what a
closure does with its captures
([ownership.md](ownership.md#closures-and-ownership)). Generic arguments are
written `Type<A, B>`.

Besides the built-in types (`array`, `Map`, `Task`, `Shared`, the `Fn`
family and the others listed above), a program's own generic classes take
type arguments: `Box<int>` ([generics](#generics)).

### `void` and `never`

An empty block, and a `while` loop, have type `void`. A function whose
result type is `void` returns nothing. Its body may still end in an
assignment: an assignment's value is the assigned value, but in a `void`
function (or method, extension or lambda) a trailing assignment just ends the
body:

```abla
import "abla/io"

var count = 0

fun bump(): void {
    count = count + 1
}

fun main {
    bump()
    bump()
    println("$count")
}
// output:
// 2
```

Any other trailing expression with a value (`fun f(): void { 1 + 2 }`) is
`function.result:f:void:i64`; end such a body with `return`.

`never` is the type of an expression that can't complete, such as a call to
`exit` or `panic`, or a `while (true)` loop with no `break`. It fits
wherever a value is expected, so a diverging branch doesn't change the type
of an `if` or `when`. A function declared `never` must not be able to return
or fall through (`function.result:<name>:never:...`).

## Functions

```abla
import "abla/io"

fun area(width: int = 80, height: int = width / 2): int = width * height

fun describe(name: string, count: int): string {
    val plural = if (count == 1) "" else "s"
    "$count $name$plural"
}

fun greet {
    println("hello")
}

fun main {
    greet()
    println(describe("file", 2))
    println("${area()} ${area(height = 30)} ${area(height = 30, width = 100)}")
}
// output:
// hello
// 2 files
// 3200 2400 3000
```

- The body is a block, whose last expression is the result, or `= expression`.
  `return value` leaves early.
- A function with no parameters may omit `()`: `fun greet { ... }`,
  `fun main: int = 0`.
- The result type may be omitted: `fun inc(a: int) = a + 1` infers `int`
  from the body (joined with what its `return`s give), and callers use it as
  they would a declared one (below).
- Parameters may have defaults, which may refer to earlier parameters.
  Arguments may be passed by name after the positional ones, to functions,
  constructors, methods and extension functions. Each argument (and a method
  call's receiver, first) is evaluated once, in source order. A method's
  default reads the receiver's fields (an extension's through `this`), never
  a caller's variable of the same name. A named method call is resolved before types are known: every class
  method and extension of that name with those parameter names must take the
  same parameters (and fill an omitted one the same way), otherwise it is
  `E_NAMED_ARGUMENT_TARGET` and the arguments go by position. Unknown, duplicate, out-of-order or
  missing required names are errors (`E_NAMED_ARGUMENT_UNKNOWN`,
  `_DUPLICATE`, `_ORDER`, `_REQUIRED`).
- Parameters borrow their arguments; `var` and `own` change that
  ([ownership.md](ownership.md#parameters-borrow-var-and-own)).
- Recursion is limited by the thread's stack. Running out of stack panics
  with `panic: stack overflow` on standard error and exit status 101:

```abla
import "abla/io"

fun depth(n: int): int {
    val local = [n, n + 1]
    if (n == 0) return local[0]
    local[1] + depth(n - 1) + local[0]
}

fun main: int {
    println("deep")
    depth(100000000) % 256   // panics: stack overflow
}
// output:
// deep
// exit: 101
```

An inferred result works the same for functions, methods, extensions and
compile funs, at runtime and under `#`:

```abla
import "abla/io"

fun sign(n: int) = if (n < 0) -1 else 1
class Counter(var count: int) {
    fun next() = count + 1
}
fun Counter.label() = "counter ${this.next()}"

fun main: int {
    val s = sign(-5)
    println("$s ${Counter(1).label()} ${#sign(3)}")
    s + 43
}
// output:
// -1 counter 2 1
// exit: 42
```

An inferred function can't call itself, directly or through other inferred
functions, because its type would depend on itself; declaring the result type
of one function in the cycle is enough:

```abla error
fun factorial(n: int) = if (n <= 1) 1 else n * factorial(n - 1)
fun main: int = factorial(5)
// error: function.result-cycle:factorial
// error: give it a result type
```

### Extension functions

`fun Type.name(...)` adds a function that is called like a method. The
receiver may be any type: a class, a scalar, `array<int>`, `Map<string, int>`
or a nullable `string?`. Inside it, `this` is the receiver, and the
receiver's fields and methods are in scope by name, as in a method:

```abla
import "abla/io"

class Point(val x: int, val y: int)

fun Point.length2(): int = x * x + y * y
fun int.isEven(): bool = this % 2 == 0
fun array<int>.total(): int {
    var sum = 0
    for (value in this) sum = sum + value
    sum
}

fun main {
    val values = [1, 2, 3]
    println("${Point(3, 4).length2()} ${10.isEven()} ${values.total()}")
}
// output:
// 25 true 6
```

### Extension fields

`var Type.name: T = default` adds a field to a class from outside it, as an
extension function adds a method. It is read and written like a declared
field, `p.label` and `p.label = "x"`, and inside the class's methods and
extension functions by name alone:

```abla
import "abla/io"

class Point(val x: int)

var Point.label: string = "none"
var Point.hits: int = this.x * 10
val Point.created: int = 0

fun Point.describe(): string = "$label:$hits"

fun main {
    val p = Point(3)
    println(p.describe())
    p.label = "named"
    p.hits = p.hits + 1
    p.created = 7
    println("${p.describe()} ${p.created}")
}
// output:
// none:30
// named:31 7
```

- **Type and default:** the type is written, and the default is required
  (`= null` for an optional type). An object that never had the field set
  reads the default, which may use `this` (the object) and its fields.
  Nothing happens at construction: a default runs at each read of an unset
  field and is not kept, so defaults should be pure.
- **Through a mutation:** a field used as the place a mutation goes through
  keeps its default from then on, so the mutation stays. Examples are
  `n.items.append(x)`, `n.items[0] = x`, `n.box.value = 3` and a map's
  `set`. A plain read never stores anything.
- **`val`:** an extension `val` takes one assignment per object. A second
  one stops the program (`field.extension-reassigned:Point.created`), and
  under `#` it is `E_EVAL_EXTENSION_REASSIGNED`.
- **Owner:** the owner is a class, from any module or package. Scalars,
  strings, arrays, nominal types and interfaces have no object to hold one
  (`field.extension-owner`).
- **Names:** a member of the class with the same name is an error
  (`field.extension-shadows`). So are two extension fields of one class with
  the same name, in any modules (`symbol.duplicate`, as for extension
  functions).
- **Ownership:** an extension field never changes what its class is to code
  that doesn't see it. A field of an affine type (a resource, `Shared`,
  `Weak`, `Mutex`) is allowed only on a class that is affine already
  (`field.extension-resource`). Such fields are dropped with the object,
  after its declared fields, from the last set to the first.
- **Access cost:** an extension field is reached by name, a little more
  slowly than a declared field, which stays at its fixed slot.

`#` code reads and writes extension fields the same way, and the compiler
API lists, adds and removes them ([compiler-api.md](compiler-api.md#extension-fields)).

### Lambdas and closures

A lambda is written in braces. Parameters, if any, come before `->`; their
types may be omitted where the expected function type supplies them. A call
whose last argument is a lambda may put it after the parentheses (a
*trailing lambda*), and omit empty parentheses:

```abla
import "abla/io"

fun apply(value: int, transform: (int) -> int): int = transform(value)
fun double(n: int): int = n * 2
fun compose(f: (int) -> int, g: (int) -> int): (int) -> int = { x: int -> g(f(x)) }

fun main {
    println("${apply(5, double)}")
    println("${apply(5) { n -> n + 1 }}")
    val add = { a: int, b: int -> a + b }
    val incremented = compose(double, { n -> n + 1 })
    val constant = { -> 42 }
    println("${add(2, 3)} ${incremented(10)} ${constant()}")
    var calls = 0
    val count = { calls += 1 }
    count()
    count()
    println("$calls")
}
// output:
// 10
// 6
// 5 21 42
// 2
```

- A lambda captures variables, not copies: `count` above changes the outer
  `calls`. Captures outlive the call that created them, and `this` is
  captured the same way.
- A function name is a function value (`apply(5, double)`).
- Any expression of function type can be called: `adder(2)(3)`,
  `handlers[0]()`, `(pick())(x)`. `button.onClick(event)` calls a method
  named `onClick` if there is one, and otherwise a property of function
  type with that name.
- Parameter types also come from where the lambda is stored: a built-in
  method's element type (`callbacks.append({ x -> x + 1 })` on an
  `array<(int) -> int>`, `Map.set`), an index assignment, an array literal
  of a declared type, a field or a variable of function type.
- A call by name looks for an *applicable* candidate level by level: a
  local or parameter, then a member of the receiver, then a top-level
  function ([classes](#classes) has the details). So a callback parameter
  named like a global function calls the callback.
- `return` inside a lambda returns from the lambda.
- Lambdas that change a capture are `FnMut`, and `move { ... }` lambdas are
  `FnOnce`. Both are affine
  ([ownership.md](ownership.md#closures-and-ownership)).
- Braces whose first member is a declaration (`{ fun f() ... }`) are a
  compile-time declaration block, not a lambda
  ([compile-time.md](compile-time.md#declaration-blocks)).

## Classes

A class declares its properties in its primary constructor: `val` for
read-only, `var` for mutable. Its body holds methods. Inside a method,
the receiver's properties and methods are in scope by name, and `this` is
the receiver itself:

```abla
import "abla/io"

class Point(val x: int, val y: int = 0) {
    fun plus(other: Point): Point = Point(x + other.x, y + other.y)
    fun describe(): string = "($x, $y)"
}

class Account(val owner: string, var balance: int) {
    fun deposit(amount: int): void {
        balance += amount
        return
    }
}

fun main {
    println(Point(3, 4).plus(Point(x = 1)).describe())
    val account = Account("ada", 10)
    account.deposit(5)
    println("${account.owner}: ${account.balance}")
}
// output:
// (4, 4)
// ada: 15
```

- Construction is a call: `Point(3, 4)`, with defaults and named arguments
  like any function (`constructor.arity`, `constructor.argument`).
- A name in a method resolves level by level: a local or parameter, then a
  member of the receiver, then a top-level declaration. A plain read
  (`scale`) takes the first level that has the name. A call (`scale(v)`)
  takes the first level with an *applicable* candidate: a method, or a
  property of function type, that takes the arguments: that many of them (a
  method's defaults may be left out, and named arguments must name its
  parameters), each of a type the parameter accepts where the code shows it
  (a literal, a declared local, parameter or field, a constructor call, a
  function's declared result; other arguments are checked against the
  candidate found). A property that isn't a function never captures a call,
  and a method that can't take the arguments lets the search continue:
  `label(7)` beside a method `label(text: string)` calls a top-level
  `label(n: int)`. With no applicable candidate
  anywhere, the error names the innermost one. A scalar conversion's name
  (`u32(x)`, `int(x)`, `f64(x)`, ...) always means the conversion: a member
  named `u32` never captures it and is called as `this.u32(...)`.
- A class body contains only methods (`fun`, `operator fun`, `trusted fun`,
  `noescape fun`). Properties belong in the constructor
  (`E_PARSE_CLASS_MEMBER`).
- Objects are references: assigning one shares it. Changing an object through
  a parameter needs a `var` parameter, and the compiler checks aliases
  ([ownership.md](ownership.md#changing-objects-through-references)).
- A method that changes `this` is detected automatically, and the receiver
  is then treated like a `var` argument.
- A name means the innermost thing it names: a parameter or local (lambda
  parameters and loop variables included), then a property or method of the
  receiver (in a method or an extension function), then a top-level
  declaration. A method calls the receiver's other methods by plain name,
  and a parameter named like a top-level function calls the parameter.
- `resource class` declares a type whose objects have one owner and an
  optional `drop()`
  ([ownership.md](ownership.md#resources-values-with-one-owner)).

```abla
import "abla/io"

fun scale(x: int): int = x * 10
fun bump(x: int): int = x + 1

class Camera(val scale: int) {
    fun bump(): int = 7
    fun calc(v: int): int = scale(v) + scale + bump(v) + bump()
}

fun main {
    println("${Camera(2).calc(4)}")   // 40 + 2 + 5 + 7
}
// output:
// 54
```

### Interfaces

An interface names a set of methods. A class conforms to it, and its values
then stand wherever the interface is expected. A call through an interface
value runs the method of the value's class.

```abla
import "abla/io"

interface Shape {
    fun area(): int
    fun describe(): string = "shape of ${this.area()}"
}

class Square(val side: int) : Shape {
    fun area(): int = this.side * this.side
}

class Circle(val radius: int) : Shape {
    fun area(): int = 3 * this.radius * this.radius
    fun describe(): string = "circle"
}

fun total(shapes: array<Shape>): int {
    var sum = 0
    for (shape in shapes) sum = sum + shape.area()
    sum
}

fun main {
    val shapes: array<Shape> = [Square(2), Circle(1)]
    println("${total(shapes)} ${shapes[0].describe()} ${shapes[1].describe()} ${Square(3).describe()}")
}
// output:
// 7 shape of 4 circle shape of 9
```

- **Members.** An interface member is a method signature. A member without a
  body names its result type (`interface.member-untyped`). A member with a
  body is a *default*: it runs for a class that has no method of that name,
  with `this` the instance. The class's values have that member too
  (`Square(3).describe()`), a direct call of the default body, without the
  class comparison a call through an interface value makes. An interface has
  no fields. A field-like need is a method, which an
  [extension field](#extension-fields) can back.
- **Conformance.** A class names its interfaces after its fields
  (`class Square(…) : Shape, Named`). `extend Square : Printable` at top level
  does the same for a class declared elsewhere, in any module. A class
  conforms only to the interfaces it names or that `extend` adds: matching
  methods alone don't make it conform.
- **Witnesses.** Each member is answered by the class's method of the same
  name, parameter types and modes, and result type. Failing that, an
  extension function `fun Square.member(…)` answers it, and then the
  interface's default. A member nothing answers is
  `interface.missing-member:Shape.area:Square`. A method of that name with
  another signature is `interface.member-signature`. A name that isn't an
  interface is `interface.unknown`.
- **Upcasts** are implicit: a `Square` passes, stores and returns where a
  `Shape` is expected, and a `Square?` where a `Shape?` is. The branches of an
  `if` or `when`, and the elements of an array literal, that are classes
  sharing exactly one interface have that interface's type.
- **`as?`** takes an interface value back to a class:
  `shape as? Square` is the `Square` when the value is one, and `null`
  otherwise (a nullable interface value too). A class that doesn't conform to
  the interface can never be the result, so naming one is an error
  (`interface.cast`).
- **Inheritance.** `interface Solid : Shape, Named { … }` extends other
  interfaces. A `Solid` stands wherever a `Shape` is expected, a class that
  conforms to `Solid` conforms to `Shape` too and answers its members, and a
  call on a `Solid` reaches the members it inherits. An interface may declare
  a parent's member again, with the same signature
  (`interface.member-conflict` otherwise), to give it a default of its own.
  When a class has no method for a member, the default of the most specific
  of its interfaces answers. Two unrelated defaults are
  `interface.default-ambiguous`: the class then writes its own. An interface
  can't extend itself (`interface.inheritance-cycle`).
- **Ownership.** A plain interface's values copy freely, so a resource class
  can't conform to one (`interface.resource-into-plain`). A
  `resource interface` is the opposite: every class conforming to it is a
  resource class (`interface.plain-into-resource`), and its values are
  resources, with one owner, moved with `move(x)` and dropped through the
  class they are an instance of. A resource interface extends only resource
  interfaces, and a plain one only plain ones. `drop` is each class's own, never an
  interface member. `as?` on a resource interface's value isn't supported
  (`interface.cast-resource`): a `when` arm `is A` tests it instead. Parameter modes (`var`, `own`, a borrow)
  apply to interface parameters as to class ones.

```abla
import "abla/io"

interface Printable {
    fun print(): string
}

class Point(val x: int, val y: int)

fun Point.print(): string = "($x, $y)"

extend Point : Printable

fun show(item: Printable): string {
    val point = item as? Point
    if (point != null) "point ${point.print()}" else item.print()
}

fun main {
    println(show(Point(1, 2)))
}
// output:
// point (1, 2)
```

An interface value is the instance itself, so taking one costs nothing and
an object's layout never depends on its interfaces. A call through one
compares the instance's class with each class that conforms and calls that
class's witness. An instance of any other class goes to the runtime's one
fallback, which stops the program with `interface.no-witness:Shape:<class>` (the class's symbol).
That can't happen in a program today: an interface value only ever comes from a
class that conforms. The fallback is where a conformance added at run time
would be found.

```abla
import "abla/io"

resource interface Handle {
    fun id(): int
}

resource class File(val number: int) : Handle {
    fun id(): int = this.number
    fun drop(): void {
        println("close ${this.number}")
    }
}

fun finish(own handle: Handle): int = handle.id()

fun main {
    val handle: Handle = File(3)
    println("finished ${finish(move(handle))}")
}
// output:
// close 3
// finished 3
```

Compile-time code (`#`) calls through interfaces with the same results, an
interface value made at compile time lifts into the program as its instance,
and the [compiler API](compiler-api.md#interfaces) reads and declares
interfaces and conformances.

#### Sealed interfaces and `is`

A `sealed interface` is a sum type. Every class conforming to it, and every
interface extending it, is declared in its own module
(`interface.sealed-foreign` otherwise), so its classes are all known. A
`when` over an interface value tests the class with `is`, and in an arm with
one `is`, a subject that is a local or parameter (not a `var`) has the type
tested. A `when` over a sealed interface with an `is` arm for each of its
classes (an interface arm covers the classes conforming to it, and a
nullable subject also needs `null ->`) needs no `else`. Over any other
interface, more classes may come from other modules, so it needs one.

```abla
import "abla/io"

sealed interface Expr

class Num(val value: int) : Expr
class Add(val left: Expr, val right: Expr) : Expr
class Neg(val operand: Expr) : Expr

fun evaluate(expr: Expr): int = when (expr) {
    is Num -> expr.value
    is Add -> evaluate(expr.left) + evaluate(expr.right)
    is Neg -> -evaluate(expr.operand)
}

fun main {
    println("${evaluate(Add(Num(2), Neg(Num(5))))}")
}
// output:
// -3
```

`is` arms on a resource interface's value see it as its class without
moving it. An `is` naming a type that isn't a class conforming to the
subject's interface (or an interface extending it) is `when.is-type`.

An interface may take type parameters too (`interface Source<T>`); see
[generic interfaces](#generic-interfaces).

## Delegated bindings

A delegated binding looks like an ordinary `val` or `var`, but every read and
every write of it goes through an object you choose: the *delegate*. Use one
when a value needs a policy attached to it (clamping, validation, logging,
counting, a value kept somewhere else) without making every use site call
that policy by hand.

```abla
import "abla/io"

class Clamped(var current: int, val minimum: int, val maximum: int) {
    fun getValue(): int = current
    fun setValue(next: int): void {
        current = if (next < minimum) minimum else if (next > maximum) maximum else next
        return
    }
}

fun main {
    var volume: int by Clamped(40, 0, 100)
    println("start: $volume")
    volume = 140                // calls setValue(140); the delegate keeps 100
    println("after 140: $volume")
    volume -= 150               // getValue, then setValue(-50); it keeps 0
    println("after -= 150: $volume")
}
// output:
// start: 40
// after 140: 100
// after -= 150: 0
```

`var volume: int by Clamped(40, 0, 100)` evaluates `Clamped(40, 0, 100)` once
and stores that object. From then on, `volume` in an expression means
`getValue()` on the stored object and `volume = x` means `setValue(x)`.

### The delegate contract

- The delegate is an instance of a class with a zero-argument `getValue()`
  method. Its result type is the *exposed* type: what `volume` reads as.
- A delegated `var` also needs `setValue(next: T): void`, where `T` is the
  exposed type. A delegated `val` needs no setter and cannot be assigned
  (`assignment.immutable`).
- The type annotation is optional: `var volume by Clamped(40, 0, 100)` takes
  its type from `getValue()`. When it is written, `getValue()` must return
  exactly that type.
- `by` works on local and top-level `val`/`var`, on `compile val` /
  `compile var`, and on class properties
  ([below](#delegated-class-properties)). It does not work on a function's
  parameters (`E_PARSE_DELEGATED_PARAMETER`).

### When the accessors run

- Every read calls `getValue()` once. That includes reads inside string
  templates and the read half of a compound assignment.
- Every assignment evaluates its right-hand side once and calls `setValue()`
  once. `volume -= 150` is one `getValue()` and one `setValue()`.
- The value of an assignment expression is the value that was *assigned*, not
  what the delegate kept. `val attempted = (volume = 140)` sets `attempted` to
  `140` even though `volume` reads back `100`. No extra `getValue()` call is
  made to find out.

```abla
import "abla/io"

class Counted(var current: int, var reads: int, var writes: int) {
    fun getValue(): int {
        reads += 1
        current
    }
    fun setValue(next: int): void {
        writes += 1
        current = next
        return
    }
}

fun main {
    var score by Counted(0, 0, 0)
    score = 10                 // 1 write
    score += 5                 // 1 read, 1 write
    val copy = score           // 1 read
    println("score $score")    // 1 read
    val attempted = (score = 7)
    println("assigned $attempted; reads ${(^score).reads}, writes ${(^score).writes}")
}
// output:
// score 15
// assigned 7; reads 3, writes 3
```

### Reaching the delegate: `^name`

Prefix `^` names the stored delegate object instead of the exposed value. Its
static type is the delegate's class, so you can read its fields, call its
methods, and pass it to functions under the usual parameter and ownership
rules. On a delegated `var`, `^name = replacement` swaps in a new delegate:

```abla
import "abla/io"

class Clamped(var current: int, val minimum: int, val maximum: int) {
    fun getValue(): int = current
    fun setValue(next: int): void {
        current = if (next < minimum) minimum else if (next > maximum) maximum else next
        return
    }
}

fun widen(var policy: Clamped): void {
    policy.current = policy.maximum   // a `var` parameter may mutate the delegate
    return
}

fun main {
    var volume: int by Clamped(40, 0, 100)
    println("limit ${(^volume).maximum}")
    widen(^volume)
    println("widened to $volume")
    ^volume = Clamped(5, 0, 10)      // replace the delegate itself
    volume += 100
    println("new policy: $volume")
}
// output:
// limit 100
// widened to 100
// new policy: 10
```

`^` binds to the name after it: `^volume.maximum` reads the delegate's field,
the same as `(^volume).maximum`, and a call or an index after it applies to
the delegate too (a binding has no members of its own).

```abla
import "abla/io"

class Clamped(var current: int, val minimum: int, val maximum: int) {
    fun getValue(): int = current
}

fun main {
    val volume by Clamped(40, 0, 100)
    println("${^volume.maximum} ${(^volume).maximum} $volume")
}
// output:
// 100 100 40
```

The rules for `^`:

- Only a delegated `var` can have its delegate replaced; on a `val` that is
  `E_DELEGATE_REPLACE_VAL`.
- The replacement must have the same class as the current delegate
  (`E_DELEGATE_TYPE_MISMATCH`).
- The replacement expression is evaluated first. Then the old delegate is
  dropped, if it is a resource.
- `move(^name)` is rejected (`E_DELEGATE_MOVE_PROJECTION`): it would leave the
  binding with no delegate to call.
- `val alias = ^name` borrows the delegate. Replacing it while `alias` is
  still used later is `E_DELEGATE_BORROW_CONFLICT`.
- `^` on an ordinary binding is `E_NOT_DELEGATED` ("`n` has ordinary
  storage"). Between two integer expressions, `^` is XOR.

### Closures, ownership and lifetime

A closure captures the binding itself, not a snapshot of its value. Each call
of the closure goes through the delegate that is current at that moment,
including one installed by `^name = ...` after the closure was created.

```abla
import "abla/io"

class Box(var current: int) {
    fun getValue(): int = current
    fun setValue(next: int): void {
        current = next
        return
    }
}

fun main {
    var value by Box(1)
    val read = { value }
    value = 7
    println("after assignment: ${read()}")
    ^value = Box(11)
    println("after replacement: ${read()}")
}
// output:
// after assignment: 7
// after replacement: 11
```

The delegate may be a `resource class`. It is dropped exactly once: when the
binding goes out of scope, or when `^name = replacement` replaces it. A
getter may not hand out an owned affine value (`E_DELEGATE_AFFINE_VALUE`), but
it may return a view tied to the delegate, as in
`fun getValue(): borrow(this) Ticket`.

A top-level delegated binding is initialized in the normal top-level
initializer order, and its delegate expression runs once.

### Delegated class properties

A constructor's `val` or `var` property may be delegated too:
`var volume: int by Clamped(40, 0, 100)`. The object's field holds the
delegate, and `mixer.volume` reads and writes through it, under the same
contract as a delegated local.

```abla
import "abla/io"

class Clamped(var current: int, val minimum: int, val maximum: int) {
    fun getValue(): int = current
    fun setValue(next: int): void {
        current = if (next < minimum) minimum else if (next > maximum) maximum else next
        return
    }
}

class Mixer(val name: string, var volume: int by Clamped(40, 0, 100), val gain: int) {
    fun louder(): void {
        volume += 30               // in a method, the bare name works the same way
        return
    }
    fun limit(): int = ^volume.maximum
}

fun main {
    val mixer = Mixer("main", 3)   // `volume` takes no argument
    mixer.volume = 140             // setValue(140): the delegate keeps 100
    println("${mixer.name}: ${mixer.volume}, limit ${mixer.limit()}")
    mixer.^volume = Clamped(5, 0, 10)
    mixer.louder()
    println("new policy: ${mixer.volume}, limit ${mixer.^volume.maximum}")
}
// output:
// main: 100, limit 100
// new policy: 10, limit 10
```

- **Construction.** A delegated property takes no constructor argument:
  positional arguments skip it (`Mixer("main", 3)` sets `name` and `gain`),
  and naming it is `E_NAMED_ARGUMENT_DELEGATED`. Its `by` expression runs at
  each construction, in parameter order, like a default, so it may read the
  parameters before it: `class Account(val start: int, var balance: int by
  Counted(start))`. It may not read itself, a later parameter, an earlier
  delegated property or `this` (`E_DELEGATE_INITIALIZER_SCOPE`).
- **Access.** `obj.name` calls `getValue()`, `obj.name = v` calls
  `setValue(v)` and is worth `v`, and `obj.name += v` is one of each, as for
  a delegated local. Inside the class's methods (and through `this` in its
  extension functions) the bare name means the same.
- **The delegate.** `obj.^name` is the delegate object, and
  `obj.^name = replacement` replaces it on a `var` property, with the
  replacement's class checked and the old delegate dropped if it is a
  resource. Inside the class's methods `^name` is the same as `this.^name`.
  The rules and diagnostics of [`^name`](#reaching-the-delegate-name) apply,
  and `^` after `.` on a property that isn't delegated is `E_NOT_DELEGATED`.
- **Types.** The type annotation is optional, as on a local:
  `var hits by Counted(0)` takes the getter's type. The delegate's getter and
  setter are checked with the class, whether or not the property is used.
- **Ownership.** The field's type is the delegate's class, under the usual
  rules: a `resource class` delegate makes its class affine (declare the class
  `resource class`), and it is dropped with the object or when replaced.
- **Under `#`.** Everything above behaves the same in compile-time code.
- **Reflection.** `compiler.fieldsOf(type)` lists a delegated property with
  the class's other properties; `compiler.fieldIsDelegated(type, name)` tells
  it apart and `compiler.fieldDelegateType(type, name)` is its delegate's type
  ([compiler-api.md](compiler-api.md#class-and-type-reflection)).
- An [extension field](#extension-fields) can't be delegated
  (`field.extension-delegate`).

### At compile time

Delegated bindings behave the same under `#`, inside `compile fun`, and as
`compile val` / `compile var`. The getter's and setter's effects count as the
binding's effects, so a getter that reads the environment needs the
`environment` capability like any other caller (`compile.effect-denied`). The
compiler's binding reflection (`compiler.findBinding`,
`compiler.bindingIsDelegated`, `compiler.bindingDelegateType`, ...; see
[compiler-api.md](compiler-api.md#binding-reflection)) reports a binding's
delegation, exposed and delegate types, mutability, accessor handles,
whether replacement is allowed, and the `by` span. Reflection describes the
declaration only. The live delegate object is reachable only through
`^name` in source.

```abla
import "abla/io"

class Box(var current: int) {
    fun getValue(): int = current
    fun setValue(next: int): void {
        current = next
        return
    }
}

compile fun staged(): int {
    var value by Box(5)
    value += 1
    value * 7
}

fun main {
    println("${#staged()}")
}
// output:
// 42
```

### Diagnostics

| Code | Cause |
|---|---|
| `E_DELEGATE_GETTER_MISSING` | The delegate has no zero-argument `getValue()`, or it doesn't return the declared type |
| `E_DELEGATE_SETTER_MISSING` | A delegated `var` whose delegate has no `setValue(T): void` |
| `E_NOT_DELEGATED` | `^` applied to something that isn't a delegated binding |
| `E_DELEGATE_REPLACE_VAL` | `^name = ...` on a delegated `val` |
| `E_DELEGATE_TYPE_MISMATCH` | `^name = ...` with a delegate of a different class |
| `E_DELEGATE_MOVE_PROJECTION` | `move(^name)` |
| `E_DELEGATE_AFFINE_VALUE` | `getValue()` returns an owned affine value |
| `E_DELEGATE_BORROW_CONFLICT` | The delegate is replaced while a borrow of it from `^name` is still used |
| `E_NAMED_ARGUMENT_DELEGATED` | A constructor argument names a delegated property |
| `E_DELEGATE_INITIALIZER_SCOPE` | A delegated property's `by` reads itself, a later parameter, an earlier delegated property or `this` |
| `E_PARSE_DELEGATED_PARAMETER` | `by` on a function's parameter |

## Overloads and operator functions

Functions, extension functions and methods may share a name when their
parameter types differ. `operator fun` gives an arithmetic operator a
meaning for a type:

```abla
import "abla/io"
import "abla/float/text"

class Vec(val x: f64, val y: f64)

operator fun Vec.plus(other: Vec): Vec = Vec(this.x + other.x, this.y + other.y)
operator fun Vec.minus(other: Vec): Vec = Vec(this.x - other.x, this.y - other.y)
operator fun Vec.times(k: f64): Vec = Vec(this.x * k, this.y * k)
operator fun f64.times(v: Vec): Vec = Vec(this * v.x, this * v.y)
operator fun Vec.unaryMinus(): Vec = Vec(-this.x, -this.y)

fun describe(v: Vec): string = "(${f64Text(v.x)}, ${f64Text(v.y)})"
fun describe(n: int): string = "#$n"
fun describe(text: string): string = "\"$text\""

fun main {
    val a = Vec(1.0, 2.0)
    val b = Vec(0.5, 0.5)
    println(describe(a + b * 2.0 - -a))   // a.plus(b.times(2.0)).minus(a.unaryMinus())
    println(describe(0.5 * a))            // the receiver may be a scalar
    println("${describe(7)} ${describe("seven")}")
    var total = Vec(0.0, 0.0)
    total += a                            // compound assignment uses `plus` too
    println(describe(total))
}
// output:
// (3, 5)
// (0.5, 1)
// #7 "seven"
// (1, 2)
```

- Each call resolves at compile time to the one candidate whose parameters
  accept the arguments, preferring the most exact type matches. Two equally
  good candidates are `call.overload-ambiguous`, and no candidate is
  `call.overload-no-match`. Two declarations with the same parameter types
  are `symbol.duplicate`.
- The operator names are `plus` (`+`), `minus` (`-`), `times` (`*`), `div`
  (`/`), `rem` (`%`) and `unaryMinus` (prefix `-`). An operator applies when
  its receiver is the left operand's type and it accepts the right operand.
  Otherwise the expression is ordinary arithmetic, unchanged.
- A parameter default may call an overload or use an operator function
  (`class Rec(var season: int = Config.season())`). A call that leaves the
  parameter out, a constructor's or a named call's included, uses the
  candidate the default's arguments select.
- Overloads are resolved before code generation, so they cost nothing at run
  time. Named arguments and function references don't choose between
  overloads.

## Generics

A function, an extension function, a class or a class's method may take
type parameters, written `<T>` (several: `<K, V>`) before a function's name
or after a class's:

```abla
import "abla/io"

class Box<T>(val value: T) {
    fun get(): T = this.value
}

class Pair<A, B>(val first: A, val second: B)

fun <T> first(items: array<T>): T = items[0]

fun <T, R> array<T>.mapped(f: (T) -> R): array<R> {
    val out: array<R> = []
    for (item in this) out.append(f(item))
    out
}

fun <K, V> Map<K, V>.valueOr(key: K, fallback: V): V {
    val found = this.get(key)
    if (found != null) found else fallback
}

fun main {
    println("${first([3, 4])} ${first(["a", "b"])}")   // T is int, then string
    val words = [1, 2].mapped { n -> "n$n" }           // R is string, from the lambda
    println(words[1])
    val box = Box(7)                                   // a Box<int>
    val small: Box<u8> = Box(200)                      // T from the expected type
    println("${box.get() + 1} ${small.get()}")
    val ages: Map<string, int> = Map()
    ages.set("ada", 36)
    println("${ages.valueOr("ada", 0)} ${ages.valueOr("bob", -1)}")
    println(Pair("x", 2.5).first)
    println("${first<int>([9])} ${Box<string>("written").get()}")
}
// output:
// 3 a
// n2
// 8 200
// 36 -1
// x
// 9 written
```

- **Type arguments are inferred** from a call's arguments (an extension's
  from its receiver too) and from the type expected of the call's result (a
  typed local's initializer, a returned value, a function's body, and the
  branches of an `if` or `when` and a block's last expression in those),
  never across statements. A
  lambda argument's parameters take their types from what is inferred
  before it, and its result can bind a type parameter (`R` above). They may
  be written out: `first<int>(xs)`, `Box<int>(1)`. A type parameter nothing
  binds is `generic.cannot-infer:<f>:<T>`, the wrong number written out is
  `generic.arity:<f>:<expected>:<written>`.
- **Monomorphized.** Each use names one copy of the generic for its type
  arguments (an instance): `Box<int>` and `Box<string>` are two classes,
  each compiled as if written out, so a call costs what a call of an
  ordinary function costs. Every module that uses `Box<int>` uses the same
  copy. A generic no code uses produces no code.
- **The body is checked once**, with each type parameter a type that has
  nothing but what every type has (`==`, being passed and stored). Calling
  a method or reading a field of a `T` is an error at the generic
  (`member:T.size`), unless a bound gives it that member (below).
- **Each instance is checked too**, with its own types. Ownership follows
  the type arguments: an instance holding a resource is a resource
  (`Box<Ticket>` is one, `Box<int>` is not), and an error that only an
  instance has names it (`context[generic-instance]: twice<Ticket>`).
  Every method of a generic class is part of each instance, so a method
  that copies a field of type `T` (`fun get(): T = this.value`) keeps that
  class from holding a resource. `own value: T` owns a resource argument
  and copies any other.
- **Defaults and delegates** are filled in with each call's type
  arguments: with `fun <T> boxedOr(value: T, box: Box<T> = Box(value))`,
  `boxedOr(1)` makes a `Box<int>` and `boxedOr("s")` a `Box<string>`. A
  generic class's property may be delegated (`var value: T by Slot(start)`),
  and its delegate is the instance its type arguments name.
- **Names in a generic's body** resolve where the generic is written, in
  every instance: its module's `private` declarations and, in a
  strict-imports package, its module's imports, whichever module uses it. A
  `private` generic is its module's alone (`name.private`), and another
  module's public generic of the same name is another generic.
- **Invariant.** `Box<Square>` is not a `Box<Shape>`.
- A generic whose instances make ever larger instances (`deep(Box(x))` in
  `deep`) is `generic.instantiation-depth:<f>`. A generic function may not
  share its name with another function (`generic.overload:<f>`), and a
  generic function is called, not passed as a value
  (`generic.reference:<f>`). `where` clauses are reserved syntax.
- **At compile time** generics behave as at run time: `#first([1, 2])`
  evaluates the instance the call names. `#` code in a generic's body runs
  per instance ([below](#compile-time-code-per-instance)).

### Generic methods

A class's method may take type parameters of its own, besides its class's:

```abla
import "abla/io"

class Bag<T>(val items: array<T>) {
    fun <U> remap(f: (T) -> U): Bag<U> {
        val out: array<U> = []
        for (item in items) out.append(f(item))
        Bag(out)
    }

    fun <U> fold(start: U, step: (U, T) -> U): U {
        var total = start
        for (item in items) total = step(total, item)
        total
    }
}

fun main {
    val bag = Bag([1, 2, 3])
    val words = bag.remap { n -> "n$n" }
    println("${words.items[2]} ${bag.fold(0) { total, n -> total + n }} ${bag.remap<string> { n -> "$n!" }.items[0]}")
}
// output:
// n3 6 1!
```

- A call binds the method's type parameters as a generic function's call
  does (its arguments, the type expected of its result), and the class's
  from the receiver. Written out, the type arguments name only the method's
  own: `bag.remap<string>(…)`.
- It is made per receiver instance and type arguments, a direct call like
  any method's, and reaches what any method reaches: the class's fields and
  methods, its module's `private` names, a delegated property's delegate
  (`this.^level`), `this` of a resource class. `#` code in it runs per
  instance. A class without type parameters may have generic methods too.
- A method's type parameter may not reuse a name of its class's
  (`generic.method-shadows`). An interface's method takes no type parameters
  of its own (`generic.interface-method`): a call through an interface value
  would need each class's instance for each type argument. So a class's
  generic method doesn't answer an interface member either.
- Diagnostics and debug information name it by its class: `Bag.remap`.

### Bounds

`<T : Shape>` bounds a type parameter by an interface, and `<T : Shape &
Named>` by several. The body may then call the bounds' members on a `T`
(and pass a `T` where a `Shape` is expected), and every type argument must
be the interface or a class conforming to it, declared or by `extend`.
Each instance calls its class's own method, with no dispatch; an interface
type argument (`totalArea<Shape>(…)`) dispatches as any interface value
does.

```abla
import "abla/io"

interface Shape {
    fun area(): int
}

interface Named {
    fun name(): string
}

class Square(val side: int) : Shape, Named {
    fun area(): int = this.side * this.side
    fun name(): string = "square"
}

class Rect(val width: int, val height: int) : Shape {
    fun area(): int = this.width * this.height
}

fun <T : Shape> totalArea(items: array<T>): int {
    var total = 0
    for (item in items) total = total + item.area()
    total
}

fun <T : Shape & Named> describe(item: T): string = "${item.name()} of ${item.area()}"

class Gallery<T : Shape>(val items: array<T>) {
    fun largest(): int {
        var best = 0
        for (item in this.items) if (item.area() > best) best = item.area()
        best
    }
}

fun main {
    println("${totalArea([Square(2), Square(3)])} ${totalArea([Rect(2, 5)])}")
    println(describe(Square(4)))
    println("${Gallery([Rect(1, 2), Rect(3, 3)]).largest()}")
}
// output:
// 13 10
// square of 16
// 9
```

A type argument that doesn't satisfy a bound is
`generic.bound:<f>:<T>:<type>:<interface>` (`totalArea([1, 2])`, or
`Gallery<string>` written as a type), and a bound that names no interface
is `generic.bound-not-interface:<f>:<T>:<bound>`.

### Generic interfaces

An interface takes type parameters as a class does: `interface Source<T>`
declares one interface per type argument, and `Source<int>` is one of them.
A class conforms to an instance (`class Numbers : Source<int>`, or `extend
Pair : Source<int>`), a generic class may conform to the instance for its
own type argument (`class Repeat<T> : Source<T>`), and an interface may
extend an instance (`interface Sized<T> : Source<T>`). Default members are
written once and run with each instance's types.

A generic function's parameter of an instance (`source: Source<T>`) takes
a value of any class conforming to one, and its type arguments come from
that conformance: `count(Numbers(3))` is `count<int>`. A bound may be an
instance, one naming the bounded parameter itself among them, so that
`<T : Ordered<T>>` takes a type that compares with its own kind. A value
of an instance's type dispatches as any interface value does. A `sealed
interface Result<T>` is sealed per instance: a `when` over a `Result<int>`
with an `is` arm for each of its classes' instances (`is Ok<int>`, `is
Failed<int>`) needs no `else`. A generic class's type arguments also come
from the interface instance expected of it: where a `Result<int>` is
expected, `Failed("bad")` is a `Failed<int>` (`class Failed<T> : Result<T>`).

```abla
import "abla/io"

interface Source<T> {
    fun at(index: int): T?
    fun all(): array<T> {
        val items: array<T> = []
        var index = 0
        var more = true
        while (more) {
            val item = this.at(index)
            if (item != null) items.append(item) else more = false
            index = index + 1
        }
        items
    }
}

class Numbers(val limit: int) : Source<int> {
    fun at(index: int): int? = if (index < this.limit) index * index else null
}

class Words(val words: array<string>) : Source<string> {
    fun at(index: int): string? = if (index < this.words.size) this.words[index] else null
}

fun <T> count(source: Source<T>): int = source.all().size

fun <T> allOf(source: Source<T>): array<T> = source.all()

interface Ordered<T> {
    fun compare(other: T): int
}

class Money(val cents: int) : Ordered<Money> {
    fun compare(other: Money): int = this.cents - other.cents
}

fun <T : Ordered<T>> largest(items: array<T>): T {
    var best = items[0]
    for (item in items) if (item.compare(best) > 0) best = item
    best
}

fun main {
    println("${allOf(Numbers(4))[3]} ${count(Numbers(3))} ${count(Words(["a", "b"]))}")
    val words: Source<string> = Words(["q"])
    println(words.at(0) ?? "-")
    println("${largest([Money(5), Money(9), Money(2)]).cents}")
}
// output:
// 9 3 2
// q
// 9
```

A type argument outside a bound that is an instance reads as one in
`generic.bound` (`generic.bound:largest:T:i64:Ordered<i64>`).

### Compile-time code per instance

`#` code in a generic's body is evaluated for each instance, and in it a
type parameter is its type argument's type handle
([compiler API](compiler-api.md#generics)). An `if` whose condition is a
`#` type query on the type parameters (`compiler.typeConformsTo(T, "I")`,
`compiler.isResource(T)`, and `!`, `&&`, `||` of them) is decided for each
instance before the instance is checked, and keeps only the branch it
takes: the other may use what only some type arguments have. That is how a
generic specializes, with no specialization feature. The generic's own
check decides it for `T` by its bounds.

```abla
import "abla/io"
import "abla/compiler"

interface Hashable {
    fun hash(): int
}

class Key(val n: int) : Hashable {
    fun hash(): int = this.n * 31
}

class Note(val text: string)

fun <T> fingerprint(value: T): int =
    if (#compiler.typeConformsTo(T, "Hashable")) value.hash() else -1

fun <T> describe(value: T): string = "${#compiler.typeName(T)}: ${fingerprint(value)}"

fun main {
    println(describe(Key(2)))
    println(describe(Note("n")))
}
// output:
// Key: 62
// Note: -1
```

## Expressions and operators

Everything that can produce a value is an expression, including `if`, `when`
and blocks. From the tightest binding to the loosest:

| Level | Operators | Notes |
|---|---|---|
| postfix | `f(x)`, `a.b`, `a?.b`, `a[i]`, trailing lambda | `a?.b` skips the rest of the chain when `a` is `null` ([null-safe operators](#null-safe-operators)) |
| prefix | `-` `+` `!` `~` `#` `^` `await` | `#` applies to the whole postfix chain after it; `^name.member` reaches into the delegate |
| multiplicative | `*` `/` `%` | |
| additive | `+` `-` | |
| shift | `<<` `>>` `>>>` | |
| range | `..` `until` | not chainable |
| null default | `??` | right-associative; the right side may be `return`, `break` or `continue` |
| comparison | `<` `<=` `>` `>=` | |
| equality | `==` `!=` | |
| bitwise | `&`, then `^`, then `\|` | looser than `==`, as in C |
| logical | `&&`, then `\|\|` | short-circuit |
| assignment | `=` `+=` `-=` `*=` `/=` `%=` | right-associative |

`yield` takes the whole expression after it.

Two traps follow from the table:

- Bitwise operators bind more loosely than comparisons, so
  `x & 1 == 0` means `x & (1 == 0)`, which is `bitwise.type` (its help says
  to parenthesize). Write
  `(x & 1) == 0`.
- `^name` projects a delegated binding, and member access after it applies
  to the delegate: `^volume.maximum` is `(^volume).maximum`
  ([delegated bindings](#delegated-bindings)). Between two integers, `^` is
  XOR.

An assignment is an expression whose value is the assigned value. Compound
assignment `place op= value` means `place = place op value`, so operator
functions apply to it. The place is evaluated twice, so it may contain only
names, literals, fields and indexes, never a call
(`E_PARSE_COMPOUND_ASSIGNMENT_TARGET`). Only names, fields, indexes and
`^name` can be assigned (`E_PARSE_ASSIGNMENT_TARGET`).

`==` and `!=` compare integers, floats, booleans and strings by value
(strings by their text; `NaN != NaN`). On class objects, arrays, maps and
closures they compare identity: whether both sides are the same object. Two
separately created objects with equal fields are not `==`. A nullable
reference compares to `null` by whether it holds a value. To compare
contents, write a function, such as a field-by-field `equals`. The same rules
hold at compile time. `<`, `<=`, `>` and `>=` order numbers and strings, and nothing else
(`comparison.type`).

## Control flow

`if` and `when` are expressions when every branch produces a compatible
value. `when` compares its subject with each arm in order and takes the
first match; an arm may list several values:

```abla
import "abla/io"

fun describe(n: int): string = when (n) {
    0 -> "zero"
    1, 2 -> "small"
    else -> "other"
}

fun sign(n: int): int = if (n < 0) -1 else if (n > 0) 1 else 0

fun main {
    for (i in 0..3) print("${describe(i)} ")
    println("")
    val answer = when (sign(-5)) {
        -1 -> "negative"
        else -> "not negative"
    }
    val flag = true
    val word = when (flag) {
        true -> "yes"
        false -> "no"
    }
    println("$answer $word")
}
// output:
// zero small small other 
// negative yes
```

- Every `when` must be exhaustive. A `bool` subject may list `true` and
  `false`, and a [sealed interface](#interfaces) subject an `is` arm for
  each of its classes; any other subject needs a final `else`
  (`when.non-exhaustive`).
  `else` must be the last arm and appear once (`when.else-last`,
  `when.else-duplicate`). A repeated literal is `when.duplicate`.
- The subject is evaluated once. Arms may match integers, booleans, strings
  and `null`, and an interface subject `is A`: an instance of the class `A`,
  or of a class conforming to the interface `A`.
- An `if` without `else` is a statement.

Loops are statements. `for (x in source)` iterates over an array, the bytes
of a string, a generator, or a range: `a..b` includes `b`, and `a until b`
stops before it. A range is an ordinary `array<int>`. The loop variable is a
`val` (`assignment.immutable` if assigned).

```abla
import "abla/io"

fun firstNegative(values: array<int>): int {
    for (v in values) {
        if (v < 0) return v
    }
    0
}

fun main {
    for (i in 0 until 3) print("$i ")
    for (b in "ab") print("$b ")
    println("")
    var i = 0
    while (true) {
        i += 1
        if (i % 2 == 0) continue
        if (i > 7) break
        print("$i ")
    }
    println("")
    var n = 10
    do {
        n -= 3
    } while (n > 0)
    println("$n ${firstNegative([3, -2, -5])}")
}
// output:
// 0 1 2 97 98 
// 1 3 5 7 
// -2 -2
```

- `break` leaves the innermost loop; `continue` starts its next iteration.
  Outside a loop they are `break.outside-loop` and `continue.outside-loop`.
- `return` leaves the innermost function or lambda; a bare `return` returns
  `void` (`return.type`, `return.outside-function`).
- Conditions must be `bool` (`if.condition`, `while.condition`,
  `do-while.condition`).
- All of these behave the same at compile time.

## Ownership and resources

Ownership has its own page, [ownership.md](ownership.md). In brief:

- Plain values (`int`, `bool`, `f64`, `string`, ...) are copied. Ordinary
  class objects, arrays and closures are *managed references*: they are
  shared freely and collected automatically, but a function changes an
  object it receives only through a `var` parameter, and an alias may not
  observe a change made after it was taken
  ([details](ownership.md#changing-objects-through-references)).
- `resource class` declares an *affine* type, whose values have one owner.
  Ownership moves with `move(x)`, and `drop()` runs exactly once when the last
  owner goes away
  ([details](ownership.md#resources-values-with-one-owner)). A class that
  stores an affine value is affine too.
- Parameters borrow by default. `var p: T` borrows exclusively for one call;
  `own p: T` takes ownership
  ([details](ownership.md#parameters-borrow-var-and-own)).
- Iterating over an array of resources borrows each element, and iterating
  over `move(array)` takes each one out
  ([details](ownership.md#collections-of-resources)).
- `Shared<T>.get()` views and `borrow(source)` results are tied to their
  owner by a control-flow check (`E_BORROW_CONFLICT`)
  ([details](ownership.md#borrowed-views-and-borrow-results)).
- `Cell<T>`, `Shared<T>`, `Weak<T>` and `Mutex<T>` make sharing explicit
  ([details](ownership.md#sharing-cell-shared-weak-mutex)).
- Closures are `Fn`, `FnMut` or `FnOnce` depending on what they do to their
  captures; `move { ... }` moves resources into a closure
  ([details](ownership.md#closures-and-ownership)).

## Scoped allocation regions

`region { ... }` runs a block whose allocations are all reclaimed when it
ends. Only a scalar result (`int`, `bool`, `f64`, ...) may leave it; the
compiler rejects anything that would let a region-owned value outlive the
block. See [regions.md](regions.md) for the rules and an example.

## Memory management

Ordinary objects, arrays, strings and closures are reclaimed by a precise
garbage collector, cycles included. Resources are destroyed
deterministically instead ([ownership.md](ownership.md)), and regions
reclaim whole blocks of allocations at once.

- Hosted native programs collect automatically, under allocation pressure:
  every allocating function is a possible collection point. Wasm and
  freestanding programs collect only when they call `memoryCollect()`.
- `memorySetManualCollection()` switches a hosted program to manual
  collection. A call to it that `main` can reach compiles the program
  without the automatic collection points.
- `memorySetLimit` and `memorySetCollectionGrowth` turn on pressure
  collection on any target.
- Every program has a hard limit on the total memory it allocates, one GiB
  by default, adjustable with `abla/memory`. Exceeding it is a controlled
  panic, raised before the allocation happens. A program whose reachable
  data stays just under its limit also reaches that panic, instead of
  collecting on nearly every allocating call.
- Native buffers owned by resources stay in place until they are dropped or
  their region ends.

See [standard-library.md](standard-library.md) for `abla/memory`.

## Compile-time execution

Compile-time execution has its own page, [compile-time.md](compile-time.md).
In brief:

- `#expression` evaluates an expression during compilation and stores the
  result in the program as a constant. `#` binds to the operand right after
  it, call and member chain included: `#f() + 1` is `(#f()) + 1`
  ([details](compile-time.md#expression)).
- `compile fun` declares a function that exists only during compilation;
  ordinary functions work in both phases
  ([details](compile-time.md#compile-fun)).
- A top-level `#expression` is an action, run for its effect after semantic
  analysis ([details](compile-time.md#top-level-actions)).
- `compile val` / `compile var` hold one value for the whole compilation,
  shared by every compile-time evaluation
  ([details](compile-time.md#compile-val-and-compile-var)).
- Files, environment, processes, network, clock and randomness need a
  capability, authorized in `abla.toml` and requested with
  `#compilerGrant` ([details](compile-time.md#capabilities-files-environment-processes-network)).
- Reflection, transforms and generated code are the `abla/compiler` module
  ([compiler-api.md](compiler-api.md)).

Typed deferred-expression reflection also exposes deterministic state access
paths. Paths are rooted at semantic parameters, receivers, locals, or globals
and retain field, constant/dynamic index, `Cell`, delegate, and conservative
wildcard projections. Function summaries propagate those paths through calls
by substituting resolved arguments; recursion or an unavailable body widens to
an explicit unknown result. Extensions may compare read and write paths for
prefix-aware invalidation and may lift a recorded expression into a generated
function only by listing explicit, ownership-safe captures (see
[compiler-api.md](compiler-api.md)).

## Compile-time subparsers

`$name` invokes a registered compile-time subparser at the current source
cursor. The handler returns an ordinary expression, so its result is usable at
runtime or under `#`. Handlers may delegate delimited regions back to the Abla
expression parser, which makes parser stacks and template interpolation
possible. Registration staging, cursor ownership, determinism, and hygiene are
specified in `docs/subparsers.md`.

A handler may record a deferred extension request containing a syntax handle,
payload, namespace, and Abla finalizer. The finalizer can inspect the syntax and
target declaration metadata, then return one bounded virtual module. The
combined handwritten/generated program passes normal semantic, ownership,
effect, IR, and backend validation atomically. Generated identifiers carry a
compiler-only hygiene marker that source and ordinary syntax builders cannot
mint. Complete overload/conversion maps and populated generic substitutions
remain later refinements.

## Cleanup, generators, tasks, and threads

These have their own page, [concurrency.md](concurrency.md). In brief:

- `defer { ... }` runs cleanup when the enclosing block ends, however it
  ends; several `defer`s run last-registered first
  ([details](concurrency.md#defer)).
- `generator { ... yield value ... }` produces a `Generator<T>` for a `for`
  loop. It is lazy: the body runs as far as the next `yield` each time the
  loop asks, and leaving the loop early closes it, running its `defer`s
  ([details](concurrency.md#generators)).
- `task { ... }` is a cooperative coroutine (`Task<T>`); `await` runs it
  and returns its result ([details](concurrency.md#tasks)).
- `thread { ... }` starts an OS thread (`Thread<T>`); `await` joins it. A
  thread may capture only `Shared`, `Mutex` and `Weak` handles and `TVar`s
  ([details](concurrency.md#threads)).

## Transactions

A `TVar<T>` is a variable that threads share and change only inside
`atomic { ... }`: each `atomic` block runs as one indivisible step (a
transaction). Other threads see all of its writes or none of them, and a
block that read something another thread changed meanwhile runs again by
itself. A `TVar` is a [delegate](#delegated-bindings), so a binding or a
class property delegated to one reads and writes through the transaction:

```abla
import "abla/io"

class Account(val owner: string, var balance: int by TVar(0)) {
    fun deposit(amount: int): void {
        balance += amount
        return
    }
}

fun transfer(from: Account, to: Account, amount: int): bool = atomic {
    if (from.balance < amount) false
    else {
        from.balance -= amount
        to.deposit(amount)     // a helper that reaches a TVar: fine inside `atomic`
        true
    }
}

fun main {
    val ada = Account("ada")
    val bob = Account("bob")
    atomic { ada.deposit(50) }
    println("${transfer(ada, bob, 30)} ${transfer(ada, bob, 30)}")
    println(atomic { "${ada.balance} ${bob.balance}" })
}
// output:
// true false
// 20 30
```

- `TVar(value)` makes one (`TVar<int>`, ...); `getValue()` and `setValue(v)`
  read and write it, and `var x by TVar(v)` (a local, a global or a class
  property) does that through `x`. Its type may not be a resource or affine
  (`stm.resource:TVar<T>`). `TVar` is the generic class `TVar<T>` of
  `abla/stm`, which a program that names it has without importing it (a
  declaration of its own called `TVar` wins); its instances are the
  runtime's transactional variables themselves, so making, reading and
  writing one costs what the runtime's calls do.
- A delegate class conforming to `abla/stm`'s `Transactional` interface (as
  `TVar` does) is a transactional delegate: a binding delegated to one may
  be read and written inside `atomic` and shared by threads, as one
  delegated to a `TVar` may. Such a class's own `getValue` and `setValue`
  are checked as any code a transaction runs (their effects, what they
  change), so a library delegate built on TVars works like a TVar.
- `atomic { ... }` is an expression worth its block's value. Inside another
  transaction it joins that one: both commit together.
- `retry` gives up the attempt and waits until a TVar the block read changes,
  then runs it again: a block that can't proceed yet (an empty queue, a
  balance too low) just says so. `retry` is a name like any other: a local or
  function called `retry` hides it.
- `atomic { a } orElse { b }` runs `b` when `a` retries, after undoing what
  `a` wrote; when `b` retries too, the whole transaction waits for a change
  to anything either read. `orElse` may follow another `orElse`.
- With one thread (always on WebAssembly) a transaction runs directly, with
  an undo log: there is nothing to conflict with, and a `retry` that no
  `orElse` takes panics (`retry can never wake`), as nothing could change
  what the block read. A panic contained by a checked export rolls the
  transaction back. On WebAssembly an `orElse` alternative that reaches a
  `retry` (itself, in a nested transaction or through what it calls) is left
  by a WebAssembly exception (legacy try/catch_all, which every engine
  shipping WebAssembly exceptions runs): only a module with such an
  alternative is built with exception handling, and any other is built
  without it.
- `#` code runs transactions as plain code, with the same results.

```abla
import "abla/io"

var stock: int by TVar(10)

// Takes `wanted` from the stock, or whatever is left, or nothing.
fun take(wanted: int): int = atomic {
    atomic {
        stock -= wanted
        if (stock < 0) retry   // undone: the next alternative runs
        wanted
    } orElse {
        atomic {
            if (stock == 0) retry
            val left = stock
            stock = 0
            left
        } orElse { 0 }
    }
}

fun main {
    println("${take(4)} ${take(4)} ${take(4)} ${take(4)} ${#take(12)}")
}
// output:
// 4 4 2 0 10
```

Threads share TVars like `Shared` handles: a thread may capture one, and a
global `TVar` or a global delegated to one is a global threads may reach
([concurrency.md](concurrency.md#threads)). Two producers retry while the
slot is full; the consumer retries while it is empty:

```abla
import "abla/io"

var slot: int by TVar(0)      // 0: empty

fun produce(from: int, count: int): int {
    for (value in from until from + count) {
        atomic {
            if (slot != 0) retry
            slot = value
        }
    }
    count
}

fun main {
    val one = thread { produce(1, 100) }
    val two = thread { produce(101, 100) }
    var sum = 0
    for (index in 0 until 200) {
        sum += atomic {
            if (slot == 0) retry
            val taken = slot
            slot = 0
            taken
        }
    }
    println("${await one + await two} values, sum $sum")
}
// output:
// 200 values, sum 20100
```

### What a transaction may do

An attempt that conflicts is thrown away and run again, so a transaction may
change only what can be put back. The compiler checks:

| Diagnostic | Cause |
|---|---|
| `stm.outside-atomic:<what>` | A TVar (or `retry`) reached outside any transaction: a function or method that reaches one outside an `atomic`, itself or through what it calls, runs only inside a transaction, and `main`, a global's initializer, a lambda (other than a transaction's body) and a top-level action can't be inside one |
| `stm.effect:<effect>` | A transaction's body, or anything it calls, prints or reads the standard streams (`io`), touches the file system (`filesystem`), the network (`network`) or native code (`native`), or starts a thread or task (`thread`). Reading the clock, random numbers and the environment is allowed |
| `stm.resource:<name>` | A `TVar` of a resource or affine type (`stm.resource:TVar<Ticket>`), or a resource-typed local declared in a transaction (`stm.resource:ticket`): an abandoned attempt would skip its drop |
| `stm.outside-mutation:<what>` | Inside a transaction, a change to anything but a TVar or what the transaction made (its own locals and the objects they hold): assigning a captured local, a global or a field, changing an outside object (a field, an element, a mutating method, a `var` argument), replacing an outer delegate, or calling a function that changes a global |
| `stm.control:return` | `return` inside a transaction's body, which is a closure: it would leave only the block |
| `stm.orElse-type:<a>:<b>` | The alternatives of an `orElse` have unrelated types |

```abla error
import "abla/io"

var balance: int by TVar(10)

fun main: int = atomic {
    println("balance $balance")
    balance
}
// error: stm.effect:io:println
```

## Modules and imports

Each source file is a module. `import "path"` makes another module's
top-level declarations available. A path is relative to the importing file,
except `abla/...`, which names a standard-library module. `as name` binds the
module to an alias instead, so its declarations are reached as
`name.declaration`:

```abla file=shapes/geometry.ab
class Rect(val width: int, val height: int)

fun area(rect: Rect): int = rect.width * rect.height

val unit = Rect(1, 1)
```

```abla file=shapes/ids.ab
private var issued = 0

fun nextId(): int {
    issued = issued + 1
    issued
}
```

```abla
import "abla/io"
import "shapes/ids.ab"

fun main {
    println("${nextId()} ${nextId()}")   // `issued` isn't visible here
}
// output:
// 1 2
```

```abla
import "abla/io"
import "shapes/geometry.ab" as geo

fun main {
    val r = geo.Rect(3, 4)
    println("${geo.area(r)} ${geo.area(geo.unit)}")
}
// output:
// 12 1
```

- Imports are top-level declarations. A module is loaded once however many
  modules import it. Two modules may import each other: a cycle of imports
  is allowed, and each module sees the other's declarations. (A cycle of
  *packages* is `E_PACKAGE_CYCLE`, see [packages.md](packages.md).) A path
  that names no file is `E_IMPORT_NOT_FOUND`.
- Without an alias, every top-level declaration of the imported module is
  visible by its short name. Two unaliased imports that expose the same name
  make that name ambiguous: `E_IMPORT_UNQUALIFIED_AMBIGUOUS`. Source order
  never picks a winner, so add an alias.
- Visibility is program-wide by default. A declaration that isn't `private`
  is visible by its short name in every module of the program, including
  modules that don't import its module, directly or at all. Importing still
  decides ambiguity and aliases, and a module's own declaration of a name, or
  a local, shadows the others. A package can opt into
  [strict imports](#strict-imports), where a module sees only what it
  imports. Two modules that both declare a name (`symbol.duplicate`) are
  kept apart by aliasing one import, or, when one module stands in for the
  other, by a [remap](packages.md#import-remaps) in the root `abla.toml`,
  which gives every module of the build the same one.
- An alias belongs to the importing module only, and it is a compile-time
  namespace, not a value (`E_IMPORT_ALIAS_USED_AS_VALUE`). Importing a
  module doesn't expose the aliases *it* uses. Other alias errors:
  `E_IMPORT_ALIAS_DUPLICATE` (one alias bound twice),
  `E_IMPORT_ALIAS_TARGET_DUPLICATE` (one module imported twice),
  `E_IMPORT_ALIAS_MEMBER_UNKNOWN`.
- `private` before a top-level declaration (`fun`, `val`, `var`, `class`,
  `interface`, `type`, an extension function or field) makes it visible only
  in its own module. Two modules may each have a private declaration of one
  name, and another module's private name never clashes with or hides a
  public one. Using one from another module is `name.private`, through an
  alias `E_NAME_PRIVATE`, and `@export` on one is `private.export`.
  (`internal`, for a package, is reserved.) The standard library never reads
  a program's global `val`s and `var`s (`library.program-global`).
- A program's declaration named like a built-in (`Cell`, `Shared`, `Mutex`,
  `Map`, `filledArray`, `move`) hides the built-in in its own module and in
  the modules that import it, as a type too (`val c: Cell = Cell(1)`). Other
  modules, and the standard library, keep the built-in.
- Names are lexical: code resolves names as the module it is written in
  sees them. A module's `#` code sees its private declarations. So do the
  modules generated for it (the members `compiler.addConformance` adds, a
  `compilerGenerateModule` source): they see names as the module that
  requested them does. So does a subparser's expansion: a name its handler
  builds (`syntaxIdentifier`, `syntaxCall`, `syntaxAssign`) means what it
  means in the module that invokes the subparser. A generic's body sees
  names as the module that declares it does, wherever it is instantiated.
- A declaration's identity (for native symbols and reflection) comes from
  the module that defines it, not from an importer's alias, so renaming an
  alias renames nothing in the output.
- Compile-time and run-time code import the same modules. Each declaration
  is kept or dropped for its phase.

An import argument may also be a compile-time *source provider* call that
returns an `ImportSource`, such as `github("owner/repository")`. Providers,
`abla.lock` and vendoring are described in [packages.md](packages.md):

```abla fragment
import github("AndreBaltazar8/abla-mvc") as mvc
```

### Strict imports

A package whose `abla.toml` says `visibility = "imports"` is strict: each of
its modules sees its own declarations and those of the modules it imports
without an alias, and nothing else. `export import "path"` imports a module
and passes its declarations on, as if declared here, to the modules that
import this one:

```toml file=abla.toml
visibility = "imports"
```

```abla file=shapes/facade.ab
export import "geometry.ab"
import "ids.ab"

fun describe(rect: Rect): string = "${area(rect)} #${nextId()}"
```

```abla
import "abla/io"
import "shapes/facade.ab"

fun main {
    val r = Rect(2, 3)    // geometry.ab's, passed on by the facade
    println("${area(r)} ${describe(r)}")
}
// output:
// 6 6 #1
```

A name the module reaches any other way, here through the facade's own
import, is `E_NAME_NOT_IMPORTED`, and its `help:` line is the import to add:

```toml file=abla.toml
visibility = "imports"
```

```abla error
import "shapes/facade.ab"

fun main: int = nextId()
// error: E_NAME_NOT_IMPORTED
// error: add: import "./shapes/ids.ab"
```

- A module that isn't strict passes on everything it reaches, as today. A
  strict package may import a flat one and the other way round.
- The standard library is a strict package. A module that fronts another
  passes it on with `export import`, so `import "abla/fs"` gives `Path`
  although `abla/fs` declares nothing itself; `abla/net`, `abla/random` and
  `abla/process` do the same. The runtime the compiler adds to every program
  (`abla/runtime/self` and its target's platform module) and `abla/stm` are
  seen by every module without an import. A library module's other files
  (such as its native bindings) aren't API: a flat program reaches their
  names through the module that imports them, and a strict one doesn't, which
  E_NAME_NOT_IMPORTED says.
- Member names (after `.`, or a class's own members in its body), named
  arguments and a declaration's own parameters and locals aren't looked up
  this way. Aliases, `private` and `E_IMPORT_UNQUALIFIED_AMBIGUOUS` work as
  in any module.
- `visibility = "program"` keeps a package flat. A program without a
  manifest, or whose manifest doesn't say, is strict when built with
  `--strict-imports`.
- To migrate, `ablac build app.ab -o app --visibility-report report.tsv`
  builds as usual and writes every name each module would lose, with the
  import to add; `ablac run tools/fix-imports.ab -- report.tsv` adds those
  imports. A new import that makes a name ambiguous needs an alias, which the
  next build reports.

### Contract imports

`import contract "path" as name` exposes another module's function
signatures, annotations, defaults, ownership modes and data shapes, without
adding its implementations to this program. It is for code that calls across
a boundary (a client calling a server): a compile-time extension must
replace every contract call with real client code, as an RPC subparser does:

```abla fragment
import contract "../backend/counter.ab" as counter

val request = $rpc(counter.incrementRemotely(41))
```

A contract call left in the program fails with
`E_CONTRACT_CALL_NOT_CONSUMED`. Contract extraction doesn't run the other
module's initializers or compile-time actions, and it follows only the
imports its declaration shapes need, so the backend's private dependencies
and capabilities stay out of the client. A contract's fingerprint excludes
function bodies: changing a signature, annotation, default or data shape
changes it, and a body-only edit does not.

### Console programs

Portable console programs import `abla/io`; each target supplies the
implementation behind the same API. `print` and `println` write standard
output, and `eprint` and `eprintln` write standard error.
`readInputLine()` returns `InputLine(text, available)`, so end of input is
distinct from an empty line. The shorter `readLine()` returns `""` at the
end of input.

## Annotations

An annotation is `@name` or `@name(argument)` before a declaration. A
declaration may carry several, each at most once.

| Annotation | On | Effect |
|---|---|---|
| `@export("symbol")` | top-level function | publishes it under a stable foreign symbol; an array of names publishes aliases |
| `@exportChecked("symbol")` | top-level function | the same, with the panic-containing checked ABI |
| `@inline` | function, method | asks the backend to inline it |
| `@noinline` | function, method | keeps it out of line (`noinline.function`, `noinline.inline` if combined with `@inline`) |
| `@naked` | trusted function | emits the body as raw assembly without a prologue ([llvm-backend.md](llvm-backend.md)) |
| `@section("name")` | function | places it in a linker section ([llvm-backend.md](llvm-backend.md)) |
| `@wasmImport("module")` | `extern:"c"` declaration | imports it from that Wasm module; `["module", "field"]` also renames it ([toolchain.md](toolchain.md)) |

Other annotation names are kept as metadata for compile-time code to read
(`compiler.annotation`, `functionsAnnotated`; see
[compiler-api.md](compiler-api.md)).

```abla
import "abla/io"

@inline
fun square(n: int): int = n * n

@noinline
fun cube(n: int): int = n * n * n

@export("example_add")
fun add(left: int, right: int): int = left + right

fun main {
    println("${square(3)} ${cube(2)} ${add(1, 1)}")
}
// output:
// 9 8 2
```

Exports:

- Exported signatures use scalar types. `bool`, `char`, `f32`, `f64` and
  every 8- to 64-bit integer type keep their exact width. In WebAssembly,
  narrow integers travel in the `i32` lane. Classes and arrays are not
  exported. A `string` parameter becomes a `(pointer, length)` pair that the
  adapter copies, and a `string` result becomes a handle with data, length
  and release functions. See [native declarations](#native-declarations).
- A program may publish up to 128 named exports.
- A scalar-only unchecked export calls the function directly. A checked
  export returns a status and contains panics.
- Naked-assembly exports with several names share one definition. Other
  exports get one adapter per name.

## Trusted native implementations

Abla has no general unsafe block. Raw native operations (pointers, raw
memory, foreign functions that take pointers) are declared `trusted`, and
only a `trusted` function may call them:

```abla fragment
trusted extern:"intrinsic" fun platformRead(address: i64*): int

trusted fun checkedRead(buffer: NativeBuffer, offset: int): int {
    if (offset < 0 || offset + 8 > buffer.capacity) 0
    else platformRead(buffer.pointerAt(offset))
}
```

Calling `platformRead` from an ordinary function is an error
(`native.trust:platformRead`). Calling the checked wrapper is ordinary safe
code: the `trusted` function is where the safety argument lives. The intended
policy also requires a package-manifest grant before a non-platform package
may define a trusted implementation. That manifest check is not enforced yet.

Object addresses are runtime-internal. The intrinsics that yield the address of
a value, an object, a field, a cell or an array (`ablaRuntimeValueAddress`,
`ablaRuntimeValueWord0`, `__ablaRuntimeWord0`, `__ablaRuntimeWord1`,
`__ablaRuntimeObjectAddress`, `__ablaRuntimeFieldAddress`,
`__ablaRuntimeFieldAddressScan`, `__ablaRuntimeFieldAddressIndexed`,
`__ablaRuntimeCellAddress`, `__ablaRuntimeArrayAddress`,
`__ablaRuntimeObjectDescriptor`), the field-slot accessors
(`ablaRuntimeLoadSlotU8`, `ablaRuntimeLoadSlotI32`, `ablaRuntimeLoadSlotI64`,
`ablaRuntimeStoreSlotU8`, `ablaRuntimeStoreSlotI32`, `ablaRuntimeStoreSlotI64`)
and the placed field accessors (`__ablaRuntimeFieldLoad`,
`__ablaRuntimeFieldStore`), are called only by
modules under `abla/runtime` and by the code the compiler generates for
compile-time evaluation. A call from anywhere else, trusted or not, is an error
(`native.runtime-internal:ablaRuntimeValueWord0`). The compiler and the backend
rely on no other code holding those addresses: an object can move or change
layout, and LLVM is told that raw memory never aliases a field slot.

Raw memory you allocate (`abla/unsafe/memory/raw`, `abla/unsafe/native`, C
allocations) stays yours to address. A function value's id, the one thing the
bridge and similar tools needed from a value's words, is
`ablaRuntimeFunctionId(f)`: the function a value calls, 0 for a value that
isn't a function.

```abla error
trusted fun word(value: any): int = ablaRuntimeValueWord0(value)

fun main: int = word(1)
// error: native.runtime-internal:ablaRuntimeValueWord0
```

`extern:"kind"` declares a function implemented outside Abla:

| Kind | Implemented by |
|---|---|
| `extern:"c"` | a C-ABI symbol, linked from libc or a declared native library |
| `extern:"intrinsic"` | the compiler, for raw memory and runtime operations |
| `extern:"host"` | the hosted platform runtime (`abla/platform/host`) |
| `extern:"compiler"`, `extern:"parser"` | the compiler, at compile time only (`abla/compiler`) |
| `extern:"inline-assembly"` | a template of target assembly ([llvm-backend.md](llvm-backend.md)) |

`noescape` on a declaration promises that it doesn't keep any Abla value it
receives, which lets region-owned values be passed to it
([regions.md](regions.md)). `trusted` and `noescape` are independent.

```abla
extern:"c" fun labs(value: int): int

fun main: int = labs(-5)
// exit: 5
```

## Native declarations

Prototype-compatible `extern:"c"` declarations are supported by the C ABI
native module. Portable standard-library APIs do not expose C strings or
variadic functions. Native declarations must use ABI-safe types; conversions
between `string` and `cstring` are explicit or generated by a declared adapter.

The bootstrap may link libc for the host runtime. The language ABI itself does
not require libc. Freestanding targets provide allocation, panic, I/O, and
process hooks through a target runtime.

The current native ABI maps Abla `int` to C `int64_t`, `bool` to C `_Bool`,
`cstring` inputs to `const char*`, explicit `T*` to opaque native pointers, and
`void` directly. A `string` supplied to a declared `cstring` parameter receives
a generated NUL-terminated input adapter. Native `cstring` results are rejected
until ownership is declared. Other types require an explicit adapter rather
than an unchecked cast. Native libraries are registered explicitly in the VM
and linked explicitly for generated code.

Export adapters are a separate, manifest-described boundary. Their current
borrowed `string` input is length-delimited `(const uint8_t*, uint64_t)`, not a
C string. The adapter validates the pair and copies it into Abla ownership, so
the caller retains and may immediately reuse or release its buffer after the
call. The ABI manifest records `ownership: borrowed` and
`calleeAction: copy`.

An exported `(int) -> int` callback parameter lowers to a C callback taking an
explicit context pointer followed by `int64_t`. It is borrowed synchronously
for that exported call. The Abla function may invoke it directly, but export
validation rejects storing, returning, capturing, or forwarding it, so the
foreign pointer cannot outlive its caller-owned context. The manifest records
the callback signature, C calling convention, call lifetime, forbidden
retention, and the requirement that it not unwind across the ABI.

Checked export adapters are opt-in through `exportCheckedFunction`. Their C ABI
returns an `int32_t` status and moves the normal result to an out-pointer. A
panic becomes status `1`; its bytes are copied into a caller-owned buffer and
the full length is reported even when that buffer truncates the message.
A successful call sets the reported error length to zero when its pointer is
non-null. Status `2` reports invalid boundary output pointers. This contains control flow
and restores the runtime's recovery/root frames, but cleanup is abortive and
external side effects are not transactional. Direct exports remain explicitly
uncontained. Targets that do not advertise the required runtime capability
reject checked exports.

An exported `string` result is copied into an opaque foreign handle rather than
leaking the tracked `%AblaValue` or an interior runtime pointer. Callers inspect
it through the manifest-named data/length functions and must call the release
function exactly once. Its bytes remain valid until release. The initial handle
allocator is available on libc-backed targets; a libc-free extension must
provide its own compatible allocation contract before selecting this result
ABI.

## Compatibility baseline

The original examples establish the initial compatibility suite:

- functions, calls, trailing lambdas, and extension functions;
- variables, arrays, classes, interfaces, and annotations;
- arithmetic, comparisons, `if`, `when`, `while`, and `do while`;
- nullable values and pointers;
- imports and C externals;
- compile-time execution and compiler-context transformations.

Compatibility means accepted useful syntax and intended results, not matching
the prototype's LLVM text, unchecked casts, races, accidental `i32` ABI, or
known TODO behavior.
