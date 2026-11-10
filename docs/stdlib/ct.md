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

## `abla/ct/scrub`

The register allocator spills secrets into the red zone or a frame, and nothing clears them when a function returns.
An entry point that has called secret work calls one of these afterwards, and every frame the work used, which now
lies below the entry's stack pointer, is zeroed:

| | |
|---|---|
| `ctScrubStack512()`, `ctScrubStack1024()`, `ctScrubStack2048()`, `ctScrubStack4096()` | zero that many bytes below the stack pointer (`rep stosq` on x86-64, a store loop on AArch64 and Xtensa; nothing on Wasm). Each calls a function of its own, marked `noredzone`, so the caller has a call and keeps nothing in a red zone the wipe would hit. On Xtensa that function's wipe starts 16 bytes under its stack pointer (the caller's register save area), and the 32 bytes it can't reach are then cleared from the caller, into which each of these is inlined ([constant-time.md](../constant-time.md#what-the-test-checks)). On Xtensa, whose stacks have no guard page, the wipe stops at the address the image's `abla_ct_stack_low()` returns, and an image that doesn't define it doesn't wipe ([what to return](../constant-time.md#what-the-test-checks)). Not available at compile time: `#` on code that calls one is refused (`compile.effect-denied`), since there is no native stack to wipe and a silent no-op would claim a wipe that didn't happen |

Pick a size that reaches the deepest frame of the work. For the fixtures, `tools/test-ct.sh` reads the depth from the
assembly (the return address, pushes, frame, red zone and callees) and fails when a wipe is shorter. For the real entry
points it runs them with the 16 KiB below the stack pointer zeroed and fails if anything is left under the entry's own
frame and the few calls it makes after the wipe: AES at 128, 192 and 256 bits and a 64 KiB input, RSA at 2048, 3072 and
4096 bits, key generation, three plain runs and one with a collection at every safe point (`ABLA_GC_STRESS=1`). Each
entry runs once unmeasured first: a process's first call also initializes the runtime (a lazy CPU probe, the allocator),
which goes deeper and holds nothing secret. It only helps in the function that made the call: spills inside an inlined
body live in that function's own frame, which is why the work is `@noinline` and the wipe follows it. `abla/crypto/aes`
wipes 2048 bytes after its public encryption and decryption functions (measured work: about 800 bytes below the entry,
and deeper when a collection runs inside); `abla/crypto/rsa` wipes 4096 after signing, decryption, key generation, key
reading and export (about 3.4 KiB). One AES-GCM seal plus one AES-ECB call of one block through the public API costs
+1.9% instructions under valgrind, which counts every `rep` iteration, and no measurable wall time (-0.6%, within noise);
300 RSA-2048 signatures cost +1.1% wall (median; the minimum differs by -0.1%). Not covered: a callee that reads a secret
through a pointer it loads itself, the runtime's own frames when they are deeper than the wipe, and anything on a target
without a native stack.
