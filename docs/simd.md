# SIMD: design

Vectors are fixed-width values: `u32x4`, `f64x4`, `i8x32`. This file says what was decided
and why; [stdlib/simd.md](stdlib/simd.md) is the reference for using them.

## What other languages do, and what Abla takes

- **Rust `std::simd`** has `Simd<T, N>` with `Mask` types, operators where they are lanewise,
  `simd_eq` and friends for comparison, and leaves target-specific instructions to
  `std::arch` behind `#[target_feature]` and runtime checks (`is_x86_feature_detected!`).
  It passes vectors by reference across non-inlined calls, because a function's enabled
  features change how vectors are passed. Abla takes the operator rules, the split between
  portable and target-specific, `@target` with `cpuHas`, and the boundary rule.
- **Zig `@Vector`** gives any length as a primitive type and lanewise builtins (`==` on
  vectors gives a vector of bools). LLVM splits or scalarizes what the CPU lacks. Abla takes
  primitive types and leaning on LLVM's legalization, but only two widths.
- **C++ `std::simd`** ties width to the target by default (`native_simd`), which makes the size
  of a type depend on the build. Abla's types mean the same on every target.

## Decisions

**Types.** A lane type (`i8`...`u64`, `f32`, `f64`) and a count making 128 or 256 bits. They
are primitive names, known to the compiler (`src/simd_types.ab`), and no other width exists:
what a program does with them doesn't depend on the target, only how fast it is.

**Masks are ordinary unsigned vectors.** A comparison gives `u32x4` with all-ones or
all-zeros lanes, and `select` is bitwise: any bit pattern means something, there's one fewer
family of types, and this is what Wasm, NEON and AVX2 all have as their shape. Rust's and
Zig's masks catch mixing up lane widths, which `select`'s types still catch here.

**`==` is refused** (`simd.equality`): lanewise in Zig, whole-value in Rust. `.eq(...).all()`
says which.

**Representation.** In a function, a vector is an LLVM vector in the scalar plan, like any
scalar (`docs/llvm-backend.md`). Where a value goes boxed (a field, an array element, a capture,
a generic), it is a `string` of its 16 or 32 bytes: every boxed path already carries a string,
the collector knows it, and a program can't see it (`.bytes()` is how it gets those bytes).
Boxing allocates; arithmetic in locals and direct calls doesn't.

**Across a direct call a vector is an integer of its width** (`bootstrapLlvmDirectType`). A
vector parameter's registers depend on the features of the function it is compiled in, so
`@target("avx2")` code and a plain caller would disagree about a `u32x8`, silently. This is
the bug Rust's indirect passing exists to avoid. An integer's registers don't depend on them,
and LLVM removes the casts when it inlines. A call that isn't inlined pays for moving a
128-bit value in two general registers; that is the price, and only of a call that stays.
Vectors can't cross an `@export` (`simd.export`): there is no C ABI to keep to here.

**Operators.** `+ - * / & | ^ ~ << >>` are operator functions, in `abla/simd`, which needed
`and`, `or`, `xor`, `inv`, `shl` and `shr` added to the language's operator names and
`@inline operator fun` to parse. Mixed operands are refused, as they are for scalars: `a + 1`
needs a `Splat`.

**Shuffles take literal indices** (`simd.shuffle-index`), since LLVM's `shufflevector` needs a
constant and a wrapper function would hide it, so each `<type>Shuffle` is an intrinsic. A
variable-index shuffle (`pshufb`, `tbl`, `i8x16.swizzle`) isn't provided: it isn't portable
below SSSE3, and it would be the one operation here whose time on some targets depends on data.

**Shift counts** out of range give zero, as scalars' do; LLVM would call them poison, so a
variable count costs a compare and a select, which folds for a constant. Rotations take the
count modulo the width.

**Float lanes.** `min` and `max` are IEEE 754-2019 `minimum`/`maximum`: NaN if either is, and
`-0 < +0`. Conversions to integers saturate and NaN gives 0, as `f32ToI32` does. Rounding lanes
isn't provided yet: baseline x86-64 would call the C library (see `bootstrapLlvmTargetHasRoundingInstructions`).

**Asking what the target has.** Two questions, because they have different answers:

- `targetHas(feature)`: every CPU of this build's target has it, and the answer is a constant in
  the code: `sse2` on x86-64, `neon` on AArch64, `simd128` on Wasm. Nothing more, since the
  compiler always targets the baseline CPU.
- `cpuHas(feature)`: this CPU, now. CPUID (and XGETBV for AVX2) on x86-64, `ID_AA64ISAR0_EL1` on
  AArch64 (Linux emulates the read; on Apple's chips it's a constant, since all have them and the
  system forbids the read). Cached after the first call. False on Wasm and Xtensa.

**`@target("aes,clmul")`** lets LLVM use those instructions in one function, through its
`target-features` attribute, and LLVM won't inline it into a plain function. A target-specific
operation outside one is `simd.target-required`, instead of LLVM's "Cannot select". What stays
the programmer's job is to check `cpuHas` before calling it: the check can't be proved here,
and running AES-NI on a CPU without it is an illegal instruction, not a wrong answer. Features a
target doesn't have are ignored there, so the same source builds everywhere, and on those
targets the operation traps, which code behind `cpuHas` never reaches.

**Target-specific operations** have one meaning everywhere: `aesEncRound` is x86's `AESENC`, and
on AArch64 `AESMC(AESE(state, 0)) ^ key`, since AESE adds the key first. `clmul`'s selector is
PCLMULQDQ's. Key expansion has no operation: `AESKEYGENASSIST` has no ARM counterpart.

## Targets

| Target | Lowered to | Tested here |
|---|---|---|
| x86-64 | SSE2 at baseline; AVX2 and others under `@target`. A 256-bit vector without AVX2 is two 128-bit ones, by LLVM | **Run**: all checks, release and `--fast`, on this machine (an i9-13900K: AES, CLMUL, AVX2), and under `qemu-x86_64 -cpu qemu64`, which has none of them |
| AArch64 | NEON; 256-bit is two 128-bit | **Run under qemu only**, `-cpu max` and `cortex-a57`, from an object linked with a start of its own (no AArch64 executable target exists). Not run on real hardware. A CPU without AES couldn't be tested: `cpuHas` false is read but untried there |
| Wasm | SIMD128 when the program uses a vector: the module then needs an engine with it (all current ones) | **Run** under Node. A program with no vector gets no SIMD128 |
| ESP32-S3 (Xtensa) | **Scalar code.** LLVM legalizes vectors into lanes. The S3's PIE vector instructions aren't reachable: upstream LLVM has no intrinsics for them, and only Espressif's fork does | **Compiled only** to an object. Nothing here runs Xtensa, and no board is attached. Sound but slower than it looks: an `f64` lane is software float there, and 64-bit lanes are pairs |
| Others | Whatever LLVM legalizes to | Nothing |

## Not yet

Variable shuffles, lane rounding, widening and narrowing conversions, gathers, 512-bit vectors,
vectors at compile time (`#` is refused, by `compile.` errors: the evaluator has no vectors).
`targetHas` doesn't know about a build that raises the CPU, since no build can yet.
