# `abla/simd`

Fixed-width vectors and what the target has. The decisions and what is tested where are in
[../simd.md](../simd.md).

```abla
import "abla/io"
import "abla/simd"

fun main {
    val a = u32x4(1, 2, 3, 4)
    val b = u32x4Splat(10)
    println((a + b).text())
    println(a.lt(u32x4Splat(3)).select(a, b).text())
    println(u32x4Shuffle(a, b, 0, 4, 1, 5).text())
    println("${(a * a).sum()}")
}
// output:
// [11, 12, 13, 14]
// [1, 2, 10, 10]
// [1, 10, 2, 10]
// 30
```

## Types

`i8x16 i16x8 i32x4 i64x2 u8x16 u16x8 u32x4 u64x2 f32x4 f64x2` (128 bits) and
`i8x32 i16x16 i32x8 i64x4 u8x32 u16x16 u32x8 u64x4 f32x8 f64x4` (256 bits) and
`i8x64 i16x32 i32x16 i64x8 u8x64 u16x32 u32x16 u64x8 f32x16 f64x8` (512 bits).
Vectors work in locals, fields, arrays, maps, closures, generics, parameters, results,
and compile-time expressions (`#`). The C ABI boundary (`@export`) accepts scalar
arguments and results. A local is a register. A field, array element or capture
holds a copy of its bytes.

## Operations

`T` is the vector, `L` its lane type, `M` the unsigned vector of the same shape.

| | |
|---|---|
| `T(l0, l1, ...)`, `TSplat(l)` | make one. `u64` lanes need `u64(1)`, as a `u64` parameter does |
| `v.get(i)`, `v.with(i, l)` | a lane; a new vector with one changed. Out of range panics |
| `TLoad(data: string, offset = 0)` | from a string's bytes, any alignment; past its end panics |
| `v.bytes()` | its bytes as a string, lane 0 first, each lane little-endian |
| `TLoadAddress(address)`, `v.storeAddress(address)` | raw memory, trusted, any alignment |
| `v.text()` | `[1, 2, 3, 4]`, for reading. `"$v"` is refused |
| `+ - *`, unary `-` | lanewise; integers wrap |
| `/`, `.sqrt()` | floats |
| `.min(o)`, `.max(o)`, `.abs()` | lanewise; a float's are IEEE `minimum`/`maximum`, NaN if either is. `abs` isn't on unsigned lanes |
| `& \| ^ ~`, `.andNot(o)` | integers. `a.andNot(b)` is `a & ~b`. For floats go through `.asU32x4()` |
| `.addSat(o)`, `.subSat(o)` | integers, saturating |
| `<< n`, `>> n` | every lane by one count; a count outside the lane is zero; `>>` is arithmetic on signed lanes |
| `.rotl(n)`, `.rotr(n)` | integers; count modulo the lane's width |
| `.eq .ne .lt .le .gt .ge` | lanewise, gives `M`: all ones or all zeros. A float compare with NaN is false, but for `ne` |
| `m.select(a, b)` | per bit: `a` where `m` has ones, `b` elsewhere. Use it on `M`s from a compare, or any others |
| `.bitmask()` | each lane's top bit, lane 0 lowest, as an `int` |
| `m.any()`, `m.all()` | on unsigned vectors: any or all lanes' top bits are set |
| `.sum()` | the sum of the lanes; integers wrap |
| `TShuffle(a, b, i0, ...)` | a lane by literal index, `0...n-1` from `a` and `n...2n-1` from `b` |
| `.swizzle(indices)`, `.swizzle2(o, indices)` | select lanes at run time from this vector or from this vector followed by `o`. Indices have type `M`. Out-of-range indices give zero |
| `TGather(values: array<L>, indices: M)` | load one value per index into a lane. An out-of-range index panics |
| `.floor()`, `.ceil()`, `.trunc()`, `.roundEven()` | round each float lane toward negative infinity, positive infinity, zero, or nearest with ties to even |
| `.widenLow()`, `.widenHigh()` | extend the chosen half of an integer vector to lanes twice as wide, preserving signedness |
| `.narrowSaturating(o)` | pack this integer vector followed by `o` into lanes half as wide, clamping to the result lane's range |
| `.interleaveLow(o)`, `.interleaveHigh(o)`, `.reverse()` | common shuffles |
| `.asU8x16()` and so on | the same bits as another type of the same width |
| `.toF32x4()`, `.toI32x4()`, ... | numeric conversion; 32- and 64-bit lanes only. To integers it saturates, and NaN gives 0 |
| `v.low()`, `v.high()`, `TConcat(low, high)` | 256- or 512-bit vectors in halves. `u32x8Concat(a, b)` and `u32x16Concat(a, b)` |

For cross-width conversion, `i32x4.toF64x2Low()` and `i32x4.toF64x2High()`
select a half. `f64x2.toI32x4(other)` converts this vector followed by `other`.
When the lane counts match, `i32x4.toF64x4()` converts all lanes. Float-to-integer
conversions truncate and saturate, with NaN giving zero.

## What the target has

| | |
|---|---|
| `targetHas(feature)` | every CPU of the build's target has it; constant in the code: `sse2` on x86-64, `neon` on AArch64, `simd128` on Wasm |
| `cpuHas(feature)` | this CPU has it: `aes`, `clmul`, `avx2`, `sse41`, `ssse3`, `avx512f`, `avx512bw`, or what `targetHas` answers for |
| `simdTargetArch()` | `SIMD_ARCH_X86_64`, `SIMD_ARCH_AARCH64`, `SIMD_ARCH_WASM`, `SIMD_ARCH_XTENSA` or `SIMD_ARCH_OTHER`; constant in the code |

A feature's name that neither function knows panics.

## Target-specific operations

| | |
|---|---|
| `aesEncRound(state, key)`, `aesEncLastRound(state, key)` | one encryption round and the last, on `u8x16` |
| `aesDecRound(state, key)`, `aesDecLastRound(state, key)` | decryption, keys as the equivalent inverse cipher has them |
| `aesInvMixColumns(state)` | to turn an encryption key into a decryption one |
| `clmul(a, b, selector)` | carry-less product of a 64-bit lane of each `u64x2`; a literal: bit 0 picks `a`'s, bit 4 `b`'s |

These need a function marked `@target("aes")` or `@target("clmul")`, and `@target` code must be
reached only past a `cpuHas`: nothing checks that for you, and without the instruction the program
dies with an illegal instruction. On targets without them they trap.

```abla
import "abla/simd"

fun softwareLastRound(state: u8x16, key: u8x16): u8x16 = state ^ key // not really

@target("aes")
fun lastRound(state: u8x16, key: u8x16): u8x16 = aesEncLastRound(state, key)

fun oneBlock(state: u8x16, key: u8x16): u8x16 =
    if (cpuHas("aes")) lastRound(state, key) else softwareLastRound(state, key)
```

`@target` takes a comma-separated list and also allows AVX2 (`@target("avx2")`): 256-bit
operations in such a function can use YMM registers. Use `@target("avx512f")` or
`@target("avx512bw")` to enable the 512-bit x86 instructions, and check the matching
feature with `cpuHas` before the call. Other targets legalize the wider vector
into smaller vectors or scalar lanes. `@target` cannot be combined with `@inline`.

## Timing

Lane indexing, gathers and runtime table lookups may branch or perform indexed
loads. LLVM may rewrite operations such as `select`, and floating-point operations
can take longer on subnormals. See `abla/ct` for constant-time operations.
