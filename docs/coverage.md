# Documentation coverage

This table is for maintainers. It lists each language feature and library
area, where the compiler implements it, where it is documented, how good
that documentation is, and which tests exercise it. Update the row in the
same change that adds or changes a feature.

Quality: **good** = explained, with runnable examples checked by
`tools/test-doc-examples.sh`; **reference** = precise rules with only a
little example code; **mentioned** = named, not explained; **missing**.

Names starting `shell-` are entries of `tests/abla-tests.json` (run by the Abla test driver); the others are
`tools/test-*.sh` scripts.

Test scripts marked † run in no suite: neither the Makefile `test` target nor
`tests/abla-tests.json` runs them.

## Language

| Feature | Implemented in | Documented in | Quality | Tested by |
|---|---|---|---|---|
| Programs, `main`, exit status, `exit`, `panic` | `backend/llvm/exports.ab`, `stdlib/abla/process/exit` | [language.md#programs](language.md#programs) | good | shell-main-void, shell-process-exit |
| Comments, identifiers, keywords, contextual keywords | `lexer.ab`, `parser.ab` (`atContextualKeyword`) | [language.md#lexical-structure](language.md#lexical-structure) | good | shell-contextual-keywords |
| Line continuation (`+`, `-`, `.` at line start) | `parser.ab` `continueAdditiveExpression`, `continueMemberChain` | [language.md#lexical-structure](language.md#lexical-structure) | good | shell-line-continuation |
| Literals, string escapes, templates, multi-line strings | `lexer.ab`, `parser.ab` `bootstrapDecodeString` | [language.md#lexical-structure](language.md#lexical-structure) | good | shell-static-strings, test-string-escapes, test-float-interpolation, shell-interpolate-fixed-width, shell-string-plus |
| `val`/`var`, deferred `var` initialization, shadowing | `parser.ab` `parseLocal`, `sema.ab` | [language.md#values-and-variables](language.md#values-and-variables) | good | definite-assignment (native), test-local-shadowing, shell-module-shadowing |
| Integer widths, conversions, wrapping, shifts | `sema.ab` primitive casts, `ir.ab` `scalar.cast` | [language.md#integers](language.md#integers) | good | test-native-width-integers, test-fixed-width-boxed-arithmetic, test-bitwise-crypto |
| `f64`/`f32` | `lexer.ab`, `stdlib/abla/float` | [language.md#floating-point](language.md#floating-point), [stdlib/numbers.md](stdlib/numbers.md) | good | test-floating-point, test-compile-time-floats |
| Strings | `sema.ab` `string.*` | [language.md#strings](language.md#strings), [stdlib/text.md](stdlib/text.md) | good | test-string-helpers, shell-string-retention |
| Arrays (`append`, `truncate`, `clear`, `filledArray`) | `sema.ab`, `ir.ab` | [language.md#arrays](language.md#arrays) | good | test-array-filled, test-array-truncate, test-arrays-dense, test-collection-modes |
| `Map<K, V>` | `sema.ab` `map.*`, `ir.ab` | [language.md#maps](language.md#maps) | good | shell-map-basic, shell-map-collect, shell-map-compile-time, shell-map-differential |
| Nullable types and narrowing | `sema.ab` refinement | [language.md#nullable-types](language.md#nullable-types) | good | shell-narrowing-and-branches, test-nullable-refinement |
| Nominal `type X = int` | `parser.ab`, `sema.ab` | [language.md#nominal-types](language.md#nominal-types) | good | test-nominal-scalars |
| `void`, `never` | `sema.ab` divergence, `ir.ab` unreachable | [language.md#void-and-never](language.md#void-and-never) | good | test-exhaustive-when |
| Functions, defaults, named arguments | `parser.ab`, `module.ab` normalizer | [language.md#functions](language.md#functions) | good | test-named-default-arguments, shell-argument-diagnostics |
| Inferred result types | `sema.ab` | [language.md#functions](language.md#functions) (known issue) | good | — |
| Extension functions | `parser.ab` `parseDeclaration` | [language.md#extension-functions](language.md#extension-functions) | good | shell-line-continuation, test-nominal-scalars |
| Lambdas, trailing lambdas, closures | `parser.ab` `parseLambda`, `sema.ab` | [language.md#lambdas-and-closures](language.md#lambdas-and-closures) | good | test-closure-captures, shell-lambda-void-assignment |
| Classes, methods, properties | `parser.ab`, `sema.ab` | [language.md#classes](language.md#classes) | good | classes (native) |
| Interfaces | `parser.ab`, `sema.ab` (nominal only) | [language.md#interfaces](language.md#interfaces) | reference | overload-probe-filter |
| `abstract`, `constructor` keywords | being removed (they did nothing) | not documented | — | — |
| Delegated bindings `by`, `^name` | `parser.ab`, `sema.ab` | [language.md#delegated-bindings](language.md#delegated-bindings) | good | test-delegated-bindings |
| Overloads, `operator fun` | `overload.ab`, `parser.ab` | [language.md#overloads-and-operator-functions](language.md#overloads-and-operator-functions) | good | shell-overloads, test-overload-probe-filter |
| Operator precedence, compound assignment | `parser.ab` | [language.md#expressions-and-operators](language.md#expressions-and-operators) | good | shell-compound-assignment |
| `if`/`when`, exhaustiveness | `parser.ab`, `sema.ab` | [language.md#control-flow](language.md#control-flow) | good | test-exhaustive-when, exhaustive-when (native) |
| Loops, ranges, `break`/`continue`/`return` | `parser.ab`, `sema.ab` | [language.md#control-flow](language.md#control-flow) | good | test-for-range, test-loop-control, test-return-control |
| Imports, aliases | `module.ab` | [language.md#modules-and-imports](language.md#modules-and-imports) | good | test-import-alias, test-import-aliases, shell-module-shadowing |
| Contract imports | `module.ab`, `sema.ab` | [language.md#contract-imports](language.md#contract-imports) | reference | test-contract-imports |
| Source providers, packages | `package.ab` | [packages.md](packages.md) | reference | test-package-providers |
| Annotations `@export`, `@exportChecked`, `@inline`, `@noinline`, `@naked`, `@section`, `@wasmImport` | `sema.ab`, `ir.ab`, backend | [language.md#annotations](language.md#annotations), [llvm-backend.md](llvm-backend.md), [toolchain.md](toolchain.md) | good | test-wasm-export-extern, test-wasm-import-module, test-internal-function, test-xtensa-interrupt-handler |
| `trusted`, `extern` kinds, `noescape` | `parser.ab`, `sema.ab` | [language.md#trusted-native-implementations](language.md#trusted-native-implementations) | reference | test-unsafe-boundary, test-native-libraries |
| Native ABI, exports | backend | [language.md#native-declarations](language.md#native-declarations), [compiler-api.md](compiler-api.md) | reference | test-value-abi, test-native-cstring-lifetime |
| Inline assembly | `sema.ab`, `ir.ab` | [llvm-backend.md](llvm-backend.md), [subparsers.md](subparsers.md) | reference | test-internal-function, test-xtensa-interrupt-handler |
| Memory management, collection modes | runtime, `stdlib/abla/memory` | [language.md#memory-management](language.md#memory-management), [standard-library.md](standard-library.md) | reference | test-runtime-memory, shell-memory-checkpoint, shell-memory-drop-root |

## Ownership

| Feature | Implemented in | Documented in | Quality | Tested by |
|---|---|---|---|---|
| Parameter modes (borrow, `var`, `own`) | `sema.ab` | [ownership.md#parameters-borrow-var-and-own](ownership.md#parameters-borrow-var-and-own) | good | test-borrow-duplicates, shell-ownership-help |
| Aliases, `E_BORROW_CONFLICT` | `sema.ab`, `ir.ab` | [ownership.md#changing-objects-through-references](ownership.md#changing-objects-through-references) | good | test-borrow-lifetimes |
| Returning managed references, `borrow(name)` results | `sema.ab` | [ownership.md#returning-references](ownership.md#returning-references) | good | managed-return-global, managed-return-stored-global, test-borrow-lifetimes |
| `resource class`, `drop`, `move`, field and element moves | `parser.ab`, `sema.ab`, `ir.ab` drop helpers | [ownership.md#resources-values-with-one-owner](ownership.md#resources-values-with-one-owner) | good | test-affine-move, resource-drop (native), test-ownership-shadows-and-globals |
| Arrays of resources, `for (x in move(a))`, await on a borrowed task | `sema.ab` | [ownership.md#collections-of-resources](ownership.md#collections-of-resources) | good | test-generators-tasks |
| `Shared` views, `Borrow<T>`, `borrow(...)` results | `sema.ab` | [ownership.md#borrowed-views-and-borrow-results](ownership.md#borrowed-views-and-borrow-results) | good | test-borrow-lifetimes |
| `Cell`, `Shared`, `Weak`, `Mutex` | `sema.ab`, runtime | [ownership.md#sharing-cell-shared-weak-mutex](ownership.md#sharing-cell-shared-weak-mutex) | good | test-shared-ownership, test-mutex, interior-cell (native) |
| `Fn`/`FnMut`/`FnOnce`/`FnNoEscape`, `move { }` | `sema.ab` | [ownership.md#closures-and-ownership](ownership.md#closures-and-ownership) | good | test-callable-families, test-scoped-region |
| Regions | `parser.ab`, `sema.ab` | [regions.md](regions.md) | good | test-scoped-region, test-region-extension-names, scoped-region (native) |

## Compile time

| Feature | Implemented in | Documented in | Quality | Tested by |
|---|---|---|---|---|
| `#expression`, lifting results | `parser.ab`, `ir.ab` `bootstrapLowerCompile`, `ct_lift.ab` | [compile-time.md#expression](compile-time.md#expression) | good | test-compile-time-branch, test-compile-time-floats |
| `compile fun` | `parser.ab`, `sema.ab` | [compile-time.md#compile-fun](compile-time.md#compile-fun) | good | many compiler tests |
| Top-level actions, literal-only actions | `parser.ab`, `staged_parser.ab`, `backend.ab` | [compile-time.md#top-level-actions](compile-time.md#top-level-actions) | good | test-compiler-service-slices |
| `compile val`, `compile var` | `eval.ab` | [compile-time.md#compile-val-and-compile-var](compile-time.md#compile-val-and-compile-var) | good | compile-globals |
| Capabilities, `abla.toml`, `compilerGrant` | `sema.ab`, `module.ab`, `eval.ab` | [compile-time.md#capabilities-files-environment-processes-network](compile-time.md#capabilities-files-environment-processes-network) | good | test-compile-effects, test-compile-effect-path |
| Step limit, `ABLA_EVAL_STEP_LIMIT` | `eval.ab` | [compile-time.md#limits](compile-time.md#limits) | good | test-eval-steps |
| Declaration blocks | `parser.ab`, `sema.ab`, `eval.ab` | [compile-time.md#declaration-blocks](compile-time.md#declaration-blocks) | reference | test-independent-modules |
| `ABLA_COMPILE_EVAL` (interpreter / JIT) | in progress | — | missing | — |
| Compiler reflection, transforms, generated modules, exports | `eval.ab`, `stdlib/abla/compiler` | [compiler-api.md](compiler-api.md) | good (reflection, transforms, types run; generated modules reference) | compiler tests (69 files) |
| Subparsers `$name` | `subparser.ab`, `stdlib/abla/compiler/parser` | [subparsers.md](subparsers.md) | good (tutorial runs) | subparser tests (34 files) |
| Programmable builds | `toolchain.ab`, `stdlib/abla/build` | [programmable-builds.md](programmable-builds.md) | reference | test-programmable-build, test-target-descriptors |

## Concurrency

| Feature | Implemented in | Documented in | Quality | Tested by |
|---|---|---|---|---|
| `defer` | `parser.ab`, `sema.ab`, `ir.ab` | [concurrency.md#defer](concurrency.md#defer) | good | test-concurrency |
| Generators | `parser.ab`, `sema.ab`, runtime | [concurrency.md#generators](concurrency.md#generators) | good | test-concurrency, test-generators-tasks |
| Tasks, `await` | `sema.ab`, runtime | [concurrency.md#tasks](concurrency.md#tasks) | good | test-concurrency, test-generators-tasks |
| Threads | `sema.ab`, runtime | [concurrency.md#threads](concurrency.md#threads) | good | test-concurrency |

## Standard library

| Modules | Documented in | Quality | Tested by |
|---|---|---|---|
| `abla/text`, `abla/bytes`, `abla/float/text` | [stdlib/text.md](stdlib/text.md) | good | string-helpers, text-unicode, bytes, floating-text |
| `abla/io`, `abla/fs`, `abla/process/*` | [stdlib/system.md](stdlib/system.md) | good | portable-buffered-io, filesystem, fs-tree, process-capture, process-environment, process-exit, process-metrics |
| `abla/core`, `abla/math`, `abla/math/v8`, `abla/math/fast`, `abla/float`, `abla/bits`, `abla/integer`, `abla/random` | [stdlib/numbers.md](stdlib/numbers.md) | good | floating-math, stdlib, bits, math-v8, math-fast (`abla/integer`: none) |
| `abla/crypto`, `abla/date` | [stdlib/security-and-dates.md](stdlib/security-and-dates.md) | good | crypto, date |
| `abla/test`, `ablac test` | [stdlib/testing.md](stdlib/testing.md) | good | shell-ablac-test |
| `abla/json`, `abla/http/json` | [json.md](json.md) | good | json-subparser, json-expressions, runtime-json, test-json-limits |
| `abla/net`, `abla/net/hosted`, `abla/http/*`, `abla/websocket/*`, `abla/tls/hosted`, `abla/dns`, `abla/dns/async`, `abla/jwt` | [networking.md](networking.md) | good (HTTP routing, hosted sockets, RPC, SSE run; servers build-only) | linux-net, hosted-network, http-*, websocket-*, tls, jwt, dns-async |
| `abla/memory` | [standard-library.md](standard-library.md) | reference | runtime-memory-* |
| `abla/html` | [subparsers.md](subparsers.md) | mentioned | html-subparser |
| `abla/compression/gzip`, `abla/process/supervisor`, `abla/net/contracts` | [standard-library.md](standard-library.md) | mentioned | http-advanced, host-process-configured |
| `abla/unsafe/*`, `abla/sys/linux/*` | [standard-library.md](standard-library.md), [freestanding.md](freestanding.md) | reference | unsafe-*, linux-* |
| `abla/llvm/aot`, `abla/llvm/orc` | [standard-library.md](standard-library.md) | mentioned | — |

## Open documentation gaps

- `ABLA_COMPILE_EVAL` and compile-time native calls: to be documented when
  they land.
- Networking: `abla/websocket/event`, `abla/websocket/tls` and
  `abla/http/async` have prose and fragments but no runnable example.
- `abla/html`, `abla/compression/gzip`, `abla/llvm/*`.
- The compiler API: the raw-line helpers of the parser cursor
  (`parserRawLineRecordsValid`, `parserRawInsert*`, `parserRawGuardNestedEntries`,
  `parserRawWrapTopLevelRecord`), the generated-declaration builders, and
  annotation arguments, which can't be reflected yet.
- Programmable builds: the examples are fragments, because they build other
  programs for fixed targets.

## Test scripts still in shell

`tests/abla-tests.json` holds the build-and-run tests whose checks are an exit status, an exact output, fixed strings or
needles in order on one line, or a regular expression (`outputLineMatches`) on a line (`shell-*` entries). The other `tools/test-*` scripts stay shell for these reasons (each script
under its first matching reason, in this order):

- **fast** (82): built at `--fast` in the default suite through `tools/test-fast-builds.txt` (`run-tests.sh` sets `ABLA_TEST_FAST_BUILDS`); a driver entry gets the same by setting `ABLA_TEST_FAST_BUILDS=1` in its steps' environment (the `test-compile-time-branch` and `test-field-shadowing` entries do), but `make test-full` then builds them fast as well, so these stay scripts.
- **python** (79): drive a Python or Node helper (a server, a fixture generator, a checker) around the compiler.
  test-ablac-test-bundle, test-analysis-graph, test-analysis-service, test-android-extension, test-android-pointer-tags, test-android-rpc-example, test-any-text-panic, test-array-remove-last, test-arrays-dense, test-bignum-secret, test-codegen-cache-race, test-compile-time-erased-floats, test-compiler-service-slices, test-crypto-encrypted-rsa, test-crypto-pure, test-ct, test-determinism, test-device-serial, test-discovery-cache, test-erased-float-boundaries, test-erased-float-containers, test-erased-float-extension, test-erased-float-format, test-event-shutdown, test-for-constant-array, test-formatter, test-function-identities, test-generic-ownership-origin, test-http-client, test-http-close-delimited, test-http-interim, test-http-peer, test-http-request-scan, test-http-tls-deadline, test-lazy-defaults, test-macos-host, test-math-v8, test-named-generic-default, test-path-file-mode, test-process-pipeline, test-programmable-build, test-resource-scope-drops, test-rsa-keygen, test-running-image-identity, test-text-blocks, test-tls-unix, test-transactions, test-uint256, test-uuid, test-wasm-export-extern, test-wasm-export-roots, test-wasm-float-remainder, test-wasm-gc, test-wasm-host, test-wasm-import-module, test-wasm-mvc-extension, test-wasm-panic-message, test-wasm-reclaim-limit, test-wrapper-demand, test-xtensa-assembly, test-xtensa-routing, test-yaml, test-bootstrap-convergence-unit, test-bootstrap-convergence, test-codegen-cache-race, test-formatter, test-generic-ownership-origin, test-held-o1, test-ios-availability, test-macos-binary-comparison, test-project-path-symbols, test-tls-unix, test-xtensa-assembly, test-xtensa-catalog, test-xtensa-embedded-installed, test-xtensa-installed, test-xtensa-installer, test-xtensa-routing-installed, test-xtensa-routing
- **proc** (35): control processes or the environment: signals, `trap`, `sleep`, `timeout`, `ulimit`, temporary directories.
  test-array-filled, test-array-truncate, test-borrow-chain-scaling, test-build-cache-build-program, test-build-killed, test-builder-chain, test-compiler-memory-budget, test-compiler-stack, test-crypto-hosted-keygen, test-defer-captures, test-doc-examples, test-emit-reachable, test-graceful-reload, test-hot-reload, test-import-precedence-diagnostics, test-jit-http, test-jit-object-cache, test-json-literal-diagnostics, test-linux-process, test-linux-sleep, test-native-object-cache, test-native-width-integers, test-orc-http, test-package-subpaths, test-path-directory-mode, test-reproducible-build, test-return-type-diagnostic, test-runtime-memory, test-serve-outputs, test-string-escapes, test-tool-object-cache, test-tracked-language-fixes, test-transform-reuse, test-value-abi, test-xtensa-test-tools
- **loop** (77): run a `for` or `while` over cases, profiles or seeds, so one script is many builds.
  test-affine-move, test-any-text-validation, test-borrow-duplicates, test-build-removed-outputs, test-cache-dir, test-callable-families, test-collection-modes, test-compile-time-diagnostics, test-compiler-bitcode, test-compiler-memory-peak, test-ct-named-constructor, test-deep-logical, test-diagnostic-hints, test-diagnostic-noise, test-exhaustive-when, test-field-places, test-for-range, test-frontend-call-chain-scaling, test-frontend-locals-scaling, test-frontend-scaling, test-gc-background-free, test-generator-step, test-generic-close, test-generics, test-host-llvm-tools, test-init-order, test-initializer-evaluation, test-integer-narrowing, test-internal-function, test-ios-static-library, test-ios-target, test-jit-host-selection, test-json-differential, test-json-limits, test-labeled-loops, test-lambda-borrow-return, test-lambda-null, test-lambda-ordinal, test-lift-codec-closures, test-local-root-liveness, test-loop-control, test-managed-alias-files, test-map-resources, test-math-fast, test-math-no-libm, test-math-v8-no-node, test-mutex, test-named-affine-borrow, test-named-borrow-result, test-named-generic-guard, test-named-method-arguments, test-named-overloads, test-native-cache-failures, test-native-partition-cache, test-null-operators, test-nullable-refinement, test-octal-literals, test-ownership-shadows-and-globals, test-pure-self-rebuild, test-region-extension-names, test-reproducible-elsewhere, test-rsa-export, test-scalar-default-unboxing, test-scoped-region, test-shadowed-branch-types, test-shared-ownership, test-stable-names, test-strict-imports, test-subparser-site-key, test-sysroot-path-symbols, test-target-descriptors, test-unbounded-exports, test-unsafe-boundary, test-unsafe-mmio, test-unsafe-static-memory, test-value-slot-addresses, test-wasm-debug-reproducible
- **tool** (17): need other tools or text processing between steps (`opt`, `clang`, `sed`, `awk`, `cmp`, `diff`, `curl`, `nix-shell`).
  test-build-same-process, test-checked-export, test-definite-assignment, test-generated-virtual-module, test-global-array-mutation, test-lazy-root-frames, test-linux-arguments, test-linux-io, test-native-cstring-lifetime, test-native-initialize-globals, test-path-home, test-portable-io, test-rewritten-module-diagnostics, test-run-built, test-sidecar, test-typed-subparser-inspection
- **captured** (33): compare a program's output captured with `$(...)` in shell, usually with counts or several conditions.
  test-cache-layout-version, test-compile-time-depth, test-direct-syscall, test-extension-receivers, test-frontend-analysis, test-fs-tree, test-inferred-receivers, test-ios-package, test-ir-finalization, test-json-ascii-spans, test-lowered-ir-cache, test-orc-session, test-parse-errors-stop, test-recursive-class-types, test-shell-environment, test-stable-native-symbols, test-transactional-native-output, test-value-lifetimes, test-version, test-when-null, test-xtensa-interrupt-handler
- **regex** (1): check output with a regular expression (`grep -E`, character classes, anchors) the driver's fixed-string and in-order-line checks do not express.
  test-unsafe-stack-memory
