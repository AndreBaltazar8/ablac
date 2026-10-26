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

.PHONY: all bootstrap ablac ablac-dev self-rebuild test test-serial check compile benchmark \
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
	mv -f $(BUILD_DIR)/.ablac-next.ll $(BUILD_DIR)/ablac.ll
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

test-serial: ablac
	tools/test-version.sh $(COMPILER)
	tools/test-analysis-service.sh $(COMPILER)
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
	tools/test-native-width-integers.sh $(COMPILER)
	tools/test-fixed-width-boxed-arithmetic.sh $(COMPILER)
	tools/test-closure-captures.sh $(COMPILER)
	tools/test-local-shadowing.sh $(COMPILER)
	tools/test-eval-steps.sh $(COMPILER)
	tools/test-borrow-duplicates.sh $(COMPILER)
	tools/test-borrow-lifetimes.sh $(COMPILER)
	tools/test-narrowing-and-branches.sh $(COMPILER)
	tools/test-line-continuation.sh $(COMPILER)
	tools/test-ownership-shadows-and-globals.sh $(COMPILER)
	tools/test-wasm-export-extern.sh $(COMPILER)
	tools/test-wasm-import-module.sh $(COMPILER)
	tools/test-wasm-debug-reproducible.sh $(COMPILER)
	tools/test-rewritten-module-diagnostics.sh $(COMPILER)
	tools/test-build-removed-outputs.sh $(COMPILER)
	tools/test-value-slot-addresses.sh $(COMPILER)
	tools/test-build-same-process.sh $(COMPILER)
	tools/test-float-interpolation.sh $(COMPILER)
	tools/test-compile-time-branch.sh $(COMPILER)
	tools/test-floating-point.sh $(COMPILER)
	tools/test-array-truncate.sh $(COMPILER)
	tools/test-array-filled.sh $(COMPILER)
	tools/test-memory-checkpoint.sh $(COMPILER)
	tools/test-memory-drop-root.sh $(COMPILER)
	tools/test-collection-modes.sh $(COMPILER)
	tools/test-arrays-dense.sh $(COMPILER)
	tools/test-json-limits.sh $(COMPILER)
	tools/test-deep-json.sh $(COMPILER)
	tools/test-json-expressions.sh $(COMPILER)
	tools/test-json-literal-diagnostics.sh $(COMPILER)
	tools/test-string-plus.sh $(COMPILER)
	tools/test-string-retention.sh $(COMPILER)
	tools/test-process-exit.sh $(COMPILER)
	tools/test-main-void.sh $(COMPILER)
	tools/test-generators-tasks.sh $(COMPILER)
	tools/test-resource-scope-drops.sh $(COMPILER)
	tools/test-run-built.sh $(COMPILER)
	tools/test-jit-host-selection.sh $(COMPILER)
	tools/test-jit-object-cache.sh $(COMPILER)
	tools/test-jit-http.sh $(COMPILER)
	tools/test-module-shadowing.sh $(COMPILER)
	tools/test-string-helpers.sh $(COMPILER)
	tools/test-proc-self-exe.sh $(COMPILER)
	tools/test-date.sh $(COMPILER)
	tools/test-interpolate-fixed-width.sh $(COMPILER)
	tools/test-contextual-keywords.sh $(COMPILER)
	tools/test-lambda-void-assignment.sh $(COMPILER)
	tools/test-process-environment.sh $(COMPILER)
	tools/test-compiler-stack.sh $(COMPILER)
	tools/test-ablac-test.sh $(COMPILER)
	tools/test-ownership-help.sh $(COMPILER)
	tools/test-fs-tree.sh $(COMPILER)
	tools/test-compile-time-floats.sh $(COMPILER)
	tools/test-compile-time-depth.sh $(COMPILER)
	tools/test-compile-time-arguments.sh $(COMPILER)
	tools/test-import-precedence-diagnostics.sh $(COMPILER)
	tools/test-string-escapes.sh $(COMPILER)
	tools/test-parse-errors-stop.sh $(COMPILER)
	tools/test-return-type-diagnostic.sh $(COMPILER)
	tools/test-diagnostic-hints.sh $(COMPILER)
	tools/test-region-escape-operators.sh $(COMPILER)
	tools/test-diagnostic-noise.sh $(COMPILER)
	tools/test-compile-time-lift.sh $(COMPILER)
	tools/test-compile-time-diagnostics.sh $(COMPILER)
	PARITY_SET=probes PARITY_OUTPUT=$(BUILD_DIR)/compile-time-parity-probes tools/test-compile-time-parity.sh $(COMPILER)
	tools/test-scoped-region.sh $(COMPILER)
	tools/test-region-extension-names.sh $(COMPILER)
	tools/test-exhaustive-when.sh $(COMPILER)
	tools/test-loop-control.sh $(COMPILER)
	tools/test-nullable-refinement.sh $(COMPILER)
	tools/test-callable-families.sh $(COMPILER)
	tools/test-field-shadowing.sh $(COMPILER)
	tools/test-global-names.sh $(COMPILER)
	tools/test-thread-globals.sh $(COMPILER)
	tools/test-compile-eval-jit.sh $(COMPILER)
	tools/test-compile-native.sh $(COMPILER)
	tools/test-optimize-o1.sh $(COMPILER)
	tools/test-map.sh $(COMPILER)
	tools/test-xtensa-interrupt-handler.sh $(COMPILER)
	tools/test-native-function-address.sh $(COMPILER)
	tools/test-native-initialize-globals.sh $(COMPILER)
	tools/test-internal-function.sh $(COMPILER)
	tools/test-static-strings.sh $(COMPILER)
	tools/test-overloads.sh $(COMPILER)
	tools/test-overload-probe-filter.sh $(COMPILER)
	tools/test-argument-diagnostics.sh $(COMPILER)
	tools/test-compound-assignment.sh $(COMPILER)
	tools/test-doc-examples.sh $(COMPILER)
	tools/test-runtime-memory.sh $(COMPILER)
	tools/test-native-object-cache.sh $(COMPILER)
	tools/test-cache-dir.sh $(COMPILER)
	tools/test-build-cache-build-program.sh $(COMPILER)
	tools/test-native-partition-cache.sh $(COMPILER)
	tools/test-lowered-ir-cache.sh $(COMPILER)
	tools/test-determinism.sh $(COMPILER)
	tools/test-compile-effects.sh $(COMPILER)
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
	tools/test-resource-drop-link.sh $(COMPILER)
	tools/test-runtime-checks.sh $(COMPILER)
	tools/test-float-integer-saturation.sh $(COMPILER)
	tools/test-named-method-arguments.sh $(COMPILER)
	tools/test-map-resources.sh $(COMPILER)
	tools/test-definite-assignment.sh $(COMPILER)
	tools/test-shared-ownership.sh $(COMPILER)
	tools/test-mutex.sh $(COMPILER)
	tools/test-affine-move.sh $(COMPILER)
	tools/test-field-places.sh $(COMPILER)
	tools/test-compile-time-cell-capture.sh $(COMPILER)
	tools/test-hosted-network.sh $(COMPILER)
	tools/test-native-platform-boundary.sh $(COMPILER)
	tools/test-math-no-libm.sh $(COMPILER)
	tools/test-math-fast.sh $(COMPILER)
	tools/test-lambda-context.sh $(COMPILER)
	tools/test-reproducible-build.sh $(COMPILER)
	tools/test-inferred-receivers.sh $(COMPILER)
	tools/test-gc-stress.sh $(COMPILER)
	tools/test-generator-step.sh $(COMPILER)
	tools/test-compile-time-files.sh $(COMPILER)
	tools/test-compiler-service-slices.sh $(COMPILER)
	tools/test-module-incremental-state.sh $(COMPILER)
	tools/test-canonical-module-paths.sh $(COMPILER)
	tools/test-for-range.sh $(COMPILER)
	tools/test-generated-virtual-module.sh $(COMPILER)
	tools/test-global-array-mutation.sh $(COMPILER)
	tools/test-global-init-order.sh $(COMPILER)
	tools/test-http-client.sh $(COMPILER)
	tools/test-import-aliases.sh $(COMPILER)
	tools/test-linux-arguments.sh $(COMPILER)
	tools/test-linux-io.sh $(COMPILER)
	tools/test-linux-process.sh $(COMPILER)
	tools/test-linux-sleep.sh $(COMPILER)
	@if test "$$(uname -s)" = Darwin; then tools/test-macos-host.sh $(COMPILER); else echo "macOS host: skipped on $$(uname -s)"; fi
	tools/test-portable-buffered-io.sh $(COMPILER)
	tools/test-portable-io.sh $(COMPILER)
	tools/test-stable-native-symbols.sh $(COMPILER)
	tools/test-structured-type-reflection.sh $(COMPILER)
	tools/test-target-descriptors.sh $(COMPILER)
	tools/test-text-unicode.sh $(COMPILER)
	tools/test-json-native-paths.sh $(COMPILER)
	tools/test-transactional-native-output.sh $(COMPILER)
	tools/test-typed-subparser-inspection.sh $(COMPILER)
	tools/test-unsafe-boundary.sh $(COMPILER)
	tools/test-wasm-gc.sh $(COMPILER)
	tools/test-repl.sh $(COMPILER)
	tools/test-android-extension.sh $(COMPILER)
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
	tools/test-stm.sh $(COMPILER)
	tools/test-frame-closures.sh $(COMPILER)
	tools/test-wasm-mvc-extension.sh $(COMPILER)
	tools/test-initializer-evaluation.sh $(COMPILER)
	tools/test-math-v8.sh $(COMPILER)
	tools/test-interfaces.sh $(COMPILER)
	tools/test-managed-alias-files.sh $(COMPILER)
	tools/test-delegated-properties.sh $(COMPILER)
	tools/test-null-operators.sh $(COMPILER)
	tools/test-resource-temporaries.sh $(COMPILER)
	tools/test-transactions.sh $(COMPILER)
	tools/test-private.sh $(COMPILER)
	tools/test-strict-imports.sh $(COMPILER)
	tools/test-generics.sh $(COMPILER)
	tools/test-transform-reuse.sh $(COMPILER)
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
	tools/test-frontend-call-chain-scaling.sh $(COMPILER)
	tools/test-recursive-class-types.sh $(COMPILER)
	tools/test-compiler-memory-budget.sh $(COMPILER)
	tools/test-gc-background-free.sh $(COMPILER)
	tools/test-json-differential.sh $(COMPILER)
	tools/test-lambda-symbols.sh $(COMPILER)
	tools/test-subparser-site-key.sh $(COMPILER)
	tools/test-stable-names.sh $(COMPILER)
	tools/test-lambda-ordinal.sh $(COMPILER)
	tools/test-lazy-root-frames.sh $(COMPILER)
	tools/test-import-remap.sh $(COMPILER)

check: test self-rebuild

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
