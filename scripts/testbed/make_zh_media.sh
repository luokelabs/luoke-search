#!/bin/bash
# The photos, recordings and films of testbed/zh/corpus (evals/zh.json), made on this Mac from macOS's own sample
# pictures (/Library/User Pictures) and voices (`say`). They are Apple's, so they aren't in git: make them once before
# an eval on testbed/zh. Same recipe as the corpus builder of the DigUp revision inside Luoke, where testbed/zh
# comes from; nothing is read from the user's files.
#   bash scripts/testbed/make_zh_media.sh            (needs ffmpeg; writes testbed/zh/corpus/{photos,audio,video})
# The podcast's topics start where testbed/zh/_segments.json says (zh.json's ranges follow it). Another macOS may
# speak at another pace: the script prints the times it got, and says so when they're more than a second off.
set -euo pipefail
cd "$(dirname "$0")/../.."
C=testbed/zh/corpus
PICS="/Library/User Pictures"
command -v ffmpeg >/dev/null && command -v ffprobe >/dev/null || { echo "needs ffmpeg" >&2; exit 1; }
[ -d "$PICS/Animals" ] || { echo "no sample pictures in $PICS" >&2; exit 1; }
ZH="${VOICE_ZH:-$(say -v '?' | awk '/zh_CN/ && /^Flo /' | sed 's/  *zh_CN.*//' | head -1)}"
EN="${VOICE_EN:-Samantha}"
[ -n "$ZH" ] || { echo "no Chinese voice Flo; install it in System Settings, or set VOICE_ZH" >&2; exit 1; }
for d in photos audio video; do
  [ -e "$C/$d" ] && { echo "$C/$d already exists; delete it first" >&2; exit 1; }
done
mkdir -p "$C/photos" "$C/audio" "$C/video"
T="$(mktemp -d)"; done=0
trap '/bin/rm -rf "$T"; [ "$done" = 1 ] || /bin/rm -rf "$C/photos" "$C/audio" "$C/video"' EXIT   # no half-made corpus

n=1001
for p in Animals/Zebra Animals/Owl Animals/Penguin Animals/Parrot Flowers/Sunflower Flowers/Lotus "Flowers/Red Rose" \
         Instruments/Violin Instruments/Piano Instruments/Drum Nature/Lightning Nature/Earth Nature/Snowflake \
         Nature/Cactus Sports/Basketball Sports/Tennis "Fun/Fortune Cookie" "Fun/Gingerbread Man"; do
  /bin/cp -f "$PICS/$p.heic" "$C/photos/IMG_$n.heic"; n=$((n + 1))
done

seconds() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
# A podcast with three topics back to back.
say -v "$ZH" -o "$T/local.aiff" "欢迎收听第十二期。今天先聊本地大模型。很多人问，既然云端模型更强，为什么还要在自己电脑上跑模型？我的答案是隐私和延迟。比如你的邮件、照片、聊天记录，这些东西你真的愿意全部上传吗？而且本地模型不用排队，不用联网，打开就能用，这对输入法和语音转写这类场景特别重要。"
say -v "$ZH" -o "$T/sleep.aiff" "第二个话题是睡眠。最近好几位听众说自己失眠，躺下两个小时都睡不着。我自己试过几个办法：睡前一小时不看手机，卧室温度调低一点，每天固定时间起床，哪怕周末也一样。坚持了三周，入睡时间从一个多小时缩短到二十分钟左右。"
say -v "$ZH" -o "$T/knee.aiff" "最后说说跑步。很多新手一开始跑得太快太多，结果膝盖疼。建议每周跑量增加不要超过百分之十，跑前做动态拉伸，选一双缓震好的跑鞋。如果膝盖外侧疼，很可能是髂胫束综合征，要先停跑休息。"
printf "file '%s'\n" "$T/local.aiff" "$T/sleep.aiff" "$T/knee.aiff" > "$T/list.txt"
ffmpeg -loglevel error -y -f concat -safe 0 -i "$T/list.txt" -c:a aac -b:a 96k "$C/audio/播客第12期.m4a"
got="$(python3 -I -c 'import sys; a, b, c = map(float, sys.argv[1:]); print(f"{{\"local\": [0.0, {a:.1f}], \"sleep\": [{a:.1f}, {a + b:.1f}], \"knee\": [{a + b:.1f}, {a + b + c:.1f}]}}")' \
  "$(seconds "$T/local.aiff")" "$(seconds "$T/sleep.aiff")" "$(seconds "$T/knee.aiff")")"
echo "podcast topics: $got"
python3 -I -c 'import json, sys
want, got = json.load(open(sys.argv[1])), json.loads(sys.argv[2])
off = max(abs(x - y) for k in want for x, y in zip(want[k], got[k]))
if off > 1: print(f"  {off:.1f} s off testbed/zh/_segments.json: the podcast questions in evals/zh.json may miss", file=sys.stderr)' \
  testbed/zh/_segments.json "$got"

# A Chinese voice memo and an English one.
say -v "$ZH" -o "$T/memo.aiff" "提醒一下，下班去超市买西红柿两斤，鸡蛋一盒，一把小葱，还有酱油快用完了。"
ffmpeg -loglevel error -y -i "$T/memo.aiff" -c:a aac "$C/audio/新录音 3.m4a"
say -v "$EN" -o "$T/en.aiff" "Note to self: call the landlord tomorrow about the leaking kitchen faucet, it has been dripping for a week."
ffmpeg -loglevel error -y -i "$T/en.aiff" -c:a aac "$C/audio/memo 0927.m4a"

# Three animals, six seconds each, silent; and a lotus with Chinese narration.
i=0
for p in Animals/Penguin Animals/Zebra Animals/Parrot; do
  sips -s format jpeg "$PICS/$p.heic" --out "$T/$i.jpg" >/dev/null; i=$((i + 1))
done
ffmpeg -loglevel error -y -loop 1 -t 6 -i "$T/0.jpg" -loop 1 -t 6 -i "$T/1.jpg" -loop 1 -t 6 -i "$T/2.jpg" \
  -filter_complex "[0:v]scale=720:720,setsar=1[v0];[1:v]scale=720:720,setsar=1[v1];[2:v]scale=720:720,setsar=1[v2];[v0][v1][v2]concat=n=3:v=1:a=0" \
  -r 25 -pix_fmt yuv420p "$C/video/VID_20260918.mp4"
sips -s format jpeg "$PICS/Flowers/Lotus.heic" --out "$T/lotus.jpg" >/dev/null
say -v "$ZH" -o "$T/narr.aiff" "七月的西湖，荷花开得正好。我们一早来到曲院风荷，湖面上一大片粉色的荷花，空气里都是清香。"
ffmpeg -loglevel error -y -loop 1 -i "$T/lotus.jpg" -i "$T/narr.aiff" -c:v libx264 -tune stillimage -c:a aac \
  -pix_fmt yuv420p -vf scale=720:720 -shortest "$C/video/VID_20260715.mp4"
done=1
echo "made $C/photos, $C/audio, $C/video"
