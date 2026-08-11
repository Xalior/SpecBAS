#!/usr/bin/env bash
#
# Put the outside pieces the SDL2 build needs into vendor/:
#
#   vendor/SDL2-for-Pascal/    the Pascal bindings, all platforms
#   vendor/SDL2.framework      the SDL2 runtime for the bundle, macOS only
#
# vendor/ is gitignored. Everything fetched here is pinned and checked, so
# this script is the tracked half and vendor/ is disposable.
#
# On Linux SDL2 comes from the distribution instead: the bindings name
# libSDL2.so, fpc turns that into -lSDL2, and the development package
# supplies both. This script checks it is there and says what to install if
# it is not.
#
# On macOS the runtime is the release framework from libsdl.org rather than
# Homebrew's sdl2, which is sdl2-compat: a shim that reaches SDL3 by dlopen
# at run time, so copying it into a bundle copies something that then looks
# for an SDL3 the target machine has no reason to have. Homebrew also builds
# to the host's own macOS version, so the result refuses to load on anything
# older. The release framework is built for this job: its LC_ID_DYLIB is
# already @rpath/SDL2.framework/Versions/A/SDL2, it is universal, and its
# minimum is macOS 11.
#
# The disk image is mounted with hdiutil rather than unpacked with an
# archiver. A framework is held together by symlinks, and an archiver writes
# those out as small text files, which gives a directory that looks right,
# fails to load, and fails codesign.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
vendor="${here}/vendor"
work="${vendor}/.download"

SDL2_VERSION="2.32.8"
SDL2_DMG_SHA256="de07f71cc85cd8909c977e105c4f2ca419abd09b981c347e003592186caf6fa0"
SDL2_DMG_URL="https://github.com/libsdl-org/SDL/releases/download/release-${SDL2_VERSION}/SDL2-${SDL2_VERSION}.dmg"

BINDINGS_URL="https://github.com/PascalGameDevelopment/SDL2-for-Pascal.git"
BINDINGS_COMMIT="a48b83efbfa7c13ce548905ebdc954eb6c8384be"

mkdir -p "${work}"

# --- SDL2 runtime ------------------------------------------------------

case "$(uname -s)" in
Darwin)
    if [[ -d "${vendor}/SDL2.framework" ]]; then
        echo "==> SDL2.framework already present"
    else
        dmg="${work}/SDL2-${SDL2_VERSION}.dmg"
        if [[ ! -f "${dmg}" ]]; then
            echo "==> downloading SDL2 ${SDL2_VERSION}"
            curl -fsSL -o "${dmg}" "${SDL2_DMG_URL}"
        fi

        got="$(shasum -a 256 "${dmg}" | awk '{print $1}')"
        if [[ "${got}" != "${SDL2_DMG_SHA256}" ]]; then
            echo "fetch-deps.sh: sha256 mismatch for ${dmg}" >&2
            echo "  expected ${SDL2_DMG_SHA256}" >&2
            echo "  got      ${got}" >&2
            exit 1
        fi

        # The mount point is hdiutil's own choice, read back out of its
        # output. Naming one under this directory is refused where the
        # repository is on a secondary volume.
        echo "==> mounting ${dmg}"
        mnt="$(hdiutil attach -nobrowse -readonly "${dmg}" \
            | sed -n 's#.*\(/Volumes/.*\)$#\1#p' | tail -1)"
        if [[ -z "${mnt}" || ! -d "${mnt}/SDL2.framework" ]]; then
            echo "fetch-deps.sh: could not mount ${dmg}" >&2
            exit 1
        fi
        trap 'hdiutil detach -quiet "'"${mnt}"'" >/dev/null 2>&1 || true' EXIT

        echo "==> copying SDL2.framework into vendor/"
        # ditto, not cp -R: it keeps the symlinks, permissions and extended
        # attributes that leave the framework's signature intact.
        ditto "${mnt}/SDL2.framework" "${vendor}/SDL2.framework"
        cp "${mnt}/License.txt" "${vendor}/SDL2-License.txt"

        hdiutil detach -quiet "${mnt}" || true
        trap - EXIT
    fi

    codesign --verify --verbose=1 "${vendor}/SDL2.framework" 2>&1 | sed 's/^/    /'
    ;;
Linux)
    if command -v sdl2-config >/dev/null 2>&1; then
        echo "==> system SDL2 $(sdl2-config --version)"
    elif command -v pkg-config >/dev/null 2>&1 && pkg-config --exists sdl2; then
        echo "==> system SDL2 $(pkg-config --modversion sdl2)"
    else
        echo "fetch-deps.sh: SDL2 development files not found." >&2
        echo "  Debian, Ubuntu, Raspberry Pi OS:  sudo apt install libsdl2-dev" >&2
        echo "  Fedora:                           sudo dnf install SDL2-devel" >&2
        echo "  Arch:                             sudo pacman -S sdl2" >&2
        exit 1
    fi
    ;;
*)
    echo "==> $(uname -s): assuming SDL2 is supplied by the system"
    ;;
esac

# --- SDL2-for-Pascal ---------------------------------------------------

if [[ -d "${vendor}/SDL2-for-Pascal/.git" ]]; then
    echo "==> SDL2-for-Pascal already present"
else
    echo "==> cloning SDL2-for-Pascal"
    rm -rf "${vendor}/SDL2-for-Pascal"
    git clone --quiet "${BINDINGS_URL}" "${vendor}/SDL2-for-Pascal"
fi
git -C "${vendor}/SDL2-for-Pascal" checkout --quiet "${BINDINGS_COMMIT}"
echo "    bindings at $(git -C "${vendor}/SDL2-for-Pascal" rev-parse HEAD)"

echo "==> vendor/ ready"
