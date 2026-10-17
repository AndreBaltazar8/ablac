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
[compile time](#compile-time-execution) · [modules](#modules-and-imports) ·
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
  status 101.

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

A template may insert strings, integers of any width, `bool`, and
`f64`/`f32` (with `import "abla/float/text"`; without it the error says so).
Other types, `char` included, are `string.interpolation:<type>`.
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
  through the functions it calls, in this module or another, is
  initialized after it. Independent globals keep declaration order. A
  cycle (`val a = b + 1` with `val b = a + 1`, also through functions or
  across modules) is a compile error,
  `global.initialization-cycle:a->b->a`, at run time and under `#` alike.
  So no initializer can see a global that isn't initialized yet.
- A local lives from its declaration to the end of its block. A local in a
  nested block may shadow an outer local, a parameter or a field; the outer
  one is visible again after the block, including to closures that captured
  it.
- Two locals of one block can't share a name (`local.duplicate`), and a
  function's or lambda's body can't redeclare one of its parameters
  (`local.shadows-parameter`).

> Known issue (being fixed by ct-infer): today a direct reference moves a
> global after the others instead of right after its dependency, a
> dependency through a function isn't followed (the read sees `0`, `""` or
> an empty object), cycles compile and read zero values, and a cycle read
> under `#` crashes the compiler. Keep initializers free of calls that read
> other globals.

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

- `>>` is arithmetic for signed types and logical for unsigned ones; `>>>`
  is always logical. A shift count may have any integer type. A count that
  is negative or at least the width gives zero.
- Mixing types (`f64 + int`, `string + int`) is `arithmetic.type`. Mixing
  bit-operation types is `bitwise.type`.
- Division or remainder by zero panics with "division by zero" (exit
  status 101). Under `#` it is a compile-time error, and a divisor that is
  the constant zero is rejected when the program is type-checked. The
  smallest value divided by `-1` wraps to itself, and its remainder is 0.

> Known issue (being fixed by ct-rt): today division and remainder by zero
> quietly give 0 at run time (`7 % 0` gives 7 under `#`), and
> `-9223372036854775808 / -1` gives 0 at run time.

> Known issue (being fixed by ablac-backend): an `int` argument passed to a parameter of a narrower type
> (`u8`, `i32`, ...) is narrowed implicitly, without a conversion call. Write
> the conversion anyway; the implicit form may become an error.

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

Both operands of float arithmetic must have the same width. Floats work at
compile time too, with identical results.

### Strings

A `string` is immutable UTF-8. `size` is its length in bytes; `text[i]` is
the byte at `i` as an `int`; `slice(begin, end)` copies a byte range; `+`
concatenates two strings. `==` compares contents, and `<`, `<=`, `>`, `>=`
compare byte by byte, lexicographically. `for (b in text)` iterates over the
bytes.
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

- An array literal's elements must share one type (`array.element-type`).
  An empty literal needs a declared type.
- A declared type flows into the literal: in
  `val grid: array<array<int>> = [[1], []]` the inner `[]` is an
  `array<int>`, and `val names: array<string?> = ["a", null]` accepts the
  `null`. The same holds for a declared result or parameter type.
- `append(value)` adds at the end, `truncate(n)` keeps the first `n`
  elements (`n` beyond the size keeps all), `clear()` removes all, and
  `filledArray(count, value)` creates a filled array. A negative count for
  either panics.
- Reading or writing outside the array panics with the index and the size
  ("index 5 out of bounds for array of size 3", exit status 101). The same
  holds for a string index or slice.
- Changing an array you received as a parameter needs a `var` parameter
  ([ownership.md](ownership.md#parameters-borrow-var-and-own)). An array of
  resources owns its elements.

> Known issue (being fixed by ablac-frontend): the constructor forms
> `array<int>()` and `Map<string, int>()` are going to mean the same as
> `val x: array<int> = []` and `val m: Map<string, int> = Map()`. Today they
> are parse errors; declare the type on the binding instead. Also today,
> only a top-level empty literal takes the declared type: nested empty
> literals and `null` elements are `array.element-type`.

> Known issue (being fixed by ablac-frontend): an array literal passed to a
> receiver whose type is only inferred (`val rows = makeRows()` then
> `rows.append([1, null])`) still types itself from its own elements.
> Annotate the local (`val rows: array<array<int?>> = makeRows()`) until
> then.

> Known issue (being fixed by ct-rt): out-of-bounds accesses, `truncate`
> with a negative count or one beyond the size, and a negative `filledArray`
> count currently stop the program with "fatal signal" and a stack trace but
> no reason, and ordered comparison of strings type-checks but crashes the
> native program.

### Maps

`Map<K, V>` is a built-in hash map with `string` or `int` keys. Its type
must be declared where it is created:

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
A map without a declared type is `map.untyped`, and other key types are
`map.key-type`.

### Nullable types

`T?` holds a `T` or `null`. A nullable value can't be used as a `T` until
the compiler can see it isn't `null`. Checking a `val` or a parameter
narrows it on the path where the check holds, and after an `if` whose
branch leaves the block (`return`, `break`, `continue`):

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
- There is no safe-call `?.` and no `?:` operator: check `x != null`, which
  narrows a `val`.

> Known issue (being fixed by ct-infer): today the arms after `null ->`
> still see the nullable type (`string.interpolation:nullable:string` in
> `else -> "got $s"`). Use `if (s == null) ... else ...` for now.

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
    println("user ${idNumber(id.next())}")
    println("${id + 1}")
}
// output:
// user 42
// 42
```

- `UserId(41)` converts an `int` to a `UserId`. An `int` is not accepted
  where a `UserId` is required (`function.argument:...:UserId:i64`).
- The other direction is implicit: a `UserId` is accepted where an `int` is,
  as an argument, a result or an operand. Arithmetic produces the underlying
  type, so wrapping the result is explicit.
- Inside an extension of a nominal type, `this` is the underlying value.
- `type` is a keyword only at the start of a declaration.

> Known issue (being fixed by ablac-backend): a nominal value can't yet initialize a typed local
> (`val raw: int = id`) or be inserted into a string template directly.
> Pass it through a function, as `idNumber` does.

### Function types

`(A, B) -> R` is a function taking `A` and `B` and returning `R`;
`T.(A) -> R` is one with a receiver. Parameter modes are part of the type:
`(var: Counter) -> int` and `(own: Ticket) -> int` differ from
`(Counter) -> int`. `Fn`, `FnMut`, `FnOnce` and `FnNoEscape` describe what a
closure does with its captures
([ownership.md](ownership.md#closures-and-ownership)). Generic arguments are
written `Type<A, B>`.

Only the built-in types take type arguments (`array`, `Map`, `Task`,
`Shared`, the `Fn` family and the others listed above). A program can't
declare its own generic functions or classes: `fun <T> first(...)` and
`class Box<T>(...)` are parse errors. Like implementing interfaces, this is
an open language-design item.

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
  from the body. Until the known issue below is fixed, write the result
  type whenever callers use the result.
- Parameters may have defaults, which may refer to earlier parameters.
  Arguments may be passed by name after the positional ones (see the
  known issue below about methods). Each argument
  is evaluated once, in source order. Unknown, duplicate, out-of-order or
  missing required names are errors (`E_NAMED_ARGUMENT_UNKNOWN`,
  `_DUPLICATE`, `_ORDER`, `_REQUIRED`).
- Parameters borrow their arguments; `var` and `own` change that
  ([ownership.md](ownership.md#parameters-borrow-var-and-own)).
- Recursion is limited by the thread's stack. Running out of stack panics
  with "stack overflow".

> Known issue (being fixed by ct-rt): today a stack overflow ends the
> program with exit status 139 and no message.

> Known issue (being fixed by ablac-backend): named arguments currently work
> only for top-level functions and constructors; a method call with them is
> `E_NAMED_ARGUMENT_TARGET`.

> Known issue (being fixed by ct-infer): a result inferred from
> `fun inc(a: int) = a + 1` is currently unknown to its callers, so `inc(41) + 1` fails with
> `arithmetic.type@..:inferred:i64` and `fun main: int = inc(41)` with
> `function.result:main:i64:inferred`.

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
- Parameter types also come from a built-in method's element type:
  `callbacks.append({ x -> x + 1 })` on an `array<(int) -> int>`, and the
  same for `Map` values.
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

> Known issue (being fixed by ablac-frontend): today a call drops a callee
> that isn't a plain name. `adder(2)(3)` silently calls `adder(3)`,
> `handlers[0]()` has an unknown type, and `button.onClick(event)` on a
> property is `method.arity`. Put the function in a local first:
> `val f = adder(2)` then `f(3)`.

> Known issue (being fixed by ct-infer): today a lambda passed to `append`
> or a `Map` method needs explicit parameter types
> (`{ x: int -> x + 1 }`); without them the parameter is
> `identifier:x`.

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
  property of function type, whose parameters accept the arguments. A
  property that isn't a function never captures a call, and a method that
  can't take these arguments lets the search continue. With no applicable
  candidate anywhere, the error names the innermost one.
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

```abla fragment
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

> Known issue (being fixed by ablac-frontend): today a property or method
> named like a top-level function captures every call of that name, even
> one it can't take (`scale(v)` above reports `call.target:scale`, so the
> example is not run yet). Until then, give such members distinct names.

> Known issue (being fixed by ablac-frontend): today a method can't call another
> method of its class by name (`area()` reports `call.target:area`; write
> `this.area()`).

### Interfaces

`interface Name { fun member(...) }` declares a named type with method
signatures. Today an interface is only a nominal type: there is no syntax
for a class to implement one, and a class value is not accepted where an
interface is expected (`function.argument:...:Shape:Square`). Interfaces are
used as opaque handle types in compiler and library APIs. Implementing
interfaces is an open language-design item, raised with the language owner.

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
- `by` works on local and top-level `val`/`var`, and on `compile val` /
  `compile var`. It does not work on parameters or class properties.

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
- Overloads are resolved before code generation, so they cost nothing at run
  time. Named arguments and function references don't choose between
  overloads.

## Expressions and operators

Everything that can produce a value is an expression, including `if`, `when`
and blocks. From the tightest binding to the loosest:

| Level | Operators | Notes |
|---|---|---|
| postfix | `f(x)`, `a.b`, `a[i]`, trailing lambda | |
| prefix | `-` `+` `!` `~` `#` `^` `await` | `#` applies to the whole postfix chain after it; `^name.member` reaches into the delegate |
| multiplicative | `*` `/` `%` | |
| additive | `+` `-` | |
| shift | `<<` `>>` `>>>` | |
| range | `..` `until` | not chainable |
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
hold at compile time.

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
  `false`; any other subject needs a final `else` (`when.non-exhaustive`).
  `else` must be the last arm and appear once (`when.else-last`,
  `when.else-duplicate`). A repeated literal is `when.duplicate`.
- The subject is evaluated once. Arms may match integers, booleans, strings
  and `null`.
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
  panic, raised before the allocation happens.
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
  thread may capture only `Shared`, `Mutex` and `Weak` handles
  ([details](concurrency.md#threads)).

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
- An alias belongs to the importing module only, and it is a compile-time
  namespace, not a value (`E_IMPORT_ALIAS_USED_AS_VALUE`). Importing a
  module doesn't expose the aliases *it* uses. Other alias errors:
  `E_IMPORT_ALIAS_DUPLICATE` (one alias bound twice),
  `E_IMPORT_ALIAS_TARGET_DUPLICATE` (one module imported twice),
  `E_IMPORT_ALIAS_MEMBER_UNKNOWN`.
- There are no visibility modifiers: every top-level declaration of a module
  is visible to its importers.
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
Status `2` reports invalid boundary output pointers. This contains control flow
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
