#!/bin/bash

# --- lpm sgdb-images <icon|splash|logo|title> <slug> [game_id] [game_name] ---
#
# "Candidate list" step of the GTK visual picker (page_images). Never interactive (no
# "read -p"): always prints JSON on stdout; the GUI shows the choice window and then calls
# "lpm icon/splash/logo <slug> --url <url>" with the chosen image (see zgp-game-icon.sh/
# zgp-game-splash.sh/zgp-game-logo.sh, "--url" option), reusing all existing download/
# conversion/placement/shortcut-regeneration code.
#
# $1 = type ("icon"/"splash"/"logo": same three commands/SteamGridDB assets as the dedicated
#      scripts, i.e. "icons/game/{id}", "heroes/game/{id}", "logos/game/{id}"; or "title",
#      which stops right after resolving the game IDENTITY (game_id/game_name) without
#      fetching any image/thumbnail. This title disambiguation must happen once per game,
#      BEFORE any image choice (see gui/*.py, SgdbTitleResolverWindow, the shared "Phase A"
#      of both page_images modes).
# $2 = Lutris game slug.
# $3 = (optional) SteamGridDB game ID already chosen: passed by the GUI on the second call
#      (after name disambiguation, see "need_game_choice" below) or the identity already
#      resolved by a previous "title" call for the same slug. If absent, the name search is
#      redone.
# $4 = (optional) SteamGridDB name matching $3, for display/Steam fallback; avoids another
#      search just to recover the name.
#
# JSON output (always exit 0, except usage/environment errors below):
#   {"error": "no_key"}                                  -- no valid SteamGridDB key
#   {"error": "slug_not_found"}                           -- slug missing from the Lutris DB
#   {"error": "not_found"}                                -- game not found on SteamGridDB
#   {"error": "no_candidates", "game_id":.., "game_name":..} -- game found but no image
#     (never returned for type "title", which fetches no image)
#   {"need_game_choice": true, "matches": [{"id":.., "name":..}, ...]} -- ambiguous name
#   {"game_id":.., "game_name":..}                        -- type "title" only
#   {"game_id":.., "game_name":.., "thumb_dir":.., "images": [{"url":.., "thumb_path":..}, ...]}
#     -- icon/splash/logo types only
#
# "thumb_dir": temporary directory created here (downloaded thumbnails); the caller (GUI)
# must delete it, it is never cleaned here. Never created for type "title".

type_arg="${1:-}"
slug="${2:-}"
given_game_id="${3:-}"
given_game_name="${4:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

_zgi_json_error() {
  python3 -c 'import json, sys; print(json.dumps({"error": sys.argv[1]}))' "$1"
  exit 0
}

case "${type_arg}" in
  icon|splash|logo|title) ;;
  *)
    zgu_cli_error "$(t sgdb_images.bad_type "${type_arg}")"
    exit 1
    ;;
esac

if [[ -z "${slug}" ]]; then
  zgu_cli_error "$(t sgdb_images.cli_usage)"
  exit 1
fi

for cmd in sqlite3 curl python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgu_cli_error "$(t sgdb_images.cmd_missing "${cmd}")"
    exit 1
  fi
done

# ImageMagick: only needed to normalize icon/splash/logo thumbnails; "title" fetches no
# image, so identity resolution does not depend on it.
convert_bin=()
identify_bin=()
if [[ "${type_arg}" != "title" ]]; then
  if command -v magick >/dev/null 2>&1; then
    convert_bin=(magick)
    identify_bin=(magick identify)
  elif command -v convert >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
    convert_bin=(convert)
    identify_bin=(identify)
  else
    zgu_cli_error "$(t sgdb_images.imagemagick_missing)"
    exit 1
  fi
fi

# --- Lutris resolution (slug -> name), same Flatpak/package detection as the 3 dedicated scripts ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgu_cli_error "$(t sgdb_images.lutris_missing)"
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak) lutris_db="${lutris_flatpak_db}" ;;
  package) lutris_db="${lutris_package_db}" ;;
  *)
    echo "Erreur interne : version Lutris inattendue '${version}'." >&2
    exit 1
    ;;
esac

if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t sgdb_images.db_missing "${lutris_db}")"
  exit 1
fi

g_name="${given_game_name}"
if [[ -z "${g_name}" ]]; then
  slug_escaped="${slug//\'/\'\'}"
  g_name=$(sqlite3 "${lutris_db}" "SELECT name FROM games WHERE slug='${slug_escaped}' AND runner='wine' LIMIT 1;" 2>/dev/null)
  if [[ -z "${g_name}" ]]; then
    _zgi_json_error "slug_not_found"
  fi
fi

# --- SteamGridDB key (already configured/validated via "lpm sgdb-key set", see
# gui/page_images); no interactive loop here: a missing/invalid key is reported in JSON and
# the GUI redirects to the key field of the page. ---
sgdb_key_file="${XDG_CONFIG_HOME:-${HOME}/.config}/lpm/steamgriddb.key"
sgdb_api="https://www.steamgriddb.com/api/v2"

sgdb_key=""
if [[ -f "${sgdb_key_file}" ]]; then
  sgdb_key=$(head -n1 "${sgdb_key_file}" 2>/dev/null | tr -d '[:space:]')
fi
if [[ -z "${sgdb_key}" ]]; then
  _zgi_json_error "no_key"
fi
sgdb_key_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Authorization: Bearer ${sgdb_key}" "${sgdb_api}/search/autocomplete/a" 2>/dev/null)
if [[ "${sgdb_key_code}" != "200" ]]; then
  _zgi_json_error "no_key"
fi

# --- Game search (unless already provided by the GUI on the second call, after disambiguation) ---
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

chosen_game_id="${given_game_id}"
chosen_game_name="${g_name}"

if [[ -z "${chosen_game_id}" ]]; then
  search_results=$(zgp_sgdb_search "${g_name}")
  if [[ -z "${search_results}" ]]; then
    _zgi_json_error "not_found"
  fi

  n_matches=$(printf '%s\n' "${search_results}" | grep -c .)
  if [[ "${n_matches}" -gt 1 ]]; then
    printf '%s\n' "${search_results}" | python3 -c '
import json, sys
matches = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    gid, _, name = line.partition("\t")
    matches.append({"id": gid, "name": name})
print(json.dumps({"need_game_choice": True, "matches": matches}))
'
    exit 0
  fi

  chosen_game_id=$(printf '%s\n' "${search_results}" | head -n1 | cut -f1)
  chosen_game_name=$(printf '%s\n' "${search_results}" | head -n1 | cut -f2)
fi

# --- Type "title": identity resolved, nothing else to do (no image to fetch) ---
if [[ "${type_arg}" = "title" ]]; then
  python3 -c 'import json, sys; print(json.dumps({"game_id": sys.argv[1], "game_name": sys.argv[2]}))' \
    "${chosen_game_id}" "${chosen_game_name}"
  exit 0
fi

# --- Fetch candidates by type (same logic as the dedicated scripts) ---
zgp_sgdb_icons() {
  local game_id="$1" g_name="$2"
  local endpoint="${sgdb_api}/icons/game/${game_id}"
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

  {
    curl -s --max-time 15 -H "Authorization: Bearer ${sgdb_key}" "${endpoint}" 2>/dev/null
    echo
    curl -s --max-time 15 -H "Authorization: Bearer ${sgdb_key}" "${endpoint}?styles=official" 2>/dev/null
    echo
    if [[ -n "${steam_appid}" ]]; then
      curl -s --max-time 15 "https://api.steamcmd.net/v1/info/${steam_appid}" 2>/dev/null
    fi
  } | python3 -c '
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
        for i in data:
            add(i.get("url", ""), i.get("thumb", ""))
    elif isinstance(data, dict):
        for entry in data.values():
            if not isinstance(entry, dict):
                continue
            appid = entry.get("appid")
            common = entry.get("common") or {}
            if not appid or not isinstance(common, dict):
                continue
            clienticon = common.get("clienticon")
            if clienticon:
                add(f"https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/{appid}/{clienticon}.ico")
            else:
                icon = common.get("icon")
                if icon:
                    add(f"https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/{appid}/{icon}.jpg")

for url, thumb in results:
    print(f"{url}\t{thumb}")
'
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

candidates=""
case "${type_arg}" in
  icon) candidates=$(zgp_sgdb_icons "${chosen_game_id}" "${chosen_game_name}") ;;
  splash) candidates=$(zgp_sgdb_heroes "${chosen_game_id}") ;;
  logo)
    candidates=$(zgp_sgdb_logos "${chosen_game_id}")
    if [[ -z "${candidates}" ]]; then
      steam_appid=$(zgp_steam_find_appid "${chosen_game_name}")
      if [[ -n "${steam_appid}" ]]; then
        steam_url="https://cdn.cloudflare.steamstatic.com/steam/apps/${steam_appid}/logo.png"
        if curl -sLf --max-time 15 -o /dev/null "${steam_url}" 2>/dev/null; then
          candidates=$(printf '%s\t%s\n' "${steam_url}" "${steam_url}")
        fi
      fi
    fi
    ;;
esac

if [[ -z "${candidates}" ]]; then
  python3 -c 'import json, sys; print(json.dumps({"error": "no_candidates", "game_id": sys.argv[1], "game_name": sys.argv[2]}))' \
    "${chosen_game_id}" "${chosen_game_name}"
  exit 0
fi

# --- Download thumbnails locally, in parallel. Each multi-resolution ".ico" is reduced to its
# largest frame before the size normalization below (see "thumb_box"/"thumb_crop": the
# uniform display size is enforced HERE by ImageMagick, not only on the GTK side). ---
thumb_dir=$(mktemp -d "${TMPDIR:-/tmp}/lpm-sgdb-thumbs.XXXXXX")

urls=() thumbs=()
while IFS=$'\t' read -r u thumb_u; do
  [[ -z "${u}" ]] && continue
  [[ -z "${thumb_u}" ]] && thumb_u="${u}"
  urls+=("${u}")
  thumbs+=("${thumb_u}")
done <<< "${candidates}"

dl_pids=()
for i in "${!thumbs[@]}"; do
  ext="${thumbs[${i}]##*.}"
  ext="${ext,,}"
  [[ "${ext}" =~ ^[a-z0-9]{1,5}$ ]] || ext="img"
  (curl -sLf --max-time 15 "${thumbs[${i}]}" -o "${thumb_dir}/${i}.raw.${ext}" 2>/dev/null) &
  dl_pids+=("$!")
done
for pid in "${dl_pids[@]}"; do
  wait "${pid}" 2>/dev/null
done

# Preview box normalized PER TYPE: all displayed thumbnails must have EXACTLY the same
# size. GTK alone is not enough (set_size_request in gui/*.py only sets a MINIMUM), so a
# source icon larger than the wanted box still enlarges its natural size reported to GTK
# and, since a FlowBox is homogeneous, the WHOLE row of thumbnails. The reliable way is to
# resize pixel-exact here, BEFORE passing them to the GUI, with a ratio per image type:
#   - icon  : square, cropped ("^" + "-extent"); the source is already ~square, so the
#             overflow can be trimmed with no notable loss.
#   - splash: wide (typical Hero ratio), cropped the same way; already panoramic.
#   - logo  : wide, but WITHOUT "^" (contained in the frame, never cropped) then padded on a
#             transparent canvas ("-background none ... -extent"): a very wide or narrow logo
#             must never be cut, and the transparent padding is invisible since SteamGridDB
#             logos are already cut out.
case "${type_arg}" in
  icon) thumb_box="112x112" thumb_crop=true ;;
  splash) thumb_box="186x60" thumb_crop=true ;;
  logo) thumb_box="170x96" thumb_crop=false ;;
esac

images_json="["
first=true
for i in "${!urls[@]}"; do
  ext="${thumbs[${i}]##*.}"
  ext="${ext,,}"
  [[ "${ext}" =~ ^[a-z0-9]{1,5}$ ]] || ext="img"
  raw="${thumb_dir}/${i}.raw.${ext}"
  [[ -s "${raw}" ]] || continue

  frame_ref="${raw}"
  if [[ "${ext}" = "ico" ]]; then
    biggest=$("${identify_bin[@]}" "${raw}" 2>/dev/null | sort -n -k3 | tail -n1 | grep -oP '\[\K[^\]]+')
    [[ -z "${biggest}" ]] && biggest=0
    frame_ref="${raw}[${biggest}]"
  fi

  normalized="${thumb_dir}/${i}.thumb.png"
  if [[ "${thumb_crop}" = true ]]; then
    "${convert_bin[@]}" "${frame_ref}" -background none -resize "${thumb_box}^" -gravity center -extent "${thumb_box}" "${normalized}" 2>/dev/null
  else
    "${convert_bin[@]}" "${frame_ref}" -background none -resize "${thumb_box}" -gravity center -extent "${thumb_box}" "${normalized}" 2>/dev/null
  fi
  [[ -s "${normalized}" ]] || continue
  thumb_path="${normalized}"

  [[ "${first}" = true ]] && first=false || images_json+=","
  images_json+=$(python3 -c 'import json, sys; print(json.dumps({"url": sys.argv[1], "thumb_path": sys.argv[2]}))' "${urls[${i}]}" "${thumb_path}")
done
images_json+="]"

python3 -c '
import json, sys
game_id, game_name, thumb_dir, images_json = sys.argv[1:5]
print(json.dumps({
    "game_id": game_id,
    "game_name": game_name,
    "thumb_dir": thumb_dir,
    "images": json.loads(images_json),
}))
' "${chosen_game_id}" "${chosen_game_name}" "${thumb_dir}" "${images_json}"
