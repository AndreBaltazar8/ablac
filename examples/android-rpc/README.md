# Android discovered RPC action

This example uses the same late typed-call discovery model as `abla-mvc`. The
application and server action live together in [main.ab](main.ab):

```abla
@rpc
fun incrementCounter(current: int): int = current + 1

fun initialCounter: int = 0

fun counterApplication: int =
    $androidclick { incrementCounter(initialCounter()) }
```

The `$androidclick` parser extension records the call rather than looking up a
hard-coded function name. After ordinary name resolution and type checking, its
finalizer requires a resolved `@rpc (int) -> int` target and generates a typed
adapter. The build selects annotated actions generically and derives both sides
of the boundary; the generated server can compile only when the discovered call
has caused that adapter to exist:

- the Android library retains the call's argument provider but strips the
  unreachable server function and adapter;
- the generated Kotlin button sends that argument to the discovered endpoint;
- the native server contains the generated adapter and original action body.

[app.ab](app.ab) is only the JNI export root; both artifacts import the shared
application and action source from `main.ab`.

Changing the function name updates the client and endpoint automatically. An
invalid or non-`@rpc` click target fails during late typed finalization.

## Build and run

From the repository root:

```sh
nix-shell examples/android-rpc/shell.nix
make ablac
build/ablac build examples/android-rpc/build.ab \
  -o build/examples/android-rpc/build-driver --fast
build/ablac build examples/android-rpc/android_build.ab \
  -o build/examples/android-rpc/android-build-driver --fast
build/ablac build build/examples/android-rpc/server.ab \
  -o build/examples/android-rpc/rpc-server --fast
```

The three bounded invocations isolate generation, cross-target Android emission,
and hosted server emission. This avoids sharing target/evaluator state while the
compiler's nested mixed-target build queue is still experimental.

Start the generated server:

```sh
build/examples/android-rpc/rpc-server
```

The endpoint uses a deterministic identifier derived from the discovered source
call. Exercise it without Android using the generated manifest:

```sh
action=$(cat build/examples/android-rpc/rpc-action.txt)
curl -X POST \
  "http://127.0.0.1:18080/rpc/$action?current=41"
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
address. Cleartext HTTP is enabled only for this local example; a production RPC
extension should add TLS, authentication, serialization, and versioned errors.
