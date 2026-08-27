#
# rapi-host builds SpecBAS as a bootable bare-metal Raspberry Pi image.
#
#   make check-toolchain     report the cross compiler this build will use
#   make check-deps          report the Circle world, the SDL2 archive and the
#                            Free Pascal compiler this build will use
#   make rpi5 | rpi4 | rpi3  one board's kernel image
#   make kernels             every board in BOARDS, built in parallel
#   make verify              truth-gate: every image exists and is non-empty
#   make card                stage a card directory into build/sd-card/
#   make clean-boards        drop every board's build tree
#
# Nothing here builds a Circle world or a Free Pascal compiler. Both are large,
# both belong to the repositories that own them, and a build that appears to
# want one started is a wrong variable. See check-deps.
#
# NOTHING HERE IS THE HOST KERNEL EITHER. The board bring-up, the card mount,
# the core split and the call into SpecBAS's entry point are circle-libfpc's
# host/host-kernel.mk, included below the same way fpc-app.mk and sdl-app.mk
# are. The only C in this directory is stubs/bass.c, and that is not a kernel:
# it is the audio library SpecBAS loads at run time on a desktop, answered
# here by a file that answers failure, because the link needs the symbols and
# this machine has no loader. Read its header.
#
# THE INTERPRETER ITSELF IS NOT COPIED AND NOT PATCHED. Unlike the game ports
# in this family, which vendor an upstream checkout and patch a copy of it,
# SpecBAS's own source is two directories up in ../../src and is compiled
# where it lies. This port is part of the SpecBAS repository, so a change
# SpecBAS needs for this target is made in SpecBAS, guarded on CIRCLESDL2, and
# is as visible as any other change to it.
#
# The bench holds a Pi 5, and rpi5 is the only world built, so BOARDS names it
# alone. Set BOARDS to build more.
#

include mk/toolchain.mk

# Stated, because the first rule seen comes from an included makefile.
.DEFAULT_GOAL := help

BOARDS ?= rpi5
BOARD  ?= rpi5

ifeq ($(filter $(BOARD),$(BOARDS) rpi3 rpi4 rpi5),)
$(error BOARD must be one of: rpi3 rpi4 rpi5, not `$(BOARD)')
endif

IMAGE_rpi3 = kernel8
IMAGE_rpi4 = kernel8-rpi4
IMAGE_rpi5 = kernel_2712
IMAGE      = $(IMAGE_$(BOARD))

PORT = $(CURDIR)

# SPECBAS ITSELF: the interpreter this image boots into, in the repository
# this directory is part of. Not a submodule and not a copy: the same tree the
# desktop SDL2 build in ../ compiles.
SPECBAS_SRC = $(abspath $(PORT)/../../src)

# CIRCLE-LIBFPC IS THE ONE DEPENDENCY THIS PORT NAMES. It is the Free Pascal
# side of the build -- the cross-compiler, its runtime, Free Pascal's packages,
# the SDL2-for-Pascal binding with this target's arm already in it, and the
# host kernel at host/host-kernel.mk, which this port includes rather than
# carrying a copy of its own. It owns the dependency on the SDL layer, so the
# SDL layer is reached through it and never named here directly.
LIBFPC_HOME   ?= $(PORT)/circle-libfpc

# The SDL layer, reached through the SDK that owns it. A build inside a larger
# repository overrides these to point at that repository's editing copies,
# which is where the worlds and the compiler are actually built. Never build a
# world from here -- a missing one is a wrong variable.
SHIM          ?= $(LIBFPC_HOME)/circle-libsdl2
CIRCLE_WORLDS ?= $(LIBFPC_HOME)/circle-libsdl2

FPC_COMPILER ?= $(LIBFPC_HOME)/fpc/compiler/ppcrossa64
FPC_UNITS    ?= $(LIBFPC_HOME)/fpc/rtl/units/aarch64-circlesdl2
# SPECBAS NEEDS THE PACKAGE UNITS, not only the runtime ones: StrUtils and
# DateUtils for its text and its clock, Generics.Collections for its
# containers, and the object-Pascal half of Classes. Every one of those lives
# in a package.
FPC_PACKAGES ?= $(LIBFPC_HOME)/fpc/packages

# THE PASCAL SDL2 BINDING, and it is circle-libfpc's rather than ../vendor's.
#
# The desktop build fetches SDL2-for-Pascal into ../vendor with fetch-deps.sh;
# circle-libfpc vendors the same binding at the same upstream revision with
# the one arm this target needs already applied (third-party/sdl2-for-pascal,
# and patches/README.md there says what that arm is and why the alternatives
# do not work). Taking it from there means this build fetches nothing, and the
# arm is maintained once, in the repository every Pascal port on this target
# already depends on.
SDL2_PASCAL = $(LIBFPC_HOME)/third-party/sdl2-for-pascal

# WHERE SPECBAS'S FILES ARE ON THE CARD, AND IT IS A BUILD PARAMETER.
#
# The kernel gives two answers about the card and both come from this: the
# working directory, which is what makes SpecBAS's own relative paths resolve
# and where LOAD and SAVE land; and the base path SDL_GetPrefPath is derived
# from. The kernel's own default is the card's root; this port sets its own,
# so the root of the card stays clear.
RAPI_WORK_DIR ?= /specbas

# No display size is named here: circle-libsdl2 settles the canvas from the
# --rapi-vfb switch, a declared device, the first window's size, or the panel.
# This port supplies none of the first three, so the panel answers. A loader
# can still stamp the switch into a single boot without a rebuild.

# Passed to every self-recursive board build below. Each has a default above
# naming this port's own pinned copy; the parent repository overrides them to
# its editing copies, where the worlds and the compiler are actually built.
BOARD_ARGS = SHIM=$(SHIM) CIRCLE_WORLDS=$(CIRCLE_WORLDS) \
	LIBFPC_HOME=$(LIBFPC_HOME) FPC_COMPILER=$(FPC_COMPILER) \
	FPC_UNITS=$(FPC_UNITS) FPC_PACKAGES=$(FPC_PACKAGES) \
	RAPI_WORK_DIR=$(RAPI_WORK_DIR)

.PHONY: help kernels rebuild verify card clean-boards check-deps $(BOARDS)
.PHONY: $(addprefix rebuild-,$(BOARDS)) build check-deps-report clean-board

help:
	@sed -n '2,32p' $(firstword $(MAKEFILE_LIST)) | sed 's/^# \{0,1\}//'

# ---------------------------------------------------------------------------
# Every board at once, one board, or a rebuild. Each self-recurses into this
# same Makefile with BOARD set and an explicit target, because the board's
# world, its object directory and its image name are all settled once per
# parse from BOARD, and a single parse cannot answer for two boards.
# ---------------------------------------------------------------------------

# What this build will reach for, reported rather than assumed. Answered by a
# recursive parse for the first board in BOARDS, because that is where WORLD
# and the rest are settled.
check-deps:
	+@$(NOT_DRY_RUN)
	@$(MAKE) --no-print-directory BOARD=$(firstword $(BOARDS)) $(BOARD_ARGS) check-deps-report

$(BOARDS): check-toolchain
	+@$(NOT_DRY_RUN)
	$(MAKE) BOARD=$@ $(BOARD_ARGS) build

# Every board at once. Each owns a different world and a different output
# directory, so there is nothing for them to collide on.
#
# Each board is waited for BY PID, and its status kept. A bare `wait` reports
# only that the shell has no children left, which is success whatever the jobs
# did, so a board that failed to build would leave this target reporting
# success, and the truth-gate would then pass that board's PREVIOUS image,
# still on disk.
kernels: check-toolchain
	+@$(NOT_DRY_RUN)
	@pids=; fail=0; \
	for b in $(BOARDS); do $(MAKE) BOARD=$$b $(BOARD_ARGS) build & pids="$$pids $$!"; done; \
	for p in $$pids; do wait $$p || fail=1; done; \
	exit $$fail

# One board from nothing, so no object is inherited from a previous build.
# A static pattern rule, because phony targets do not match pattern rules.
$(addprefix rebuild-,$(BOARDS)): rebuild-%: check-toolchain
	+@$(NOT_DRY_RUN)
	$(MAKE) BOARD=$* $(BOARD_ARGS) clean-board
	$(MAKE) BOARD=$* $(BOARD_ARGS) build

rebuild: check-toolchain
	+@$(NOT_DRY_RUN)
	@pids=; fail=0; \
	for b in $(BOARDS); do \
		( $(MAKE) BOARD=$$b $(BOARD_ARGS) clean-board && \
		  $(MAKE) BOARD=$$b $(BOARD_ARGS) build ) & pids="$$pids $$!"; \
	done; \
	for p in $$pids; do wait $$p || fail=1; done; \
	exit $$fail

# Truth-gate: ask the filesystem, not the exit codes. An image that is missing
# or empty fails here even if the build claimed success.
#
# What this cannot tell you is whether the image was built from the sources as
# they now stand. That is a question about the build, not about the file, and
# `make rebuild` is the only answer to it.
verify:
	@fail=0; \
	for b in $(BOARDS); do \
		case $$b in \
			rpi3) img=build/rpi3/$(IMAGE_rpi3).img ;; \
			rpi4) img=build/rpi4/$(IMAGE_rpi4).img ;; \
			rpi5) img=build/rpi5/$(IMAGE_rpi5).img ;; \
		esac; \
		if [ ! -s "$$img" ]; then \
			echo "  FAIL  $$img missing or empty"; fail=1; \
		else \
			echo "  OK    $$img ($$(wc -c < $$img | tr -d ' ') bytes)"; \
		fi; \
	done; \
	exit $$fail

# ---------------------------------------------------------------------------
# The card
# ---------------------------------------------------------------------------
#
# SpecBAS carries its own fonts and its own everything: the desktop bundle in
# ../ is the executable and SDL2, with no data directory beside it. So there
# is nothing to stage but the empty directory the kernel will make its working
# directory, which has to exist on the card before SpecBAS can write a program
# into it.
#
# This writes no firmware, no boot configuration and no kernel image. Nothing
# here claims to produce a whole card.
CARD_DIR = build/sd-card

card:
	@rm -rf $(CARD_DIR)
	@mkdir -p $(CARD_DIR)$(RAPI_WORK_DIR)
	@echo "  CARD  staged $(CARD_DIR), copy its contents to the root of the card"
	@echo "        SpecBAS will read and write its files at $(RAPI_WORK_DIR)"

clean-boards:
	@for b in $(BOARDS); do $(MAKE) BOARD=$$b $(BOARD_ARGS) clean-board; done
	@rm -rf $(CARD_DIR)

# ---------------------------------------------------------------------------
# One board's build. Guarded on its world being configured, so `help`,
# `verify`, `card` and `clean-boards` above answer with no world at all. A
# missing one is reported by check-deps and refused here, never assumed.
# ---------------------------------------------------------------------------

WORLD = $(CIRCLE_WORLDS)/circle-stdlib-$(BOARD)

ifneq ($(wildcard $(WORLD)/Config.mk),)

include $(WORLD)/Config.mk

OBJDIR = build/$(BOARD)
GENDIR = $(OBJDIR)/gen
TARGET = $(OBJDIR)/$(IMAGE)

# ---------------------------------------------------------------------------
# The host kernel
# ---------------------------------------------------------------------------
#
# Circle-libfpc's, not this port's. See host/host-kernel.mk there for what it
# does and why. Before Rules.mk, it needs the C++ dialect and the dependency-
# tracking switch it and this port's own compile both use.
STANDARD   = -std=c++23 -Wno-volatile
CHECK_DEPS = 0

# sdl-app.mk replaces Circle's own $(TARGET).img rule. Pointing TARGET at a
# name nothing builds while Rules.mk is read attaches its rule there instead.
# The card's read cache, from circle-libsdl2. It must come BEFORE Rules.mk,
# which reads OBJS as it is included - a source added after it is one make
# never checks. RAPI_DISKCACHE turns on the host kernel's half.
include $(SHIM)/circle-diskcache/diskcache.mk
DEFINE += -DRAPI_DISKCACHE

SDL_APP_IMAGE := $(TARGET)
TARGET := $(OBJDIR)/.circle-unused
include $(CIRCLEHOME)/Rules.mk
TARGET := $(SDL_APP_IMAGE)

include $(LIBFPC_HOME)/host/host-kernel.mk
# A plain assignment, so anything OBJS already held is dropped here on purpose
# - the host kernel's objects are the base this image is built from. Everything
# else is added back below, the card's read cache included: diskcache.mk put
# its object in OBJS before Rules.mk, which is where Rules.mk had to see it,
# and this line is after that.
OBJS = $(HOST_KERNEL_OBJS) $(DISKCACHE_OBJ)

# ---------------------------------------------------------------------------
# The BASS stub
# ---------------------------------------------------------------------------
#
# Its own rule, because host-kernel.mk's pattern rule reaches only that
# kernel's own C++ sources and Circle's Rules.mk would build this beside its
# source rather than under the board's object directory. Read stubs/bass.c for
# what it is and why the link needs it.
OBJS += $(OBJDIR)/bass.o

$(OBJDIR)/bass.o: $(PORT)/stubs/bass.c | $(OBJDIR)
	@echo "  CC    $@"
	@$(CC) $(CFLAGS) -MD -MP -c -o $@ $<

-include $(OBJDIR)/bass.d

# ---------------------------------------------------------------------------
# SpecBAS
# ---------------------------------------------------------------------------
#
# THE VERSION SPECBAS SHOWS IN ITS TITLE BAR AND IN BUILDSTR.
#
# On Windows it comes from the executable's own VERSIONINFO resource, read
# back at run time. src/SpecBAS.rc is where that resource is written, so it is
# the project's one statement of its own version; this build reads that same
# file rather than keeping a second copy of the number, exactly as the desktop
# SDL2 build in ../ does. Only the last two of the four components are used,
# because that is what the Windows title bar shows.
VERSION_RC  = $(SPECBAS_SRC)/SpecBAS.rc
VERSION_INC = $(GENDIR)/SpecBAS_Version.inc

$(VERSION_INC): $(VERSION_RC) | $(GENDIR)
	@echo "  GEN   $@"
	@sed -n 's/^FILEVERSION *\([0-9]*\),\([0-9]*\),\([0-9]*\),\([0-9]*\).*/'"'"'\3.\4'"'"'/p' \
	    $(VERSION_RC) > $@
	@test -s $@ || { echo "no FILEVERSION in $(VERSION_RC)" >&2; rm -f $@; exit 1; }

$(GENDIR):
	@mkdir -p $(GENDIR)

# WHERE THE PASCAL SOURCE IS, AND IN WHICH ORDER IT IS SEARCHED.
#
#   $(SPECBAS_SRC)  the interpreter's own units, compiled where they lie.
#   $(SDL2_PASCAL)  the SDL2-for-Pascal binding, with this target's arm. The
#                   library it names is resolved at link time against
#                   circle-libsdl2 instead of against a shared object.
#   units/          circle-libsdl2's Circle extensions, which no SDL binding
#                   carries because they are not in SDL's headers. SpecBAS
#                   never names this unit, because the host kernel makes every
#                   Circle declaration, but it is on the path for anything that
#                   does.
FPC_UNIT_SRC_DIRS = $(SPECBAS_SRC) $(SDL2_PASCAL) $(LIBFPC_HOME)/units

# The switches the desktop SDL2 build uses, and for the same reasons. See
# ../Makefile, which states each of them:
#
#   -MDelphi  the mode every SpecBAS unit selects for itself.
#   -O1       not -O2: Free Pascal 3.2.2 for aarch64 raises internal error
#             200510011 on SP_FPEditor.pas at -O2.
#   -Fi       the include path: SpecBAS.inc beside the sources, and the
#             generated version include above.
FPC_EXTRA_FLAGS = -MDelphi -Sh -O1 -vew \
	-Fi$(SPECBAS_SRC) -Fi$(SDL2_PASCAL) -Fi$(GENDIR)

# fpc-app.mk needs PREFIX and AR, which Rules.mk has just settled, and its
# results have to be in hand before LIBS and OBJS are finished below.
FPC_APP      = $(SPECBAS_SRC)/SpecBAS_SDL2.dpr
FPC_BLOB_DIR = $(OBJDIR)/fpcblob
include $(LIBFPC_HOME)/fpc-app.mk

ifeq ($(strip $(FPC_PACKAGE_UNITS)),)
$(error no package units under $(FPC_PACKAGES). Build them with `make fpc-packages' in the parent repository; SpecBAS is written in units that live there)
endif

# The generated version include is read by SP_SDL2Host as it compiles, so it
# has to exist before the compiler runs. fpc-app.mk states that object's own
# prerequisites; this adds one to them.
$(FPC_APP_OBJ): $(VERSION_INC)

# SpecBAS's own object joins the kernel's. sdl-app-init.ld defers the
# constructors of everything arriving as an OBJECT until the kernel exists,
# and runs everything arriving as an ARCHIVE member early; SpecBAS is the
# application, so it belongs on the object side of that line.
OBJS += $(FPC_APP_OBJS)

# The Free Pascal runtime units and this library's C half go inside the link's
# --start-group with everything else: SpecBAS's object and the runtime refer
# to each other in both directions, so neither can simply come first.
LIBS := $(FPC_APP_LIBS) $(SHIM)/libSDL2-$(BOARD).a $(CIRCLE_STDLIB_LIBS)

include $(SHIM)/sdl-app.mk

# The image, and nothing done to it afterwards. Ports that fix a canvas size
# stamp it into the boot argument block here with circle-libsdl2's
# tools/stamp-bootargs; this one names no size at all, so the linked image is
# the finished article.
build: $(TARGET).img

# What this build reached for, read out of the variables that decided it. Every
# line is a path; the mark beside it says whether that path is there. Nothing
# here builds anything, and a missing world or compiler is reported rather than
# started.
check-deps-report:
	@echo "  BOARD     $(BOARD)"
	@echo "  WORK DIR  $(RAPI_WORK_DIR)"
	@for p in "SPECBAS   $(SPECBAS_SRC)/SpecBAS_SDL2.dpr" \
		  "WORLD     $(WORLD)/Config.mk" \
		  "ARCHIVE   $(SHIM)/libSDL2-$(BOARD).a" \
		  "LIBFPC    $(LIBFPC_HOME)/fpc-app.mk" \
		  "BINDING   $(SDL2_PASCAL)/sdl2.pas" \
		  "COMPILER  $(FPC_COMPILER)" \
		  "RTL       $(FPC_UNITS)" \
		  "PACKAGES  $(FPC_PACKAGES)"; do \
		path=$${p#* }; path=$${path##* }; \
		if [ -e "$$path" ]; then echo "  $$p"; else echo "  $$p   ABSENT"; fi; \
	done

clean-board: fpc-app-clean
	@rm -rf $(OBJDIR)

else

build check-deps-report clean-board:
	@echo "the $(BOARD) world is not configured ($(WORLD)/Config.mk is missing)."
	@echo "CIRCLE_WORLDS says where the worlds are; they are circle-libsdl2's to"
	@echo "build, never this build's to start."
	@exit 1

endif

# Stops the pattern rule above matching this file.
Makefile: ;
