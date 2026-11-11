#!/bin/sh
# Builds luoke-search as the program 螺壳.app carries in Contents/Helpers, for luoke-core's app/build_app.sh:
#
#   LUOKE_OUT=<folder> sh scripts/build_helper.sh
#   LUOKE_OUT=<folder> LUOKE_SEARCH_DEV_APP=1 sh scripts/build_helper.sh     takes the development switches
#
# <folder> gets the program (luoke-search), the accessory manifest (luoke-accessory.json), LICENSE and NOTICE. A bare
# program, not a bundle: macOS charges what it reads to the app around it either way, and a nested .app would also
# be registered with LaunchServices under ai.luoke.search, a second copy for anything opening that id to land on.
#
# Its signature has to name it ai.luoke.search: nothing else tells this program it's the shipped one, and without that
# it won't start at all (`LuokeSearch.isApp`, so never the real data for a program that isn't). Signed ad hoc here;
# luoke-core signs it again for a release, keeping the identifier and the entitlements (tools/release_sign.sh). The
# entitlements only count on the app around it: they stay here so a build of this program alone is the same program.
#
# The version is linked into the program (__TEXT,__info_plist), so the signature covers it: 螺壳 reads it from the
# stopped process and compares it with the one it packed before letting it run. Only version keys: with a bundle id in
# there, `Bundle.main` would name it and `LuokeSearch.holder` would tell people about 螺壳搜索 instead of 螺壳.
#
# LUOKE_SEARCH_DEV_APP gives a program signed the same as a release one: nothing on it tells them apart. Only luoke-core's
# build_app.sh decides it, by the bundle id it's building for.
#
# This is the only build luoke-core's pipeline takes; it no longer takes the 螺壳搜索.app scripts/build_app.sh builds.
set -eu
out=${LUOKE_OUT:-}
dev=${LUOKE_SEARCH_DEV_APP:-}
if [ -z "$out" ]; then
  echo "build_helper.sh: set LUOKE_OUT to the folder the program goes to" >&2
  exit 1
fi
case "$out" in /*) ;; *) out="$(pwd)/$out" ;; esac   # relative to where it was called from, not the cd below
cd "$(dirname "$0")/.."
bundle_id=$(sed -n 's/.*public static let bundleID = "\(.*\)".*/\1/p' Sources/LuokeSearchKit/Hub/Hub.swift)
version=$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' Sources/LuokeSearchKit/Hub/Hub.swift)
# Two matching lines give two lines here, and `grep -F` below would take them as two patterns: one is enough to pass.
case "$bundle_id" in *[!a-z0-9.-]*) bundle_id= ;; esac
case "$version" in *[!0-9.]*) version= ;; esac
if [ -z "$bundle_id" ] || [ -z "$version" ]; then
  echo "build_helper.sh: no bundle id or version in Hub.swift: its lines changed, change the two above" >&2
  exit 1
fi

mkdir -p .build
plist="$(pwd)/.build/helper-info.plist"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleShortVersionString</key>
	<string>$version</string>
	<key>CFBundleVersion</key>
	<string>$version</string>
</dict>
</plist>
PLIST
set -- -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$plist"
if [ -n "$dev" ]; then
  swift build -c release --product luoke-search -Xswiftc -DLUOKE_SEARCH_DEV_APP "$@"
else
  swift build -c release --product luoke-search "$@"
fi
mkdir -p "$out"
rm -f "$out/luoke-search"
cp .build/release/luoke-search "$out/luoke-search"
# No debug symbols or local symbol names: they carry the build folder's path, and a third of the size.
strip -S -x "$out/luoke-search"
cp Resources/luoke-accessory.json "$out/luoke-accessory.json"
# Apache-2.0 §4(d): what is given on carries the NOTICE with the license.
cp LICENSE NOTICE "$out/"
codesign --force --sign - --timestamp=none --options runtime --identifier "$bundle_id" \
  --entitlements Resources/LuokeSearch.entitlements "$out/luoke-search"
signed=$(codesign -dv "$out/luoke-search" 2>&1 | sed -n 's/^Identifier=//p')
if [ "$signed" != "$bundle_id" ]; then
  echo "build_helper.sh: signed as $signed, not $bundle_id: it wouldn't start" >&2
  exit 1
fi
if ! otool -P "$out/luoke-search" | grep -qF "<string>$version</string>" \
   || ! codesign -dv "$out/luoke-search" 2>&1 | grep -q '^Info.plist entries='; then
  echo "build_helper.sh: version $version isn't in the signed program: 螺壳 wouldn't start it" >&2
  exit 1
fi
echo "$out/luoke-search ($bundle_id $version)"
