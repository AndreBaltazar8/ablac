# Android RPC counter

This example turns one annotated Abla function into a server endpoint and a
generated Android click handler. Pressing the button calls the server, which
increments the counter by running the original Abla function.

[actions.ab](actions.ab) is the single source of truth:

```abla
@rpc
fun incrementCounter(current: int, amount: int): int = current + amount
```

At compile time, [build.ab](build.ab) uses the imported `compiler` service to
inspect the annotation, function name, parameter names, and types. It then:

- generates a Kotlin client whose button sends the RPC;
- generates a typed HTTP adapter around the action;
- compiles that adapter and action into a native server executable;
- compiles [app.ab](app.ab) into the Android `libabla_app.so`.

The action body is not bundled into the APK. Android packaging remains in this
extension-owned build file rather than becoming compiler policy.

## Build and run

From the repository root:

```sh
nix-shell examples/android-rpc/shell.nix
make ablac
build/ablac build examples/android-rpc/build.ab \
  -o build/examples/android-rpc/build-driver --fast
```

Start the generated server:

```sh
build/examples/android-rpc/rpc-server
```

You can exercise the same endpoint without Android:

```sh
curl -X POST \
  'http://127.0.0.1:18080/rpc/incrementCounter?current=41&amount=1'
```

It returns `42`. In another terminal, package the Android application:

```sh
android-gradle -p build/examples/android-rpc assembleDebug bundleRelease
```

The outputs are:

- `build/examples/android-rpc/build/outputs/apk/debug/AblaRpcCounter-debug.apk`
- `build/examples/android-rpc/build/outputs/bundle/release/AblaRpcCounter-release.aab`

The generated client uses Android Emulator's `10.0.2.2` alias to reach port
`18080` on the development machine. A physical device needs a reachable server
address. Cleartext HTTP is enabled only to keep this local example small; a
real RPC extension should generate TLS, authentication, stable serialization,
timeouts, and versioned error contracts.
