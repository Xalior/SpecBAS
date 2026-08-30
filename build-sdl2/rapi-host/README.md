# rapi-host

**SpecBAS running directly on a Raspberry Pi with no operating system.** The
board powers on and SpecBAS is what boots: no Linux, no desktop, no launcher,
and nothing else running beside it.

## What this is

The SDL2 backend in `..` builds SpecBAS for macOS and Linux. This directory
builds the same interpreter, from the same `src/`, as a bootable kernel image.
Nothing about SpecBAS is copied here and nothing is forked: the port is a
Makefile, one C file, and a submodule.

Starting the board, mounting the card and calling into the Pascal program's
entry point is [circle-libfpc](https://github.com/Xalior/circle-libfpc), which
is Free Pascal's runtime resolved against
[Circle](https://github.com/rsta2/circle).

[circle-libsdl2](https://github.com/Xalior/circle-libsdl2) is the SDL2 that
kernel is built on. This port includes both rather than carrying a copy of
either, and carries no Circle kernel, no SDL2, and no linker script.

## Layout

```
Makefile            the build
stubs/bass.c        the audio library SpecBAS loads at run time on a desktop
circle-libfpc/      the Free Pascal side of the build, a submodule, pinned
mk/toolchain.mk     finds the cross compiler
```

`circle-libsdl2` is not a direct dependency of this port. It is
`circle-libfpc`'s own dependency, and belongs one level deeper, as a submodule
of `circle-libfpc`, arriving through this repository's recursive clone rather
than a submodule of its own here.

## Building

The build needs the Arm GNU `aarch64-none-elf` cross toolchain, a built Circle
world for the board, and a built Free Pascal cross-compiler for the
`aarch64-circlesdl2` target. It builds none of them. If a build appears to
want one of them started, a variable is wrong.

```sh
make check-toolchain     # which cross compiler this will use
make check-deps          # every path this build will reach for, and whether it is there
make rpi5                # the image
make verify              # the image exists and is not empty
make card                # stage the card directory
```

The targets are `rpi5`, `rpi4` and `rpi3`, and each needs a Circle world built
for it. `make kernels` builds every board named in `BOARDS`.

The image is `build/rpi5/kernel_2712.img`.

## The card

`make card` stages a directory into `build/sd-card/`. Copy its contents to the
root of a card the board can boot.

SpecBAS carries its own fonts and everything else. The desktop bundle in `..`
is the executable and SDL2, with no data directory beside it, so all that is
staged is the empty directory the kernel makes its working directory,
which has to exist before SpecBAS can write a program into it. It writes no
firmware and no boot configuration, because those come from the Raspberry Pi
rather than from here, and it writes no kernel image, because which one you
want depends on the board. This stages what the port owns, not a whole card.

That directory is `/specbas`, and it is a build parameter, not a fixed value.
The kernel's own default is the card's root, and this port sets its own so the
root of the card stays clear. A card laid out differently is a `RAPI_WORK_DIR`
setting, not an edit to the kernel:

```sh
make rpi5 card RAPI_WORK_DIR=/somewhere/else
```

The kernel gives two answers derived from it. One is the working directory,
which makes SpecBAS's own relative paths work and is where `LOAD` and `SAVE`
land. The other is the base path SDL derives the preferences path from. Both
come from the one value, so they cannot disagree.

## The picture

**Nothing anywhere names a size, and the panel decides.** `circle-libsdl2`
settles the canvas from the first of these it finds: the `--rapi-vfb` boot
switch, a declared virtual device, the size of the first window created, and
the panel's own size read from the firmware. This port supplies none of the
first three, and SpecBAS asks `SDL_CreateWindow` for nothing rather than for
the 800x480 it opens at on a desktop, so the last one answers and SpecBAS
fills the screen it was given at 1:1 instead of drawing small and leaving the
library to scale it up.

A size can still ride a single boot with no rebuild, because a loader writes
the switch into the image's boot argument block over the wire. That is what a
bench uses to try one; there is no size this port knows better than the panel
does, so none is stamped in at build time.

## What SpecBAS needed changing, and why there are no patch files

The game ports in this family vendor an upstream checkout and patch a copy of
it, because forking someone else's game to port it is not on. **SpecBAS is
this repository's own program**, so there is nothing to fork: what this target
needs is written into `src/`, guarded on `CIRCLESDL2`, and is as visible in a
diff as any other change to SpecBAS. Every guard leaves the desktop and
Windows builds reading exactly as they did.

Not everything this target needed is a guard, and the two that are not are the
more interesting half. `SDL_GetDisplayUsableBounds` was a gap in
`circle-libsdl2`, and guarding SpecBAS's call to it would have been one port's
private workaround for a library that every other consumer wanted the same
answer from, so that library answers it now. The event buffer below was never
right on any platform; it is fixed for all of them rather than guarded for this
one.

- **`SP_Sockets.pas`** grows a third arm beside WinSock and POSIX. Circle
  brings up the display, the card, USB and sound, and has no TCP/IP stack, so
  there is no socket to open. Every entry point answers the failure it would
  answer for a socket that could not be created. `SOCKET CONNECT` reports
  "no network on this machine" rather than timing out. The URL, Base64 and
  HTTP sections are not guarded and are the same code every target compiles.

- **`SP_Display.pas`** and **`RunTimeCompiler.pas`** each had a Windows-only
  `uses` clause written as "not Unix". Bare metal is neither, so each now says
  what it means. `SmartSleep` gains a third arm for the same reason: no
  `nanosleep` and no Windows waitable timer, so it uses the fallback the
  Windows arm already uses when the high-resolution timer is absent.

- **`SP_SDL2Host.pas`** takes its startup size from the window SDL settled
  rather than from the 800x480 a desktop opens at, and **`SP_SDL2Backend.pas`**
  gives the renderer the size SDL granted rather than the size asked for. A
  window manager may differ on that anywhere, and a request of 0x0 means "you
  choose", which is how the panel gets to answer.

- **`SP_SDL2Host.pas`** does not look for a COMPILE payload. A payload is a
  blob appended to SpecBAS's own executable file, and there is no executable
  file here, because the image the board booted is the program. Looking anyway
  is not
  a harmless nothing: `ParamStr(0)` is empty because the runtime is handed no
  argument vector, `Reset` on an empty name binds standard input instead of
  failing, and the `FileSize` that follows stops the program on its first line
  with "invalid file handle".

- **`SP_SDL2Host.pas`** states that sound is off rather than looking for BASS,
  and **`bass.pas`** gains the library-name arm every platform block in it
  needs. See below.

## The event buffer, and why it is bigger than the record

SDL's `SDL_Event` is a union carrying a padding member that fixes it at 56
bytes, held there by a compile-time assertion in `SDL_events.h`. Every entry
point that fills an event assigns the whole union, so 56 bytes are written
whatever kind of event it is.

**The Pascal translation of that header carries the variants and not the
padding**, so `TSDL_Event` is exactly as large as its largest declared variant,
which is smaller. Handing `SDL_PollEvent` the address of a bare one gives SDL a
buffer shorter than the one it will fill, on every platform including the
desktop.

On a desktop the few bytes over land in another local and the damage is
usually invisible, which is why this survived there. On a bare-metal board they
land on a stack the SDL layer allocated for the core the pump runs on, and
those stacks are laid out one after another with no guard page between them, so
the overrun writes into a neighbouring core's stack. That presents as the
program running normally until something unrelated stops.

`SDLHost_PumpEvents` declares a variant record that is at least 56 bytes and at
least `SizeOf(TSDL_Event)`, whichever is larger, and reads the event out of it.
The handlers are untouched and still take a `TSDL_Event`. It is not guarded on
`CIRCLESDL2`: the bug was never platform-specific, only survivable elsewhere.

`circle-libfpc/docs/SDL.md` describes the trap; this is a port getting it
wrong first and then right.

## Sound, and `stubs/bass.c`

SpecBAS reaches sound through BASS, a closed-source shared library it **loads
by hand** at start-up and does without when the load fails. Bare metal is such
a machine permanently: there is no BASS build for it and no loader to open one
with. So `SoundEnabled` is set false outright and SpecBAS runs silent.

The link still needs the symbols. Free Pascal emits a reference wherever a call
is written, whether or not a flag guards it at run time, so the thirty BASS
entry points SpecBAS names are undefined symbols in the compiled blob. The
desktop build answers that with an empty linker script and
`--unresolved-symbols=ignore-all`; a bare-metal link has no such escape and
would not want one, because a link that ignores unresolved symbols ignores real
ones too.

`stubs/bass.c` defines them, in the port's own layer, each answering failure in
the terms BASS itself uses. `src/bass.pas` is otherwise untouched. The day a
real audio backend arrives, that file is what it replaces.

## Where this lives

`circle-libfpc` is a real submodule, pinned at a published commit, so a fresh
clone with `--recurse-submodules` gets everything this port names directly. It
owns both of its own dependencies as submodules of its own, `circle-libsdl2`
and the Free Pascal compiler, runtime and packages built for the `circlesdl2`
target. Its `Makefile` defaults `CIRCLE_WORLDS`, `SHIM`, `FPC_COMPILER`,
`FPC_UNITS` and `FPC_PACKAGES` to those.

It is also where the Pascal SDL2 binding comes from. The desktop build fetches
SDL2-for-Pascal into `../vendor` with `fetch-deps.sh`; `circle-libfpc` vendors
the same binding at the same upstream revision with the one arm this target
needs already applied. Taking it from there means this build fetches nothing,
and that arm is maintained once, in the repository every Pascal port on this
target already depends on.

A repository that develops this port alongside its dependencies can override
`CIRCLE_WORLDS`, `SHIM`, `LIBFPC_HOME`, `FPC_COMPILER`, `FPC_UNITS` and
`FPC_PACKAGES` to point at its own editing copies instead of this port's pinned
ones. See the Makefile's own comments above `LIBFPC_HOME` for how that override
works.
