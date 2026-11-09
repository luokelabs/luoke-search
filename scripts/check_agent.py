"""Walks through what luoke-agent does with luoke-search, using the agent's own reference client and card validator
(scripts/agent/: luoke-agent's mcp.py and a2ui.py, unmodified).

    LUOKE_SEARCH_OPENER=dry luoke-search serve --index .dev/<name> --socket /tmp/lsag.sock &
    python3 -I scripts/check_agent.py --socket /tmp/lsag.sock --query "团队版怎么收费" --folder testbed/zh/office

Prints one line per check and exits non-zero if any fails. Only the settings of the --index given are changed.
"""
import argparse
import base64
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "agent"))
import a2ui  # noqa: E402
import mcp  # noqa: E402

failures = []


def check(name, ok, detail=""):
    print(("ok    " if ok else "FAIL  ") + name + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        failures.append(name)


def card_ok(name, messages):
    problems = a2ui.validate(messages)
    check(name, not problems, "; ".join(problems))
    return not problems


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--query", default="团队版怎么收费")
    parser.add_argument("--folder", required=True, help="a folder to propose adding to the settings")
    args = parser.parse_args()
    client = mcp.ToolClient(args.socket)

    discover = client.discover()
    check("server/discover: 2026-07-28", mcp.PROTOCOL_VERSION in discover.get("supportedVersions", []))

    tools = {t["name"]: t for t in client.list_tools()}
    check("tools/list: the seven tools and outbox_ack",
          set(tools) == {"search_query", "search_similar", "search_open", "search_status", "search_settings",
                         "search_settings_apply", "search_open_system_settings", "outbox_ack"}, ", ".join(sorted(tools)))
    check("search_open is Mac only", tools["search_open"].get("_meta", {}).get("ai.luoke/where") == "mac")
    check("only the manifest's actions need a tap",
          {n for n, t in tools.items() if not t["annotations"]["readOnlyHint"]}
          == {"search_settings_apply", "search_open"})

    outbox = client.outbox("luoke-search")
    check("outbox reads", isinstance(outbox, list))
    for item in outbox:
        card_ok(f"outbox card {item.get('kind')}", item.get("card"))
        check(f"outbox {item.get('kind')} has title and summary", bool(item.get("title")) and bool(item.get("summary")))

    # §1a: relative ids.
    relative = client.read_json("outbox")
    check("outbox by relative id", isinstance(relative, dict) and isinstance(relative.get("items"), list))
    page = client.read_json("page/overview")
    check("page/overview is a card the agent draws", a2ui.validate(page) == [], str(a2ui.validate(page)))

    summary = client.read_json("summary")
    check("summary has count and text",
          isinstance(summary.get("count"), int) and isinstance(summary.get("text"), str), str(summary))
    permissions = client.read_json("permissions")
    check("permissions: photos", permissions.get("photos") in ("granted", "denied", "ask"), str(permissions))

    found = client.call_tool("search_query", {"query": args.query})
    check("search_query answers", not found.is_error and bool(found.text), found.text)
    hits = found.structured.get("hits") or []
    check("search_query has hits with where and why", bool(hits) and all("why" in h and "id" in h for h in hits))
    if card_ok("result card is valid A2UI", found.card):
        surface = a2ui.build(found.card)
        check("result card is a new card", "createSurface" in found.card[0])
        check("result card is under 200 components", len(surface.components) <= a2ui.MAX_COMPONENTS)
        if hits:
            untapped = client.call_tool("search_open", {"id": hits[0]["id"]})
            check("search_open without a tap is refused",
                  untapped.is_error and untapped.code == "needs_user_action", untapped.text)
            tap = {"surfaceId": surface.surface_id, "componentId": "b1", "at": "2026-10-20T10:00:00+08:00"}
            opened = client.call_tool("search_open", {"id": hits[0]["id"]}, user_action=tap)
            check("search_open after a tap opens (dry)", not opened.is_error and "演习" in opened.text, opened.text)

    # §1b: the window's global search draws the hits itself; a time alone lists; thumbnails are resources.
    check("hits in the window's shape",
          bool(hits) and all(h.get("source") in ("files", "photos") and h.get("kind_label") and h.get("actions")
                             and all(a.get("name") in tools and a.get("args", {}).get("id") == h["id"]
                                     for a in h["actions"]) for h in hits))
    # The window's filter and its counts: each source's total, whatever the limit and the filter.
    totals = found.structured.get("totals")
    check("totals: files and photos, counted past the limit",
          isinstance(totals, dict) and set(totals) == {"files", "photos"}
          and all(isinstance(n, int) for n in totals.values()) and totals["files"] + totals["photos"] >= len(hits),
          str(totals))
    only_files = client.call_tool("search_query", {"query": args.query, "sources": ["files"]})
    check("sources keeps to one",
          not only_files.is_error and all(h.get("source") == "files" for h in only_files.structured.get("hits") or []),
          only_files.text)
    # Each call has its own wait for the query's vector (one may be words only), and the index may change between
    # them: compare only two answers that say the same about what they're missing.
    if found.structured.get("partial_reason") == only_files.structured.get("partial_reason"):
        check("the totals stay under the filter", only_files.structured.get("totals") == totals,
              f"{totals} → {only_files.structured.get('totals')}")
    else:
        print("skip  the totals under the filter (the two answers are partial in different ways)")
    # 「找相似的」: read-only, pressed without a tap, answered in the same shape.
    similar = next((a for h in hits for a in h["actions"] if a.get("name") == "search_similar"), None)
    if similar:
        alike = client.call_tool("search_similar", similar["args"])
        check("search_similar answers in the search's shape",
              not alike.is_error and isinstance(alike.structured.get("hits"), list)
              and isinstance(alike.structured.get("skipped"), list) and isinstance(alike.structured.get("totals"), dict)
              and similar["args"]["id"] not in [h["id"] for h in alike.structured["hits"]], alike.text)
        if alike.card:
            card_ok("similar card is valid A2UI", alike.card)
    else:
        print("skip  search_similar (no result has vectors in this index)")
    listed = client.call_tool("search_query", {"since": "2000-01-01", "limit": 50})
    check("a time alone lists", not listed.is_error and bool(listed.structured.get("hits")), listed.text)
    # What wasn't looked in (the row under the window's results): always a list, each with its source and why.
    skipped = listed.structured.get("skipped")
    check("skipped is a list", isinstance(skipped, list), str(skipped))
    if skipped:
        check("skipped rows have source, why, text and detail",
              all(s.get("source") and s.get("why") and s.get("text") and s.get("detail") for s in skipped), str(skipped))
    else:
        print("skip  skipped rows (nothing left out here: a terminal's serve doesn't read Photos)")
    thumbs = [h["thumb"] for h in listed.structured.get("hits") or [] if h.get("thumb")]
    if thumbs:
        try:
            contents = client.request("resources/read", {"uri": thumbs[0]}).get("contents") or [{}]
            picture = base64.b64decode(contents[0].get("blob") or "")
            check("a thumbnail is a JPEG within 256 KB",
                  contents[0].get("mimeType") == "image/jpeg" and picture[:3] == b"\xff\xd8\xff"
                  and len(picture) <= 256 * 1024, thumbs[0])
        except mcp.RpcError as error:
            check("a thumbnail is a JPEG within 256 KB", False, f"{thumbs[0]}: {error}")
    else:
        print("skip  a thumbnail (no picture in this index)")

    status = client.call_tool("search_status")
    check("search_status answers", not status.is_error and "items" in status.structured, status.text)

    proposed = client.call_tool("search_settings", {"change": {"add_folders": [os.path.abspath(args.folder)]}})
    plan = proposed.structured.get("plan_id")
    if plan is None:
        check("search_settings: already searched", "不用改" in proposed.text, proposed.text)
        return finish()
    check("search_settings makes a plan", bool(plan), proposed.text)
    card_ok("plan card is valid A2UI", proposed.card)
    surface = a2ui.build(proposed.card)

    untapped = client.call_tool("search_settings_apply", {"plan_id": plan})
    check("apply without a tap is refused", untapped.is_error and untapped.code == "needs_user_action", untapped.text)
    tap = {"surfaceId": surface.surface_id, "componentId": "b1", "at": "2026-10-20T10:00:00+08:00"}
    applied = client.call_tool("search_settings_apply", {"plan_id": plan}, user_action=tap)
    check("apply after a tap is done", not applied.is_error and applied.done, applied.text)
    if applied.card:
        try:
            a2ui.update(surface, applied.card)
            check("result replaces the plan card", True)
        except a2ui.CardError as error:
            check("result replaces the plan card", False, str(error))
    again = client.call_tool("search_settings_apply", {"plan_id": plan}, user_action=tap)
    check("the same plan twice is stale", again.is_error and again.code == "stale", again.text)
    return finish()


def finish():
    print(f"{len(failures)} failed" if failures else "all good")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
