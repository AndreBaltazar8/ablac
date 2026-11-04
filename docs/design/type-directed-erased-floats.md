# Type-directed float identity at erasure boundaries

Status: design approved; scalar-boundary phase (a) is implemented for review,
2026-11-04. Collection boundaries, formatting and JIT lifting remain open.
Before phase (a), native `any` boxes used the same integer tag and auxiliary
word for floats and integers. Phase (a) preserves scalar float kinds at the
covered boundaries; dynamic interpolation still formats their payload bits as
integers until phase (c). The interpreter retains the float kind. A
correct change must preserve float identity even when a value crosses an
unknown generic, indirect or separately compiled boundary.

## Representation and the boundary

Keep typed scalar operations, ABI, typed field payloads and dense typed arrays
as they are. Give an erased boxed float a discriminator in the existing
auxiliary word: 1 for `f32`, 2 for `f64`; integer values keep auxiliary zero.
These values are in the tag-2 namespace; closure function IDs use the separate
tag-5 namespace. Box copies preserve the header, and the auxiliary contains no
GC pointer. Preserve all float bits, including f32 payloads, signed zero
and NaNs. The earlier auxiliary and boundary audit chose these discriminators;
recheck the remaining uses as collection and JIT paths change. Equality and
hashing through `any` currently ignore the auxiliary word: keep that behavior
for this change, document it, and make a separate language-policy decision
before altering map keys or comparison.

Introduce an explicit IR operation for *typed-to-erased conversion*, emitted
only where the destination can observe a value as `any` or another erased
representation. Its inputs include the resolved source type. A scalar float
at that operation gets its corresponding discriminator; integer boxes and
ordinary typed float paths retain their current code. Erased-to-erased copies
copy the complete existing box, including the auxiliary word. A typed float
recovered from an erased value is unboxed normally; a subsequent erasure must
reapply its known type. A nullable float gets the discriminator only when its
tag indicates a present float; null retains its existing header. Do not infer
a float kind from the payload bits.

Find the boundaries in both semantic analysis and lowering: `any` locals,
arguments and returns; fields; array and map insertions and extraction;
conditionals and nullable values; indirect calls, interfaces and captures;
generic instantiations; reflection and runtime tables; and staged values.
Nominal float aliases follow their resolved underlying type. A generic body
may specialize only if its concrete type is actually proven. Unknown type
parameters and open-world/foreign inputs must conservatively preserve or
create the tag, with a proof that typed callers and adapters apply the same
contract. An effectful expression must be evaluated once, in the same order,
and the conversion must not change ownership or borrow provenance.

In particular, writing a float into `array<any>` or a map of erased values
must retain the tag; an `array<f64>` remains a dense array of eight-byte words.
When a typed field or typed dense array is read through a dynamically typed
interface, reconstruct the discriminator from reliable field/element type
metadata at the erasure boundary. A type descriptor or specialized boundary
adapter may be needed if existing metadata is insufficient. Do not globally
change integer/float array kinds or add a branch to every typed array access.
Mixed containers, resizing, generic stores, boxed fallbacks and GC tracing
need explicit validation. If an ambiguous container cannot prove a type,
keep each full boxed value rather than silently dropping its discriminator.

The proposed internal representation is not a stable external object ABI.
Version whole-object, partition, unit and compile-time caches or protocols as
appropriate. Internal Abla objects must be rebuilt with the compiler; the
public interface does not accept prebuilt internal Abla objects. C exports
keep their existing typed ABI and adapters are erasure
origins when they admit a float. Wasm's 32-bit layout and constant tables need
the same identity semantics without adding host imports.

## Demand-driven formatting and compile time

Dynamic formatting must call the existing float text formatter with the same
f32-to-f64 widening and spelling as static interpolation. Do not introduce an
unconditional formatter reference in the integer runtime. Discover a
conservative module-wide formatter demand from reachable erased-float origins
and reachable dynamic conversions, including callbacks, unknown dispatch,
foreign entry points and staged values. If flow is uncertain, retain the
formatter; never guess that an unknown value is an integer. A code-generation
unit or parallel partition must receive the same decision, and its cache key
must reflect it. Integer-only modules must have no formatter reference.

The interpreter already has float value kinds. Extend the native compile-time
JIT wire and lift so nested erased floats, not just statically typed results,
carry the discriminator across serialization and reconstruction. Run the
interpreter and native JIT explicitly, as well as native and Wasm runtime
paths, and compare them on ordinary values, f32 rounding, subnormals,
infinities, NaNs, negative zero and nested containers. Preserve hostless Wasm
import sets. This is a separate stage from introducing the representation;
phase boundaries must remain correct and independently testable.

## Acceptance gates and evidence

Use the same pinned compiler, source/sysroot, build mode and target for each
baseline/candidate pair; repeat measurements on one P-core and keep raw data.

* Integer-only programs outside generic array runtime: byte-identical output;
  no float formatter retained. Dense typed floats retain eight-byte payloads,
  and their layout and hot paths remain unchanged.
* Compare the 13 benchmark programs, JSON array workloads, and the abla-qr
  test bundle, with special scrutiny of QR, matrix and nbody. Target at most
  0.5% stripped size growth for realistic programs and runtime instructions
  within 0.3% of matched baseline; report build instructions as well. Do not
  accept a regression outside noise without lead review. Earlier exceptions
  for one prototype were matrix +0.54% and nbody +0.59% size; they do not
  automatically approve a new candidate. The rejected whole-module flag grew
  the QR O1 bundle 543,128 -> 551,512 bytes (+1.54%) and used 209.462 ->
  210.490 billion instructions (+0.49%, one pair).
* The matched abla-embedded package-import `pi.o` must be byte-identical to
  baseline for a program that does not format erased floats. Measure compiler
  and firmware peak RSS, preserving the firmware's 4 GB gate.
* Exercise native fast and release, Wasm, CT interpreter and JIT, generics,
  callbacks, closures, exports, field and array reflection, mixed containers,
  mutation, caches and GC stress; verify correct output and unchanged integer
  behavior. Use negative controls that fail against the old compiler. Check
  optimized output and self-rebuild stability in the normal integration gates.

Open questions before coding: the IR representation of generic conversions,
the metadata needed for reflective dense reads without slowing typed accesses,
and a sound reachability boundary for unknown producers. Prototype these on
small programs and report any lost type or budget failure before broadening
the change. The earlier global-flag prototype is retained separately as a
negative result, not an implementation to ship.
