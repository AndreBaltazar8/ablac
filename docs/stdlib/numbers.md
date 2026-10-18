# Numbers, bits and randomness

| Import | What it gives you |
|---|---|
| `abla/core` | `int.abs`, `int.sign` |
| `abla/math` | integer `min`/`max`/`clamp`; `f64` functions and constants |
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
}
// output:
// 3 7 10
// 1.4142135623730951 1024 -2 -1
// 1 true 5
// true 1 2.5 2
```

| Function | Notes |
|---|---|
| `min(a, b)`, `max(a, b)`, `clamp(value, minimum, maximum)` | `int` |
| `fmin`, `fmax`, `fclamp`, `fabs` | the `f64` versions |
| `sqrt`, `pow(x, y)`, `exp`, `log` | `log` is the natural logarithm |
| `sin`, `cos`, `tan`, `atan`, `atan2(y, x)` | radians |
| `floor`, `ceil`, `trunc`, `roundEven` | `roundEven` rounds halves to even; there is no other rounding mode |
| `hypot(x, y)`, `lerp(from, to, t)` | |
| `isNaN`, `isFinite` | |
| `mathPi`, `mathHalfPi`, `mathQuarterPi`, `mathTau`, `mathE`, `mathLn2` | constants |

The functions are implemented in Abla, so results are bit-for-bit identical
on every target and at compile time.

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
