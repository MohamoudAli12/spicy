# Builds the single spicy binary. Needs only the Odin compiler (raylib ships
# with Odin's vendor collection and is linked statically).
#   make              optimised build  -> ./spicy
#   make debug        debug build      -> ./spicy
#   make install      build and install to ~/.local/bin (Linux: plus menu entry and icons)
#   make uninstall    remove what install put there
#   make test         vet + unit tests + command-line tests
#   make vet          the compiler's checks for unused and shadowed names (all platforms)
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
# the program icon (assets/spicy.rc -> assets/spicy.ico), compiled with rc.exe
ODINFLAGS += -resource:assets/spicy.rc
endif

SRC := $(wildcard src/*.odin) $(wildcard config/*.edn) symbols/standard.edn models/standard.lib assets/spicy.rc assets/spicy.ico $(wildcard assets/icons/*.png)

.PHONY: all debug install uninstall clean test vet test-unit test-cli test-gui built

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

# Linux also gets a menu entry and icons, so launchers (rofi, GNOME, KDE) find
# spicy. Only these exact files are written, and uninstall removes only them.
DATADIR  ?= $(PREFIX)/share
DESKTOP  := $(DATADIR)/applications/spicy.desktop
ICONS    := $(foreach s,16 24 32 48 64 128 256 512,$(DATADIR)/icons/hicolor/$(s)x$(s)/apps/spicy.png)
LINUX    := $(if $(filter Linux,$(shell uname -s 2>/dev/null)),yes,)

install: built
	install -Dm755 spicy $(BINDIR)/spicy
ifeq ($(LINUX),yes)
	@for f in $(ICONS); do s=$$(basename $$(dirname $$(dirname $$f))); install -Dm644 assets/icons/$${s%x*}.png $$f; done
	@mkdir -p build
	sed 's|^Exec=spicy|Exec=$(BINDIR)/spicy|' assets/spicy.desktop > build/spicy.desktop
	install -Dm644 build/spicy.desktop $(DESKTOP)
	@echo "installed the menu entry $(DESKTOP) and icons under $(DATADIR)/icons/hicolor"
endif
	@echo "installed $$($(BINDIR)/spicy --version) to $(BINDIR)/spicy"

uninstall:
	rm -f $(BINDIR)/spicy
ifeq ($(LINUX),yes)
	rm -f $(DESKTOP) $(ICONS)
endif

# The tests use a throw-away config folder (build/testcfg), never ~/.config/spicy.
vet:
	odin check src -vet
	odin check src -vet -target:windows_amd64
	odin check src -vet -target:darwin_arm64

test-unit:
	@mkdir -p build
	SPICY_CONFIG_DIR=$(CURDIR)/build/testcfg odin test tests -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false -out:build/spicy-tests

test-cli: built
	tests/cli_test.sh ./spicy

test-gui: built
	tests/gui_smoke.sh ./spicy

test: vet test-unit test-cli

clean:
	rm -f spicy
	rm -rf build

FORCE:
