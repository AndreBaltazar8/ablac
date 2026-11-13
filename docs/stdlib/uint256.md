# `abla/uint256`

Unsigned 256-bit integers: EVM amounts and hashes. `uint256` is a type of the language, like `u64`;
what's done with it comes with the import.

```abla
import "abla/io"
import "abla/uint256"

fun main {
    val wei = uint256FromDecimal("1500000000000000000")
    if (wei == null) return
    val total = wei * uint256(3) + uint256(1)
    println("$total ${total.toHex()}")
    println("${total / uint256(1000000000)} ${total % uint256(10)} ${total > wei}")
    println("${uint256(0) - uint256(1) == uint256Max()} ${uint256(1) << 255 >> 254}")
    val fits = uint256Max().addChecked(uint256(1))
    println(if (fits == null) "doesn't fit" else "$fits")
    println("${uint256FromBytes(total.toBytes()) == total}")
}
// output:
// 4500000000000000001 0x3e73362871420001
// 4500000000 1 true
// true 2
// doesn't fit
// true
```

## Why a language type

Every integer width is one in Abla: known by name, a value in a register that a local, a call and a
return don't allocate for, with conversions by its name. `uint256` is the same, on the road already
taken by `u32x8`: an LLVM `i256` in a function's scalar plan, and 32 bytes of string data where a
value goes boxed (a field, an array element, a capture, a generic, a `T?`), as nothing wider than a
slot fits one. A stdlib class would have allocated each result, and couldn't have `==` or `<`.

Its operators are `operator fun`s in this module, and each is one LLVM instruction where the target
allows, so a program that doesn't import it has none of it: a hello program comes out the same byte
for byte. Its name is `uint256` because that's what's asked of it and what Solidity calls it.

## What it does

| | |
|---|---|
| `+ - * & \| ^ ~ -x` | wrap at 256 bits, as every fixed width's do and as the EVM's do; both sides must be `uint256` |
| `/ %` | unsigned; by zero is the language's panic, `division by zero`, exit 101 |
| `<< >>` | a count of any integer type; negative or at least 256 gives zero. `>>` is logical. `a.shl(b)` and `a.shr(b)` take a `uint256` count, as the EVM's SHL and SHR |
| `== != < <= > >=` | both sides `uint256` |
| `"$x"` | decimal, as any integer |
| `uint256(x)` | from any integer width. As every widening, a signed source extends its sign: `uint256(-1)` is the largest value. `uint256OrNull(x)` is null below zero |
| `uint256Max()`, `uint256Words(w7, ..., w0)` | 2^256 - 1; eight `u32`s, most significant first, for a constant too big for a literal |
| `a.addChecked(b)`, `a.subChecked(b)`, `a.mulChecked(b)` | `uint256?`: null if it doesn't fit |
| `a.toU64()`, `toInt()`, `toU32()`, `toU16()`, `toU8()` | the low bits, as every narrowing |
| `a.toU64OrNull()`, `toIntOrNull()`, `toU32OrNull()`, `toU16OrNull()`, `toU8OrNull()` | null if it doesn't fit. `toIntOrNull` fits below 2^63 |
| `a.toDecimal()`, `uint256FromDecimal(text)` | digits only: no sign, space or point; leading zeros are allowed; null otherwise, or above the range |
| `a.toHex()`, `uint256FromHex(text)` | `0x`, lower case, no leading zeros, as a JSON-RPC quantity; reads with or without `0x`, in either case |
| `a.toBytes()`, `uint256FromBytes(bytes)` | 32 bytes, big-endian, an EVM word; reads up to 32, padding on the left |
| `a.toBytesLittleEndian()`, `uint256FromBytesLittleEndian(bytes)` | the same little-endian: the least significant byte first, and a short input padding at the top |
| `a.isZero()`, `a.bit(i)`, `a.bitLength()` | |

## What it doesn't do

- **Mix with other types.** `x + 1` and `x == 0` are `arithmetic.type` and `comparison.type`, as for vectors:
  `x + uint256(1)`. A literal too big for an `int` comes through `uint256Words` or `uint256FromHex`.
- **Keep secrets: it is not constant-time.** Its comparison and division take a time that depends on the value, and
  `tools/test-ct.sh` does not read it. A key belongs in `abla/ct` ([ct.md](ct.md): `secretU32`, `secretU64`) and the
  bignum helpers.
- **Cross an `@export`** (`simd.export`), be the subject of a `when` (`secret.when`: use `if`), or be a `Map`
  key (use `.toBytes()`). `u64(x)` doesn't take one: `x.toU64()`. All of these are as vectors have it.
- **Lend a `type Wei = uint256` its operators.** It converts as any nominal scalar does, `Wei(x)` in and
  `val x: uint256 = wei` out; arithmetic, comparison and methods are the `uint256`'s, on that `x`.
- **Mean anything unsigned in another width.** The others are [`uint128`](uint128.md), [`int256`](int256.md) and [`int128`](int128.md), each a type and a module of its own; none converts to another implicitly.

## At compile time

`#` runs all of it, with the same results as a program's: the evaluator has a value of 32 bytes for it, and a
`uint256` it hands the program is those bytes. `/` by zero is `E_EVAL_DIVISION_BY_ZERO`.

## On each target

`WIDE_FULL=1 tools/test-wide-integers.sh` (`make test-wide-integers-full`; `make test` runs a quick version) runs it against JavaScript's BigInt on fresh random values and edge values each
time, without a C library:

| Target | How it's run | What it calls |
|---|---|---|
| x86-64, AArch64 | natively, under qemu | nothing |
| Wasm | under Node | nothing: a program using this has its own `__multi3`, for the wide `mul` LLVM makes |
| Xtensa (`-mcpu=esp32`) | under qemu (dc232b), without `mul32high` because it has none; built with it too | nothing for arithmetic |
| RISC-V 32 and 64 | under qemu | without the M extension, which ablac's RISC-V code doesn't assume, libgcc's `__muldi3`, `__mulsi3`, on 64 bits `__multi3`, and on 32 bits the shifts `__ashldi3` and `__lshrdi3` (and `__ashrdi3` for the signed types): what a `*` or a `u64` shift calls there anyway. They aren't libc |

Multiplication is `i256`'s `mul` on x86-64 and AArch64 and 36 word products elsewhere. Division is LLVM's
expansion to a shift-and-subtract loop, one for `/` and one for `%`, each once in a program (about 2 KB on Xtensa).
`toDecimal` calls both, nine digits at a time.
