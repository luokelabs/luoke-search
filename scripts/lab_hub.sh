#!/bin/sh
# An isolated lab luoke-core for luoke-search's real-model evals and reference-vector checks. Adapted from the lab script
# of luoke's internal DigUp fork (same isolation). Ask before every start: it loads a real model.
#
# Never touches the production hub or anyone's data:
#   - everything lives in <luoke-search>/.dev/lab-hub (gitignored): state, logs, the engine's base_path, HOME;
#   - HOME and LUOKE_HOME point inside it: no installed accessories seen, ~/.luoke never touched;
#   - the socket is in its run/; /tmp/lksr is a short symlink to that folder (AF_UNIX paths are limited to 104 bytes);
#   - the engine package (oMLX 0.7.1rc1, or another one there named by LUOKE_LAB_ENGINE) and the weights are the ones
#     luoke-core-embedtest already has, used read-only by path: nothing is downloaded (no --release), nothing in them
#     changes;
#   - no base model in any tier: only the embedding worker runs;
#   - the recipe is a lab copy of luoke-core's dev.json (scripts/lab_recipe.py): its embedding task named
#     luoke-search.embed (renamed from digup.embed in luoke-core#16, 11-02; a copy from before it is taken too), pictures
#     and sound on.
#
#   sh scripts/lab_hub.sh <luoke-core source, a read-only copy (git archive)>
#   LUOKE_LAB_ENGINE=omlx-0.7.2 sh scripts/lab_hub.sh …   another engine package under luoke-core-embedtest/engines
#   luoke-search side: LUOKE_HUB_SOCKET=/tmp/lksr/hub.sock
# Stop it: kill the PID it prints. The hub stops its worker and removes its socket.
set -eu
src=$(cd "${1:?usage: lab_hub.sh <luoke-core source copy>}" && pwd)
shift
repo=$(cd "$(dirname "$0")/.." && pwd)
lab="$HOME/Library/Application Support/luoke-core-embedtest"
engine=${LUOKE_LAB_ENGINE:-omlx-0.7.1rc1}
engine_app="$lab/engines/$engine/oMLX.app"
weights="$lab/models/embeddinggemma-2-bf16"
env="$repo/.dev/lab-hub"
short=/tmp/lksr

grep -q '/v1/embed' "$src/luoke_core/hub.py" || { echo "$src has no /v1/embed" >&2; exit 1; }
[ -d "$engine_app" ] || { echo "no engine package at $engine_app (not downloading one)" >&2; exit 1; }
[ -f "$weights/model.safetensors" ] || { echo "no weights at $weights (not downloading them)" >&2; exit 1; }
# The hub removes a stale socket at --socket on start, so the short path must be free or already our symlink.
if [ -e "$short" ] || [ -L "$short" ]; then
  [ -L "$short" ] && [ "$(readlink "$short")" = "$env/run" ] || { echo "$short is taken by something else" >&2; exit 1; }
fi

mkdir -p "$env/run" "$env/models" "$env/home/Applications" "$env/home/.luoke"
# The recipe before the links: one it can't make stops here with nothing linked.
recipe="$env/recipe-luoke-search-lab.json"
/usr/bin/python3 -I "$repo/scripts/lab_recipe.py" "$src/recipes/dev.json" "$recipe" "$engine_app" "$engine"
ln -sfn "$weights" "$env/models/embeddinggemma-2-bf16"
ln -sfn "$env/run" "$short"

echo "lab env: $env"
echo "engine: $engine ($engine_app), pictures and sound on"
echo "socket: $short/hub.sock"
echo "PID: $$ (stop only this one)"
# Every path above is resolved against the real HOME; from here on the hub and its children only see the lab folder.
export HOME="$env/home" LUOKE_HOME="$env/home/.luoke"
cd "$src"
exec /usr/bin/python3 -m luoke_core serve --lab --no-smoke --recipe "$recipe" --model-dir "$env/models" \
  --env "$env" --socket "$short/hub.sock" "$@"
