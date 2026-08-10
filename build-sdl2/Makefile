# build-sdl2/Makefile
#
# Builds SpecBAS with the SDL2 backend, using plain Free Pascal. No Lazarus,
# no lazbuild, no .lpi, no package manager.
#
#   make deps      fetch SDL2.framework and the Pascal bindings into vendor/
#   make           build the executable
#   make app       build build/SpecBAS.app, self-contained
#   make clean     remove build/
#   make distclean also remove vendor/
#
# Linking against a framework from fpc:
#
#   SDL2-for-Pascal's sdl2.pas carries {$LINKLIB libSDL2} for Darwin, so fpc
#   always asks the linker for a library named libSDL2 and there is no
#   switch to stop it. build/link/ holds one symlink, libSDL2.dylib,
#   pointing at the framework's Mach-O binary. The linker follows it, reads
#   the binary's own LC_ID_DYLIB, and records that name in the executable —
#   @rpath/SDL2.framework/Versions/A/SDL2, exactly the dependency a bundled
#   framework needs. The symlink exists only at link time; nothing is copied
#   and nothing is rewritten, so the framework's signature stays valid.

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

# -WM11.0 pins the deployment target to the same macOS 11 floor the SDL2
# release framework carries, so the bundle is not silently tied to whatever
# macOS the build host happens to run.
# -Mdelphi matches the mode every SpecBAS unit selects for itself.
FPCFLAGS   := -MDelphi -Sh -O2 -vewn -Fu$(SRC) -Fi$(SRC) -Fu$(UNITS) -Fi$(UNITS)

ifeq ($(shell uname -s),Darwin)
FPCFLAGS   += -WM11.0 -Fl$(LINKDIR) -k-rpath -k@executable_path/../Frameworks
endif

.PHONY: all deps exe app clean distclean

all: exe

deps:
	@$(HERE)/fetch-deps.sh

$(LINKDIR)/libSDL2.dylib: $(FRAMEWORK)/Versions/A/SDL2
	@mkdir -p $(LINKDIR)
	@ln -sf $(FRAMEWORK)/Versions/A/SDL2 $@

exe: $(LINKDIR)/libSDL2.dylib
	@mkdir -p $(OBJDIR)
	$(FPC) $(FPCFLAGS) -FU$(OBJDIR) -FE$(OBJDIR) -o$(OBJDIR)/$(BIN_NAME) $(PROGRAM)

app: exe
	@$(HERE)/bundle.sh $(OBJDIR)/$(BIN_NAME) $(FRAMEWORK) $(APP) $(BIN_NAME)

clean:
	rm -rf $(BUILD)

distclean: clean
	rm -rf $(VENDOR)
