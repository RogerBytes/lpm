"""Asynchronous, cached check for a newer lpm version."""

import json
import os
import re
import time

import backend
from util import _run_on_main


# ---------------------------------------------------------------------------------------
# --- lpm update check (home page banner, see page_home) ---
# "lpm self-update check" (lib/zgc-self-update.sh) contacts GitHub; its result is cached for
# 24 h to avoid hitting the API (60 requests/hour/IP without an account) on every launch. The
# cache keeps the LATEST published version (not a yes/no): the comparison with the installed
# version is redone on each launch, otherwise the banner would survive the update itself.
_UPDATE_CACHE_FILE = os.path.join(os.path.expanduser("~"), ".cache", "lpm", "update-check.json")


_UPDATE_CACHE_MAX_AGE_S = 24 * 3600


_UPDATE_INFO_RE = re.compile(r"^\[UPDATE-INFO\]\s+([^|]+)\|([^|]*)\|(\w+)")


def _version_key(version: str) -> tuple:
    return tuple(int(x) for x in re.findall(r"\d+", version))


def _check_update_async(callback):
    """callback(info | None) is called on the main thread, with info = {"latest", "url",
    "method"}; silent (None) if offline or if the check fails."""
    try:
        with open(_UPDATE_CACHE_FILE, "r", encoding="utf-8") as f:
            cached = json.load(f)
        if time.time() - float(cached.get("ts", 0)) < _UPDATE_CACHE_MAX_AGE_S and cached.get("latest"):
            callback({k: cached.get(k, "") for k in ("latest", "url", "method")})
            return
    except (OSError, ValueError):
        pass

    def on_done(result):
        info = None
        if result.returncode == 0:
            for line in result.stdout.splitlines():
                m = _UPDATE_INFO_RE.match(line.strip())
                if m:
                    info = {"latest": m.group(1).strip(), "url": m.group(2).strip(), "method": m.group(3)}
                    break
        if info:
            try:
                os.makedirs(os.path.dirname(_UPDATE_CACHE_FILE), exist_ok=True)
                with open(_UPDATE_CACHE_FILE, "w", encoding="utf-8") as f:
                    json.dump({**info, "ts": time.time()}, f)
            except OSError:
                pass
        _run_on_main(callback, info)

    backend.run_lpm_async(["self-update", "check"], on_done=on_done)
