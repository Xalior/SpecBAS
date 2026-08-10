#!/usr/bin/env bash
# build-sdl2/bundle.sh <executable> <SDL2.framework> <out.app> <binname>
#
# Assemble a self-contained .app: the executable, an Info.plist, and SDL2
# inside the bundle. The result runs on a machine with no toolchain, no
# Homebrew and no system SDL2.
#
# The whole mechanism is three facts that have to agree:
#
#   1. SDL2.framework's own install name (LC_ID_DYLIB) is
#      @rpath/SDL2.framework/Versions/A/SDL2. That is what the release
#      framework from libsdl.org ships with — nothing here sets it.
#   2. The executable therefore records that same @rpath dependency, which
#      it picked up at link time (see the Makefile's link/ symlink).
#   3. The executable carries LC_RPATH = @executable_path/../Frameworks,
#      added by fpc's -k-rpath. From Contents/MacOS that resolves to
#      Contents/Frameworks, where the framework is copied.
#
# Nothing needs install_name_tool. Because nothing is rewritten, the
# framework's ad-hoc signature survives the copy and only the executable and
# the outer bundle need signing.
#
# Layout produced:
#
#   SeamTest.app/Contents/Info.plist
#   SeamTest.app/Contents/MacOS/seamtest
#   SeamTest.app/Contents/Frameworks/SDL2.framework/…

set -euo pipefail

exe="${1:?executable}"
framework="${2:?SDL2.framework}"
app="${3:?out .app}"
binname="${4:?bin name}"

contents="${app}/Contents"

rm -rf "${app}"
mkdir -p "${contents}/MacOS" "${contents}/Frameworks" "${contents}/Resources"

cp "${exe}" "${contents}/MacOS/${binname}"
# ditto keeps the framework's symlinks and signature intact; cp -R does not.
ditto "${framework}" "${contents}/Frameworks/SDL2.framework"

cat > "${contents}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>          <string>en</string>
	<key>CFBundleExecutable</key>                 <string>${binname}</string>
	<key>CFBundleIdentifier</key>                 <string>net.xalior.specbas</string>
	<key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
	<key>CFBundleName</key>                       <string>$(basename "${app}" .app)</string>
	<key>CFBundlePackageType</key>                <string>APPL</string>
	<key>CFBundleShortVersionString</key>         <string>1.0</string>
	<key>CFBundleVersion</key>                    <string>1</string>
	<key>LSMinimumSystemVersion</key>             <string>11.0</string>
	<key>NSHighResolutionCapable</key>            <true/>
	<key>NSPrincipalClass</key>                   <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Apple Silicon refuses to run an unsigned Mach-O, and the
# linker's own ad-hoc signature on the executable is enough on its own — but
# signing the bundle from the inside out is the habit that keeps working
# once a real identity is used. --deep is deprecated, so each piece is named.
codesign --force --sign - --timestamp=none \
    "${contents}/Frameworks/SDL2.framework" >/dev/null 2>&1
codesign --force --sign - --timestamp=none \
    "${contents}/MacOS/${binname}" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "${app}" >/dev/null 2>&1

echo "==> ${app}"
codesign --verify --deep --verbose=1 "${app}" 2>&1 | sed 's/^/    /'
echo "    executable links:"
otool -L "${contents}/MacOS/${binname}" | tail -n +2 | sed 's/^/    /'
echo "    rpaths:"
otool -l "${contents}/MacOS/${binname}" \
    | awk '/LC_RPATH/{f=1} f&&/path /{print "    " $2; f=0}'
