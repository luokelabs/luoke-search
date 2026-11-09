#!/bin/sh
# A test on a real Photos library (only with the say-so of the library's owner): read-only, the index in
# .dev/photos-real (deleted at the end), and only totals come out — never a photo's name, identifier, date, place or
# text. It never searches. Everything that reads the library runs as 螺壳搜索.app itself: its development build
# (LUOKE_SEARCH_DEV_APP=1), the one that takes this test's index; the app as it ships refuses it. Nothing here asks
# macOS for the library (only luoke's own program does): `job` and `probe` need access given to the app before.
#
#   sh scripts/photos_real_test.sh prepare      build the app and the spawner, turn photos on in the test index
#   sh scripts/photos_real_test.sh who          which identity Photos access is checked against: started plainly by
#                                               another program, started disclaiming, opened by LaunchServices
#   sh scripts/photos_real_test.sh job [s]      the first pass (index --job), at most s seconds (default 1800)
#   sh scripts/photos_real_test.sh probe [n] [o]   what the library gives: n photos and videos fetched, o originals
#   sh scripts/photos_real_test.sh cleanup      stop anything left, unregister the app, delete .dev/photos-real
#
# Output of the programs is filtered: only lines that are totals by construction are shown; others are counted.
set -eu
cd "$(dirname "$0")/.."
base=.dev/photos-real
home="$PWD/$base/home"
app=build.noindex/螺壳搜索.app
exe="$PWD/$app/Contents/MacOS/luoke-search"
spawn="$PWD/$base/spawn_measured"
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Shows only the lines matching $1 from file $2; says how many others there were.
only() {
  grep -E "$1" "$2" || true
  others=$(grep -cvE "$1" "$2" || true)
  [ "$others" -eq 0 ] || echo "（另有 $others 行输出没显示）"
}

# This build's app only (its path is under build.noindex): an installed 螺壳搜索.app is never touched.
serving() { pgrep -f "build.noindex/螺壳搜索.app/Contents/MacOS/luoke-search" || true; }

# Nothing read here is ever sent to a hub, whatever the terminal has set.
unset LUOKE_HUB_SOCKET
case "${1:-}" in
prepare)
  unset LUOKE_SEARCH_PHOTOS
  LUOKE_SEARCH_DEV_APP=1 sh scripts/build_app.sh | tail -1
  mkdir -p "$home"
  chmod 700 "$base"
  clang -O2 -o "$spawn" scripts/spawn_measured.c
  .build/release/luoke-search settings --photos on --index "$home" >/dev/null
  .build/release/luoke-search settings --index "$home" | grep '照片图库'
  ;;
who)
  plain=$("$spawn" -- "$exe" photos-probe --access 2>/dev/null || true)
  disclaimed=$("$spawn" --disclaim -- "$exe" photos-probe --access 2>/dev/null || true)
  : > "$base/who.out"   # open --stdout appends
  open -W -n -g --stdout "$PWD/$base/who.out" "$app" --args photos-probe --access 2>/dev/null || true
  echo "别的程序直接起（像主控起空闲任务）：${plain:-?}"
  echo "起的时候声明自己负责（disclaim）：${disclaimed:-?}"
  echo "LaunchServices 打开（open）：$(cat "$base/who.out")"
  ;;
job)
  "$spawn" --disclaim --timeout "${2:-1800}" -- "$exe" index --job --index "$home" 2> "$base/job.err" || true
  only '^(luoke-search job:|spawn:)' "$base/job.err"
  .build/release/luoke-search status --json --index "$home" | /usr/bin/python3 -I -c '
import json, sys
s = json.load(sys.stdin)
c = s["counts"]
print("索引里：", json.dumps(c["items"], ensure_ascii=False), "等着读", c["waiting_to_read"], "读不了", c["failed"],
      "跳过", c["skipped"], "等图片和声音向量", c["waiting_for_media"])
print("索引大小：%.1f MB" % (s["bytes"] / 1048576), "；不进 Time Machine：", s["excluded_from_backup"])'
  echo "数据目录：$(du -sh "$home" | cut -f1)"
  ;;
probe)
  "$spawn" --disclaim -- "$exe" photos-probe --sample "${2:-2000}" --originals "${3:-300}" \
    > "$base/probe.json" 2> "$base/probe.err" || true
  /usr/bin/python3 -I -c 'import json, sys; print(json.dumps(json.load(open(sys.argv[1])), indent=1))' \
    "$base/probe.json" || echo "没有汇总（看退出码）"
  only '^spawn:' "$base/probe.err"
  ;;
cleanup)
  for pid in $(serving); do kill -TERM "$pid"; done
  sleep 2
  for pid in $(serving); do kill -KILL "$pid"; done
  "$lsregister" -u "$app" 2>/dev/null || true
  rm -rf "$base"
  [ ! -e "$base" ] && echo "删干净了：$base" || echo "还在：$base"
  [ -z "$(serving)" ] && echo "没有残留进程" || echo "还有进程：$(serving)"
  ;;
*)
  sed -n '2,14p' "$0"
  exit 2
  ;;
esac
