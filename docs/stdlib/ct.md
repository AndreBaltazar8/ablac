# `abla/ct`

Secret integers, and operations on them that have no branch or memory index from the value. What's
promised and what isn't is in [../constant-time.md](../constant-time.md): read it before relying on this.

```abla
import "abla/io"
import "abla/ct"

fun main {
    val a = secretU32(7)
    val b = secretU32(9)
    val larger = ctSelect(ctLt(a, b), b, a)
    println("${larger.declassify()}")
    println("${ctEquals("token", "token")} ${ctEquals("token", "tokeN")}")
}
// output:
// 9
// true false
```

| | |
|---|---|
| `secretU8(x)`, `secretU16(x)`, `secretU32(x)`, `secretU64(x)` | make one from a value of that width |
| `s.declassify()` | the bits, public. After this the value can be branched on, and it isn't protected any more |
| `+ - *`, `& \| ^ ~` | wrapping arithmetic and logic. Both sides are secret: `s + secretU32(1)` |
| `s << n`, `s >> n`, `s.rotl(n)`, `s.rotr(n)` | shift by a **public** `int` count. `>>` is logical |
| `ctEq(a, b)`, `ctLt(a, b)` | a mask: all ones or zero. `ctLt` is unsigned |
| `ctIsZero(s)`, `ctIsNonZero(s)`, `ctFromLowBit(s)` | a mask |
| `ctSelect(mask, a, b)` | `a` where the mask has ones, `b` where it has zeros |
| `secretU32.widen()`, `secretU8.widen()` | to `secretU64` and `secretU32` |
| `secretU64.low()`, `.high()`, `secretU32.lowU8()` | a part |
| `ctEquals(a: string, b: string)` | whether they're equal, reading every byte. Different lengths are unequal at once: lengths aren't secret |
| `ctDifferenceAddress(a, b, count)` | trusted: a `secretU8` mask of whether `count` bytes at two addresses differ |

There is no division, no `==`, no `<`, no conversion to `int` and no text: they're compile errors, and so are
`if`, `when`, an index, a range or a `Map` key made from a secret, and passing one as `any`. A secret can be
held in a field, an array or a closure. Not at compile time, and not across an `@export`.
