BUILD_DIR := build
COMPILER := $(BUILD_DIR)/ablac
COMPILER_PAYLOAD := $(BUILD_DIR)/ablac.bin
COMPILER_ENTRY := src/orc_main.ab
COMPILER_SOURCES := $(shell find src stdlib -name '*.ab' -type f | sort) \
	tools/value-abi-probe.ab

SOURCE ?=
OUTPUT ?= $(BUILD_DIR)/program

.DEFAULT_GOAL := all

# Installs replace build/ablac and build/ablac.bin by a rename in the same
# directory, never by writing or unlinking in place, so a build running
# concurrently always finds a complete compiler. `ln -sfn` unlinks before it
# links; the launcher link is made beside it and renamed over it instead.
define install_launcher
	@if test "$$(readlink $(COMPILER) 2>/dev/null)" != \
		../tools/run-limited-compiler.sh; then \
		ln -sfn ../tools/run-limited-compiler.sh $(COMPILER).next.$$$$ && \
		mv -f $(COMPILER).next.$$$$ $(COMPILER); \
	fi
endef

.PHONY: all bootstrap ablac ablac-dev self-rebuild test test-full test-serial test-wide-integers-full check compile benchmark \
	benchmark-network clean prepare-test-driver

all: ablac

$(BUILD_DIR):
	mkdir -p $@

# A clean checkout starts with the checksum-pinned compiler release selected by
# tools/bootstrap-compiler.sh. It immediately rebuilds the current source graph,
# so src/*.ab remains the only compiler implementation in the repository.
$(COMPILER_PAYLOAD): $(COMPILER_SOURCES) tools/build-self-hosted-release.sh \
		tools/build-self-hosted-current.sh \
		| $(BUILD_DIR) tools/bootstrap-compiler.sh
	@if test ! -x $@; then tools/bootstrap-compiler.sh $@; fi
	$(install_launcher)
	tools/build-self-hosted-current.sh $@ $(BUILD_DIR)/.ablac-next $(COMPILER_ENTRY)
	@if test -s $(BUILD_DIR)/.ablac-next.ll; then \
		mv -f $(BUILD_DIR)/.ablac-next.ll $(BUILD_DIR)/ablac.ll; \
	else rm -f $(BUILD_DIR)/ablac.ll; fi
	mv -f $(BUILD_DIR)/.ablac-next $@

$(COMPILER): $(COMPILER_PAYLOAD) tools/run-limited-compiler.sh
	$(install_launcher)

bootstrap: | $(BUILD_DIR)
	@if test ! -x $(COMPILER_PAYLOAD); then \
		tools/bootstrap-compiler.sh $(COMPILER_PAYLOAD); \
	fi
	$(install_launcher)

ablac: $(COMPILER)

# Compiler-development loop: rebuild the current sources with --fast (skips the
# whole-module O2 pipeline, ~20s instead of ~3min). The result compiles programs
# several times slower than the release compiler, so ship with `make ablac`.
# Depends only on *a* compiler existing (bootstrap), never on rebuilding the
# release payload from the changed sources first.
ablac-dev: bootstrap
	ABLA_SYSROOT=$(CURDIR) $(COMPILER_PAYLOAD) build $(COMPILER_ENTRY) \
		-o $(BUILD_DIR)/ablac-dev --no-cache --fast

self-rebuild: ablac
	tools/test-pure-self-rebuild.sh $(COMPILER_PAYLOAD)

prepare-test-driver:
	tools/prepare-abla-test-driver.sh

# The suite below, several commands at a time (JOBS=N caps them; the default is
# the number of CPUs), one log each (tools/run-tests.sh). `make test-serial`
# runs it one command after another.
test: ablac
	tools/run-tests.sh $(COMPILER)

# Every script's builds for release: what a release must pass.
test-full: ablac
	RUN_TESTS_FULL=1 tools/run-tests.sh $(COMPILER)

# The wide integers' whole differential run (60,000 random cases on every target, release, GC stress): the default
# suite runs a quick one. `make test-full` runs it as well.
test-wide-integers-full: ablac
	for type in uint256 int256 uint128 int128; do WIDE_FULL=1 tools/test-wide-integers.sh $(COMPILER) $$type || exit 1; done

test-serial: ablac
	tools/test-repo-language-guard.sh
	tools/test-repo-language-guard-selftest.sh
	tools/test-run-limited.sh
	tools/test-libc-imports.sh $(COMPILER)
	tools/test-libsystem-imports.sh $(COMPILER)
	tools/test-libc-memory-routines.sh $(COMPILER)
	tools/test-darwin-syscalls.sh $(COMPILER)
	tools/test-darwin-routines.sh $(COMPILER)
	tools/test-futex-locks.sh $(COMPILER)
	tools/test-libc-jump-routines.sh $(COMPILER)
	tools/test-version.sh $(COMPILER)
	tools/test-coverage.sh $(COMPILER)
	tools/test-analysis-service.sh $(COMPILER)
	tools/test-frontend-analysis.sh $(COMPILER)
	tools/test-analysis-graph.sh $(COMPILER)
	tools/test-deep-logical.sh $(COMPILER)
	tools/test-compile-effect-path.sh $(COMPILER)
	tools/test-value-abi.sh $(COMPILER)
	tools/test-unsafe-mmio.sh $(COMPILER)
	tools/test-unsafe-stack-memory.sh $(COMPILER)
	tools/test-value-lifetimes.sh $(COMPILER)
	tools/test-overflow-fields.sh $(COMPILER)
	tools/test-value-arguments.sh $(COMPILER)
	tools/test-slot-alias.sh $(COMPILER)
	bash tools/test-scalar-default-unboxing.sh $(COMPILER)
	tools/test-unsafe-static-memory.sh $(COMPILER)
	tools/test-native-cstring-lifetime.sh $(COMPILER)
	tools/test-nominal-scalars.sh $(COMPILER)
	tools/test-tracked-language-fixes.sh $(COMPILER)
	tools/test-native-width-integers.sh $(COMPILER)
	tools/test-fixed-width-boxed-arithmetic.sh $(COMPILER)
	tools/test-closure-captures.sh $(COMPILER)
	tools/test-local-shadowing.sh $(COMPILER)
	tools/test-eval-steps.sh $(COMPILER)
	tools/test-eval-limit-config.sh $(COMPILER)
	tools/test-borrow-duplicates.sh $(COMPILER)
	tools/test-host-llvm-tools.sh $(COMPILER)
	tools/test-compiler-memory-peak.sh $(COMPILER)
	tools/test-borrow-lifetimes.sh $(COMPILER)
	tools/test-lambda-borrow-return.sh $(COMPILER)
	tools/test-inferred-affine-return.sh $(COMPILER)
	tools/test-lambda-null.sh $(COMPILER)
	tools/test-ownership-shadows-and-globals.sh $(COMPILER)
	tools/test-wasm-export-extern.sh $(COMPILER)
	tools/test-wasm-import-module.sh $(COMPILER)
	tools/test-wasm-float-remainder.sh $(COMPILER)
	tools/test-wasm-host.sh $(COMPILER)
	tools/test-wasm-panic-message.sh $(COMPILER)
	tools/test-release-scripts.sh $(COMPILER)
	tools/test-wasm-debug-reproducible.sh $(COMPILER)
	tools/test-rewritten-module-diagnostics.sh $(COMPILER)
	tools/test-build-removed-outputs.sh $(COMPILER)
	tools/test-build-killed.sh $(COMPILER)
	tools/test-value-slot-addresses.sh $(COMPILER)
	tools/test-build-same-process.sh $(COMPILER)
	tools/test-float-interpolation.sh $(COMPILER)
	tools/test-erased-float-boundaries.sh $(COMPILER)
	tools/test-erased-float-containers.sh $(COMPILER)
	tools/test-erased-float-extension.sh $(COMPILER)
	tools/test-erased-float-format.sh $(COMPILER)
	tools/test-compile-time-branch.sh $(COMPILER)
	tools/test-floating-point.sh $(COMPILER)
	tools/test-f32.sh $(COMPILER)
	tools/test-xtensa-test-tools.sh
	tools/test-xtensa-routing.sh $(COMPILER)
	tools/test-xtensa-assembly.sh $(COMPILER)
	tools/test-xtensa-catalog.sh $(COMPILER)
	tools/test-simd.sh $(COMPILER)
	tools/test-ct.sh $(COMPILER)
	python3 tools/ct-timing/test-stats.py
	tools/test-bignum-secret.sh $(COMPILER)
	tools/test-wide-integers.sh $(COMPILER)
	tools/test-wide-integers.sh $(COMPILER) int256
	tools/test-wide-integers.sh $(COMPILER) uint128
	tools/test-wide-integers.sh $(COMPILER) int128
	tools/test-array-truncate.sh $(COMPILER)
	tools/test-array-filled.sh $(COMPILER)
	tools/test-load-alias.sh $(COMPILER)
	tools/test-borrow-chain-scaling.sh $(COMPILER)
	tools/test-builder-chain.sh $(COMPILER)
	tools/test-collection-modes.sh $(COMPILER)
	tools/test-android-pointer-tags.sh $(COMPILER)
	tools/test-arrays-dense.sh $(COMPILER)
	tools/test-json-limits.sh $(COMPILER)
	tools/test-yaml.sh $(COMPILER)
	tools/test-gzip-inflate.sh $(COMPILER)
	tools/test-gzip-stream.sh $(COMPILER)
	tools/test-gzip-parity.sh $(COMPILER)
	tools/test-tar-reader.sh $(COMPILER)
	tools/test-tar-stream.sh $(COMPILER)
	tools/test-deep-json.sh $(COMPILER)
	tools/test-json-expressions.sh $(COMPILER)
	tools/test-json-literal-diagnostics.sh $(COMPILER)
	tools/test-generators-tasks.sh $(COMPILER)
	tools/test-generator-borrowed-container.sh $(COMPILER)
	tools/test-owned-container-loop.sh $(COMPILER)
	tools/test-map-temporary-loop.sh $(COMPILER)
	tools/test-discarded-affine-container.sh $(COMPILER)
	tools/test-resource-scope-drops.sh $(COMPILER)
	tools/test-shadowed-branch-types.sh $(COMPILER)
	tools/test-run-built.sh $(COMPILER)
	tools/test-jit-host-selection.sh $(COMPILER)
	tools/test-jit-object-cache.sh $(COMPILER)
	tools/test-jit-http.sh $(COMPILER)
	tools/test-string-helpers.sh $(COMPILER)
	tools/test-proc-self-exe.sh $(COMPILER)
	tools/test-any-text-validation.sh $(COMPILER)
	tools/test-any-text-panic.sh $(COMPILER)
	tools/test-compiler-stack.sh $(COMPILER)
	tools/test-fs-tree.sh $(COMPILER)
	tools/test-compile-time-floats.sh $(COMPILER)
	tools/test-eval-parity.sh $(COMPILER)
	tools/test-lang-parity.sh $(COMPILER)
	tools/test-null-compare.sh $(COMPILER)
	tools/test-int-text.sh $(COMPILER)
	tools/test-compile-time-depth.sh $(COMPILER)
	tools/test-import-precedence-diagnostics.sh $(COMPILER)
	tools/test-string-escapes.sh $(COMPILER)
	tools/test-text-blocks.sh $(COMPILER)
	tools/test-parse-errors-stop.sh $(COMPILER)
	tools/test-return-type-diagnostic.sh $(COMPILER)
	tools/test-diagnostic-hints.sh $(COMPILER)
	tools/test-defer-captures.sh $(COMPILER)
	tools/test-diagnostic-noise.sh $(COMPILER)
	tools/test-compile-time-lift.sh $(COMPILER)
	tools/test-lift-codec-closures.sh $(COMPILER)
	tools/test-compile-time-erased-floats.sh $(COMPILER)
	tools/test-formatter.sh $(COMPILER)
	tools/test-generic-close.sh $(COMPILER)
	tools/test-compile-time-diagnostics.sh $(COMPILER)
	PARITY_SET=probes PARITY_OUTPUT=$(BUILD_DIR)/compile-time-parity-probes tools/test-compile-time-parity.sh $(COMPILER)
	tools/test-scoped-region.sh $(COMPILER)
	tools/test-memory-promote.sh $(COMPILER)
	tools/test-region-extension-names.sh $(COMPILER)
	tools/test-null-default-leave.sh $(COMPILER)
	tools/test-exhaustive-when.sh $(COMPILER)
	tools/test-loop-control.sh $(COMPILER)
	tools/test-labeled-loops.sh $(COMPILER)
	tools/test-nullable-refinement.sh $(COMPILER)
	tools/test-callable-families.sh $(COMPILER)
	tools/test-field-shadowing.sh $(COMPILER)
	tools/test-global-names.sh $(COMPILER)
	tools/test-thread-globals.sh $(COMPILER)
	tools/test-compile-global-graph.sh $(COMPILER)
	tools/test-compile-eval-jit.sh $(COMPILER)
	tools/test-compile-eval-shared-state.sh $(COMPILER)
	tools/test-compile-eval-cross-target.sh $(COMPILER)
	tools/test-compile-eval-method-targets.sh $(COMPILER)
	tools/test-compile-eval-environment.sh $(COMPILER)
	tools/test-compile-eval-directory.sh $(COMPILER)
	tools/test-compile-native.sh $(COMPILER)
	tools/test-xtensa-interrupt-handler.sh $(COMPILER)
	tools/test-native-function-address.sh $(COMPILER)
	tools/test-native-initialize-globals.sh $(COMPILER)
	tools/test-internal-function.sh $(COMPILER)
	tools/test-overload-probe-filter.sh $(COMPILER)
	tools/test-doc-examples.sh $(COMPILER)
	tools/test-runtime-memory.sh $(COMPILER)
	tools/test-native-object-cache.sh $(COMPILER)
	tools/test-running-image-identity.sh $(COMPILER)
	tools/test-discovery-cache.sh $(COMPILER)
	tools/test-event-shutdown.sh $(COMPILER)
	tools/test-cache-dir.sh $(COMPILER)
	tools/test-ablac-test-bundle.sh $(COMPILER)
	tools/test-build-cache-build-program.sh $(COMPILER)
	tools/test-native-partition-cache.sh $(COMPILER)
	tools/test-lowered-ir-cache.sh $(COMPILER)
	tools/test-ir-finalization.sh $(COMPILER)
	tools/test-determinism.sh $(COMPILER)
	tools/test-compile-effects.sh $(COMPILER)
	tools/test-compiler-capture-process.sh $(COMPILER)
	tools/test-subparser-generated-adapter.sh $(COMPILER)
	tools/test-ct-bridge.sh $(COMPILER)
	tools/test-self-hosted.sh $(COMPILER)
	tools/test-inferred-results.sh $(COMPILER)
	tools/test-when-null.sh $(COMPILER)
	tools/test-init-order.sh $(COMPILER)
	tools/test-runtime-internal.sh $(COMPILER)
	tools/test-transform-targets.sh $(COMPILER)
	tools/test-extension-fields.sh $(COMPILER)
	tools/test-extension-receivers.sh $(COMPILER)
	tools/test-compile-time-scalars.sh $(COMPILER)
	tools/test-integer-narrowing.sh $(COMPILER)
	tools/test-array-remove-last.sh $(COMPILER)
	tools/test-path-home.sh $(COMPILER)
	tools/test-path-directory-mode.sh $(COMPILER)
	tools/test-path-file-mode.sh $(COMPILER)
	tools/test-open-nofollow.sh $(COMPILER)
	tools/test-secure-fs.sh $(COMPILER)
	tools/test-xtensa-companion-offline.sh $(COMPILER)
	tools/test-xtensa-native.sh $(COMPILER)
	tools/test-xtensa-http-stream.sh $(COMPILER)
	tools/test-process-pipeline.sh $(COMPILER)
	tools/test-runtime-checks.sh $(COMPILER)
	tools/test-float-integer-saturation.sh $(COMPILER)
	tools/test-named-method-arguments.sh $(COMPILER)
	tools/test-named-overloads.sh $(COMPILER)
	tools/test-ct-named-constructor.sh $(COMPILER)
	tools/test-map-resources.sh $(COMPILER)
	tools/test-map-growth.sh $(COMPILER)
	tools/test-string-equal.sh $(COMPILER)
	tools/test-definite-assignment.sh $(COMPILER)
	tools/test-shared-ownership.sh $(COMPILER)
	tools/test-mutex.sh $(COMPILER)
	tools/test-affine-move.sh $(COMPILER)
	tools/test-field-places.sh $(COMPILER)
	tools/test-compile-time-cell-capture.sh $(COMPILER)
	tools/test-hosted-network.sh $(COMPILER)
	tools/test-device-serial.sh $(COMPILER)
	tools/test-uuid.sh $(COMPILER)
	tools/test-regex.sh $(COMPILER)
	tools/test-native-platform-boundary.sh $(COMPILER)
	tools/test-math-no-libm.sh $(COMPILER)
	tools/test-math-fast.sh $(COMPILER)
	tools/test-reproducible-build.sh $(COMPILER)
	tools/test-reproducible-elsewhere.sh $(COMPILER)
	tools/test-inferred-receivers.sh $(COMPILER)
	tools/test-gc-stress.sh $(COMPILER)
	tools/test-generator-step.sh $(COMPILER)
	tools/test-compile-time-files.sh $(COMPILER)
	tools/test-compiler-service-slices.sh $(COMPILER)
	tools/test-module-incremental-state.sh $(COMPILER)
	tools/test-for-range.sh $(COMPILER)
	tools/test-for-constant-array.sh $(COMPILER)
	tools/test-generated-virtual-module.sh $(COMPILER)
	tools/test-global-array-mutation.sh $(COMPILER)
	tools/test-global-init-order.sh $(COMPILER)
	tools/test-http-client.sh $(COMPILER)
	tools/test-http-peer.sh $(COMPILER)
	tools/test-http-close-delimited.sh $(COMPILER)
	tools/test-http-interim.sh $(COMPILER)
	tools/test-http-request-scan.sh $(COMPILER)
	tools/test-http-header-lookup.sh $(COMPILER)
	tools/test-http-tls-deadline.sh $(COMPILER)
	tools/test-tls-faults.sh $(COMPILER)
	tools/test-tls-unix.sh $(COMPILER)
	tools/test-crypto.sh $(COMPILER)
	tools/test-crypto-pure.sh $(COMPILER)
	tools/test-crypto-hosted-keygen.sh $(COMPILER)
	tools/test-crypto-encrypted-rsa.sh $(COMPILER)
	tools/test-rsa-export.sh $(COMPILER)
	tools/test-rsa-keygen.sh $(COMPILER)
	tools/test-p256.sh $(COMPILER)
	tools/test-import-aliases.sh $(COMPILER)
	tools/test-linux-arguments.sh $(COMPILER)
	tools/test-linux-io.sh $(COMPILER)
	tools/test-linux-process.sh $(COMPILER)
	tools/test-linux-sleep.sh $(COMPILER)
	tools/test-linux-syscall.sh $(COMPILER)
	tools/test-aarch64-linux.sh $(COMPILER)
	tools/test-fork-heap.sh $(COMPILER)
	@if test "$$(uname -s)" = Darwin; then tools/test-macos-host.sh $(COMPILER); else echo "macOS host: skipped on $$(uname -s)"; fi
	tools/test-portable-io.sh $(COMPILER)
	tools/test-stable-native-symbols.sh $(COMPILER)
	tools/test-function-identities.sh $(COMPILER)
	tools/test-wrapper-demand.sh $(COMPILER)
	tools/test-target-descriptors.sh $(COMPILER)
	tools/test-ios-target.sh $(COMPILER)
	tools/test-ios-static-library.sh $(COMPILER)
	tools/test-ios-availability.sh $(COMPILER)
	tools/test-json-native-paths.sh $(COMPILER)
	tools/test-json-ascii-spans.sh $(COMPILER)
	tools/test-json-hex-quad.sh $(COMPILER)
	tools/test-json-utf8.sh $(COMPILER)
	tools/test-transactional-native-output.sh $(COMPILER)
	tools/test-typed-subparser-inspection.sh $(COMPILER)
	tools/test-unsafe-boundary.sh $(COMPILER)
	tools/test-wasm-gc.sh $(COMPILER)
	tools/test-wasm-ct-barrier.sh $(COMPILER)
	tools/test-fast-inline-cache.sh $(COMPILER)
	tools/test-any-eq-split.sh $(COMPILER)
	tools/test-any-float-literal.sh $(COMPILER)
	tools/test-ct-elvis-jump.sh $(COMPILER)
	tools/test-wasm-reclaim-limit.sh $(COMPILER)
	tools/test-wasm-export-roots.sh $(COMPILER)
	tools/test-repl.sh $(COMPILER)
	tools/test-android-extension.sh $(COMPILER)
	tools/test-android-link.sh $(COMPILER)
	tools/test-x64-library.sh $(COMPILER)
	tools/test-android-rpc-example.sh $(COMPILER)
	tools/test-hot-reload.sh $(COMPILER)
	tools/test-orc-session.sh $(COMPILER)
	tools/test-orc-http.sh $(COMPILER)
	tools/test-http-server.sh $(COMPILER)
	tools/test-graceful-reload.sh $(COMPILER)
	tools/test-direct-syscall.sh $(COMPILER)
	tools/test-emitted-value-runtime.sh $(COMPILER)
	tools/test-unbounded-exports.sh $(COMPILER)
	tools/test-programmable-build.sh $(COMPILER)
	tools/test-checked-export.sh $(COMPILER)
	tools/test-export-global-roots.sh $(COMPILER)
	tools/test-stm.sh $(COMPILER)
	tools/test-frame-closures.sh $(COMPILER)
	tools/test-wasm-mvc-extension.sh $(COMPILER)
	tools/test-initializer-evaluation.sh $(COMPILER)
	tools/test-math-v8.sh $(COMPILER)
	tools/test-math-v8-no-node.sh $(COMPILER)
	tools/test-interfaces.sh $(COMPILER)
	tools/test-action-journal.sh $(COMPILER)
	tools/test-managed-alias-files.sh $(COMPILER)
	tools/test-delegated-properties.sh $(COMPILER)
	tools/test-null-operators.sh $(COMPILER)
	tools/test-resource-temporaries.sh $(COMPILER)
	tools/test-transactions.sh $(COMPILER)
	tools/test-private.sh $(COMPILER)
	tools/test-strict-imports.sh $(COMPILER)
	tools/test-generics.sh $(COMPILER)
	tools/test-generic-ownership-origin.sh $(COMPILER)
	tools/test-octal-literals.sh $(COMPILER)
	tools/test-lazy-defaults.sh $(COMPILER)
	tools/test-named-generic-guard.sh $(COMPILER)
	tools/test-named-generic-default.sh $(COMPILER)
	tools/test-named-borrow-result.sh $(COMPILER)
	tools/test-named-affine-borrow.sh $(COMPILER)
	tools/test-transform-reuse.sh $(COMPILER)
	tools/test-serve-outputs.sh $(COMPILER)
	tools/test-shell-environment.sh $(COMPILER)
	tools/test-emit-reachable.sh $(COMPILER)
	tools/test-package-subpaths.sh $(COMPILER)
	tools/test-process-metrics.sh $(COMPILER)
	tools/test-dns-async.sh $(COMPILER)
	tools/test-websocket-tls-server.sh $(COMPILER)
	tools/test-commit-edits.sh $(COMPILER)
	tools/test-conformance-ir-cache.sh $(COMPILER)
	tools/test-builtin-names.sh $(COMPILER)
	tools/test-sidecar.sh $(COMPILER)
	tools/test-tool-object-cache.sh $(COMPILER)
	tools/test-native-cstring.sh $(COMPILER)
	tools/test-frontend-scaling.sh $(COMPILER)
	tools/test-frontend-locals-scaling.sh $(COMPILER)
	tools/test-stm-wasm-unwinding.sh $(COMPILER)
	tools/test-sysroot-path-symbols.sh $(COMPILER)
	tools/test-project-path-symbols.sh $(COMPILER)
	tools/test-frontend-call-chain-scaling.sh $(COMPILER)
	tools/test-recursive-class-types.sh $(COMPILER)
	tools/test-compiler-memory-budget.sh $(COMPILER_PAYLOAD)
	tools/test-gc-background-free.sh $(COMPILER)
	tools/test-json-differential.sh $(COMPILER)
	tools/test-fuzz-differential.sh $(COMPILER)
	tools/test-subparser-site-key.sh $(COMPILER)
	tools/test-subparser-named-arguments.sh $(COMPILER)
	tools/test-stable-names.sh $(COMPILER)
	tools/test-lambda-ordinal.sh $(COMPILER)
	tools/test-lazy-root-frames.sh $(COMPILER)
	tools/test-import-remap.sh $(COMPILER)
	tools/test-ownership-precision.sh $(COMPILER)
	tools/test-when-subject-owner.sh $(COMPILER)
	tools/test-elvis-container-loop.sh $(COMPILER)
	tools/test-elvis-field-owner.sh $(COMPILER)
	tools/test-elvis-borrow-argument.sh $(COMPILER)
	tools/test-drop-temporaries.sh $(COMPILER)
	tools/test-exit-temporary-defer.sh $(COMPILER)
	tools/test-extension-temporary-receiver.sh $(COMPILER)
	tools/test-operator-temporary-operands.sh $(COMPILER)
	tools/test-conditional-method-temporary.sh $(COMPILER)
	tools/test-ownership-doc-lifetimes.sh $(COMPILER)
	tools/test-when-temporary-condition.sh $(COMPILER)
	tools/test-when-affine-value.sh $(COMPILER)
	tools/test-default-temporary-owner.sh $(COMPILER)
	tools/test-default-shadow-helper.sh $(COMPILER)
	tools/test-local-root-liveness.sh $(COMPILER)
	tools/test-global-initializer-split.sh $(COMPILER)
	tools/test-gc-growth.sh $(COMPILER)
	tools/test-gc-lookup.sh $(COMPILER)
	tools/test-heap-allocator.sh $(COMPILER)
	tools/test-object-layout.sh $(COMPILER)
	tools/test-cache-layout-version.sh $(COMPILER)
	tools/test-held-o1.sh $(COMPILER)
	tools/test-codegen-units.sh $(COMPILER)
	tools/test-codegen-cache.sh $(COMPILER)
	tools/test-codegen-cache-race.sh $(COMPILER)
	tools/test-compiler-bitcode.sh $(COMPILER)
	tools/test-native-cache-failures.sh $(COMPILER)

check: test-full self-rebuild

compile: ablac
	@test -n "$(SOURCE)" || { \
		echo 'usage: make compile SOURCE=program.ab [OUTPUT=path]' >&2; \
		exit 2; \
	}
	mkdir -p $(dir $(OUTPUT))
	$(COMPILER) build $(SOURCE) -o $(OUTPUT)

benchmark: ablac
	tools/benchmark-selfhost.sh $(COMPILER)

benchmark-network: ablac
	mkdir -p $(BUILD_DIR)/benchmarks
	$(COMPILER) build tests/benchmarks/websocket-codec.ab \
		-o $(BUILD_DIR)/benchmarks/websocket-codec --fast --no-cache
	$(BUILD_DIR)/benchmarks/websocket-codec

clean:
	rm -rf -- $(BUILD_DIR)
