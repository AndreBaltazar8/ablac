# Numbers, bits and randomness

| Import | What it gives you |
|---|---|
| `abla/core` | `int.abs`, `int.sign` |
| `abla/math` | integer `min`/`max`/`clamp`; `f64` functions and constants |
| `abla/math/v8` | the same declarations as `abla/math`, with the results of JavaScript's `Math` in V8 |
| `abla/float` | conversions between integers and floats, and float bit patterns |
| `abla/float/text` | float formatting and parsing ([text.md](text.md#ablafloattext-floats-as-text)) |
| `abla/bits` | named bit operations (`bitAnd`, `bitShiftLeft`, ...) |
| `abla/integer` | `u32.countLeadingZeros()` |
| `abla/random` | cryptographically secure random bytes |

Integer arithmetic, widths and conversions are part of the language
([integers](../language.md#integers)). Everything here except
`abla/random` is pure arithmetic: it works on every target and gives the
same results at compile time.

## `abla/math`

```abla
import "abla/io"
import "abla/math"
import "abla/float/text"

fun main {
    println("${min(3, 7)} ${max(3, 7)} ${clamp(15, 0, 10)}")
    println("${sqrt(2.0)} ${pow(2.0, 10.0)} ${floor(-1.5)} ${ceil(-1.5)}")
    println("${sin(mathPi / 2.0)} ${atan2(1.0, 1.0) == mathQuarterPi} ${hypot(3.0, 4.0)}")
    println("${exp(1.0) == mathE} ${log(mathE)} ${lerp(0.0, 10.0, 0.25)} ${roundEven(2.5)}")
    println("${1.0 / fmin(0.0, -0.0)} ${fmax(-1.0, 0.0 / 0.0)}")
}
// output:
// 3 7 10
// 1.4142135623730951 1024 -2 -1
// 1 true 5
// true 1 2.5 2
// -Infinity NaN
```

| Function | Notes |
|---|---|
| `min(a, b)`, `max(a, b)`, `clamp(value, minimum, maximum)` | `int` |
| `fmin`, `fmax`, `fclamp`, `fabs` | the `f64` versions; `fmin` and `fmax` are IEEE 754 minimum and maximum: NaN if either argument is NaN, and `-0.0` below `0.0` |
| `sqrt`, `pow(x, y)`, `exp`, `log` | `log` is the natural logarithm; all four are correctly rounded (the double nearest the exact result); `pow` follows C's special cases, so `pow(x, 0.0)` and `pow(1.0, y)` are 1 even for a quiet NaN and `pow(-1.0, ±inf)` is 1 |
| `sin`, `cos`, `tan`, `atan`, `atan2(y, x)` | radians; all five are correctly rounded, for every finite argument however large |
| `floor`, `ceil`, `trunc`, `roundEven` | `roundEven` rounds halves to even; there is no other rounding mode |
| `hypot(x, y)`, `lerp(from, to, t)` | `hypot` is correctly rounded (the double nearest the exact root), never overflows or underflows on the way, and gives infinity when either argument is infinite, even if the other is NaN |
| `isNaN`, `isFinite` | |
| `mathPi`, `mathHalfPi`, `mathQuarterPi`, `mathTau`, `mathE`, `mathLn2` | constants |

The functions are implemented in Abla, so results are bit-for-bit identical
on every target and at compile time.

## `abla/math/v8`

`abla/math/v8` declares exactly what `abla/math` declares (every function with
its parameter names and types, every constant), and computes the results
Node 22's `Math` gives on x86-64: a program moves from one to the other by its
import alone. Use it where Abla code must agree with JavaScript to the bit, such
as a simulation that a browser replays in JavaScript.

```abla
import "abla/io"
import "abla/float/text"
import "abla/math" as correct
import "abla/math/v8" as v8

fun main {
    val nan = 0.0 / 0.0
    val inf = 1.0 / 0.0
    println("${correct.pow(1.0, nan)} ${v8.pow(1.0, nan)} ${correct.pow(-1.0, inf)} ${v8.pow(-1.0, inf)}")
    println("${correct.fmin(nan, 1.0)} ${v8.fmin(nan, 1.0)} ${1.0 / correct.fmin(-0.0, 0.0)} ${1.0 / v8.fmin(-0.0, 0.0)}")
    println("${correct.hypot(inf, nan)} ${v8.hypot(inf, nan)} ${v8.hypot(1e300, 1e300)}")
    println("${v8.sin(1e300)} ${v8.tan(1e10)} ${v8.pow(2.5, 3.1)}")
}
// output:
// 1 NaN 1 NaN
// 1 NaN Infinity -Infinity
// NaN Infinity 1.4142135623730952e+300
// -0.8178819121159085 -0.5583496378112418 17.12434728726902
```

- `sin`, `cos`, `tan`, `atan`, `atan2`, `exp`, `log` and `pow` are ports of
  V8's `src/base/ieee754.cc` (fdlibm 5.3 as V8 changed it), the argument
  reduction of huge angles included; `hypot` is V8's `Math.hypot` (scaled by
  the larger magnitude, Kahan-summed), and `fmin`/`fmax` are `Math.min` and
  `Math.max`. `sqrt`, `floor`, `ceil`, `trunc`, `fabs`, `isNaN` and `isFinite`
  are exact in both modules, and the constants are the same values.
- Where JavaScript and `abla/math` disagree, this module answers as JavaScript
  does: `pow(1, NaN)` and `pow(±1, ±inf)` are NaN; `fmin` and `fmax` return NaN
  when either argument is NaN and order -0 below +0; `hypot` of an infinity and
  a NaN is infinity, and it doesn't overflow before its result does.
- The functions without a JavaScript counterpart (`min`, `max`, `clamp`,
  `fclamp`, `lerp`, `roundEven`) are `abla/math`'s.
- The reference is V8's code as written, as Node 22.14 (V8 12.4.254.21) runs
  it on x86-64: no fused multiply-adds, and a correctly rounded `scalbn`. Node
  and browsers on Arm64 or macOS can differ from it by 1 ulp in about 0.07–0.1%
  of results (Node 22.14: 0.070% on Linux Arm64, 0.094% on macOS Arm64, over 16
  million cases), where the C compiler fuses multiply-adds in that code or the
  C library's `scalbn` truncates `pow`'s subnormal results. V8 built with
  Chromium's configuration computes `sin` and `cos` with a port of glibc's
  instead of fdlibm's, so browsers' `Math.sin` and `Math.cos` are not these.
  A NaN's payload is not part of the contract, as JavaScript doesn't show it.
- Like `abla/math`, the module uses only `+`, `-`, `*`, `/` and exact
  operations, so native, Wasm and compile-time results are the same bits.
  Angles beyond 2^19 · pi/2 reduce through scratch arrays in a
  [region](../regions.md), so no call leaves garbage behind.

`tools/test-math-v8.sh` checks both claims: the two modules' declarations,
read from the compiler, must match, and every function's results over a
seeded set of inputs (random bit patterns, each function's branch points and
their neighbours, huge, subnormal and special arguments) must have the bits
recorded from Node 22.14 on x86-64, natively at every optimization level, as
release and development WebAssembly, and under `#` in both tiers. It runs the
harness on Node 22.14 (`MATH_V8_NODE`, default
`~/.nvm/versions/node/v22.14.0/bin/node`) and checks its V8 version.

## `abla/float`

| Function | Converts |
|---|---|
| `f64FromInt(n)`, `f64ToInt(x)` | `int` and `f64` (`f64ToInt` truncates toward zero, saturates out-of-range values to the `int` limits, and gives 0 for NaN) |
| `f64ToF32(x)`, `f32ToF64(x)` | between float widths |
| `f32FromI32`, `f32FromU32`, `f32ToI32`, `f32ToU32` | between `f32` and 32-bit integers; `f32ToI32`/`f32ToU32` truncate toward zero, saturate and give 0 for NaN, like `f64ToInt` |
| `f64ToBits(x)`, `f64FromBits(n)`, `f32ToBits(x)`, `f32FromBits(n)` | to and from IEEE bit patterns |

```abla
import "abla/io"
import "abla/float"

fun main {
    val nan = f64ToF32(0.0 / 0.0)
    val big = f64ToF32(1.0e20)
    val small = f64ToF32(-1.0e20)
    println("${f32ToI32(nan)} ${f32ToI32(big)} ${f32ToI32(small)} ${f32ToI32(f64ToF32(-7.9))}")
    println("${f32ToU32(nan)} ${f32ToU32(big)} ${f32ToU32(small)}")
}
// output:
// 0 2147483647 -2147483648 -7
// 0 4294967295 0
```

The same values come out at run time and under `#`.

## `abla/bits` and `abla/integer`

`bitAnd`, `bitOr`, `bitXor`, `bitNot`, `bitShiftLeft`, `bitShiftRight` and
`bitShiftRightUnsigned` are named forms of `&`, `|`, `^`, `~`, `<<`, `>>`
and `>>>` on `int`. `abla/integer` adds `u32.countLeadingZeros()`, which
compiles to the processor's instruction.

## `abla/random`

```abla
import "abla/io"
import "abla/random"
import "abla/crypto"

fun main {
    val random = secureRandomBytes(16)
    if (random.succeeded) println("${random.bytes.size} bytes, ${hexEncode(random.bytes).size} hex digits")
}
// output:
// 16 bytes, 32 hex digits
```

`secureRandomBytes(count)` returns a `SecureRandomResult(bytes, succeeded,
errorCode)` with `count` bytes from the operating system's secure
generator (up to 1 MiB per call). It never falls back to a weaker source:
on failure `succeeded` is `false`. `abla/random/hosted` provides the same
function as `hostedSecureRandomBytes`. Compile-time code uses
`compilerRandomInteger` instead, which needs the `random` capability
([compile-time.md](../compile-time.md#capabilities-files-environment-processes-network)).
