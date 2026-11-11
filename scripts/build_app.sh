#!/bin/sh
# Builds build.noindex/螺壳搜索.app: the luoke-search executable, Info.plist (LSUIElement, ai.luoke.search,
# macOS 26.2), the icon (AppIcon.icns, made from Resources/AppIcon.png), the accessory manifest luoke-core reads
# (Contents/Resources/luoke-accessory.json), signed with the hardened runtime and the entitlements it needs (Apple
# Events for QuickTime, the Photos library).
#
#   sh scripts/build_app.sh                      ad-hoc signature (development)
#   SIGN_IDENTITY="Developer ID Application: …" sh scripts/build_app.sh     (or put the identity in .sign-id)
#   LUOKE_OUT=<folder> sh scripts/build_app.sh   also puts the signed app in <folder> (replacing one there); relative
#                                                to the caller's folder. Nothing takes it from there any more.
#
# luoke-core's pipeline no longer takes this app: 螺壳.app carries the program scripts/build_helper.sh builds.
#
# Notarizing isn't done here: with LUOKE_NOTARIZE set (as the pipeline asks of luoke-ime) it stops rather than leave
# an ad-hoc build where a notarized one is expected. Signing for a release has to keep Resources/LuokeSearch.entitlements
# (Apple Events for QuickTime, the Photos library).
#
# Opened as an app (with --resident or by hand) it runs `serve` on ~/.luoke-search, and takes none of the
# development switches (--index, --socket, LUOKE_SEARCH_HOME, LUOKE_HUB_SOCKET, LUOKE_SEARCH_PHOTOS,
# LUOKE_SEARCH_OPENER…): any process of this user could otherwise point it elsewhere and borrow what macOS lets it
# read. Only a development build of the app takes them, LUOKE_SEARCH_DEV_APP=1 (never with LUOKE_OUT). For a
# development run, build that, keep it off the real data and hub, and never leave it registered with LaunchServices:
#   LUOKE_SEARCH_DEV_APP=1 sh scripts/build_app.sh
#   open -n -g --env LUOKE_SEARCH_HOME="$PWD/.dev/app" --env LUOKE_SEARCH_OPENER=dry \
#        build.noindex/螺壳搜索.app --args --socket /tmp/lsapp.sock
#   …  then: kill the process, and
#   /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
#        -u build.noindex/螺壳搜索.app
set -eu
if [ -n "${LUOKE_NOTARIZE:-}" ]; then
  echo "build_app.sh: LUOKE_NOTARIZE is set, but this script doesn't notarize; sign and notarize the app it builds" \
    "with Resources/LuokeSearch.entitlements kept" >&2
  exit 1
fi
out=${LUOKE_OUT:-}
dev=${LUOKE_SEARCH_DEV_APP:-}
if [ -n "$dev" ] && [ -n "$out" ]; then
  echo "build_app.sh: LUOKE_SEARCH_DEV_APP builds an app that takes development switches; it never goes to LUOKE_OUT" >&2
  exit 1
fi
case "$out" in ""|/*) ;; *) out="$(pwd)/$out" ;; esac   # relative to where it was called from, not the cd below
case "$out" in ?*/) out=${out%/} ;; esac
cd "$(dirname "$0")/.."
if [ -n "$out" ]; then
  mkdir -p "$out" build.noindex
  if [ "$(cd "$out" && pwd -P)" = "$(cd build.noindex && pwd -P)" ]; then
    echo "build_app.sh: LUOKE_OUT is build.noindex itself, where the app is built anyway" >&2
    exit 1
  fi
fi
version=$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' Sources/LuokeSearchKit/Hub/Hub.swift)
build=$(git rev-list --count HEAD 2>/dev/null || echo 1)
identity=${SIGN_IDENTITY:-$(cat .sign-id 2>/dev/null || printf %s -)}   # printf: zsh's echo takes "-" for an option
# A development app is signed ad hoc, whatever identity is set: signed as the released one, it would have the same
# standing with macOS (the folders and Photos it was allowed) while taking every development switch.
if [ -n "$dev" ]; then identity=-; fi

if [ -n "$dev" ]; then
  swift build -c release --product luoke-search -Xswiftc -DLUOKE_SEARCH_DEV_APP
else
  swift build -c release --product luoke-search
fi
app="build.noindex/螺壳搜索.app"
rm -rf "$app"
# Its name before 0.1.4: an old build left here would stay registered under the same bundle id.
if [ -e build.noindex/螺壳深度搜索.app ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$(pwd)/build.noindex/螺壳深度搜索.app" 2>/dev/null || true
  rm -rf build.noindex/螺壳深度搜索.app
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp .build/release/luoke-search "$app/Contents/MacOS/luoke-search"
# No debug symbols or local symbol names: they carry the build folder's path, and a third of the size.
strip -S -x "$app/Contents/MacOS/luoke-search"
cp Resources/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build" "$app/Contents/Info.plist"
# The manifest with this build's version (luoke-core decides whether to upgrade by it).
/usr/bin/python3 -I - Resources/luoke-accessory.json "$app/Contents/Resources/luoke-accessory.json" "$version" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
manifest["version"] = sys.argv[3]
json.dump(manifest, open(sys.argv[2], "w", encoding="utf-8"), ensure_ascii=False, indent=1)
PY
# Apache-2.0 §4(d): what is given on carries the NOTICE with the license.
cp LICENSE "$app/Contents/Resources/LICENSE"
cp NOTICE "$app/Contents/Resources/NOTICE"
# The icon: Resources/AppIcon.png is luoke-brand's media-kit/app-icons/search-1024.png as it is (its rounded square
# and margin already drawn); every size macOS asks for is made from it.
iconset=build.noindex/AppIcon.iconset
rm -rf "$iconset"
mkdir -p "$iconset"
for px in 16 32 128 256 512; do
  sips -z $px $px Resources/AppIcon.png --out "$iconset/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) Resources/AppIcon.png --out "$iconset/icon_${px}x${px}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
rm -rf "$iconset"
# A real identity's signature carries a secure timestamp (notarizing needs it; it asks Apple's server, so online);
# an ad-hoc one doesn't, so a development build needs no network.
if [ "$identity" = "-" ]; then timestamp=--timestamp=none; else timestamp=--timestamp; fi
codesign --force --sign "$identity" $timestamp --options runtime --entitlements Resources/LuokeSearch.entitlements "$app"
codesign --verify --strict "$app"
echo "$app ($version, build $build, signed: $identity)"
if [ -n "$out" ]; then
  # Its name before 0.1.4: a copy left there would be a second .app with the same bundle id (the release pipeline
  # takes the one .app in this folder).
  if [ -e "$out/螺壳深度搜索.app" ]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -u "$out/螺壳深度搜索.app" 2>/dev/null || true
    rm -rf "$out/螺壳深度搜索.app"
  fi
  rm -rf "$out/螺壳搜索.app"
  ditto "$app" "$out/螺壳搜索.app"
  # Never left registered with LaunchServices (a Finder window on the folder registers it), so luoke-core finding
  # ai.luoke.search doesn't land on this copy.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -u "$out/螺壳搜索.app" 2>/dev/null || true
  echo "$out/螺壳搜索.app"
fi
