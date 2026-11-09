#!/bin/bash
# One memo in several of macOS's voices and in two languages (evals/audio-voices.json): is a recording found less well
# because of its language, its voice, or neither? Everything is spoken by `say`; nothing is read from the user's files.
#   bash scripts/testbed/make_voices.sh .dev/testbed-voices        (needs ffmpeg)
set -euo pipefail
V="${1:?usage: make_voices.sh <out>}"
[ -e "$V" ] && { echo "$V already exists; delete it first" >&2; exit 1; }
mkdir -p "$V/memos"
ZH="明天上午十点去社区医院拿体检报告，记得带上身份证和医保卡。"
EN="Tomorrow at ten in the morning, go to the community hospital to pick up the checkup report, and bring your ID card and medical insurance card."
PL="Reminder: the plumber is coming on Thursday at nine to fix the leaking kitchen tap."
make() { say -v "$1" -o "$V/say.aiff" "$3"; ffmpeg -loglevel error -y -i "$V/say.aiff" -ac 1 -ar 16000 "$V/memos/$2.wav"; rm -f "$V/say.aiff"; }
make "Flo (Chinese (China mainland))" "checkup zh Flo" "$ZH"
make "Eddy (Chinese (China mainland))" "checkup zh Eddy" "$ZH"
make "Reed (Chinese (China mainland))" "checkup zh Reed" "$ZH"
make "Meijia" "checkup zh Meijia" "$ZH"
make "Samantha" "checkup en Samantha" "$EN"
make "Samantha" "plumber en Samantha" "$PL"
make "Flo (Chinese (China mainland))" "plumber en Flo" "$PL"
echo "voices in $V"
