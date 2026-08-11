# build-sdl2/Makefile
#
# Builds SpecBAS with the SDL2 backend, using plain Free Pascal. No Lazarus,
# no lazbuild, no .lpi, no package manager.
#
#   make deps      fetch the outside pieces into vendor/
#   make           build the executable
#   make app       macOS only: build build/SpecBAS.app, self-contained
#   make clean     remove build/
#   make distclean also remove vendor/
#
# Linking against a framework from fpc (macOS):
#
#   SDL2-for-Pascal's sdl2.pas carries {$LINKLIB libSDL2} for Darwin, so fpc
#   always asks the linker for a library named libSDL2 and there is no
#   switch to stop it. build/link/ holds one symlink, libSDL2.dylib,
#   pointing at the framework's Mach-O binary. The linker follows it, reads
#   the binary's own LC_ID_DYLIB, and records that name in the executable —
#   @rpath/SDL2.framework/Versions/A/SDL2, exactly the dependency a bundled
#   framework needs. The symlink exists only at link time; nothing is copied
#   and nothing is rewritten, so the framework's signature stays valid.
#
#   On Linux SDL2 comes from the system: sdl2.pas names libSDL2.so, fpc
#   turns that into -lSDL2, and the distribution's development package
#   supplies it.

FPC        ?= fpc
APP_NAME   ?= SpecBAS
BIN_NAME   ?= specbas

HERE       := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
ROOT       := $(dir $(HERE))
SRC        := $(ROOT)src
VENDOR     := $(HERE)/vendor
BUILD      := $(HERE)/build
UNITS      := $(VENDOR)/SDL2-for-Pascal/units
FRAMEWORK  := $(VENDOR)/SDL2.framework
LINKDIR    := $(BUILD)/link
OBJDIR     := $(BUILD)/obj
APP        := $(BUILD)/$(APP_NAME).app
PROGRAM    := $(SRC)/SpecBAS_SDL2.dpr

UNAME_S    := $(shell uname -s)

# -O1, not -O2: Free Pascal 3.2.2 for aarch64 raises internal error
# 200510011 on SP_FPEditor.pas at -O2. Seen on both macOS and Linux hosts.
#
# -Mdelphi matches the mode every SpecBAS unit selects for itself.
FPCFLAGS   := -MDelphi -Sh -O1 -vew -Fu$(SRC) -Fi$(SRC) -Fu$(UNITS) -Fi$(UNITS)

ifeq ($(UNAME_S),Darwin)
# -WM11.0 pins the deployment target to the same macOS 11 floor the SDL2
# release framework carries, so the bundle is not silently tied to whatever
# macOS the build host happens to run.
#
# -undefined dynamic_lookup leaves the BASS imports unresolved at link time.
# bass.pas declares them "delayed", which Free Pascal honours only on
# Windows; elsewhere they become ordinary imports and the link fails without
# a BASS library present. SpecBAS loads BASS by hand at startup and runs
# silent when the load fails, so nothing calls those symbols when the
# library is absent, and a build is not blocked on obtaining one (SPX-006).
FPCFLAGS   += -WM11.0 -Fl$(LINKDIR) -k-rpath -k@executable_path/../Frameworks \
              -k-undefined -kdynamic_lookup
LINKDEPS   := $(LINKDIR)/libSDL2.dylib
else
# The same BASS problem, and Linux needs two pieces to answer it, because
# GNU ld fails earlier than Apple's does.
#
#   1. bass.pas names its library "libbass.so", which fpc hands to the
#      linker as -lbass, so the link dies on a missing library before it
#      ever reaches the symbols. build/link/libbass.so is an empty GNU ld
#      linker script: -lbass finds it, it contributes nothing, and — unlike
#      a stub shared object — it leaves no DT_NEEDED behind, so the finished
#      executable does not ask for a BASS library at run time either.
#   2. --unresolved-symbols=ignore-all then lets the BASS_* symbols stay
#      undefined, which is what "delayed" does on Windows.
#
# Nothing calls those symbols while BASS is absent: SoundEnabled is only
# ever set from a successful run-time load, so SpecBAS runs silent.
FPCFLAGS   += -Fl$(LINKDIR) -k--unresolved-symbols=ignore-all
LINKDEPS   := $(LINKDIR)/libbass.so
endif

.PHONY: all deps exe app clean distclean

all: exe

deps:
	@$(HERE)/fetch-deps.sh

$(LINKDIR)/libSDL2.dylib: $(FRAMEWORK)/Versions/A/SDL2
	@mkdir -p $(LINKDIR)
	@ln -sf $(FRAMEWORK)/Versions/A/SDL2 $@

$(LINKDIR)/libbass.so:
	@mkdir -p $(LINKDIR)
	@printf '/* Empty linker script. See the BASS note in build-sdl2/Makefile. */\n' > $@

exe: $(LINKDEPS)
	@mkdir -p $(OBJDIR)
	$(FPC) $(FPCFLAGS) -FU$(OBJDIR) -FE$(OBJDIR) -o$(OBJDIR)/$(BIN_NAME) $(PROGRAM)

app: exe
ifeq ($(UNAME_S),Darwin)
	@$(HERE)/bundle.sh $(OBJDIR)/$(BIN_NAME) $(FRAMEWORK) $(APP) $(BIN_NAME)
else
	@echo "make app builds a macOS application bundle; on $(UNAME_S) the"
	@echo "executable in $(OBJDIR) is the build product."
endif

clean:
	rm -rf $(BUILD)

distclean: clean
	rm -rf $(VENDOR)
