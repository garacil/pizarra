# Makefile for the pizarra suite (Free Pascal).
# Produces the hub, team client/daemon, and web console binaries.

FPC        = fpc
SRC        = src
BUILD      = build
BINS       = pizarra tiza pzweb

# Build variants must never share compiled units: FPC does not encode every
# command-line option in its PPU freshness check. Keep the root fixed as well,
# so clean and compilation cannot be redirected outside this tree.
EXPECTED_BUILD := $(CURDIR)/build
ifneq ($(abspath $(BUILD)),$(EXPECTED_BUILD))
    $(error BUILD must resolve to '$(EXPECTED_BUILD)', got '$(abspath $(BUILD))')
endif
BUILD_RELEASE = $(BUILD)/release
BUILD_DEBUG   = $(BUILD)/debug
BUILD_TINY    = $(BUILD)/tiny

-include config.mk

PREFIX    ?= /usr/local
BINDIR    ?= $(PREFIX)/bin
DATADIR   ?= $(PREFIX)/share/pizarra
RELEASEDIR ?= /var/lib/pizarra/releases

# Detect the release architecture.
ARCH := $(shell uname -m)
ifeq ($(ARCH),x86_64)
    TARGET_CPU = x86_64
else ifeq ($(ARCH),aarch64)
    TARGET_CPU = aarch64
else ifneq ($(filter i386 i486 i586 i686,$(ARCH)),)
    TARGET_CPU = i386
else
    $(error Unsupported release architecture '$(ARCH)'; add and verify an explicit mapping before publishing)
endif
# Artifact naming for `make publish` must match what a daemon asks for:
# lowercase {$I %FPCTARGETOS%}-{$I %FPCTARGETCPU%} (e.g. linux-x86_64).
TARGET_OS := $(shell uname -s | tr 'A-Z' 'a-z')

# Treat compiler warnings as errors. The GCC library directory supplies the
# startup objects expected by the linker on GNU/Linux.
GCCLIB := $(shell dirname `gcc -print-file-name=crtbeginS.o` 2>/dev/null)

# Base flags: smartlink for small binaries, variant-specific units, executables
# in the repository root.
FPC_BASE    = -XX -CX -Sc -Sew -Fu$(SRC) -FE. $(if $(GCCLIB),-Fl$(GCCLIB))
FPC_RELEASE = $(FPC_BASE) -FU$(BUILD_RELEASE) -O3 -Os
FPC_DEBUG   = $(FPC_BASE) -FU$(BUILD_DEBUG) -g -gl -O1 -Ci -Co -Cr -Ct
FPC_TINY    = $(FPC_BASE) -FU$(BUILD_TINY) -O3 -Os -CfSSE2 -OoREGVAR -OoPEEPHOLE

.PHONY: all release debug static tiny clean distclean install publish check test info help

all: release

$(BUILD_RELEASE) $(BUILD_DEBUG) $(BUILD_TINY):
	@mkdir -p "$@"

# Standard optimized + stripped build (default)
release: $(BUILD_RELEASE)
	@echo "Compiling pizarra, tiza, and pzweb (release)..."
	$(FPC) $(FPC_RELEASE) -opizarra    $(SRC)/pizarra.pas
	$(FPC) $(FPC_RELEASE) -otiza       $(SRC)/tiza.pas
	$(FPC) $(FPC_RELEASE) -opzweb      $(SRC)/pzweb.pas
	strip --strip-all $(BINS)
	@echo "Built: $$(du -h pizarra | cut -f1) pizarra, $$(du -h tiza | cut -f1) tiza, $$(du -h pzweb | cut -f1) pzweb"

# Debug build with checks
debug: $(BUILD_DEBUG)
	@echo "Compiling debug..."
	$(FPC) $(FPC_DEBUG) -opizarra-debug    $(SRC)/pizarra.pas
	$(FPC) $(FPC_DEBUG) -otiza-debug       $(SRC)/tiza.pas
	$(FPC) $(FPC_DEBUG) -opzweb-debug      $(SRC)/pzweb.pas

# The threaded binaries use glibc and load SQLite dynamically, so fully static
# linking is not supported.
static:
	@echo "static linking is not supported by the threaded glibc build."
	@echo "Linked binaries depend only on libc; libsqlite3 is loaded at runtime."
	@exit 1

# Ultra-compact (experimental)
tiny: $(BUILD_TINY)
	@echo "Compiling tiny..."
	$(FPC) $(FPC_TINY) -opizarra    $(SRC)/pizarra.pas
	$(FPC) $(FPC_TINY) -otiza       $(SRC)/tiza.pas
	$(FPC) $(FPC_TINY) -opzweb      $(SRC)/pzweb.pas
	strip --strip-all $(BINS)
	upx --best $(BINS) 2>/dev/null || true

clean:
	@echo "Cleaning..."
	@test "$(abspath $(BUILD))" = "$(CURDIR)/build" || \
	  (echo "clean: refusing unexpected BUILD path: $(abspath $(BUILD))" && exit 1)
	rm -rf -- "$(CURDIR)/build"
	rm -f -- pizarra tiza pzweb pizarra-debug tiza-debug pzweb-debug
	rm -f -- *.o *.ppu *.compiled *.or link.res ppas.sh

distclean: clean
	rm -f -- config.mk

# Install the hub and web console on the control host and tiza wherever needed.
# All service bootstrap configuration lives under /etc/pizarra; see examples.
install: release
	@echo "Installing binaries and web assets..."
	install -D -m0755 pizarra $(DESTDIR)$(BINDIR)/pizarra
	install -D -m0755 tiza    $(DESTDIR)$(BINDIR)/tiza
	install -D -m0755 pzweb   $(DESTDIR)$(BINDIR)/pzweb
	install -d -m0755 $(DESTDIR)$(DATADIR)/web/apps
	install -m0644 web/apps/* $(DESTDIR)$(DATADIR)/web/apps/
	@echo "Installed binaries in $(BINDIR) and web assets in $(DATADIR)/web/apps"

# Publish release artifacts for the daemon self-update channel (cmd=upget).
# [server] releases uses RELEASEDIR. RUN THIS AFTER COMMITTING:
# src.tar.gz is cut from HEAD, so an uncommitted tree would publish a source
# snapshot that does not match the binaries.
publish: release
	@test -z "$$(git status --porcelain)" || \
	  (echo "publish: the tree has uncommitted changes - commit first" \
	   "(src.tar.gz is cut from HEAD and must match these binaries)" && exit 1)
	@case "$(RELEASEDIR)" in \
	  /*) ;; \
	  *) echo "publish: RELEASEDIR must be absolute: $(RELEASEDIR)"; exit 1 ;; \
	esac
	@test "$(RELEASEDIR)" != / || \
	  (echo "publish: refusing RELEASEDIR=/" && exit 1)
	@test ! -L "$(RELEASEDIR)" || \
	  (echo "publish: refusing symbolic-link RELEASEDIR: $(RELEASEDIR)" && exit 1)
	install -d -m0700 "$(RELEASEDIR)"
	@# stage + rename: the hub serves this dir live, so a half-written
	@# artifact must never be visible to a downloading daemon
	install -m0755 tiza "$(RELEASEDIR)/.tiza-$(TARGET_OS)-$(TARGET_CPU).tmp"
	git archive --format=tar.gz --prefix=pizarra/ -o "$(RELEASEDIR)/.src.tar.gz.tmp" HEAD
	chmod 0644 "$(RELEASEDIR)/.src.tar.gz.tmp"
	./tiza --version | awk '{print $$2}' > "$(RELEASEDIR)/.VERSION.tmp"
	chmod 0644 "$(RELEASEDIR)/.VERSION.tmp"
	mv -f -- "$(RELEASEDIR)/.tiza-$(TARGET_OS)-$(TARGET_CPU).tmp" "$(RELEASEDIR)/tiza-$(TARGET_OS)-$(TARGET_CPU)"
	mv -f -- "$(RELEASEDIR)/.src.tar.gz.tmp" "$(RELEASEDIR)/src.tar.gz"
	@# VERSION last: it is the flag that makes the hub serve this release
	mv -f -- "$(RELEASEDIR)/.VERSION.tmp" "$(RELEASEDIR)/VERSION"
	@echo "Published release $$(cat "$(RELEASEDIR)/VERSION"): tiza-$(TARGET_OS)-$(TARGET_CPU) + src.tar.gz in $(RELEASEDIR)"

check:
	@which $(FPC) >/dev/null || (echo "FPC not installed" && exit 1)
	@echo "FPC: $$($(FPC) -iV)  arch: $(TARGET_CPU)"

test: release
	@./pizarra --version
	@./tiza --version
	@./pzweb --version

info:
	@for b in $(BINS); do \
	  if [ -f $$b ]; then \
	    echo "--- $$b ---"; \
	    echo "size: $$(du -h $$b | cut -f1)"; \
	    ldd $$b 2>/dev/null | head -4 || echo "  (static)"; \
	  fi; \
	done

help:
	@echo "Configure: ./configure [--prefix=PATH] [--bindir=PATH] [--datadir=PATH]"
	@echo "Targets: release (default) | debug | tiny | clean | distclean | install | publish | check | test | info"
