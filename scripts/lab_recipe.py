"""The recipe scripts/lab_hub.sh starts its lab luoke-core with: a copy of luoke-core's dev.json with luoke-search's
embedding task named luoke-search.embed, pictures and sound on, and only that task assigned (no base model in any tier).
luoke-core's recipe names the task luoke-search.embed since its rename (luoke-core#16, 11-02); a copy of luoke-core from
before it calls it digup.embed. Either name is taken, and the copy has the new one. Reads dev.json and writes the copy,
nothing else.

    python3 -I scripts/lab_recipe.py <luoke-core's recipes/dev.json> <the copy> <engine app> <engine version>
"""
import json
import sys

TASK = "luoke-search.embed"
OLD = "digup.embed"   # luoke-core's name for it before the rename


def lab(d: dict, engine_app: str, engine: str) -> dict:
    named = [name for name in (TASK, OLD) if name in d["tasks"]]
    if len(named) != 1:
        found = f"both {TASK} and {OLD}" if named else f"neither {TASK} nor {OLD}"
        raise SystemExit(f"the recipe has {found}: one of them is expected")
    task = d["tasks"].pop(named[0])
    task["accessory"] = "luoke-search"
    d["tasks"][TASK] = task
    d["recipe_version"] += "-luoke-search-lab"
    d["engine"]["app"] = engine_app
    d["engine"]["version"] = engine
    # luoke-core's multimodal draft: with image_batch and audio_batch the hub takes pictures and sound.
    for params in task["params"].values():
        params.update({"image_batch": 8, "image_budgets": [70, 140, 280, 560, 1120], "audio_batch": 2,
                       "max_image_bytes": 4000000, "max_audio_bytes": 1100000, "max_audio_secs": 30})
    # As luoke-core's own embedding checks: no base model, only the embedding task assigned.
    d["assignment"] = {tier: {"base": None, "special": {TASK: "embeddinggemma-2"}} for tier in d["tiers"]}
    d["verified"].pop("digup", None)
    d["verified"]["luoke-search"] = {"versions": ["*"]}
    return d


if __name__ == "__main__":
    source, copy, engine_app, engine = sys.argv[1:5]
    recipe = lab(json.load(open(source, encoding="utf-8")), engine_app, engine)
    json.dump(recipe, open(copy, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
