# Android top-byte heap pointer audit

Status: device-free validation complete on the e58429b0 base; on-device validation remains separate.
The Mobile manifest workaround remains in place until NovaKind performs its
on-device gate. This is a TBI audit, not an MTE or HWASan certification.

## Address rules

A heap pointer stored in an Abla `int` is a bit pattern, not a positive number.
Android checks the allocator's top-byte tag when memory is returned, so the
runtime must retain the original pointer for loads, stores, copies, realloc and
free. It must not globally strip the high byte to make signed comparisons work.
See [Android's tagged-pointer contract](https://source.android.com/docs/security/test/tagged-pointers)
and the [AArch64 tagged-address ABI](https://www.kernel.org/doc/html/latest/arch/arm64/tagged-address-abi.html).

The collector keeps tagged addresses throughout its registry, free lists,
worklist and page directory. Their complete bit patterns are ordered as `u64`:
heap min/max, large-allocation heap sort and binary search, allocation membership
and interior-pointer extents. Extent subtraction is unsigned too, so a wrapped
large difference cannot become a negative length and accidentally match.
Page ordinals use `>>> 16`, while reconstruction by `page << 16` restores the
original tag. Returned header pointers are never untagged.

The RSA secret-buffer guards need a different comparison: two TBI addresses
with different public tag bytes may alias the same physical bytes. Only these
public extent/overlap calculations mask the top byte. They reject a zero base,
zero/invalid widths, wrap into the tag byte, and overlap, while leaving every
actual buffer access and release on its original pointer. Widths and addresses
are public; no secret-dependent branch is introduced. The source-generated CT
fixtures, including their excluded-source guards, remain authoritative.

## Audit map

| Source | Address assumption and action |
| --- | --- |
| `runtime/platform/host.ab`: tracked allocation | unsigned payload/end min/max |
| same: collection range sift/sort | unsigned full-address ordering |
| same: page-directory build and locate | logical address shifts; low-bit bitmap indexes remain ordinary nonnegative counts |
| same: locate and mark | unsigned bounds, binary search and unsigned subtraction; original tagged headers retained |
| `runtime/self/entry.ab`: object creation | descriptor validity means non-null, not positive |
| `crypto/rsa/entry.ab`: `bnSecretRangeValid`, `bnSecretDisjoint` | tag-independent public physical extents and alias rejection |
| `tls/hosted/entry.ab` | connection/listener handles are native control pointers; only `-1` denotes failed/closed, across drop, read, write, close, accept, port and timeout paths |
| `http/tls/entry.ab`, `websocket/tls/entry.ab` | same TLS sentinel instead of a sign check |
| `unsafe/memory/entry.ab`: `adoptNativeString` | already correctly uses `address != 0`; retain and exercise it |

The following similar-looking expressions were checked and deliberately left
alone:

- `CopyString`'s `storage > 0` is a **leaf length** when its `data != 0`, not a
  rope pointer. When `data == 0`, rope storage already uses `!= 0`.
- Host `owner >= 0 && owner < 48` distinguishes a small numeric layout/mark
  from a region descriptor pointer. Negative tagged region owners correctly
  take the region path.
- Array capacity's high-byte shift decodes a **kind/length word**, not an address.
- `place < 0`, field offsets/kinds, map entries, bitmap positions and counters
  are numeric descriptors, indexes or sentinels, not native pointers.
- Socket/file descriptors, PIDs, syscall results and compiler handles/indexes
  retain their signed error checks. They are distinct from TLS control pointers.
- Wasm's platform allocator uses bounded 32-bit linear-memory addresses. Its
  arithmetic and storage model are unchanged.
- Other native memory, hosted crypto and LLVM/ORC pointer-null checks use pointer
  null predicates or zero equality, not positivity.

Existing TLS test callers use the same `-1` convention; compiler-index tests
are unchanged. A consumer outside this repo that checks TLS `handle < 0` must
also change to `handle == -1` before enabling heap tags.

## Device-free regression

`tools/test-android-pointer-tags.sh` generates the private RSA implementation
from the actual selected sysroot's source and compiles a bare AArch64 object
using the production hosted runtime. The support assembly is derived from the
existing AArch64 crypto-test allocator, with asserted replacement boundaries.

Under `qemu-aarch64 -cpu max`, real heap loads/stores carry the pointer tags.
Allocations alternate `0xB4`, `0x54`, `0xF1`, `0x01`, or use a uniform `0xB4`.
The test covers adoption/slices/ropes, arrays/classes across collection,
small-object bitmaps, page-cache keys, growing hash/bitmap/range tables,
large/interior allocation lookup, tagged descriptors and secret-buffer division.
No copy of the collector algorithm substitutes for the production functions.

The bounded bump allocator checks that `free`/`realloc` receive exactly the tag
it returned, rejects repeated releases, and poisons released/moved allocation
bytes so a wrongly collected live value cannot survive in stale bump memory.
Deliberately stripped-tag free and realloc subprocesses must exit
66, proving the shim enforces this property. It does not recycle allocations;
this is a correctness test, not an allocator benchmark. Only the fixture's
kernel `write` stub strips a tag for the kernel boundary; heap operations don't.

A separate native TLS test calls an empty write on a synthetic negative handle.
That path has no OpenSSL call or control-pointer dereference, then restores `-1`
before dropping the resource. It tests the real TLS method rather than a copy
of its predicate. It does **not** claim tagged Android TLS transport interop.
Existing real TLS/HTTP/WSS tests still gate the normal native paths.

The manual CI input `android_pointer_tags_control=true` uses the same pinned
compiler against candidate and v0.2.47 sysroots. The candidate must pass; the
released sysroot must specifically fail TLS with 11, collector bounds with 24 and RSA
range validation with 41. Arbitrary build or emulator failures do not count as
negative-control success. Both release and fast output are checked.

## Verified device-free evidence

[CI 42169396786](https://github.com/AndreBaltazar8/ablac/actions/runs/42169396786)
passes all 14 candidate cases (seven each in release/fast, including the two
expected exit-66 tag-loss controls). With the released stdlib, the same fixtures
fail in both modes: TLS 11, collector unsigned bounds 24, descriptor SIGTRAP 133
and RSA 41. Positive tagged values and allocator refusal controls still pass in
the baseline, distinguishing intended bugs from a broken emulator.

`git diff v0.2.47 f5fd77b8` is empty for all audited runtime/crypto/TLS sources:
the released-stdlib negative arm also proves failure on this task's master base.
The CT source-fixture generator and its scaffold/leak controls pass unchanged;
none of the six excluded-source digests was re-pinned.

Compiler-host-only `ctNativeCheckedAddress` is outside this app-runtime fix.
It would need architecture-gated pointer handling if a tagged-heap ARM64 host
compiler ever ships. No Android-host compiler is currently shipped.

## Gate status

- [Full CI 42169555608](https://github.com/AndreBaltazar8/ablac/actions/runs/42169555608):
  Linux 324/324, including four-target CT checks, source guards and real TLS;
  macOS native host, iOS Simulator and compiler fixed-point checks all green.
- Local rebased stages 1, 2 and 3 are byte-identical:
  SHA256 `0cf8626ddc3e909cfb81952c720bc5a6155395c8467818fed9f552ed4b19ed16`.
  Stage-2/3 GNU-time peaks were 1,377,864 / 1,378,812 KiB.
- All 14 tagged-pointer cases also pass locally through the exact
  `build/ablac` launcher on the rebased stage-2 compiler.
- Source formatting, actionlint and the source-fixture/leak scaffold checks pass;
  excluded-source guard digests are unchanged.
- On-device Android validation and removal of Mobile's manifest workaround by
  NovaKind, separately; no device result is implied by emulation.
