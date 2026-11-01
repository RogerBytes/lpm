#!/usr/bin/env python3
"""Merges the JSON documents read on stdin (SteamGridDB icons calls + api.steamcmd.net app
info, see zgp_sgdb_icons in zgu-sgdb.sh) into "url<TAB>thumb" lines, deduplicated by URL."""
import sys, json

buf = sys.stdin.read()
decoder = json.JSONDecoder()
idx = 0
n = len(buf)
seen = set()
results = []

def add(url, thumb=None):
    if url and url not in seen:
        seen.add(url)
        results.append((url, thumb or url))

while idx < n:
    while idx < n and buf[idx] in " \t\n\r":
        idx += 1
    if idx >= n:
        break
    try:
        obj, end = decoder.raw_decode(buf, idx)
    except Exception:
        break
    idx = end
    if not isinstance(obj, dict):
        continue
    ok = obj.get("success") is True or obj.get("status") == "success"
    if not ok:
        continue
    data = obj.get("data")
    if isinstance(data, list):
        # Shape of the two SteamGridDB calls (icons/game/{id}, with or without
        # ?styles=official).
        for i in data:
            add(i.get("url", ""), i.get("thumb", ""))
    elif isinstance(data, dict):
        # Shape of the api.steamcmd.net/v1/info/{appid} response: {"<appid>":
        # {"appid":..., "common": {"clienticon": "...", "icon": "...", ...}, ...}}.
        for entry in data.values():
            if not isinstance(entry, dict):
                continue
            appid = entry.get("appid")
            common = entry.get("common") or {}
            if not appid or not isinstance(common, dict):
                continue
            # "icon" (the small Steam favicon, always low resolution, ~32x32) is
            # added ONLY if "clienticon" (the real Client Icon, up to 256x256) is
            # absent, never both at once: "icon" is never better than "clienticon"
            # when the latter exists. It remains a useful fallback for the (rare)
            # games with "icon" but no "clienticon".
            clienticon = common.get("clienticon")
            if clienticon:
                add(f"https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/{appid}/{clienticon}.ico")
            else:
                icon = common.get("icon")
                if icon:
                    add(f"https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/{appid}/{icon}.jpg")

for url, thumb in results:
    print(f"{url}\t{thumb}")
