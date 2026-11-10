# Constant-time code: what the compiler promises

Code that handles a secret must not let its timing depend on it. Two things can make it: the
source, by branching or indexing on a secret, and the compiler, which can turn arithmetic written to
avoid that back into a branch. `abla/ct` ([reference](stdlib/ct.md)) answers both, and
`tools/test-ct.sh` reads the generated code to check it. Results of ordinary tests can't show any of
this: a leaking function and a clean one return the same bytes.

## What it does

**In the source: types.** `secretU8`, `secretU16`, `secretU32` and `secretU64` are language types the
compiler knows by name. It gives them no comparison, conversion, division or text, and `if`, `when`,
indexing, a range, a `Map` key and `any` don't take them. Their only ways out are the operations of
`abla/ct`, which are arithmetic and masks, and `.declassify()`, which says in the source that this
value may be known from here on. Generic code can't compare them either. Each of these is a compile
error in `tests/cases/ct/invalid-*.ab`.

**In the optimizer: a barrier.** Every result of an operation on a secret passes through an inline
assembly statement with no instructions that claims to compute its output. LLVM can't see through it,
so it knows nothing about how a mask relates to a compare, and a mask and two ANDs stay what they are.
Without it LLVM recognizes `(x | -x) >> 31` as a compare, and mask-and-select as a `select`, which it may
lay out as a branch: the transformations are good ones, and only wrong here. On Wasm the barrier's the same
idea (`local.get; local.set`), and is gone after LLVM, so the masks are written in a form `wasm-opt`
doesn't recognize, which the test holds it to.

**On 32-bit targets: no 64-bit carries.** LLVM builds a 64-bit add, subtract or compare on Xtensa from
`bltu`, a branch on the data. The first run of the test found this. There `secretU64`'s `+`, `-`, `ctLt`
and `ctIsNonZero` work in 32-bit halves in plain arithmetic instead.

## What the test checks

`tools/test-ct.sh` builds `tests/cases/ct/fixture.ab` for each target and runs
`tools/ct/check-asm.py` over its disassembly: a forward dataflow from the secret parameters through
registers and stack slots, to a fixed point over the jumps. It fails on a conditional branch whose
condition is secret, a load or store whose address is, a division of one, a call it can't read (see
below), on Wasm a `select` on a secret, and code the disassembler can't read. The same script builds
deliberate leaks (a secret `if`, a secret table index, `memcmp` over secret memory, a division, a branch to a
trap, one a call down, a secret stored through a pointer inside a callee, and a twin of each generated crypto
fixture with a secret-indexed store) and fails if any target's check doesn't catch them, which is what keeps a
passing result meaningful. Pointers to secret memory remain marked through stack spills; unclassified
non-stack memory loads are conservatively secret. On Wasm, where linear-memory aliases aren't modeled, every
memory load is considered secret. These rules can reject safe code.

**Calls.** A call is read, not refused, when it goes to a function of the same object or module
(`--follow-calls`): the callee is checked on exactly the arguments the caller passes that it reads, what it
hands back is what its own analysis found, and the registers it may clobber are dead. This holds on all four
targets (x86-64 `call`, AArch64 `bl` and tail calls, Wasm `call` by function index, Xtensa `call4/8/12` named by
the object's relocations). A recursion, an indirect call, a call to something outside the object and a Wasm
import are still refused; the exceptions are `abla_platform_panic` (it ends the program, and must be given
nothing secret) and, on Xtensa, the compiler-rt arithmetic helpers (`__moddi3`, shifts and the like) with
public operands (a secret divisor, dividend or shift count is refused). Release builds inline most Abla
calls, so this matters most for the `--fast` build and for the crypto entry points, whose key schedules and
bignum helpers are `@noinline` workers read whole with the calls between them followed.

| Target | Read | Run |
|---|---|---|
| x86-64 | release object, `--fast` object | yes, here; values also checked with `--fast` |
| AArch64 | release object, `--fast` object | under qemu only |
| Wasm | the final module, after `wasm-opt`, and the `--fast` module | under Node |
| Xtensa (`-mcpu=esp32`) | release object, `--fast` object | **no**, nothing here runs it |

A `--fast` build keeps what release removes, so its findings are classed and pinned in
`tests/cases/ct/fast-known*.txt` (x86-64: the type-tag check of every erased scalar conversion and the divisions
by a secret that aren't strength-reduced; Xtensa: sixteen bignum fixtures whose unoptimised frames the checker
can't place, which the release read covers; AArch64 and Wasm: none). A finding not in the list fails, and so
does a listed fixture that comes out clean. Nothing in a `--fast` path is expected to add a branch on a
secret that release doesn't, but the release read is still the one that counts, so build secret code in
release.

**Residue.** `--residue` (x86-64, AArch64 and Xtensa objects) also fails an entry
that returns with a secret in a slot of its frame, or that gave a secret to a callee and did not wipe the
stack below it (`abla/ct/scrub`: the checker reads the callees' depth and the size of the wipe). The AES and
RSA private entry points and the password paths of `abla/crypto/pbe` wipe, and on x86-64 a run scan checks that
nothing is left below them (AArch64 and Xtensa are read, not run). Registers, the GC heap and Wasm are not covered.

On Xtensa the windowed ABI decides where a frame's registers go when the register file overflows (a deep call
chain, or any interrupt or task switch, which spills every live frame): a function's a0-a3 to the 16 bytes under
the stack pointer of the function it is calling, its a4-a7 (a4-a11 when it was called by `call12`) to the 16 (32)
above those, at the bottom of its caller's callee area. So the wipe stops 16 bytes under its own stack pointer
(those are the entry's a0-a3, which the return reloads), and the public `ctScrubStack*`, inlined into the entry, clears the 32 bytes above that from the entry
after the wipe returns. That reaches the whole wipe function's frame only if it is at most 32 bytes; the checker
reads the frame and finds the rest (a control with a 48-byte frame). The checker counts those save areas: a
callee's depth includes the 16 bytes under its stack pointer, and an entry holding a secret in a0-a3 across any call leaves it under that callee unless something
public is written over it. Not covered: an entry's own a4-a7 are kept, on an overflow, in its caller's frame, which
no wipe below the entry reaches (the checker takes every argument register of a secret-taking entry as secret, so
it can't tell when that matters); and an interrupt that arrives during the wipe pushes its frame under the
stack pointer, possibly over bytes already zeroed, with the interrupted registers (the wipe's own and the
entry's), not the work's, which had returned. That is assumed from the ABI, not measured on a device.

**On Xtensa the wipe is off unless the image turns it on.** An Xtensa stack has no guard page under it (an ESP32
FreeRTOS task has 3 to 8 KiB), so a wipe of its full size could run past the stack's end into whatever lies below.
There the wipe stops at the lowest address the image says it may write, and an image that says nothing gets no wipe
at all: the crypto entry points then leave their residue, with no error. The image gives the limit by defining, in C
or as an exported Abla function:

```c
uint32_t abla_ct_stack_low(void);   /* lowest address of the running stack the wipe may zero; 0: don't wipe */
```

It is linked weakly: an image that doesn't define it links, and its wipes do nothing (what Xtensa did before). The
wipe asks it once each time, from the task that wipes, so it can answer per task. For a FreeRTOS image: return 0
when `xPortInIsrContext()` (an interrupt runs on the interrupt stack, which the task's limit doesn't describe), else
`pxTaskGetStackStart(NULL) + 64`: the 64 bytes keep the wipe off the lowest bytes of the task's stack, where
FreeRTOS's overflow check keeps its fill pattern and ESP-IDF its end-of-stack watchpoint, either of which a zero there
would trip. For an image without a scheduler, its stack's low symbol (abla-embedded's ESP32-S3 boot:
`__abla_boot_stack_low`) plus the same margin, and 0 while the stack pointer is outside that stack. The checker reads
every Xtensa entry twice: as an image that defines it (`tests/cases/ct/residue-known-xtensa*.txt`) and as one that
doesn't (`residue-known-xtensa*-no-low.txt`: 32 of the 63 release entries are then unwiped; the rest used no more
than the 32 bytes the entry clears itself), so a clean read can't be taken for coverage an image doesn't have.
A clamped wipe still covers what the work used, which ran on the same stack, as long as the work stayed above the
limit: the stack needs the margin as headroom beyond its deepest use, or what lies in those last bytes stays. `--fast` objects are
read too: some unoptimised work goes deeper than the fixtures' 1024-byte wipe
(`tests/cases/ct/residue-known-xtensa-fast.txt`). The 32 bytes the entry clears itself are checked to lie within the
16 bytes under the frame of a function it has already called on every path, which the ABI guarantees is stack.

**Object pointers.** A spec can mark a parameter `%n`: a pointer to an object whose first 32 bytes (the header) are
public and whose payload is secret. The checker reads a header word at a constant offset as public, and anything else
through the pointer as secret. The tag lasts only while the register is untouched: a write, a call, or a merge with a
path that wrote it ends it, and storing a secret through any pointer in the function is refused. The crypto
modules allocate through one out-of-line entry (`abla/crypto/alloc`, a function in the section `.text.abla_ct_allocate`), which the checker does not
read (a release build inlines the ordinary allocator, whose branches depend on the heap's state): a call to it must be given a public size and returns a pointer to secret memory (the collector's block header lies below the returned pointer, so nothing at or above it is public). Both are the
mechanism and its hand-written controls (`tests/cases/ct/header-*.s`) for now, on x86-64, AArch64 and Wasm (the
entry) and on those and Xtensa (the pointer); real Wasm modules have no section to mark it yet; no real crypto entry is read through them yet, so they add no coverage
to the table above.

The fixtures are what is checked: `ctSelect`, `ctEq`, `ctLt`, `ctIsNonZero`, arithmetic and
`ctDifferenceAddress`, at the widths listed in the script, and what `abla/crypto` builds on them: AES's
bitsliced rounds and padding check, software GHASH, Montgomery multiplication, the exponent table's lookup and
the base 64 step ([what's protected, function by function](stdlib/security-and-dates.md#what-timing-protection-each-has-and-hasnt)).
Your own function isn't read unless you add it to such a test. The types stop you writing a leak in it;
they don't stop you declassifying.

## What can't be promised

- **The CPU's own instructions.** Nothing here is promised by hardware. Add, shift, multiply and logic
  are data-independent on the cores in use today by every published measurement, but no vendor promises
  it without a mode: Intel's DOITM and ARM's DIT must be set for that guarantee, and Abla doesn't set
  them. Multiplication is variable-time on some older and smaller cores (Cortex-M3, some PowerPC, early
  Atom), and Xtensa's `mull` and `muluh` have no published timing: that target is checked in the assembly
  and nothing more. Division isn't offered at all, because it varies nearly everywhere.
- **Wasm engines.** The module has no branch on a secret, and that is all that can be read. What V8 or
  another engine compiles it to is its own business: a baseline compiler and an optimizer may differ.
- **Speculation, power, and shared memory.** Spectre-style leaks, power and electromagnetic analysis, and
  fault injection are out of scope. So are things that look at the machine from outside (Hertzbleed-style
  frequency effects).
- **What surrounds the secret.** Lengths and public values aren't hidden. An allocation's timing and a
  collector's pause don't depend on a value's bits but do depend on sizes. Nothing wipes memory by itself: a secret
  stays in a string or an array until reused, and a spill the register allocator makes stays on the stack (see
  `abla/ct/scrub`, which the AES and RSA private entry points call to wipe the stack their work used). A boxed secret (in an array or a field) is copied in plain
  moves, which is fine for timing, and is one more copy.
- **Code outside the types.** A `string` or `u32` holding a secret has none of this. `.declassify()` ends it
  by design. The types are only as good as the code that puts a secret in them right away.
- **Compiler bugs.** The barrier stops LLVM reasoning about values. A pass that changes timing without
  reasoning about them, such as a future backend pass making a carry out of a branch as Xtensa's does,
  isn't stopped by it, only caught when it reaches a fixture.

LLVM has a `llvm.ct.select` proposal, which would give a stronger per-target promise for select itself. The
barrier is what works on all four targets with the LLVM in `shell.nix`.
