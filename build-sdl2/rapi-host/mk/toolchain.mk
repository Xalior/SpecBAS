#
# toolchain.mk finds the make this build needs, and the Arm GNU aarch64-none-elf
# cross toolchain it compiles with.
#
# Include this at the top of any makefile here that compiles for the Pi.
#
# GNU make 4.0 or later. Earlier versions compare file timestamps to the
# second, so a source rewritten within the same second its object was compiled
# in is never seen as newer and the stale object stays in the link.
ifeq ($(filter 1.% 2.% 3.%,$(MAKE_VERSION)),$(MAKE_VERSION))
$(error this build needs GNU make 4.0 or later; this is '$(MAKE)' version '$(MAKE_VERSION)')
endif

# `make -n` runs any recipe line containing $(MAKE), so a recursive target
# builds for real under it. Recursive targets put NOT_DRY_RUN first and refuse.
DRY_RUN     := $(findstring n,$(firstword -$(MAKEFLAGS)))
NOT_DRY_RUN  = $(if $(DRY_RUN),echo "$@: no dry run. This recipe drives sub-makes and make -n executes those for real." >&2; exit 1,:)

# ---------------------------------------------------------------------------
# The cross toolchain
# ---------------------------------------------------------------------------
#
# The cross compiler is looked for on PATH first, so a machine that already has
# it installed is left alone. Failing that, RAPI_TOOLCHAIN_DIR names one
# unpacked toolchain, or a directory holding one or more unpacked releases.
#
# The toolchain is never searched for beyond that and never fetched. Free
# Pascal must use the same assembler Circle's build does, for its objects to
# link with Circle's, so there is one toolchain in the picture and it is named
# rather than discovered.
#
# There is no copy in this port: it is a couple of gigabytes of vendor
# binaries. Download release 15.2.Rel1 for the aarch64-none-elf target,
# matching the machine you build ON, from
# https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads, unpack it
# somewhere, and name it.

TOOLCHAIN_MK_DIR := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))
PORT_ROOT        := $(abspath $(TOOLCHAIN_MK_DIR)/..)

ifeq ($(shell command -v aarch64-none-elf-gcc 2>/dev/null),)
TOOLCHAIN_BIN := $(firstword \
	$(wildcard $(RAPI_TOOLCHAIN_DIR)/arm-gnu-toolchain-*-aarch64-none-elf/bin) \
	$(wildcard $(RAPI_TOOLCHAIN_DIR)/bin))
ifneq ($(TOOLCHAIN_BIN),)
export PATH := $(TOOLCHAIN_BIN):$(PATH)
endif
endif

.PHONY: check-toolchain
check-toolchain:
	@command -v aarch64-none-elf-g++ >/dev/null 2>&1 || { \
		echo "aarch64-none-elf-g++ not found."; \
		echo "Put the Arm GNU aarch64-none-elf toolchain on your PATH, or set"; \
		echo "RAPI_TOOLCHAIN_DIR to where it lives. See mk/toolchain.mk."; \
		echo "Do not fetch one."; \
		exit 1; }
	@echo "  TOOLCHAIN $$(command -v aarch64-none-elf-g++)"
	@aarch64-none-elf-g++ --version | head -1
