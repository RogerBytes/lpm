#!/bin/bash

# --- SteamGridDB: API key and calls, shared by every lpm command that uses it ---
#
# Library (no code runs when it is sourced): lib/zgp-game-icon.sh, zgp-game-logo.sh,
# zgp-game-splash.sh, zgl-sgdb-images.sh and zgl-sgdb-key.sh all use THESE functions, so the key
# handling and the API calls exist once. Needs "t" (zgl-lang-loader.sh) and curl/python3 at call
# time. "sgdb_key" (the key in use) is set by zgp_sgdb_ensure_key in the calling script.

# Same file for every command: single source of truth, read/written identically everywhere.
sgdb_key_file="${XDG_CONFIG_HOME:-${HOME}/.config}/lpm/steamgriddb.key"
sgdb_api="https://www.steamgriddb.com/api/v2"
ZGU_SGDB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- 5. SteamGridDB API key ---
#
# Strictly personal to the user: no shared/bundled key in lpm (one key for many users would
# quickly be blocked), and no account imposed for the rest of lpm; only this command, which
# depends on the third-party service, needs one. Validated before being accepted (never stored
# without a real API call succeeding), and re-prompted on refusal instead of failing outright.
zgp_sgdb_read_key() {
  [[ -f "${sgdb_key_file}" ]] || return 1
  head -n1 "${sgdb_key_file}" 2>/dev/null | tr -d '[:space:]'
}

zgp_sgdb_save_key() {
  local key="$1"
  mkdir -p "$(dirname "${sgdb_key_file}")"
  printf '%s\n' "${key}" > "${sgdb_key_file}"
  chmod 600 "${sgdb_key_file}"
}

zgp_sgdb_key_valid() {
  local key="$1" code
  [[ -z "${key}" ]] && return 1
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${key}" "${sgdb_api}/search/autocomplete/a" 2>/dev/null)
  [[ "${code}" = "200" ]]
}

zgp_sgdb_ensure_key() {
  local lang_prefix="$1"
  sgdb_key=$(zgp_sgdb_read_key)
  if [[ -n "${sgdb_key}" ]] && zgp_sgdb_key_valid "${sgdb_key}"; then
    return 0
  fi

  local candidate first_try=true
  while true; do
    [[ "${first_try}" = false ]] && t "${lang_prefix}.key_invalid" >&2
    t "${lang_prefix}.key_text_cli"
    read -r -p "$(t "${lang_prefix}.key_prompt_cli")" candidate
    first_try=false

    [[ -z "${candidate}" ]] && return 1

    candidate="${candidate//[$'\n\r\t ']/}"

    if zgp_sgdb_key_valid "${candidate}"; then
      zgp_sgdb_save_key "${candidate}"
      sgdb_key="${candidate}"
      return 0
    fi
  done
}

# --- 6. SteamGridDB calls ---
zgp_sgdb_search() {
  local term="$1" encoded
  encoded=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${term}" 2>/dev/null)
  [[ -z "${encoded}" ]] && return 1
  curl -s --max-time 15 -H "Authorization: Bearer ${sgdb_key}" "${sgdb_api}/search/autocomplete/${encoded}" 2>/dev/null | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(data, dict) or not data.get("success"):
    sys.exit(0)
for g in data.get("data", []) or []:
    gid = g.get("id")
    name = g.get("name", "")
    if gid is None:
        continue
    name = str(name).replace("\t", " ").replace("\n", " ").replace("\r", " ")
    print(f"{gid}\t{name}")
'
}

# Output: one line per candidate icon, "full_resolution_url<TAB>thumbnail_url". SteamGridDB's
# "thumb" field (each icon has "url" AND "thumb", per the JSON structure documented by official
# Picks the SteamGridDB game among search results ("id<TAB>name" lines): asks the user when
# several match (CLI), else takes the single one. Sets sgdb_pick_id / sgdb_pick_name.
# Args: lang_prefix (icon|splash|logo, for the messages) g_name search_results.
# Returns 1 if the user's choice is invalid (cancelled).
sgdb_pick_id="" sgdb_pick_name=""
zgp_sgdb_pick_game() {
  local lang="$1" g_name="$2" search_results="$3"
  local chosen_game_id="" chosen_game_name=""
  local n_matches
  n_matches=$(printf '%s\n' "${search_results}" | grep -c .)

  if [[ "${n_matches}" -gt 1 ]]; then
    t "${lang}.pick_game_text_cli" "${g_name}"
    local -A idx_to_id=() idx_to_name=()
    local idx=1 g_gid g_sgdb_name
    while IFS=$'\t' read -r g_gid g_sgdb_name; do
      [[ -z "${g_gid}" ]] && continue
      printf '  %d) %s\n' "${idx}" "${g_sgdb_name}"
      idx_to_id["${idx}"]="${g_gid}"
      idx_to_name["${idx}"]="${g_sgdb_name}"
      idx=$((idx + 1))
    done <<< "${search_results}"
    local choice
    read -r -p "$(t "${lang}.pick_game_prompt_cli")" choice
    chosen_game_id="${idx_to_id[${choice}]:-}"
    chosen_game_name="${idx_to_name[${choice}]:-}"
    [[ -n "${chosen_game_id}" ]] || return 1
  else
    chosen_game_id=$(printf '%s\n' "${search_results}" | head -n1 | cut -f1)
    chosen_game_name=$(printf '%s\n' "${search_results}" | head -n1 | cut -f2)
  fi

  # The CONFIRMED SteamGridDB name (that of the chosen row), never the raw Lutris name: Lutris
  # may hold a customized or misspelled name, which the Steam store search does not tolerate.
  # Looked up by ID in the results (single source of truth); falls back to g_name.
  local sr_gid sr_name
  while IFS=$'\t' read -r sr_gid sr_name; do
    if [[ "${sr_gid}" = "${chosen_game_id}" ]]; then
      chosen_game_name="${sr_name}"
      break
    fi
  done <<< "${search_results}"
  [[ -z "${chosen_game_name}" ]] && chosen_game_name="${g_name}"

  # shellcheck disable=SC2034  # both read by the scripts that source this library
  sgdb_pick_id="${chosen_game_id}"
  # shellcheck disable=SC2034
  sgdb_pick_name="${chosen_game_name}"
  return 0
}

# Steam AppID of a game name (official Steam store search), empty if not found. Arg: name.
zgp_sgdb_steam_appid() {
  local g_name="$1"
  # Third source, distinct from the two SteamGridDB calls below: the real Steam "Client Icon"
  # (hash "clienticon"/"icon" + Steam AppID), for games for which SteamGridDB hosts NO icon (0
  # icons, whatever the style), e.g. Crossbar Cards. SteamGridDB shows a "View Original Steam
  # Assets" button for these games, but builds that link from an internal API of the
  # steamgriddb.com SITE ("/api/public/game/{id}"), undocumented and answering 403 to anything
  # that is not a real browser, so unusable from a script. The same data (same
  # "clienticon"/"icon" hashes) is available from two public APIs, no key and no anti-bot
  # blocking, built for programmatic use:
  #  1. store.steampowered.com/api/storesearch/ (official Steam API): game name -> AppID.
  #  2. api.steamcmd.net/v1/info/{appid} (open source project "steamcmd/api",
  #     https://github.com/steamcmd/api, public instance, nothing to host): AppID ->
  #     "clienticon"/"icon" hash (JSON dump of app_info, exactly what the Steam client reads).
  # The hashes are combined with the AppID as the SteamGridDB page does:
  # "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/<appid>/<hash>.<ext>".
  # "clienticon" (a real .ico) is tried first, as the closest to what lpm already uses as
  # shortcut icon. Best-effort at each step: a game not found in the Steam Store, or without
  # "clienticon"/"icon" in app_info, leaves this source empty and only the two SteamGridDB
  # calls remain; never a blocking failure.
  local steam_appid=""
  if [[ -n "${g_name}" ]]; then
    local encoded_name
    encoded_name=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${g_name}" 2>/dev/null)
    if [[ -n "${encoded_name}" ]]; then
      steam_appid=$(curl -s --max-time 15 "https://store.steampowered.com/api/storesearch/?term=${encoded_name}&cc=us&l=en" 2>/dev/null | python3 -c '
import sys, json
try:
    obj = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = obj.get("items") if isinstance(obj, dict) else None
if items:
    appid = items[0].get("id", "")
    if appid:
        print(appid)
' 2>/dev/null)
    fi
  fi

  printf '%s' "${steam_appid}"
}

# third-party clients such as node-steamgriddb and the Go steam-shortcut-manager) is a thumbnail
# already reduced by SteamGridDB, much lighter and faster to download than the full-resolution
# image. It is used only for the picker preview, never for the icon finally applied (always
# "url", full quality). Falls back to "url" if "thumb" is ever missing from a response.
zgp_sgdb_icons() {
  local game_id="$1" g_name="$2"
  local endpoint="${sgdb_api}/icons/game/${game_id}"
  local steam_appid=""
  [[ -n "${g_name}" ]] && steam_appid=$(zgp_sgdb_steam_appid "${g_name}")

  {
    curl -s --max-time 15 -H "Authorization: Bearer ${sgdb_key}" "${endpoint}" 2>/dev/null
    echo
    # Second explicit call with "styles=official": "official" is a real style value for
    # icons (seen in the filter form of a game page on steamgriddb.com: "Any Style" /
    # "Official" / "Custom"). For a game with "official" icons contributed to SteamGridDB
    # itself (as opposed to "custom"), this filter can reveal some that the default call
    # does not include. Merged with the first call (deduplicated by URL in the Python code
    # below), never replacing it: if "styles=official" fails, this block is silently ignored
    # and the first call stands.
    curl -s --max-time 15 -H "Authorization: Bearer ${sgdb_key}" "${endpoint}?styles=official" 2>/dev/null
    echo
    if [[ -n "${steam_appid}" ]]; then
      curl -s --max-time 15 "https://api.steamcmd.net/v1/info/${steam_appid}" 2>/dev/null
    fi
  } | python3 "${ZGU_SGDB_DIR}/zgu-sgdb-merge-icons.py"
}

zgp_sgdb_heroes() {
  local game_id="$1"
  curl -s --max-time 15 -H "Authorization: Bearer ${sgdb_key}" \
    "${sgdb_api}/heroes/game/${game_id}?types=static&mimes=image/png,image/jpeg,image/webp" 2>/dev/null | python3 -c '
import sys, json
try:
    obj = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(obj, dict) or not obj.get("success"):
    sys.exit(0)
seen = set()
for h in obj.get("data", []) or []:
    url = h.get("url", "")
    thumb = h.get("thumb") or url
    if url and url not in seen:
        seen.add(url)
        print(f"{url}\t{thumb}")
'
}

zgp_sgdb_logos() {
  local game_id="$1"
  curl -s --max-time 15 -H "Authorization: Bearer ${sgdb_key}" \
    "${sgdb_api}/logos/game/${game_id}?types=static&mimes=image/png,image/webp" 2>/dev/null | python3 -c '
import sys, json
try:
    obj = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not isinstance(obj, dict) or not obj.get("success"):
    sys.exit(0)
seen = set()
for h in obj.get("data", []) or []:
    url = h.get("url", "")
    thumb = h.get("thumb") or url
    if url and url not in seen:
        seen.add(url)
        print(f"{url}\t{thumb}")
'
}

zgp_steam_find_appid() {
  local term="$1" encoded
  encoded=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${term}" 2>/dev/null)
  [[ -z "${encoded}" ]] && return 1
  curl -s --max-time 15 "https://store.steampowered.com/api/storesearch/?term=${encoded}&cc=us&l=en" 2>/dev/null | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = data.get("items") or []
if items:
    aid = items[0].get("id")
    if aid is not None:
        print(aid)
'
}
