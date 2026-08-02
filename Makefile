CXX ?= c++
CPPFLAGS := -Iinclude
CXXFLAGS := -std=c++20 -Wall -Wextra -Wpedantic -Wconversion -Wshadow \
	-Wnon-virtual-dtor -Wold-style-cast -O2 -g
BOOTSTRAP_CFLAGS ?= -O2
ABLA_MAX_MEMORY_MB ?= 512
ABLA_SELFHOST_EMIT_MEMORY_MB ?= 4096
ABLA_SELFHOST_EMIT_SECONDS ?= 3600
ABLA_FINAL_SELFHOST_EMIT_MEMORY_MB ?= 2048
ABLA_FAST_SELFHOST_EMIT_MEMORY_MB ?= 1160
ABLA_RELEASE_SELFHOST_BUILD_MEMORY_MB ?= 4096
ABLA_FAST_SELFHOST_BUILD_MEMORY_MB ?= 4096
ABLA_MAX_SECONDS ?= 600
ABLA_MAX_CPU_SECONDS ?= $(ABLA_MAX_SECONDS)
LDFLAGS :=

export ABLA_MAX_MEMORY_MB
export ABLA_MAX_SECONDS
export ABLA_MAX_CPU_SECONDS
export ABLA_FINAL_SELFHOST_EMIT_MEMORY_MB
export ABLA_FAST_SELFHOST_EMIT_MEMORY_MB
export ABLA_RELEASE_SELFHOST_BUILD_MEMORY_MB
export ABLA_FAST_SELFHOST_BUILD_MEMORY_MB

BUILD_DIR := build
ABLA_VERIFICATION_STAMP := $(BUILD_DIR)/.ablac-verified
ABLA_VERIFICATION_FINGERPRINT = { \
	find bootstrap include runtime src stdlib tests tools -type f -print0; \
	printf '%s\0' Makefile shell.nix; \
} | sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
SOURCE ?=
OUTPUT ?= $(BUILD_DIR)/program
LIB_SOURCES := $(filter-out src/main.cpp,$(wildcard src/*.cpp))
LIB_OBJECTS := $(patsubst src/%.cpp,$(BUILD_DIR)/%.o,$(LIB_SOURCES))
CLI_OBJECT := $(BUILD_DIR)/main.o
TEST_OBJECT := $(BUILD_DIR)/tests.o
DEPS := $(LIB_OBJECTS:.o=.d) $(CLI_OBJECT:.o=.d) $(TEST_OBJECT:.o=.d)

.PHONY: all ablac ablac-force self-rebuild check test bootstrap-check bootstrap-stage1 bootstrap-selfhost bootstrap-llvm-selfhost benchmark-selfhost benchmark-native compat-original compile sanitize clean

all: $(BUILD_DIR)/ablac0

ablac:
	@set -e; \
	current_fingerprint=$$($(ABLA_VERIFICATION_FINGERPRINT)); \
	verified_fingerprint=$$(sed -n '1p' $(ABLA_VERIFICATION_STAMP) 2>/dev/null || true); \
	if test ! -x $(BUILD_DIR)/ablac.bin || \
		test "$$current_fingerprint" != "$$verified_fingerprint"; then \
		$(MAKE) ablac-force; \
	fi

ablac-force: bootstrap-llvm-selfhost
	ABLA_MAX_MEMORY_MB=$(ABLA_SELFHOST_EMIT_MEMORY_MB) \
		$(BUILD_DIR)/bootstrap/ablac-llvm --emit-llvm \
		bootstrap/compiler/orc_main.ab \
		> $(BUILD_DIR)/bootstrap/ablac-orc.reference.ll
	ABLA_MAX_MEMORY_MB=$(ABLA_RELEASE_SELFHOST_BUILD_MEMORY_MB) ABLA_MAX_SECONDS=240 tools/run-limited.sh \
		nix-shell --run '$(BUILD_DIR)/bootstrap/ablac-llvm build bootstrap/compiler/orc_main.ab -o $(BUILD_DIR)/ablac.bin --no-cache'
	ln -sfn ../tools/run-limited-compiler.sh $(BUILD_DIR)/ablac
	ABLA_MAX_MEMORY_MB=$(ABLA_FINAL_SELFHOST_EMIT_MEMORY_MB) ABLA_MAX_SECONDS=120 \
		$(BUILD_DIR)/ablac --emit-llvm bootstrap/compiler/orc_main.ab \
		> $(BUILD_DIR)/ablac.fixed.ll
	cmp $(BUILD_DIR)/bootstrap/ablac-orc.reference.ll $(BUILD_DIR)/ablac.fixed.ll
	ABLA_MAX_MEMORY_MB=$(ABLA_RELEASE_SELFHOST_BUILD_MEMORY_MB) ABLA_MAX_SECONDS=240 tools/run-limited.sh \
		nix-shell --run '$(BUILD_DIR)/ablac build bootstrap/compiler/orc_main.ab -o $(BUILD_DIR)/bootstrap/ablac-orc-self2 --no-cache'
	ABLA_MAX_MEMORY_MB=$(ABLA_FINAL_SELFHOST_EMIT_MEMORY_MB) ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		$(BUILD_DIR)/bootstrap/ablac-orc-self2 --emit-llvm \
		bootstrap/compiler/orc_main.ab \
		> $(BUILD_DIR)/bootstrap/ablac-orc.self2.ll
	cmp $(BUILD_DIR)/bootstrap/ablac-orc.reference.ll \
		$(BUILD_DIR)/bootstrap/ablac-orc.self2.ll
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-inprocess-aot.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		nix-shell --run 'tools/test-fast-aot.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=$(ABLA_RELEASE_SELFHOST_BUILD_MEMORY_MB) ABLA_MAX_SECONDS=240 tools/run-limited.sh \
		nix-shell --run 'tools/test-pure-self-rebuild.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=90 tools/run-limited.sh \
		nix-shell --run 'tools/test-native-object-cache.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-emitted-value-runtime.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-native-platform-boundary.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=$(ABLA_RELEASE_SELFHOST_BUILD_MEMORY_MB) ABLA_MAX_SECONDS=360 tools/run-limited.sh \
		nix-shell --run 'tools/test-final-native-conformance.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=90 tools/run-limited.sh \
		nix-shell --run 'tools/test-orc-session.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-repl.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-direct-syscall.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=90 tools/run-limited.sh \
		nix-shell --run 'tools/test-libc-free-target.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=90 tools/run-limited.sh \
		nix-shell --run 'tools/test-target-descriptors.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=90 tools/run-limited.sh \
		nix-shell --run 'tools/test-transactional-native-output.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-linux-io.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-linux-arguments.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-linux-sleep.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-linux-process.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-runtime-memory.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-module-incremental-state.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=90 tools/run-limited.sh \
		nix-shell --run 'tools/test-lowered-ir-cache.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=90 tools/run-limited.sh \
		nix-shell --run 'tools/test-stable-native-symbols.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		nix-shell --run 'tools/test-native-partition-cache.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-return-control.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-loop-control.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-for-range.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-definite-assignment.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-unsafe-boundary.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-affine-move.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-nullable-refinement.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-shared-ownership.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-borrow-lifetimes.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-callable-families.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-mutex.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-compile-effects.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-canonical-module-paths.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-global-array-mutation.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-typed-subparser-inspection.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-structured-type-reflection.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-generated-virtual-module.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-subparser-generated-adapter.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-scoped-region.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-exhaustive-when.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-portable-io.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-portable-buffered-io.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-http-client.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-package-build.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-text-unicode.sh $(BUILD_DIR)/ablac.bin'
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		nix-shell --run 'tools/test-graceful-reload.sh $(BUILD_DIR)/ablac'
	@set +e; ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=30 \
		tools/run-limited.sh $(BUILD_DIR)/ablac run \
		tests/cases/bootstrap/block.ab; \
		status=$$?; set -e; test $$status -eq 42
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-jit-host-selection.sh $(BUILD_DIR)/ablac'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'ABLA_EXPECT_JIT_HOST_FREE=1 tools/test-jit-http.sh $(BUILD_DIR)/ablac'
	@set -e; \
	current_fingerprint=$$($(ABLA_VERIFICATION_FINGERPRINT)); \
	stamp_tmp=$(ABLA_VERIFICATION_STAMP).tmp; \
	printf '%s\n' "$$current_fingerprint" > "$$stamp_tmp"; \
	mv "$$stamp_tmp" $(ABLA_VERIFICATION_STAMP)

self-rebuild:
	@test -x $(BUILD_DIR)/ablac.bin || { \
		echo 'build/ablac.bin is required; run make ablac once for a clean seed' >&2; \
		exit 2; \
	}
	nix-shell --run 'tools/test-pure-self-rebuild.sh $(BUILD_DIR)/ablac.bin'

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/%.o: src/%.cpp | $(BUILD_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(TEST_OBJECT): tests/tests.cpp | $(BUILD_DIR)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(BUILD_DIR)/ablac0: $(LIB_OBJECTS) $(CLI_OBJECT)
	$(CXX) $(LDFLAGS) $^ -o $@

$(BUILD_DIR)/abla-tests: $(LIB_OBJECTS) $(TEST_OBJECT)
	$(CXX) $(LDFLAGS) $^ -o $@

test: $(BUILD_DIR)/abla-tests $(BUILD_DIR)/ablac0
	tools/test-run-limited.sh
	$(BUILD_DIR)/abla-tests
	tools/test-native.sh $(BUILD_DIR)/ablac0

check: all test bootstrap-check bootstrap-stage1 bootstrap-selfhost bootstrap-llvm-selfhost
	$(BUILD_DIR)/ablac0 check tests/cases/parser/compat.ab

bootstrap-check: all
	$(BUILD_DIR)/ablac0 check bootstrap/compiler/lexer.ab
	$(BUILD_DIR)/ablac0 check bootstrap/compiler/parser.ab
	$(BUILD_DIR)/ablac0 check bootstrap/compiler/subparser.ab
	$(BUILD_DIR)/ablac0 check bootstrap/compiler/sema.ab
	$(BUILD_DIR)/ablac0 check bootstrap/compiler/eval.ab
	$(BUILD_DIR)/ablac0 check bootstrap/compiler/staged_parser.ab
	$(BUILD_DIR)/ablac0 check bootstrap/compiler/ir.ab
	$(BUILD_DIR)/ablac0 check bootstrap/compiler/backend_c.ab
	$(BUILD_DIR)/ablac0 check bootstrap/compiler/backend_llvm.ab
	@test "$$($(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-lexer.ab)" = 42
	@test "$$($(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-parser.ab)" = 42
	@test "$$($(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-subparser-registry.ab)" = 42
	@test "$$($(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-subparser-cursor.ab)" = 42
	@test "$$($(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-subparser-handler.ab)" = 42
	$(BUILD_DIR)/ablac0 emit-c tests/cases/bootstrap/subparser-providers.ab \
		> $(BUILD_DIR)/bootstrap/subparser-providers.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/subparser-providers.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/subparser-providers
	@set +e; $(BUILD_DIR)/bootstrap/subparser-providers; status=$$?; set -e; test $$status -eq 42
	@test "$$($(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-sema.ab)" = 42
	@test "$$($(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-ir.ab)" = 42
	@test "$$($(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-block.ab)" = 42
	@test "$$($(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-collections.ab)" = 42
	@test "$$($(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-objects.ab)" = 42
	mkdir -p $(BUILD_DIR)/bootstrap
	$(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-backend.ab > $(BUILD_DIR)/bootstrap/program.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/program.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/program
	@set +e; $(BUILD_DIR)/bootstrap/program; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-llvm.ab \
		> $(BUILD_DIR)/bootstrap/program.ll
	$(BUILD_DIR)/ablac0 run tests/cases/modules/bootstrap-llvm.ab \
		> $(BUILD_DIR)/bootstrap/program.repeated.ll
	cmp $(BUILD_DIR)/bootstrap/program.ll \
		$(BUILD_DIR)/bootstrap/program.repeated.ll
	nix-shell --run 'llvm-as $(BUILD_DIR)/bootstrap/program.ll -o $(BUILD_DIR)/bootstrap/program.bc && llc -filetype=obj -relocation-model=pic -O2 $(BUILD_DIR)/bootstrap/program.ll -o $(BUILD_DIR)/bootstrap/program-llvm.o && clang -std=c11 -O2 -Iruntime -c runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/abla-runtime-host-llvm.o && clang -fuse-ld=lld -Wl,--threads=1 $(BUILD_DIR)/bootstrap/program-llvm.o $(BUILD_DIR)/bootstrap/abla-runtime-host-llvm.o -o $(BUILD_DIR)/bootstrap/program-llvm'
	@set +e; ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
		tools/run-limited.sh $(BUILD_DIR)/bootstrap/program-llvm; \
		status=$$?; set -e; test $$status -eq 42

bootstrap-stage1: all
	mkdir -p $(BUILD_DIR)/bootstrap
	tools/test-seed-intrinsics.sh $(BUILD_DIR)/ablac0
	$(BUILD_DIR)/ablac0 emit-c bootstrap/compiler/main.ab > $(BUILD_DIR)/bootstrap/ablac1.c
	$(CC) $(BOOTSTRAP_CFLAGS) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/ablac1.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/ablac1.bin
	ln -sfn ../../tools/run-limited-compiler.sh $(BUILD_DIR)/bootstrap/ablac1
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/block.ab \
		> $(BUILD_DIR)/bootstrap/stage1-output.c
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/block.ab \
		> $(BUILD_DIR)/bootstrap/stage1-output.repeated.c
	cmp $(BUILD_DIR)/bootstrap/stage1-output.c \
		$(BUILD_DIR)/bootstrap/stage1-output.repeated.c
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid.ab \
		> $(BUILD_DIR)/bootstrap/invalid-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-output.c
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid-call.ab \
		> $(BUILD_DIR)/bootstrap/invalid-call-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-call-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-call-output.c
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid-arity.ab \
		> $(BUILD_DIR)/bootstrap/invalid-arity-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-arity-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-arity-output.c
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid-argument.ab \
		> $(BUILD_DIR)/bootstrap/invalid-argument-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-argument-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-argument-output.c
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid-lambda-argument.ab \
		> $(BUILD_DIR)/bootstrap/invalid-lambda-argument-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-lambda-argument-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-lambda-argument-output.c
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid-immutable.ab \
		> $(BUILD_DIR)/bootstrap/invalid-immutable-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-immutable-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-immutable-output.c
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid-immutable-field.ab \
		> $(BUILD_DIR)/bootstrap/invalid-immutable-field-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-immutable-field-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-immutable-field-output.c
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid-immutable-global.ab \
		> $(BUILD_DIR)/bootstrap/invalid-immutable-global-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-immutable-global-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-immutable-global-output.c
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid-condition.ab \
		> $(BUILD_DIR)/bootstrap/invalid-condition-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-condition-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-condition-output.c
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid-while-condition.ab \
		> $(BUILD_DIR)/bootstrap/invalid-while-condition-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-while-condition-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-while-condition-output.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-output.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-output
	@set +e; $(BUILD_DIR)/bootstrap/stage1-output; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/collections.ab \
		> $(BUILD_DIR)/bootstrap/stage1-collections.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-collections.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-collections
	@set +e; $(BUILD_DIR)/bootstrap/stage1-collections; status=$$?; set -e; test $$status -eq 42
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid-array.ab \
		> $(BUILD_DIR)/bootstrap/invalid-array-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-array-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-array-output.c
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/objects.ab \
		> $(BUILD_DIR)/bootstrap/stage1-objects.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-objects.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-objects
	@set +e; $(BUILD_DIR)/bootstrap/stage1-objects; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/class-default.ab \
		> $(BUILD_DIR)/bootstrap/stage1-class-default.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-class-default.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-class-default
	@set +e; $(BUILD_DIR)/bootstrap/stage1-class-default; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/function-default.ab \
		> $(BUILD_DIR)/bootstrap/stage1-function-default.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-function-default.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-function-default
	@set +e; $(BUILD_DIR)/bootstrap/stage1-function-default; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/when.ab \
		> $(BUILD_DIR)/bootstrap/stage1-when.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-when.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-when
	@set +e; $(BUILD_DIR)/bootstrap/stage1-when; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/do-while.ab \
		> $(BUILD_DIR)/bootstrap/stage1-do-while.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-do-while.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-do-while
	@set +e; $(BUILD_DIR)/bootstrap/stage1-do-while; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/index-assignment.ab \
		> $(BUILD_DIR)/bootstrap/stage1-index-assignment.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-index-assignment.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-index-assignment
	@set +e; $(BUILD_DIR)/bootstrap/stage1-index-assignment; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/nullable.ab \
		> $(BUILD_DIR)/bootstrap/stage1-nullable.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-nullable.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-nullable
	@set +e; $(BUILD_DIR)/bootstrap/stage1-nullable; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/method-dispatch.ab \
		> $(BUILD_DIR)/bootstrap/stage1-method-dispatch.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-method-dispatch.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-method-dispatch
	@set +e; $(BUILD_DIR)/bootstrap/stage1-method-dispatch; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/extension.ab \
		> $(BUILD_DIR)/bootstrap/stage1-extension.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-extension.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-extension
	@set +e; $(BUILD_DIR)/bootstrap/stage1-extension; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/lambda.ab \
		> $(BUILD_DIR)/bootstrap/stage1-lambda.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-lambda.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-lambda
	@set +e; $(BUILD_DIR)/bootstrap/stage1-lambda; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/lambda-capture.ab \
		> $(BUILD_DIR)/bootstrap/stage1-lambda-capture.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-lambda-capture.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-lambda-capture
	@set +e; $(BUILD_DIR)/bootstrap/stage1-lambda-capture; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/local-in-while.ab \
		> $(BUILD_DIR)/bootstrap/stage1-local-in-while.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-local-in-while.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-local-in-while
	@set +e; $(BUILD_DIR)/bootstrap/stage1-local-in-while; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/compile-method.ab \
		> $(BUILD_DIR)/bootstrap/stage1-compile-method.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-compile-method.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-compile-method
	@set +e; $(BUILD_DIR)/bootstrap/stage1-compile-method; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/compile-function-value.ab \
		> $(BUILD_DIR)/bootstrap/stage1-compile-function-value.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-compile-function-value.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-compile-function-value
	@set +e; $(BUILD_DIR)/bootstrap/stage1-compile-function-value; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 --emit-llvm tests/cases/bootstrap/block.ab \
		> $(BUILD_DIR)/bootstrap/stage1-block.ll
	nix-shell --run 'llvm-as $(BUILD_DIR)/bootstrap/stage1-block.ll -o $(BUILD_DIR)/bootstrap/stage1-block.bc && llc -filetype=obj -relocation-model=pic -O2 $(BUILD_DIR)/bootstrap/stage1-block.ll -o $(BUILD_DIR)/bootstrap/stage1-block.o && clang -std=c11 -O2 -Iruntime -c runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/abla-runtime-host-llvm.o && clang -fuse-ld=lld -Wl,--threads=1 $(BUILD_DIR)/bootstrap/stage1-block.o $(BUILD_DIR)/bootstrap/abla-runtime-host-llvm.o -o $(BUILD_DIR)/bootstrap/stage1-block-llvm'
	@set +e; ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
		tools/run-limited.sh $(BUILD_DIR)/bootstrap/stage1-block-llvm; \
		status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/modules/abla-subparser-builder.ab \
		> $(BUILD_DIR)/bootstrap/stage1-subparser-builder.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-subparser-builder.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-subparser-builder
	@set +e; $(BUILD_DIR)/bootstrap/stage1-subparser-builder; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/modules/abla-subparser-import.ab \
		> $(BUILD_DIR)/bootstrap/stage1-subparser-import.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-subparser-import.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-subparser-import
	@set +e; $(BUILD_DIR)/bootstrap/stage1-subparser-import; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/modules/json-subparser.ab \
		> $(BUILD_DIR)/bootstrap/stage1-json-subparser.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-json-subparser.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-json-subparser
	@set +e; $(BUILD_DIR)/bootstrap/stage1-json-subparser; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/modules/html-subparser.ab \
		> $(BUILD_DIR)/bootstrap/stage1-html-subparser.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-html-subparser.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-html-subparser
	@set +e; $(BUILD_DIR)/bootstrap/stage1-html-subparser; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/modules/compile-time.ab \
		> $(BUILD_DIR)/bootstrap/stage1-compile-time.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-compile-time.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-compile-time
	@set +e; $(BUILD_DIR)/bootstrap/stage1-compile-time; status=$$?; set -e; test $$status -eq 40
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/modules/compile-compound.ab \
		> $(BUILD_DIR)/bootstrap/stage1-compile-compound.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-compile-compound.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-compile-compound
	@set +e; $(BUILD_DIR)/bootstrap/stage1-compile-compound; status=$$?; set -e; test $$status -eq 35
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/modules/compile-shared.ab \
		> $(BUILD_DIR)/bootstrap/stage1-compile-shared.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-compile-shared.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-compile-shared
	@set +e; $(BUILD_DIR)/bootstrap/stage1-compile-shared; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/modules/compile-cycle.ab \
		> $(BUILD_DIR)/bootstrap/stage1-compile-cycle.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-compile-cycle.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-compile-cycle
	$(BUILD_DIR)/bootstrap/stage1-compile-cycle
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/modules/native-c.ab \
		> $(BUILD_DIR)/bootstrap/stage1-native-c.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-native-c.c tests/native/native_test.c \
		runtime/abla_runtime.c runtime/abla_runtime_host.c \
		-o $(BUILD_DIR)/bootstrap/stage1-native-c
	@set +e; $(BUILD_DIR)/bootstrap/stage1-native-c; status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/modules/entry.ab \
		> $(BUILD_DIR)/bootstrap/stage1-module.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage1-module.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage1-module
	@set +e; $(BUILD_DIR)/bootstrap/stage1-module; status=$$?; set -e; test $$status -eq 42
	@set +e; $(BUILD_DIR)/bootstrap/ablac1 tests/cases/bootstrap/invalid-field.ab \
		> $(BUILD_DIR)/bootstrap/invalid-field-output.c \
		2> $(BUILD_DIR)/bootstrap/invalid-field-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/invalid-field-output.c
	$(BUILD_DIR)/bootstrap/ablac1 bootstrap/compiler/lexer.ab \
		> $(BUILD_DIR)/bootstrap/self-lexer.c
	$(BUILD_DIR)/bootstrap/ablac1 bootstrap/compiler/lexer.ab \
		> $(BUILD_DIR)/bootstrap/self-lexer.repeated.c
	cmp $(BUILD_DIR)/bootstrap/self-lexer.c \
		$(BUILD_DIR)/bootstrap/self-lexer.repeated.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/self-lexer.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/self-lexer

bootstrap-selfhost: bootstrap-stage1
	ABLA_MAX_MEMORY_MB=$(ABLA_SELFHOST_EMIT_MEMORY_MB) \
		$(BUILD_DIR)/bootstrap/ablac1 bootstrap/compiler/main.ab \
		> $(BUILD_DIR)/bootstrap/ablac2.c
	$(CC) $(BOOTSTRAP_CFLAGS) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/ablac2.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/ablac2.bin
	ln -sfn ../../tools/run-limited-compiler.sh $(BUILD_DIR)/bootstrap/ablac2
	ABLA_MAX_MEMORY_MB=$(ABLA_SELFHOST_EMIT_MEMORY_MB) \
		$(BUILD_DIR)/bootstrap/ablac2 bootstrap/compiler/main.ab \
		> $(BUILD_DIR)/bootstrap/ablac3.c
	cmp $(BUILD_DIR)/bootstrap/ablac2.c $(BUILD_DIR)/bootstrap/ablac3.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/block.ab \
		> $(BUILD_DIR)/bootstrap/stage2-output.c
	cmp $(BUILD_DIR)/bootstrap/stage1-output.c \
		$(BUILD_DIR)/bootstrap/stage2-output.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/class-default.ab \
		> $(BUILD_DIR)/bootstrap/stage2-class-default.c
	cmp $(BUILD_DIR)/bootstrap/stage1-class-default.c \
		$(BUILD_DIR)/bootstrap/stage2-class-default.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/function-default.ab \
		> $(BUILD_DIR)/bootstrap/stage2-function-default.c
	cmp $(BUILD_DIR)/bootstrap/stage1-function-default.c \
		$(BUILD_DIR)/bootstrap/stage2-function-default.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/when.ab \
		> $(BUILD_DIR)/bootstrap/stage2-when.c
	cmp $(BUILD_DIR)/bootstrap/stage1-when.c \
		$(BUILD_DIR)/bootstrap/stage2-when.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/do-while.ab \
		> $(BUILD_DIR)/bootstrap/stage2-do-while.c
	cmp $(BUILD_DIR)/bootstrap/stage1-do-while.c \
		$(BUILD_DIR)/bootstrap/stage2-do-while.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/index-assignment.ab \
		> $(BUILD_DIR)/bootstrap/stage2-index-assignment.c
	cmp $(BUILD_DIR)/bootstrap/stage1-index-assignment.c \
		$(BUILD_DIR)/bootstrap/stage2-index-assignment.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/nullable.ab \
		> $(BUILD_DIR)/bootstrap/stage2-nullable.c
	cmp $(BUILD_DIR)/bootstrap/stage1-nullable.c \
		$(BUILD_DIR)/bootstrap/stage2-nullable.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/method-dispatch.ab \
		> $(BUILD_DIR)/bootstrap/stage2-method-dispatch.c
	cmp $(BUILD_DIR)/bootstrap/stage1-method-dispatch.c \
		$(BUILD_DIR)/bootstrap/stage2-method-dispatch.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/extension.ab \
		> $(BUILD_DIR)/bootstrap/stage2-extension.c
	cmp $(BUILD_DIR)/bootstrap/stage1-extension.c \
		$(BUILD_DIR)/bootstrap/stage2-extension.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/lambda.ab \
		> $(BUILD_DIR)/bootstrap/stage2-lambda.c
	cmp $(BUILD_DIR)/bootstrap/stage1-lambda.c \
		$(BUILD_DIR)/bootstrap/stage2-lambda.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/lambda-capture.ab \
		> $(BUILD_DIR)/bootstrap/stage2-lambda-capture.c
	cmp $(BUILD_DIR)/bootstrap/stage1-lambda-capture.c \
		$(BUILD_DIR)/bootstrap/stage2-lambda-capture.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/local-in-while.ab \
		> $(BUILD_DIR)/bootstrap/stage2-local-in-while.c
	cmp $(BUILD_DIR)/bootstrap/stage1-local-in-while.c \
		$(BUILD_DIR)/bootstrap/stage2-local-in-while.c
	@set +e; $(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/invalid-lambda-argument.ab \
		> $(BUILD_DIR)/bootstrap/stage2-invalid-lambda-argument.c \
		2> $(BUILD_DIR)/bootstrap/stage2-invalid-lambda-argument-errors.txt; status=$$?; set -e; \
		test $$status -eq 1; test ! -s $(BUILD_DIR)/bootstrap/stage2-invalid-lambda-argument.c; \
		cmp $(BUILD_DIR)/bootstrap/invalid-lambda-argument-errors.txt \
			$(BUILD_DIR)/bootstrap/stage2-invalid-lambda-argument-errors.txt
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/compile-method.ab \
		> $(BUILD_DIR)/bootstrap/stage2-compile-method.c
	cmp $(BUILD_DIR)/bootstrap/stage1-compile-method.c \
		$(BUILD_DIR)/bootstrap/stage2-compile-method.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/bootstrap/compile-function-value.ab \
		> $(BUILD_DIR)/bootstrap/stage2-compile-function-value.c
	cmp $(BUILD_DIR)/bootstrap/stage1-compile-function-value.c \
		$(BUILD_DIR)/bootstrap/stage2-compile-function-value.c
	$(BUILD_DIR)/bootstrap/ablac2 --emit-llvm tests/cases/bootstrap/block.ab \
		> $(BUILD_DIR)/bootstrap/stage2-block.ll
	cmp $(BUILD_DIR)/bootstrap/stage1-block.ll \
		$(BUILD_DIR)/bootstrap/stage2-block.ll
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/modules/abla-subparser-builder.ab \
		> $(BUILD_DIR)/bootstrap/stage2-subparser-builder.c
	cmp $(BUILD_DIR)/bootstrap/stage1-subparser-builder.c \
		$(BUILD_DIR)/bootstrap/stage2-subparser-builder.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/modules/abla-subparser-import.ab \
		> $(BUILD_DIR)/bootstrap/stage2-subparser-import.c
	cmp $(BUILD_DIR)/bootstrap/stage1-subparser-import.c \
		$(BUILD_DIR)/bootstrap/stage2-subparser-import.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/modules/json-subparser.ab \
		> $(BUILD_DIR)/bootstrap/stage2-json-subparser.c
	cmp $(BUILD_DIR)/bootstrap/stage1-json-subparser.c \
		$(BUILD_DIR)/bootstrap/stage2-json-subparser.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/modules/html-subparser.ab \
		> $(BUILD_DIR)/bootstrap/stage2-html-subparser.c
	cmp $(BUILD_DIR)/bootstrap/stage1-html-subparser.c \
		$(BUILD_DIR)/bootstrap/stage2-html-subparser.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/modules/compile-time.ab \
		> $(BUILD_DIR)/bootstrap/stage2-compile-time.c
	cmp $(BUILD_DIR)/bootstrap/stage1-compile-time.c \
		$(BUILD_DIR)/bootstrap/stage2-compile-time.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/modules/compile-compound.ab \
		> $(BUILD_DIR)/bootstrap/stage2-compile-compound.c
	cmp $(BUILD_DIR)/bootstrap/stage1-compile-compound.c \
		$(BUILD_DIR)/bootstrap/stage2-compile-compound.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/modules/compile-shared.ab \
		> $(BUILD_DIR)/bootstrap/stage2-compile-shared.c
	cmp $(BUILD_DIR)/bootstrap/stage1-compile-shared.c \
		$(BUILD_DIR)/bootstrap/stage2-compile-shared.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/modules/compile-cycle.ab \
		> $(BUILD_DIR)/bootstrap/stage2-compile-cycle.c
	cmp $(BUILD_DIR)/bootstrap/stage1-compile-cycle.c \
		$(BUILD_DIR)/bootstrap/stage2-compile-cycle.c
	$(BUILD_DIR)/bootstrap/ablac2 tests/cases/modules/native-c.ab \
		> $(BUILD_DIR)/bootstrap/stage2-native-c.c
	cmp $(BUILD_DIR)/bootstrap/stage1-native-c.c \
		$(BUILD_DIR)/bootstrap/stage2-native-c.c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(BUILD_DIR)/bootstrap/stage2-output.c runtime/abla_runtime.c \
		runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/stage2-output
	@set +e; $(BUILD_DIR)/bootstrap/stage2-output; status=$$?; set -e; test $$status -eq 42

bootstrap-llvm-selfhost: bootstrap-stage1
	ABLA_MAX_MEMORY_MB=$(ABLA_SELFHOST_EMIT_MEMORY_MB) \
	ABLA_MAX_SECONDS=$(ABLA_SELFHOST_EMIT_SECONDS) \
	ABLA_MAX_CPU_SECONDS=$(ABLA_SELFHOST_EMIT_SECONDS) \
		$(BUILD_DIR)/bootstrap/ablac1 --emit-llvm bootstrap/compiler/main.ab \
		> $(BUILD_DIR)/bootstrap/ablac-llvm.ll
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=600 tools/run-limited.sh \
		nix-shell --run 'opt --threads=1 -passes=verify -disable-output $(BUILD_DIR)/bootstrap/ablac-llvm.ll && llc --threads=1 -filetype=obj -relocation-model=pic -O2 $(BUILD_DIR)/bootstrap/ablac-llvm.ll -o $(BUILD_DIR)/bootstrap/ablac-llvm.o && clang -std=c11 -O2 -Iruntime -c runtime/abla_runtime_host.c -o $(BUILD_DIR)/bootstrap/ablac-llvm-host.o && clang -fuse-ld=lld -Wl,--threads=1 $(BUILD_DIR)/bootstrap/ablac-llvm.o $(BUILD_DIR)/bootstrap/ablac-llvm-host.o -o $(BUILD_DIR)/bootstrap/ablac-llvm.bin'
	ln -sfn ../../tools/run-limited-compiler.sh $(BUILD_DIR)/bootstrap/ablac-llvm
	@if ! test -s $(BUILD_DIR)/bootstrap/ablac-llvm.fixed.ll || \
		! cmp -s $(BUILD_DIR)/bootstrap/ablac-llvm.ll \
			$(BUILD_DIR)/bootstrap/ablac-llvm.fixed.ll; then \
		ABLA_MAX_MEMORY_MB=$(ABLA_SELFHOST_EMIT_MEMORY_MB) \
		ABLA_MAX_SECONDS=$(ABLA_SELFHOST_EMIT_SECONDS) \
		ABLA_MAX_CPU_SECONDS=$(ABLA_SELFHOST_EMIT_SECONDS) \
			$(BUILD_DIR)/bootstrap/ablac-llvm --emit-llvm \
			bootstrap/compiler/main.ab \
			> $(BUILD_DIR)/bootstrap/ablac-llvm.fixed.ll; \
	fi
	cmp $(BUILD_DIR)/bootstrap/ablac-llvm.ll \
		$(BUILD_DIR)/bootstrap/ablac-llvm.fixed.ll
	$(BUILD_DIR)/bootstrap/ablac-llvm --emit-llvm \
		tests/cases/bootstrap/llvm-stack-loop.ab \
		> $(BUILD_DIR)/bootstrap/llvm-stack-loop.ll
	ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		nix-shell --run 'opt --threads=1 -passes=verify -disable-output $(BUILD_DIR)/bootstrap/llvm-stack-loop.ll && llc --threads=1 -filetype=obj -relocation-model=pic -O2 $(BUILD_DIR)/bootstrap/llvm-stack-loop.ll -o $(BUILD_DIR)/bootstrap/llvm-stack-loop.o && clang -fuse-ld=lld -Wl,--threads=1 $(BUILD_DIR)/bootstrap/llvm-stack-loop.o $(BUILD_DIR)/bootstrap/ablac-llvm-host.o -o $(BUILD_DIR)/bootstrap/llvm-stack-loop'
	@set +e; ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
		tools/run-limited.sh $(BUILD_DIR)/bootstrap/llvm-stack-loop; \
		status=$$?; set -e; test $$status -eq 42
	ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		nix-shell --run '$(BUILD_DIR)/bootstrap/ablac-llvm build tests/cases/bootstrap/lambda-capture.ab -o $(BUILD_DIR)/bootstrap/ablac-build-test'
	@set +e; ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
		tools/run-limited.sh $(BUILD_DIR)/bootstrap/ablac-build-test; \
		status=$$?; set -e; test $$status -eq 42
	ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		nix-shell --run '$(BUILD_DIR)/bootstrap/ablac-llvm build tests/cases/bootstrap/string-rope-small.ab -o $(BUILD_DIR)/bootstrap/string-rope-small'
	@set +e; ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
		tools/run-limited.sh $(BUILD_DIR)/bootstrap/string-rope-small; \
		status=$$?; set -e; test $$status -eq 42
	ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		nix-shell --run '$(BUILD_DIR)/bootstrap/ablac-llvm build tests/cases/bootstrap/identifier-shadowing.ab -o $(BUILD_DIR)/bootstrap/identifier-shadowing'
	@set +e; ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
		tools/run-limited.sh $(BUILD_DIR)/bootstrap/identifier-shadowing; \
		status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac-llvm --emit-llvm \
		tests/cases/modules/native-c-string.ab \
		> $(BUILD_DIR)/bootstrap/native-c-string.ll
	$(BUILD_DIR)/bootstrap/ablac-llvm --emit-llvm \
		tests/cases/bootstrap/native-c-abi.ab \
		> $(BUILD_DIR)/bootstrap/native-c-abi.ll
	ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		nix-shell --run 'opt --threads=1 -passes=verify -disable-output $(BUILD_DIR)/bootstrap/native-c-string.ll && opt --threads=1 -passes=verify -disable-output $(BUILD_DIR)/bootstrap/native-c-abi.ll && llc --threads=1 -filetype=obj -relocation-model=pic -O2 $(BUILD_DIR)/bootstrap/native-c-string.ll -o $(BUILD_DIR)/bootstrap/native-c-string.o && llc --threads=1 -filetype=obj -relocation-model=pic -O2 $(BUILD_DIR)/bootstrap/native-c-abi.ll -o $(BUILD_DIR)/bootstrap/native-c-abi.o && clang -std=c11 -c tests/native/native_test.c -o $(BUILD_DIR)/bootstrap/native-test-abi.o && clang -fuse-ld=lld -Wl,--threads=1 $(BUILD_DIR)/bootstrap/native-c-string.o $(BUILD_DIR)/bootstrap/ablac-llvm-host.o -o $(BUILD_DIR)/bootstrap/native-c-string && clang -fuse-ld=lld -Wl,--threads=1 $(BUILD_DIR)/bootstrap/native-c-abi.o $(BUILD_DIR)/bootstrap/native-test-abi.o $(BUILD_DIR)/bootstrap/ablac-llvm-host.o -o $(BUILD_DIR)/bootstrap/native-c-abi'
	@set +e; $(BUILD_DIR)/bootstrap/native-c-string; status=$$?; set -e; test $$status -eq 42
	@set +e; $(BUILD_DIR)/bootstrap/native-c-abi; status=$$?; set -e; test $$status -eq 42
	ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		nix-shell --run '$(BUILD_DIR)/bootstrap/ablac-llvm build tests/cases/modules/bytes.ab -o $(BUILD_DIR)/bootstrap/bytes-native'
	@set +e; ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
		tools/run-limited.sh $(BUILD_DIR)/bootstrap/bytes-native; \
		status=$$?; set -e; test $$status -eq 42
	ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		nix-shell --run '$(BUILD_DIR)/bootstrap/ablac-llvm build tests/cases/modules/unsafe-memory.ab -o $(BUILD_DIR)/bootstrap/unsafe-memory-native'
	@set +e; ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=30 \
		tools/run-limited.sh $(BUILD_DIR)/bootstrap/unsafe-memory-native; \
		status=$$?; set -e; test $$status -eq 42
	$(BUILD_DIR)/bootstrap/ablac-llvm --emit-llvm bootstrap/orc_runner.ab \
		> $(BUILD_DIR)/bootstrap/orc-runner.ll
	ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
		nix-shell --run 'libdir=$$(llvm-config --libdir); opt --threads=1 -passes=verify -disable-output $(BUILD_DIR)/bootstrap/orc-runner.ll && llc --threads=1 -filetype=obj -relocation-model=pic -O2 $(BUILD_DIR)/bootstrap/orc-runner.ll -o $(BUILD_DIR)/bootstrap/orc-runner.o && clang -fuse-ld=lld -Wl,--threads=1 -Wl,--export-dynamic $(BUILD_DIR)/bootstrap/orc-runner.o $(BUILD_DIR)/bootstrap/ablac-llvm-host.o -L"$$libdir" -Wl,-rpath,"$$libdir" -lLLVM -o $(BUILD_DIR)/abla-orc-runner'
	@set +e; ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=30 \
		tools/run-limited.sh $(BUILD_DIR)/abla-orc-runner \
		$(BUILD_DIR)/bootstrap/stage1-block.ll; \
		status=$$?; set -e; test $$status -eq 42
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-orc-http.sh $(BUILD_DIR)/bootstrap/ablac-llvm $(BUILD_DIR)/abla-orc-runner'
	@set +e; ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=120 \
		tools/run-limited.sh nix-shell --run '$(BUILD_DIR)/bootstrap/ablac-llvm run tests/cases/bootstrap/block.ab'; \
		status=$$?; set -e; test $$status -eq 42
	ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=30 tools/run-limited.sh \
		nix-shell --run 'tools/test-hot-reload.sh $(BUILD_DIR)/bootstrap/ablac-llvm'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-http-server.sh $(BUILD_DIR)/bootstrap/ablac-llvm'
	ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 tools/run-limited.sh \
		nix-shell --run 'tools/test-jit-http.sh $(BUILD_DIR)/bootstrap/ablac-llvm'

benchmark-selfhost:
	@test -x $(BUILD_DIR)/bootstrap/ablac2 || $(MAKE) bootstrap-selfhost
	tools/benchmark-selfhost.sh $(BUILD_DIR)/bootstrap/ablac2

benchmark-native: bootstrap-llvm-selfhost
	tools/benchmark-native.sh $(BUILD_DIR)/bootstrap/ablac-llvm

compat-original: all
	tools/check-original-syntax.sh $(BUILD_DIR)/ablac0

compile: all
	@test -n "$(SOURCE)" || { echo "usage: make compile SOURCE=program.ab [OUTPUT=path]" >&2; exit 2; }
	mkdir -p $(dir $(OUTPUT))
	$(BUILD_DIR)/ablac0 emit-c $(SOURCE) > $(OUTPUT).c
	$(CC) -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
		-Iruntime $(OUTPUT).c runtime/abla_runtime.c runtime/abla_runtime_host.c \
		-o $(OUTPUT)

sanitize:
	$(MAKE) clean
	$(MAKE) CXXFLAGS="$(CXXFLAGS) -O1 -fsanitize=address,undefined" \
		LDFLAGS="-fsanitize=address,undefined" check

clean:
	rm -rf -- $(BUILD_DIR)

-include $(DEPS)
