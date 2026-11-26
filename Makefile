# Builds the single spicy binary. Needs only the Odin compiler (raylib ships
# with Odin's vendor collection and is linked statically).
#   make              optimised build  -> ./spicy
#   make debug        debug build      -> ./spicy
#   make install      build and install to ~/.local/bin
#   make uninstall    remove the installed binary
#   make test         unit tests + command-line tests
#   make test-unit    unit tests (tests/*.odin, `odin test`)
#   make test-cli     end-to-end tests of the built binary (needs ngspice on the PATH)
#   make test-gui     GUI smoke test on a virtual display (Linux, needs xvfb-run)
#   make clean        remove the built binary

PREFIX   ?= $(HOME)/.local
BINDIR   ?= $(PREFIX)/bin

# Version baked into the binary: dev-<short git hash>, or "dev" outside a git
# checkout. Release builds pass the tag instead: make VERSION=2026-11
VERSION  ?= dev-$(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
VERSION  := $(patsubst dev-unknown,dev,$(VERSION))

ODINFLAGS ?=
# Windows: a GUI program, so no console window opens with it (src/win_console_windows.odin)
ifeq ($(OS),Windows_NT)
ODINFLAGS += -subsystem:windows
endif

SRC := $(wildcard src/*.odin) $(wildcard config/*.edn) symbols/standard.edn models/standard.lib

.PHONY: all debug install uninstall clean test test-unit test-cli test-gui built

all: spicy

spicy: $(SRC) build/version
	odin build src -out:spicy -o:speed -define:SPICY_VERSION=v$(VERSION) $(ODINFLAGS)
	@echo "built $$(./spicy --version)"

build/version: FORCE
	@mkdir -p build
	@if [ ! -e $@ ] || [ "$$(cat $@)" != '$(VERSION)' ]; then echo '$(VERSION)' > $@; fi

built:
	@if [ ! -e spicy ] || [ -n "$$(find $(SRC) -newer spicy)" ]; then \
		$(MAKE) --no-print-directory spicy; \
	fi

debug:
	odin build src -out:spicy -debug -define:SPICY_VERSION=v$(VERSION) $(ODINFLAGS)

install: built
	install -Dm755 spicy $(BINDIR)/spicy
	@echo "installed $$($(BINDIR)/spicy --version) to $(BINDIR)/spicy"

uninstall:
	rm -f $(BINDIR)/spicy

# The tests use a throw-away config folder (build/testcfg), never ~/.config/spicy.
test-unit:
	@mkdir -p build
	SPICY_CONFIG_DIR=$(CURDIR)/build/testcfg odin test tests -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false -out:build/spicy-tests

test-cli: built
	tests/cli_test.sh ./spicy

test-gui: built
	tests/gui_smoke.sh ./spicy

test: test-unit test-cli

clean:
	rm -f spicy
	rm -rf build

FORCE:
