"""Measures luoke-search on a scale corpus (scripts/testbed/make_scale.py).

    python3 -I scripts/testbed/scale_measure.py --corpus .dev/scale/10k --index .dev/scale-idx-10k \\
        --hub /tmp/lksr/hub.sock --pids .dev/lab-hub/run7.pids --out .dev/scale-10k.json [--job] [--idle]

The lab hub (scripts/lab_hub.sh) must be up for vectors and searches by meaning; every process started here goes
into --pids for scripts/lab_watchdog.sh. Memory is phys_footprint (what the kernel charges a process): the peak from
.dev/spawn_measured, a moment's from `footprint`. Only counts, times and sizes are written; no file names or text.
"""
import argparse
import json
import os
import random
import re
import signal
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "agent"))
import mcp  # noqa: E402  (the agent's own client, scripts/agent/mcp.py)

parser = argparse.ArgumentParser()
parser.add_argument("--corpus", required=True)
parser.add_argument("--index", required=True)
parser.add_argument("--hub", required=True)
parser.add_argument("--pids", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--bin", default=".build/release/luoke-search")
parser.add_argument("--spawn", default=".dev/spawn_measured")
parser.add_argument("--vector-timeout", type=float, default=0, help="stop filling vectors after this many seconds")
parser.add_argument("--job", action="store_true", help="also time `index --job` on a fresh index")
parser.add_argument("--idle", action="store_true", help="also wait out the resident's 10 minutes before releasing")
parser.add_argument("--partial-vectors", action="store_true",
                    help="vectors were capped (--vector-timeout): later steps don't wait for the rest of them")
parser.add_argument("--steps", default="first,rescan,search,resident,job", help="which of them to run")
args = parser.parse_args()
steps = set(args.steps.split(","))

corpus = os.path.abspath(args.corpus)
results = json.load(open(args.out)) if os.path.exists(args.out) else {}
results["corpus"] = os.path.basename(corpus)
quiet = dict(os.environ)
quiet.pop("LUOKE_HUB_SOCKET", None)
withHub = dict(quiet, LUOKE_HUB_SOCKET=args.hub)


def note(key, value):
    results[key] = value
    with open(args.out, "w") as f:
        json.dump(results, f, indent=1, ensure_ascii=False)
    print("%s: %s" % (key, json.dumps(value, ensure_ascii=False)), flush=True)


def measured(command, env, timeout=0):
    """Runs a command under spawn_measured: exit code, seconds, peak MB, its stdout."""
    pidfile = args.out + ".pid"
    spawn = [args.spawn, "--pid-file", pidfile] + (["--timeout", str(timeout)] if timeout else []) + ["--"] + command
    process = subprocess.Popen(spawn, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    for _ in range(50):
        if os.path.exists(pidfile):
            break
        time.sleep(0.1)
    with open(args.pids, "a") as f:
        f.write(open(pidfile).read())
    out, err = process.communicate()
    os.remove(pidfile)
    match = re.search(r"spawn: exit (\d+), ([\d.]+) s, peak footprint (\d+) MB", err)
    return {"exit": int(match.group(1)), "seconds": float(match.group(2)), "peak_mb": int(match.group(3))}, out


def footprint(pid):
    out = subprocess.run(["footprint", str(pid)], capture_output=True, text=True).stdout
    match = re.search(r"phys_footprint:\s*([\d.]+)\s*([KMG]B)", out)
    if not match:
        return None
    value, unit = float(match.group(1)), match.group(2)
    return round(value * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[unit])


def status():
    out = subprocess.run([args.bin, "status", "--index", args.index, "--json"], env=quiet, capture_output=True, text=True)
    data = json.loads(out.stdout)
    return {"bytes": data.get("bytes"), "counts": data.get("counts")}


def files(kinds):
    out = []
    for root, _, names in os.walk(corpus):
        out += [os.path.join(root, n) for n in names if n.rsplit(".", 1)[-1] in kinds]
    return sorted(out)


def queries(path):
    rng = random.Random(7)
    en = ["quarterly report", "client meeting invoice", "budget review", "hotel flight travel", "contract renewal",
          "kitchen repair warranty", "insurance payment", "school doctor", "release testing plan", "customer survey"]
    zh = ["季度报告", "客户会议发票", "预算评审", "酒店航班", "合同续签", "厨房维修保修", "保险付款", "学校医生", "上线测试", "客服问卷"]
    qs = [{"q": rng.choice(en) + " " + str(rng.randint(1, 99)), "expect": ["none"]} for _ in range(30)]
    qs += [{"q": rng.choice(zh), "expect": ["none"]} for _ in range(30)]
    with open(path, "w") as f:
        json.dump({"base": "~/DigUpTestbed", "queries": qs}, f, ensure_ascii=False)


def timing(env):
    path = args.out + ".queries.json"
    queries(path)
    out = subprocess.run([args.bin, "eval", path, "--index", args.index, "--timing", "--json"], env=env,
                         capture_output=True, text=True)
    line = [l for l in out.stderr.splitlines() if l.startswith("用时")]
    return line[0] if line else out.stderr[-300:]


def change_files(tag):
    """100 documents changed, 100 added, 100 deleted. Returns a word only the added ones hold."""
    marker = "marker%d" % (time.time() * 1000)
    docs = [p for p in files({"txt", "md"}) if "scale-added" not in p]
    rng = random.Random(tag)
    picked = rng.sample(docs, 200)
    for path in picked[:100]:
        with open(path, "a", encoding="utf-8") as f:
            f.write("\nupdated %s\n" % tag)
    for path in picked[100:]:
        os.remove(path)
    folder = os.path.join(corpus, "Documents", "scale-added-%s-%d" % (tag, time.time()))
    os.makedirs(folder, exist_ok=True)
    for index in range(100):
        with open(os.path.join(folder, "added %d.md" % index), "w", encoding="utf-8") as f:
            f.write("# Added %d\n\nA note added while measuring, %s, %s.\n" % (index, tag, marker))
    return marker


# 1. The first pass: reading, then vectors.
if "first" in steps:
  subprocess.run([args.bin, "settings", "--add-folder", corpus, "--index", args.index], env=quiet, check=True,
               capture_output=True)
  run, _ = measured([args.bin, "index", corpus, "--index", args.index, "--no-vectors", "--json"], quiet)
  note("read", dict(run, **status()))
  run, _ = measured([args.bin, "index", corpus, "--index", args.index, "--wait", "--json"], withHub, args.vector_timeout)
  note("vectors", dict(run, **status()))

# 2. A walk with nothing changed; 100 changed, added and deleted.
if "rescan" in steps:
  run, _ = measured([args.bin, "index", corpus, "--index", args.index, "--no-vectors", "--json"], quiet)
  note("rescan_unchanged", run)
  change_files("cli")
  if args.partial_vectors:
      run, _ = measured([args.bin, "index", corpus, "--index", args.index, "--no-vectors", "--json"], quiet)
  else:
      run, _ = measured([args.bin, "index", corpus, "--index", args.index, "--wait", "--json"], withHub, args.vector_timeout)
  note("rescan_300_changes" + ("_without_vectors" if args.partial_vectors else ""), run)

# 3. Searches: by words only, and by meaning.
if "search" in steps:
  note("search_words_only", timing(quiet))
  note("search_meaning", timing(withHub))


def resident_step():
  socket = "/tmp/lsscale.sock"
  pidfile = args.out + ".serve.pid"
  serve = subprocess.Popen([args.spawn, "--pid-file", pidfile, "--", args.bin, "serve", "--index", args.index,
                            "--socket", socket], env=withHub, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
  for _ in range(100):
      if os.path.exists(pidfile) and os.path.exists(socket):
          break
      time.sleep(0.2)
  pid = int(open(pidfile).read())
  with open(args.pids, "a") as f:
      f.write("%d\n" % pid)
  time.sleep(30)   # its first look at the folders
  resident = {"idle_mb": footprint(pid)}
  client = mcp.ToolClient(socket)
  client.discover()
  took = []
  for q in json.load(open(args.out + ".queries.json"))["queries"][:30]:
      start = time.time()
      client.call_tool("search_query", {"query": q["q"]})
      took.append(round((time.time() - start) * 1000))
  resident["first_search_ms"] = took[0]
  rest = sorted(took[1:])
  resident["search_ms_p50_p90_max"] = [rest[len(rest) // 2], rest[len(rest) * 9 // 10], rest[-1]]
  resident["searched_mb"] = footprint(pid)
  # Until nothing waits and the new notes are found: FSEvents hands changes over a moment after they're made.
  marker = change_files("resident")
  start = time.time()
  while time.time() - start < 1800:
      waiting = (client.call_tool("search_status", {}).structured or {}).get("waiting", {})
      kinds = ("read", "rest_of_long_files") if args.partial_vectors else ("read", "vectors", "media", "rest_of_long_files")
      busy = any(waiting.get(k) for k in kinds)
      hits = (client.call_tool("search_query", {"query": marker}).structured or {}).get("hits") or []
      if not busy and any((h.get("title") or "").startswith("added") for h in hits):
          break
      time.sleep(0.5)
  resident["follow_300_changes_s"] = round(time.time() - start, 1)
  resident["after_changes_mb"] = footprint(pid)
  if args.idle:
      time.sleep(610)
      resident["after_idle_release_mb"] = footprint(pid)
  os.kill(pid, signal.SIGTERM)
  _, err = serve.communicate(timeout=120)
  match = re.search(r"peak footprint (\d+) MB", err)
  resident["peak_mb"] = int(match.group(1)) if match else None
  note("resident", resident)


if "resident" in steps:
  resident_step()

# 5. index --job on a fresh index (the first pass as luoke-core runs it).
if args.job and "job" in steps:
    fresh = args.index + "-job"
    subprocess.run([args.bin, "settings", "--add-folder", corpus, "--index", fresh], env=quiet, check=True,
                   capture_output=True)
    run, out = measured([args.bin, "index", "--job", "--index", fresh], withHub, args.vector_timeout)
    note("job", run)
print("done", flush=True)
