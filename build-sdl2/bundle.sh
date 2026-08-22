#!/usr/bin/env bash
# bundle.sh <executable> <SDL2.framework> <out.app> <binname> <version> <build>
#
# Assemble a self-contained .app: the executable, an Info.plist, and SDL2
# inside the bundle. The result runs on a machine with no toolchain and no
# system SDL2.
#
# Three facts have to agree, and none of them is set here:
#
#   1. SDL2.framework's own install name is
#      @rpath/SDL2.framework/Versions/A/SDL2, which is what the release
#      framework ships with.
#   2. The executable records that same dependency, picked up at link time
#      through the symlink the Makefile makes.
#   3. The executable carries an rpath of @executable_path/../Frameworks,
#      which from Contents/MacOS is Contents/Frameworks, where the framework
#      is copied.
#
# So nothing needs install_name_tool, and because nothing is rewritten the
# framework's signature survives the copy.

set -euo pipefail

exe="${1:?executable}"
framework="${2:?SDL2.framework}"
app="${3:?out .app}"
binname="${4:?bin name}"
version="${5:?version}"
buildnum="${6:?build number}"

contents="${app}/Contents"

rm -rf "${app}"
mkdir -p "${contents}/MacOS" "${contents}/Frameworks" "${contents}/Resources"

cp "${exe}" "${contents}/MacOS/${binname}"
# ditto keeps the framework's symlinks and signature; cp -R does not.
ditto "${framework}" "${contents}/Frameworks/SDL2.framework"

cat > "${contents}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>          <string>en</string>
	<key>CFBundleExecutable</key>                 <string>${binname}</string>
	<key>CFBundleIdentifier</key>                 <string>org.specos.SpecBAS</string>
	<key>CFBundleInfoDictionaryVersion</key>      <string>6.0</string>
	<key>CFBundleName</key>                       <string>$(basename "${app}" .app)</string>
	<key>CFBundlePackageType</key>                <string>APPL</string>
	<key>CFBundleShortVersionString</key>         <string>${version}</string>
	<key>CFBundleVersion</key>                    <string>${buildnum}</string>
	<key>LSMinimumSystemVersion</key>             <string>11.0</string>
	<key>NSHighResolutionCapable</key>            <true/>
	<key>NSPrincipalClass</key>                   <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc signature. Apple Silicon refuses to run an unsigned Mach-O.
# --deep is deprecated, so each piece is named, innermost first.
codesign --force --sign - --timestamp=none \
    "${contents}/Frameworks/SDL2.framework" >/dev/null 2>&1
codesign --force --sign - --timestamp=none \
    "${contents}/MacOS/${binname}" >/dev/null 2>&1
codesign --force --sign - --timestamp=none "${app}" >/dev/null 2>&1

echo "==> ${app}"
codesign --verify --deep --verbose=1 "${app}" 2>&1 | sed 's/^/    /'
echo "    executable links:"
otool -L "${contents}/MacOS/${binname}" | tail -n +2 | sed 's/^/    /'
