# A tour of Abla

This tour introduces Abla through small programs that build on each other.
It assumes you have written code in a language like Kotlin, Swift, Rust or
TypeScript. Each section ends with a link to the reference that covers the
details. Every program here is compiled and run by the documentation tests,
and the output shown is what it prints.

## 1. Hello, world

```abla
import "abla/io"

fun main {
    println("Hello, world!")
}
// output:
// Hello, world!
```

Save it as `hello.ab` and run it:

```sh
ablac run hello.ab                 # compile and run in one step
ablac build hello.ab -o hello      # or build an executable
./hello
```

`import "abla/io"` brings in `println`. `fun main` is the entry point. If
`main` returns an `int`, that becomes the exit status. See
[programs](language.md#programs) and [toolchain.md](toolchain.md).

## 2. Values, functions and control flow

```abla
import "abla/io"

fun fizzbuzz(n: int): string {
    val by3 = n % 3 == 0
    val by5 = n % 5 == 0
    return if (by3 && by5) "FizzBuzz"
        else if (by3) "Fizz"
        else if (by5) "Buzz"
        else "$n"
}

fun main {
    var line = ""
    for (i in 1..15) line = "$line${fizzbuzz(i)} "
    println(line)
}
// output:
// 1 2 Fizz 4 Buzz Fizz 7 8 Fizz Buzz 11 Fizz 13 14 FizzBuzz 
```

- `val` is assigned once and `var` can change. Types are inferred from
  initializers. Function parameters and results are written out.
- `if` and `when` are expressions, and the last expression of a block is its
  value. `return` leaves a function early.
- `"$n"` and `"${expression}"` are string templates.
- `1..15` includes 15, and `0 until 15` doesn't.

See [values and variables](language.md#values-and-variables),
[functions](language.md#functions) and
[control flow](language.md#control-flow).

## 3. Classes, arrays and maps

```abla
import "abla/io"

class Item(val name: string, val price: int, var stock: int) {
    fun describe(): string = "$name x$stock at $price"
}

fun totalValue(items: array<Item>): int {
    var total = 0
    for (item in items) total += item.price * item.stock
    total
}

fun main {
    val items = [Item("bolt", 2, 100), Item("gear", 15, 4)]
    items.append(Item("spring", 1, 250))
    for (item in items) println(item.describe())
    println("value: ${totalValue(items)}")

    val byName: Map<string, Item> = Map()
    for (item in items) byName.set(item.name, item)
    val gear = byName.get("gear")          // Item?, since the key may be missing
    if (gear != null) println("found ${gear.name}")
}
// output:
// bolt x100 at 2
// gear x4 at 15
// spring x250 at 1
// value: 510
// found gear
```

- A class lists its properties in its constructor: `val` for read-only,
  `var` for mutable. Methods see the properties by name.
- `array<T>` grows with `append`. `Map<K, V>` maps `string` or `int` keys to
  values.
- `T?` may be `null`. After `if (gear != null)`, the compiler knows `gear`
  is an `Item`.

See [classes](language.md#classes), [arrays](language.md#arrays),
[maps](language.md#maps) and [nullable types](language.md#nullable-types).

## 4. Who may change what

Objects are shared by reference, but a function can only change an object it
receives if its parameter says `var`:

```abla
import "abla/io"

class Item(val name: string, var stock: int)

fun restock(var item: Item, amount: int): void {
    item.stock += amount
    return
}

fun report(item: Item): string = "${item.name}: ${item.stock}"

fun main {
    val gear = Item("gear", 4)
    restock(gear, 10)
    println(report(gear))
}
// output:
// gear: 14
```

Leave the `var` off and `item.stock += amount` is an error that suggests
adding it. Values that must be released exactly once (files, sockets,
locks) are declared `resource class`. They have a single owner, move with
`move(...)`, and clean up in `drop()`:

```abla
import "abla/io"

resource class Lease(val id: int) {
    fun drop(): void {
        println("lease $id returned")
        return
    }
}

fun use(lease: Lease): string = "using lease ${lease.id}"
fun keep(own lease: Lease): int = lease.id

fun main {
    val first = Lease(1)
    println(use(first))              // borrowed: `first` is still ours
    println("kept ${keep(move(first))}")
    val second = Lease(2)
    println("end of main")
}
// output:
// using lease 1
// lease 1 returned
// kept 1
// end of main
// lease 2 returned
```

The compiler checks every one of these rules before the program runs:
there is no use after `move`, no double release, and no change seen through
an alias. See [ownership.md](ownership.md).

## 5. Modules

Each file is a module. `import` a relative path, optionally with an alias:

```abla file=pricing.ab
fun withTax(price: int, percent: int): int = price + price * percent / 100
```

```abla
import "abla/io"
import "pricing.ab" as pricing

fun main {
    println("${pricing.withTax(200, 20)}")
}
// output:
// 240
```

See [modules and imports](language.md#modules-and-imports). Packages from
Git use the same `import`, with a provider: `import github("owner/repo")`
([packages.md](packages.md)).

## 6. Running code at compile time

Any expression can run during compilation: prefix it with `#`. The compiler
evaluates it with the same language and libraries, and stores the result in
the program as a constant:

```abla
import "abla/io"
import "abla/json"

fun primes(limit: int): array<int> {
    val found: array<int> = []
    for (n in 2..limit) {
        var prime = true
        for (p in found) if (n % p == 0) prime = false
        if (prime) found.append(n)
    }
    found
}

compile fun banner(name: string): string = "== $name =="

fun main {
    val table = #primes(50)          // computed by the compiler
    println(#banner("primes"))
    println("${table.size} primes, the last is ${table[table.size - 1]}")
    val config = #$jsons { "mode": "release", "workers": 4 }
    println(config)
}
// output:
// == primes ==
// 15 primes, the last is 47
// {"mode":"release","workers":4}
```

- `primes` is an ordinary function, usable at run time too. `#primes(50)`
  runs it once, while compiling.
- A `compile fun` exists only at compile time.
- `$jsons { ... }` is a *subparser*: library code that parses its own
  syntax at compile time. Libraries can define new ones
  ([subparsers.md](subparsers.md)).
- Compile-time code can also read files and the environment, but only with
  an explicit capability, so a build never reaches outside the project
  silently.

See [compile-time.md](compile-time.md). The `abla/compiler` module lets
compile-time code inspect and extend the program being compiled
([compiler-api.md](compiler-api.md)).

## 7. Tasks and threads

```abla
import "abla/io"

resource class Tally(var count: int)

fun add(var tally: Tally): int {
    tally.count += 1
    tally.count
}

fun main {
    val parse = task { "a,b,c".size }
    println("parsed ${await parse} bytes")

    val tally = Mutex(Tally(0))
    val workerCopy = tally.clone()
    val worker = thread { workerCopy.with(add) }
    tally.with(add)
    await worker
    println("tally ${tally.with(add) - 1}")
}
// output:
// parsed 5 bytes
// tally 2
```

- `task { }` is a cooperative coroutine that `await` runs to completion.
- `thread { }` is an OS thread, joined by `await`. A thread can only share
  state through `Shared`, `Mutex` and `Weak` handles.

See [concurrency.md](concurrency.md).

## Where next

- [language.md](language.md): the full language reference
- [ownership.md](ownership.md), [compile-time.md](compile-time.md),
  [concurrency.md](concurrency.md): the three big topics in depth
- [standard-library.md](standard-library.md), [json.md](json.md),
  [networking.md](networking.md): the libraries
- [diagnostics.md](diagnostics.md): reading compiler errors
- [debugging.md](debugging.md): stack traces and debuggers
