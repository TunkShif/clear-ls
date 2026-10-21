# clear-ls build
#
#   make            build bin/clear-ls (fetches and compiles pinned deps)
#   make release    optimised build (use this for editor use)
#   make spec       run specs
#   make verify-static   check no dynamic Tree-sitter dependency
#   make grammar-check   parse the Crystal stdlib, list grammar failures
#   make syntax-gen      regenerate src/clear_ls/syntax/kinds.cr
#   make probes          build analysis probes into bin/probes/ (tools/README.md)
#   make nvim-check      headless Neovim checks against tools/fixtures/
#   make distclean  remove deps and build outputs

CRYSTAL ?= crystal
SHARDS ?= shards
CC ?= cc
AR ?= ar
GIT ?= git
TREE_SITTER_CLI ?= tree-sitter

TREE_SITTER_REPO ?= https://github.com/tree-sitter/tree-sitter
TREE_SITTER_REV ?= v0.26.9
GRAMMAR_REPO ?= https://github.com/crystal-lang-tools/tree-sitter-crystal
GRAMMAR_REV ?= 50ca9e6fcfb16a2cbcad59203cfd8ad650e25c49

ROOT := $(abspath .)
VENDOR := $(ROOT)/vendor
BUILD := $(ROOT)/build
TS_DIR := $(VENDOR)/tree-sitter
GRAMMAR_DIR := $(VENDOR)/tree-sitter-crystal
LIB_DIR := $(BUILD)/lib
PC_DIR := $(BUILD)/pkgconfig
TS_LIB := $(LIB_DIR)/libtree-sitter.a
GRAMMAR_LIB := $(LIB_DIR)/libtree-sitter-crystal.a
TS_PC := $(PC_DIR)/tree-sitter.pc
GRAMMAR_PC := $(PC_DIR)/tree-sitter-crystal.pc
BIN := bin/clear-ls

CFLAGS ?= -O2
CFLAGS += -fPIC
# Tree-sitter uses libc malloc rather than the binding's default Boehm GC
# hook: 17 MB vs 282 MB GC heap for the parsed stdlib, and ~4.7x faster
# parallel parsing. Native trees are freed by `Tree#finalize`.
CRYSTAL_FLAGS ?= -Dcrystal_tree_sitter_no_init

export CRYSTAL_CACHE_DIR ?= $(ROOT)/.crystal-cache
export PKG_CONFIG_PATH := $(PC_DIR):$(PKG_CONFIG_PATH)

SOURCES := $(shell find src -name '*.cr' 2>/dev/null)

.PHONY: all build release deps spec verify-static grammar-check syntax-gen probes nvim-check clean distclean

all: build

build: $(BIN)

deps: lib/tree_sitter $(TS_PC) $(GRAMMAR_PC)

$(BIN): deps $(SOURCES)
	@mkdir -p bin
	$(CRYSTAL) build $(CRYSTAL_FLAGS) src/main.cr -o $(BIN)

release: deps
	@mkdir -p bin
	$(CRYSTAL) build --release $(CRYSTAL_FLAGS) src/main.cr -o $(BIN)

spec: deps
	$(CRYSTAL) spec $(CRYSTAL_FLAGS)

lib/tree_sitter: shard.yml
	$(SHARDS) install
	@touch $@

$(TS_DIR):
	$(GIT) clone --quiet --depth 1 --branch $(TREE_SITTER_REV) $(TREE_SITTER_REPO) $@

$(GRAMMAR_DIR):
	$(GIT) clone --quiet $(GRAMMAR_REPO) $@
	$(GIT) -C $@ checkout --quiet $(GRAMMAR_REV)

$(TS_LIB): | $(TS_DIR)
	@mkdir -p $(BUILD)/obj $(LIB_DIR)
	$(CC) $(CFLAGS) -I$(TS_DIR)/lib/include -I$(TS_DIR)/lib/src -c $(TS_DIR)/lib/src/lib.c -o $(BUILD)/obj/tree-sitter.o
	$(AR) rcs $@ $(BUILD)/obj/tree-sitter.o

$(GRAMMAR_LIB): | $(GRAMMAR_DIR)
	@mkdir -p $(BUILD)/obj $(LIB_DIR)
	$(CC) $(CFLAGS) -I$(GRAMMAR_DIR)/src -c $(GRAMMAR_DIR)/src/parser.c -o $(BUILD)/obj/crystal-parser.o
	$(CC) $(CFLAGS) -I$(GRAMMAR_DIR)/src -c $(GRAMMAR_DIR)/src/scanner.c -o $(BUILD)/obj/crystal-scanner.o
	$(AR) rcs $@ $(BUILD)/obj/crystal-parser.o $(BUILD)/obj/crystal-scanner.o

# Local pkg-config files name the archives directly so the linker cannot
# pick a same-named shared library from the system.
$(TS_PC): $(TS_LIB)
	@mkdir -p $(PC_DIR)
	@printf 'Name: tree-sitter\nDescription: static runtime\nVersion: %s\nLibs: %s\nCflags:\n' \
	  "$(TREE_SITTER_REV)" "$(TS_LIB)" > $@

$(GRAMMAR_PC): $(GRAMMAR_LIB)
	@mkdir -p $(PC_DIR)
	@printf 'Name: tree-sitter-crystal\nDescription: static grammar\nVersion: 0\nLibs: %s\nCflags:\n' \
	  "$(GRAMMAR_LIB)" > $@

verify-static: $(BIN)
	@if command -v ldd >/dev/null 2>&1 && ldd $(BIN) | grep -q tree-sitter; then \
	  echo "FAIL: dynamic tree-sitter dependency"; ldd $(BIN); exit 1; fi
	@nm $(BIN) | grep -q ' T tree_sitter_crystal$$' || { echo "FAIL: grammar not embedded"; exit 1; }
	@nm $(BIN) | grep -q ' T ts_parser_new$$' || { echo "FAIL: runtime not embedded"; exit 1; }
	@echo "OK: tree-sitter runtime and crystal grammar statically linked"

STDLIB := $(shell $(CRYSTAL) env CRYSTAL_PATH 2>/dev/null | tr ':' '\n' | grep -v '^lib$$' | tail -1)

grammar-check: | $(GRAMMAR_DIR)
	@mkdir -p $(BUILD)
	@find $(STDLIB) -name '*.cr' | sort > $(BUILD)/stdlib-files.txt
	@cd $(GRAMMAR_DIR) && $(TREE_SITTER_CLI) parse -q -s --paths $(BUILD)/stdlib-files.txt 2>&1 | \
	  sed 's|$(STDLIB)/||' | grep -E 'ERROR|MISSING|Total parses' || true

syntax-gen: | $(GRAMMAR_DIR)
	$(CRYSTAL) run tools/gen_syntax.cr -- $(GRAMMAR_DIR)/src/node-types.json src/clear_ls/syntax/kinds.cr

PROBES := $(patsubst tools/probes/%.cr,bin/probes/%,$(wildcard tools/probes/*.cr))

probes: $(PROBES)

bin/probes/%: tools/probes/%.cr deps $(SOURCES)
	@mkdir -p bin/probes
	$(CRYSTAL) build --release $(CRYSTAL_FLAGS) $< -o $@

# Copies each fixture project to a temp dir and drives the release binary
# from headless Neovim; prints results for review (no assertions).
NVIM ?= nvim
NVIM_CHECKS ?= smoke calls chains compiler

nvim-check: release
	@for c in $(NVIM_CHECKS); do echo "== $$c"; tools/nvim/run.sh $$c || exit 1; done

clean:
	rm -rf bin $(CRYSTAL_CACHE_DIR)

distclean: clean
	rm -rf $(BUILD) $(VENDOR) lib
