BUILD_DIR := build
COMPILER := $(BUILD_DIR)/ablac
COMPILER_PAYLOAD := $(BUILD_DIR)/ablac.bin
COMPILER_ENTRY := src/orc_main.ab
COMPILER_SOURCES := $(shell find src stdlib -name '*.ab' -type f | sort) \
	runtime/abla_runtime.c runtime/abla_runtime.h runtime/abla_runtime_host.c \
	runtime/abla_runtime_raw.c runtime/abla_runtime_wasm.c \
	runtime/abla_llvm_host.c

SOURCE ?=
OUTPUT ?= $(BUILD_DIR)/program

.DEFAULT_GOAL := all

.PHONY: all bootstrap ablac self-rebuild test check compile benchmark \
	benchmark-network clean

all: ablac

$(BUILD_DIR):
	mkdir -p $@

# A clean checkout starts with the checksum-pinned compiler release selected by
# tools/bootstrap-compiler.sh. It immediately rebuilds the current source graph,
# so src/*.ab remains the only compiler implementation in the repository.
$(COMPILER_PAYLOAD): $(COMPILER_SOURCES) tools/build-self-hosted-release.sh \
		| $(BUILD_DIR) tools/bootstrap-compiler.sh
	@if test ! -x $@; then tools/bootstrap-compiler.sh $@; fi
	ln -sfn ../tools/run-limited-compiler.sh $(COMPILER)
	tools/build-self-hosted-release.sh $@ $(BUILD_DIR)/.ablac-next $(COMPILER_ENTRY)
	mv -f $(BUILD_DIR)/.ablac-next.ll $(BUILD_DIR)/ablac.ll
	mv -f $(BUILD_DIR)/.ablac-next $@

$(COMPILER): $(COMPILER_PAYLOAD) tools/run-limited-compiler.sh
	ln -sfn ../tools/run-limited-compiler.sh $@

bootstrap: | $(BUILD_DIR)
	@if test ! -x $(COMPILER_PAYLOAD); then \
		tools/bootstrap-compiler.sh $(COMPILER_PAYLOAD); \
	fi
	ln -sfn ../tools/run-limited-compiler.sh $(COMPILER)

ablac: $(COMPILER)

self-rebuild: ablac
	tools/test-pure-self-rebuild.sh $(COMPILER_PAYLOAD)

test: ablac
	tools/test-self-hosted.sh $(COMPILER)

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
