#!/usr/bin/env bash
# test/sdl2-seam/fetch-deps.sh
#
# Put the two outside pieces the seam proof needs into vendor/:
#
#   vendor/SDL2.framework      the SDL2 runtime that goes inside the bundle
#   vendor/SDL2-for-Pascal/    the Pascal bindings, units only
#
# vendor/ is gitignored. Both pieces are pinned by version and verified, so
# this script is the tracked, repeatable half and vendor/ is disposable.
#
# Why the official SDL2 release framework and not Homebrew's sdl2:
#
#   Homebrew's "sdl2" formula is sdl2-compat, a shim that reaches SDL3 by
#   dlopen at run time. Copying its dylib into a bundle copies a stub that
#   then looks for an SDL3 the target machine does not have. It is also
#   built with a deployment target equal to the host's macOS version, so it
#   refuses to load on anything older.
#
#   The libsdl.org release framework is built for this exact job: its
#   LC_ID_DYLIB is already @rpath/SDL2.framework/Versions/A/SDL2, so it is
#   copied into a bundle unmodified and its ad-hoc signature stays valid. It
#   is universal (x86_64 + arm64) with a macOS 11.0 minimum.
#
# The disk image must be mounted with hdiutil, not unpacked with 7z: a
# framework is held together by symlinks (SDL2 -> Versions/Current/SDL2 and
# so on) and 7z writes those out as small text files, which produces a
# directory that looks right, fails to load, and fails codesign.

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

# --- SDL2.framework ----------------------------------------------------

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

    # The image is mounted at hdiutil's own choice of mount point, not one
    # named here: `-mountpoint` under this repository is refused outright
    # ("attach failed - Permission denied"), because the repository lives on
    # a secondary volume and macOS will not nest a mount inside it. The
    # chosen path is read back out of hdiutil's own output.
    echo "==> mounting ${dmg}"
    mnt="$(hdiutil attach -nobrowse -readonly "${dmg}" \
        | sed -n 's#.*\(/Volumes/.*\)$#\1#p' | tail -1)"
    if [[ -z "${mnt}" || ! -d "${mnt}/SDL2.framework" ]]; then
        echo "fetch-deps.sh: could not mount ${dmg}" >&2
        exit 1
    fi
    trap 'hdiutil detach -quiet "'"${mnt}"'" >/dev/null 2>&1 || true' EXIT

    echo "==> copying SDL2.framework into vendor/"
    # ditto, not cp -R: it keeps symlinks, permissions and extended
    # attributes, which is what leaves the framework's signature intact.
    ditto "${mnt}/SDL2.framework" "${vendor}/SDL2.framework"
    cp "${mnt}/License.txt" "${vendor}/SDL2-License.txt"

    hdiutil detach -quiet "${mnt}" || true
    trap - EXIT
fi

codesign --verify --verbose=1 "${vendor}/SDL2.framework" 2>&1 | sed 's/^/    /'

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
