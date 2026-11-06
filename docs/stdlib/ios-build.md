# iOS static libraries

`abla/ios/build` registers two libc/Mach-O library targets:

| Helper | Target name | LLVM triple |
| --- | --- | --- |
| `iosDeviceTarget()` | `ios-arm64` | `arm64-apple-ios17.0` |
| `iosSimulatorTarget()` | `ios-arm64-simulator` | `arm64-apple-ios17.0-simulator` |

Each helper returns the registered name. Register each target once, inside the
same compile-time build function that uses it. Keep the names in local variables;
a runtime global initialized with `#` can have its initializer evaluated again
when another compile-time expression reads that global.

Use `buildProgram(..., target, "static-library", ...)` to produce a `.a` with the
Abla object and its Darwin compatibility adapter. Both objects use the same
triple and SDK. Object-only emission for these non-hosted targets needs no SDK.
Existing hosted macOS targets retain their SDK requirements, including objects.

## SDK selection

The target helpers call `defineTargetSdk` with `iphoneos` or `iphonesimulator`.
On macOS, the compiler discovers the SDK with `xcrun --sdk NAME --show-sdk-path`.
An existing SDK can be selected explicitly with `ABLA_APPLE_SDK_IPHONEOS` or
`ABLA_APPLE_SDK_IPHONESIMULATOR`; the compiler does not download one. SDK selection
participates in the target and adapter cache identities. `ABLA_MACOS_SDK`
continues to select an SDK for the existing macOS targets.

Deployment targets are iOS 17.0. A newer SDK does not change that minimum.

## Export and package

Export functions through `abla/build`, and provide a C header matching their
foreign ABI. For example, an application library source can contain:

```abla fragment
import "abla/build"

fun answer(): int = 42
val exported = #exportFunction("answer", "abla_app_answer")
```

Its header declares `int64_t abla_app_answer(void)` and includes `<stdint.h>`.
Application-owned checked entry points, callbacks and other C support should be
compiled separately for each slice using that slice's triple and SDK. Do not
archive the same application support objects twice.

`iosCreateXcframework(output, slices, headersDirectory)` stages a packaging step.
Its bool means **accepted**, like `buildProgram`; the compiler runs `xcodebuild
-create-xcframework` only after all child programs build successfully. A packaging
failure fails the enclosing build. The output must end in `.xcframework`, slices
must be `.a` paths, and one invocation accepts at most 16 slices and 16 packaging
requests. Paths are bounded to 4 KiB. Device and Simulator libraries remain
separate, even though both have the arm64 architecture.

This complete example defines a build function. Invoke it with `#` from a macOS
build driver after creating `include/abla_app.h` and the application source.

```abla build
import "abla/build"
import "abla/ios/build"

compile fun buildIos(entry: string): bool {
    val device = iosDeviceTarget()
    val simulator = iosSimulatorTarget()
    val deviceLibrary = buildProgram(
        "app-ios", entry, "build/ios/device/libabla_app.a",
        device, "static-library", false, true
    )
    val simulatorLibrary = buildProgram(
        "app-ios-simulator", entry, "build/ios/simulator/libabla_app.a",
        simulator, "static-library", false, true
    )
    val package = iosCreateXcframework(
        "build/ios/App.xcframework",
        [
            "build/ios/device/libabla_app.a",
            "build/ios/simulator/libabla_app.a"
        ],
        "include"
    )
    deviceLibrary && simulatorLibrary && package
}

fun main(): int = 0
```

Packaging requires macOS and Xcode. Other hosts return false with the named
`E_IOS_XCFRAMEWORK_HOST` diagnostic. Imports and unused build functions do not run
packaging. `ablac run`, `serve` and `--emit-llvm` reject staged packaging, just as
they reject staged program builds; use `ablac build`.

The packaging step constructs a temporary XCFramework beside the output and
publishes it after success. A failed `xcodebuild` leaves an existing output intact.

## Validation and memory scope

The Simulator gate links a C harness, calls an exported Abla function, and keeps
an array live across collection under the existing `memorySetLimit` API. It
records startup virtual/resident-memory deltas after priming libc's allocation
zones. The host runtime uses malloc and growing registries, not a large reserved
arena; no new reserve setting is needed. These measurements concern the Simulator
harness, not physical-device memory limits. No extended-address entitlement is
added by the build helpers.

Static-library and Simulator inspection do not by themselves establish support
for every native stdlib API or constitute a physical-device test.
