# Android hello world

This example compiles [main.ab](main.ab) into an arm64 Android shared library,
generates a small JNI/Kotlin application around it, and packages that project as
an APK or Android App Bundle. The screen displays `Hello from Abla: 42`; the
number is returned by the Abla function through the generated native boundary.

The compiler only emits `libabla_app.so` and the declared integration files.
Android SDK, NDK, Kotlin, CMake, Gradle, and packaging remain owned by the
Android extension and its generated project.

## Build

From the repository root, enter the pinned Android development shell. The first
entry downloads the Android SDK/NDK components and requires accepting Google's
Android SDK licenses:

```sh
nix-shell examples/android/shell.nix
```

Build or verify the Abla compiler if needed, then generate the application and
its arm64 native library:

```sh
make ablac
build/ablac build examples/android/build.ab \
  -o build/examples/android/build-driver --fast
```

Package both forms with the pinned Gradle toolchain:

```sh
android-gradle -p build/examples/android assembleDebug bundleRelease
```

`android-gradle` is the shell's small Gradle wrapper. It selects the pinned,
Nix-compatible Android asset packager without committing a Gradle wrapper JAR.

The resulting files are:

- `build/examples/android/build/outputs/apk/debug/AblaHello-debug.apk`
- `build/examples/android/build/outputs/bundle/release/AblaHello-release.aab`

The debug APK is automatically signed with Gradle's development key. The
release AAB is a packaging proof; configure a private release signing key in the
generated project before uploading it to Google Play. All generated sources,
native libraries, Gradle state, APKs, and AABs remain under ignored `build/`.

The example currently targets arm64 devices running Android 7.0/API 24 or
newer. Additional Android ABIs belong in the Android extension's build graph,
not in `ablac`.
