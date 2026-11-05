# Native iOS targets

Implementation plan for the compiler-side iOS target. This document describes
work in progress; simulator execution is the acceptance gate, not object output.

## Build contract

`abla/ios/build` registers `ios-arm64` and `ios-arm64-simulator`, targeting
`arm64-apple-ios17.0` and `arm64-apple-ios17.0-simulator`. Registration returns
the target name for `buildProgram`. Each target uses Mach-O, libc and the
`apple-static` archive policy, without a hosted executable entry point.

`defineTargetSdk(name, sdk)` attaches one of `macosx`, `iphoneos` or
`iphonesimulator` to an already registered target. This metadata follows the
staged descriptor and participates in the target cache identity. SDK paths
come from `ABLA_APPLE_SDK_IPHONEOS` / `ABLA_APPLE_SDK_IPHONESIMULATOR`, or
`xcrun --sdk <name> --show-sdk-path` on macOS. Existing macOS targets retain
`ABLA_MACOS_SDK`. SDK-free object emission must not discover or compile an SDK
adapter; archive emission compiles the Darwin adapter with the same triple and
SDK, and archives it beside the Abla object.

The public C header is the export contract. The mobile host owns its checked
entry point, failure readers, platform callbacks and ABI version functions.
These are ordinary C support objects, not compiler intrinsics. Every support
object must be compiled for its destination slice before linking it with the
Abla archive. No Abla heap pointer crosses the mobile ABI.

## Platform restrictions

The iOS runtime must reject process execution, signal APIs, serial/device APIs
and runtime LLVM/JIT/ORC entry points with source-level diagnostics. Importing a
module or executing a permitted build-time compiler operation is not itself a
runtime use. Refusals therefore follow reachable runtime operations, including
calls introduced by lowering. Static archives must contain no LLVM/ORC code.
Darwin compatibility functions must also avoid APIs unavailable in iOS SDKs.

## Memory

The current libc-host runtime allocates its managed objects with malloc; it does
not reserve a large contiguous arena. Its 64 MiB collection pressure headroom is
arithmetic, not a virtual-memory mapping. The allocation registry's first growth
is 65,536 pointer slots (512 KiB); marking tables grow on demand. Measure process
VM and resident memory for the Simulator harness against an equivalent C
harness before adding a reserve setting. A new setting must control an actual
allocation or mapping, not merely rename GC pressure arithmetic.

## Validation sequence

1. Linux: device and simulator Mach-O objects, C-export symbols and exact
   LC_BUILD_VERSION platform values; invalid descriptor/SDK diagnostics.
2. macOS: compile the compatibility adapter and all mobile support for each
   slice; link a C harness and run the simulator slice using simctl; package the
   device/simulator archives with xcodebuild -create-xcframework and headers.
3. Reachable forbidden-operation negatives; native build-path compatibility,
   cache separation and no LLVM/ORC archive members.
4. Two-stage compiler fixed point, self-rebuild, full suite and NovaKind gate,
   followed by macOS CI. No Xcode or SDK download on the Linux development host.

## Apple references

- [XCFramework packaging](https://developer.apple.com/documentation/xcode/creating-a-multi-platform-binary-framework-bundle):
  use separate device and Simulator libraries with `-library` and `-headers`;
  do not combine the two platforms with lipo.
- [Extended Virtual Addressing entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.extended-virtual-addressing):
  this increases addressable space; it is distinct from the increased-memory-limit
  entitlement. This implementation must not depend on either entitlement.

A Simulator VM measurement is evidence about that harness, not a measurement of
physical-device memory limits. Record allocation/mapping deltas rather than
claiming a universal iOS address-space ceiling.
