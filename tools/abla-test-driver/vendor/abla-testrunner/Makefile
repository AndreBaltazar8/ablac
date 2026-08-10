ABLAC_DIR ?= ../ablac
COMPILER ?= $(ABLAC_DIR)/build/ablac

.PHONY: build check test

build:
	mkdir -p build
	$(COMPILER) build src/main.ab -o build/abla-test --fast --no-cache

check: build
	$(COMPILER) build tests/fixture.ab -o build/fixture --fast --no-cache
	$(COMPILER) build tests/parser_test.ab -o build/parser-test --fast --no-cache
	$(COMPILER) build tests/integration_test.ab -o build/integration-test --fast --no-cache
	build/parser-test
	build/integration-test

test: check
