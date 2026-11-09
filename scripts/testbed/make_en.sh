#!/bin/bash
# The corpus of upstream DigUp's English and Bengali/Arabic evals (evals/synthetic.json, evals/multilingual.json):
# its synthetic/ and traps/ parts, made with upstream's own generators (scripts/testbed in DigUp 1b8671f, MIT,
# Copyright (c) 2026 Abdur Rahim). Upstream's make-testbed.sh also clones a sample of the user's own files into real/
# and builds code/: neither is made here. Everything is generated: macOS's sample pictures and voices, drawn
# screenshots, ffmpeg.
#
#   git -C <a clone of upstream DigUp> archive 1b8671f scripts/testbed | tar -x -C <empty folder>
#   bash scripts/testbed/make_en.sh <that folder> .dev/testbed-en     (needs ffmpeg)
#   luoke-search eval evals/synthetic.json --testbed .dev/testbed-en …   (its base ~/DigUpTestbed is this folder)
set -euo pipefail
UP="$(cd "${1:?usage: make_en.sh <upstream DigUp scripts copy> <out>}" && pwd)/scripts/testbed"
TB="${2:?usage: make_en.sh <upstream DigUp scripts copy> <out>}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
command -v ffmpeg >/dev/null || { echo "needs ffmpeg" >&2; exit 1; }
[ -e "$TB" ] && { echo "$TB already exists; delete it first" >&2; exit 1; }
mkdir -p "$TB"

# As upstream's make-testbed.sh, from "== synthetic/ ==" to the end of "== traps/ ==" (its real/ and code/ left out).
S="$TB/synthetic"
"$UP/make_media.sh" "$S" >/dev/null
rm -rf "$S/audio_trunc" "$S/audio/bench_60s.wav" "$S/video/bench_45s.mp4" "$S/video"/seg_*.mp4
mv "$S/shots" "$S/screenshots"
for f in "$S/screenshots"/*.png; do xattr -w com.apple.metadata:kMDItemIsScreenCapture 1 "$f"; done
swift "$UP/make_docs.swift" "$S/docs" >/dev/null
swift "$UP/make_long.swift" "$S/long" >/dev/null
"$UP/make_lang.sh" "$S/lang"

T="$TB/traps"; mkdir -p "$T"
mkdir -p "$T/ts-code" "$T/real-mpeg-ts"
printf 'export const greet = (name: string): string => `hello ${name}`;\n' > "$T/ts-code/app.ts"
printf 'import { greet } from "./app";\nconsole.log(greet("zebra"));\n' > "$T/ts-code/main.mts"
ffmpeg -loglevel error -i "$S/video/penguin_zebra_parrot_18s.mp4" -c copy -f mpegts "$T/real-mpeg-ts/zoo clip.ts"
P="$T/MyProject"; mkdir -p "$P/.git" "$P/assets" "$P/node_modules/lib" "$P/screenshots"
echo '{"name": "my-project"}' > "$P/package.json"
cp -c "$S/img/Animals-Owl.jpg" "$P/assets/hero.jpg"
cp -c "$S/img/Animals-Eagle.jpg" "$P/node_modules/lib/logo.jpg"
cp -c -p "$S/screenshots/shot_weather.png" "$P/screenshots/Screenshot 2026-10-02 at 8.15.40 AM.png"
mkdir -p "$T/node_modules/pkg" "$T/.hidden" "$T/Fake.app/Contents/Resources"
cp -c "$S/img/Nature-Leaf.jpg" "$T/node_modules/pkg/leaf.jpg"
cp -c "$S/img/Nature-Zen.jpg" "$T/.hidden/zen.jpg"
cp -c "$S/img/Fun-Medal.jpg" "$T/Fake.app/Contents/Resources/medal.jpg"
mkdir -p "$T/icons"
for px in 32 64 128; do sips -s format png -Z $px "$S/img/Sports-Target.jpg" --out "$T/icons/target-$px.png" >/dev/null; done
mkdir -p "$T/dataset_clips"
ffmpeg -loglevel error -f lavfi -i "sine=frequency=440:duration=1" -ac 1 -ar 16000 "$T/dataset_clips/clip_000000.wav"
for i in $(seq -f "%06g" 1 599); do cp -c "$T/dataset_clips/clip_000000.wav" "$T/dataset_clips/clip_$i.wav"; done
N="$T/Names with spaces & ünïcödé"; mkdir -p "$N"
nnbsp=$(printf '\342\200\257')   # U+202F, which macOS puts before AM/PM
cp -c -p "$S/screenshots/shot_chat_meeting.png" "$N/Screenshot 2026-10-05 at 9.41.07${nnbsp}PM.png"
cp -c "$S/img/Flowers-Sunflower.jpg" "$N/Café menü — 日本語.jpg"
mkdir -p "$T/duplicates"
cp -c "$S/img/Animals-Penguin.jpg" "$T/duplicates/penguin.jpg"
cp -c "$S/img/Animals-Penguin.jpg" "$T/duplicates/penguin copy.jpg"
echo "testbed in $TB"
