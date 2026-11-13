# `abla/uint128`

Unsigned 128-bit integers. `uint128` is a type of the language, like `u64`;
what's done with it comes with the import. It is the sibling of [`uint256`](uint256.md), and works the same way: an LLVM
`i128` in a function's scalar plan, and 16 bytes of string data where a value goes boxed (a field, an array element,
a capture, a generic, a `T?`). A program that doesn't import it has none of it.

```abla
import "abla/io"
import "abla/uint128"

fun main {
    val a = uint128(1) << 126
    val b = uint128(3) * a
    println("${a} ${b} ${b > a}")
    println("${a.toHex()} ${uint128FromDecimal("340282366920938463463374607431768211455") == uint128Max()}")
    println("${uint128FromBytes(a.toBytes()) == a} ${uint128FromBytesLittleEndian(a.toBytesLittleEndian()) == a}")
}
// output:
// 85070591730234615865843651857942052864 255211775190703847597530955573826158592 true
// 0x40000000000000000000000000000000 true
// true true
```

## What it does

| | |
|---|---|
| `+ - * & \| ^ ~ -x` | wrap at 128 bits, as every fixed width's do; both sides must be `uint128` |
| `/ %` | unsigned; by zero is the language's panic, `division by zero`, exit 101 |
| `<< >>` | a count of any integer type; negative or at least 128 gives zero. `>>` is logical. `a.shl(b)` and `a.shr(b)` take a `uint128` count |
| `== != < <= > >=` | both sides `uint128` |
| `"$x"` | decimal, as any integer |
| `uint128(x)` | from any integer width. As every widening, a signed source extends its sign: `uint128(-1)` is the largest value. `uint128OrNull(x)` is null below zero |
| `uint128Max()`, `uint128Words(...)` | 2^128 - 1; 4 `u32`s, most significant first, for a constant too big for a literal |
| `a.addChecked(b)`, `subChecked`, `mulChecked` | `uint128?`: null if it doesn't fit |
| `a.toU64()`, `toInt()`, `toU32()`, `toU16()`, `toU8()` | the low bits, as every narrowing |
| `a.toU64OrNull()`, `toIntOrNull()`, `toU32OrNull()`, ... | null if it doesn't fit. `toIntOrNull` fits below 2^63 |
| `a.toDecimal()`, `uint128FromDecimal(text)` | digits only: no sign, space or point; leading zeros are allowed; null otherwise, or above the range |
| `a.toHex()`, `uint128FromHex(text)` | `0x`, lower case, no leading zeros; reads with or without `0x`, in either case |
| `a.toBytes()`, `uint128FromBytes(bytes)` | 16 bytes, big-endian; reads up to 16, padding on the left |
| `a.toBytesLittleEndian()`, `uint128FromBytesLittleEndian(bytes)` | the same little-endian: the least significant byte first, and a short input padding at the top |
| `a.isZero()`, `a.bit(i)`, `a.bitLength()` | |

## What it doesn't do

- **Mix with other types.** `x + 1` and `x == 0` are `arithmetic.type` and `comparison.type`, as for vectors: `x + uint128(1)`.
  A literal too big for an `int` comes through `uint128Words` or `uint128FromHex`.
- **Keep secrets: it is not constant-time.** Its comparison and division take a time that depends on the value, as
  `uint256`'s do, and `tools/test-ct.sh` does not read it. A key belongs in `abla/ct` ([ct.md](ct.md): `secretU32`, `secretU64`)
  and the bignum helpers.
- **Cross an `@export`**, be the subject of a `when`, be a `Map` key (use `.toBytes()`), or go through `u64(x)` (use
  `x.toU64()`). All of these are as `uint256`'s ([uint256.md](uint256.md)).
- **Convert to the other wide types.** Go through a `u64`, or bytes.

## At compile time and on each target

`#` runs all of it with the same results as a program's. `WIDE_FULL=1 tools/test-wide-integers.sh COMPILER uint128` (`make test-wide-integers-full`; `make test` runs a quick version) runs it against JavaScript's
BigInt on fresh random values and edge values each time (every carry and edge), on
x86-64 (release, `--fast`, `-g` and `ablac run`), Wasm under Node, AArch64, RISC-V 32 and 64 and Xtensa, as
[uint256](uint256.md#on-each-target) does, with no C library.

A 128-bit division, and a variable shift off x86-64 and AArch64, is done at 256 bits in a small function of its own and narrowed:
at 128 bits they are calls to `__udivti3` and `__lshrti3`, which nothing here links. It is slower than a native 64-bit divide.
Multiplication is native on x86-64 and AArch64 and words elsewhere.
