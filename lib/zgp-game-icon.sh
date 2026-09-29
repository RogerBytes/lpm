#!/bin/bash

# --- lpm icon [slug...] ---
#
# Récupère automatiquement une icône pour un ou plusieurs jeux déjà installés, via
# SteamGridDB (icônes carrées communautaires + icônes officielles "Steam Client Icon"
# quand elles existent), et régénère les raccourcis existants du jeu (menu et/ou bureau)
# pour qu'ils l'utilisent.
#
# Commande à part, jamais greffée automatiquement dans install/shortcut : c'est la seule
# fonctionnalité de lpm qui dépend d'un service tiers (réseau + clé API) -- une panne de
# SteamGridDB ou l'absence de clé ne doit jamais faire échouer une installation ou la
# création d'un raccourci, qui restent 100% autonomes.
#
# $1, $2... = slugs de jeux cibles en CLI. Vide => mode interactif Zenity, liste à cocher de
# tous les jeux installés, pré-cochant uniquement ceux qui n'ont pas encore d'icône
# personnalisée (voir zgp_icon_has_custom_icon plus bas).
cli_targets=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-desktop-utils.sh
source "${script_dir}/zgu-desktop-utils.sh"
# shellcheck source=./zgu-checklist-utils.sh
source "${script_dir}/zgu-checklist-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

will_use_zenity=true
[[ ${#cli_targets[@]} -gt 0 ]] && will_use_zenity=false

# La clé SteamGridDB est strictement personnelle à l'utilisateur (voir zgp_sgdb_ensure_key
# plus bas) : jamais partagée, jamais embarquée dans lpm -- un fichier dédié, hors de portée
# du reste du projet, permissions 600 (lecture/écriture propriétaire seulement).
sgdb_key_file="${XDG_CONFIG_HOME:-${HOME}/.config}/lpm/steamgriddb.key"
sgdb_api="https://www.steamgriddb.com/api/v2"
sgdb_key=""

# --- 1. Vérification des dépendances ---
zgp_icon_report_error_early() {
  local msg="$1"
  if [[ "${will_use_zenity}" = true ]] && command -v zenity >/dev/null 2>&1; then
    zenity --error --text="${msg}" 2>/dev/null
  fi
  echo "${msg}" >&2
}

for cmd in sqlite3 curl python3 realpath; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgp_icon_report_error_early "$(t icon.cmd_missing "${cmd}")"
    exit 1
  fi
done

if [[ "${will_use_zenity}" = true ]] && ! command -v zenity >/dev/null 2>&1; then
  zgu_cli_error "$(t icon.zenity_missing)"
  exit 1
fi

# ImageMagick : nécessaire pour convertir les icônes ".ico" (fréquentes, extraites
# d'exécutables Windows à l'origine) en ".png", le seul format que la spec freedesktop
# Desktop Entry attend de façon fiable pour "Icon=" -- voir zgp_icon_fetch_and_place plus
# bas. ImageMagick 7 fusionne convert/identify dans un seul binaire "magick" ; ImageMagick 6
# garde deux binaires séparés -- les deux formes sont acceptées.
convert_bin=()
identify_bin=()
if command -v magick >/dev/null 2>&1; then
  convert_bin=(magick)
  identify_bin=(magick identify)
elif command -v convert >/dev/null 2>&1 && command -v identify >/dev/null 2>&1; then
  convert_bin=(convert)
  identify_bin=(identify)
else
  zgp_icon_report_error_early "$(t icon.imagemagick_missing)"
  exit 1
fi

# --- 2. Détection Flatpak vs Paquet natif + résolution des chemins Lutris ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"
lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"
games_dir="${HOME}/Games"

icon_display_mode="gui"
[[ "${will_use_zenity}" = false ]] && icon_display_mode="cli"
version=$(zgu_resolve_lutris_version "${icon_display_mode}" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgp_icon_report_error_early "$(t icon.lutris_missing)"
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_system_file="${lutris_flatpak_system_file}"
    runner_dir="${lutris_flatpak_runner_dir}"
    ;;
  package)
    lutris_db="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    lutris_system_file="${lutris_package_system_file}"
    runner_dir="${lutris_package_runner_dir}"
    ;;
  *)
    echo "Erreur interne : version Lutris inattendue '${version}'." >&2
    exit 1
    ;;
esac

if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
fi

if [[ ! -f "${lutris_db}" ]]; then
  zgp_icon_report_error_early "$(t icon.db_missing "${lutris_db}")"
  exit 1
fi

# --- 3. Récupération des jeux Wine depuis la base Lutris ---
games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(id,'') || char(31) || COALESCE(name,'') || char(31) || COALESCE(slug,'') || char(31) || COALESCE(directory,'') || char(31) || COALESCE(executable,'') || char(31) || COALESCE(configpath,'') FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgp_icon_report_error_early "$(t icon.none_found)"
  exit 0
fi

declare -A name_by_slug
declare -A dir_by_slug
declare -A id_by_slug
declare -A exe_by_slug
declare -A configpath_by_slug

# Jeux vivant dans un préfixe de store partagé (Epic Games Store, EA App, Ubisoft
# Connect...) : hors du principe un-jeu-un-préfixe de lpm, jamais proposés ici -- même
# filtre que zgp-game-shortcutter.sh/zgp-game-uninstaller.sh (voir zgu_get_blacklisted_slugs).
declare -A blacklisted_slugs
while IFS= read -r bl_slug; do
  [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
done < <(zgu_get_blacklisted_slugs "${lutris_db}")

sorted_slugs=()

while IFS=$'\x1f' read -r g_id g_name g_slug g_dir g_exe g_configpath; do
  [[ -z "${g_slug}" ]] && continue
  [[ -n "${blacklisted_slugs[${g_slug}]:-}" ]] && continue
  [[ -z "${g_dir}" ]] && g_dir="${games_dir}/${g_slug}"

  name_by_slug["${g_slug}"]="${g_name}"
  dir_by_slug["${g_slug}"]="${g_dir}"
  id_by_slug["${g_slug}"]="${g_id}"
  exe_by_slug["${g_slug}"]="${g_exe}"
  configpath_by_slug["${g_slug}"]="${g_configpath}"
  sorted_slugs+=("${g_slug}")
done <<< "${games_list}"

if [[ ${#sorted_slugs[@]} -eq 0 ]]; then
  zgp_icon_report_error_early "$(t icon.none_found)"
  exit 0
fi

# Un jeu a déjà une icône personnalisée si <prefix_dir>/icon contient un fichier image --
# EXACTEMENT le même test que celui fait par zgu_write_game_shortcut pour résoudre l'icône
# d'un raccourci : les deux doivent toujours s'accorder.
zgp_icon_has_custom_icon() {
  local dir="$1"
  [[ -d "${dir}/icon" ]] || return 1
  local f
  f=$(find "${dir}/icon" -maxdepth 1 -type f \( -name "*.png" -o -name "*.ico" -o -name "*.svg" -o -name "*.xpm" \) -print -quit 2>/dev/null)
  [[ -n "${f}" ]]
}

# --- 4. Sélection des jeux cibles ---
targets=()

if [[ ${#cli_targets[@]} -gt 0 ]]; then
  # --- MODE CLI ---
  if [[ "${cli_targets[0]}" = "--all" ]]; then
    targets=("${sorted_slugs[@]}")
  else
    for target_slug in "${cli_targets[@]}"; do
      if [[ -n "${name_by_slug[${target_slug}]:-}" ]]; then
        targets+=("${target_slug}")
      elif [[ -n "${blacklisted_slugs[${target_slug}]:-}" ]]; then
        zgu_cli_error "$(t icon.slug_blacklisted "${target_slug}")"
        exit 1
      else
        zgu_cli_error "$(t icon.slug_not_found "${target_slug}")"
        exit 1
      fi
    done
  fi
else
  # --- MODE INTERACTIF (Zenity) ---
  # Précoche uniquement les jeux sans icône personnalisée -- voir zgu_gui_checklist_with_states
  # dans zgu-checklist-utils.sh pour la mécanique d'états différenciés par ligne.
  checklist_values=()
  for g_slug in "${sorted_slugs[@]}"; do
    if zgp_icon_has_custom_icon "${dir_by_slug[${g_slug}]}"; then
      checklist_values+=("FALSE" "${name_by_slug[${g_slug}]}" "${g_slug}")
    else
      checklist_values+=("TRUE" "${name_by_slug[${g_slug}]}" "${g_slug}")
    fi
  done

  selected=$(zgu_gui_checklist_with_states 2 \
    "$(t icon.select_title)" \
    "$(t icon.select_text)" \
    650 450 \
    "$(t icon.select_col_fetch)" "$(t icon.select_col_game)" "$(t icon.select_col_slug)" \
    -- \
    "${checklist_values[@]}")

  [[ -z "${selected}" ]] && exit 0

  # zgu_gui_checklist_with_states/--list --checklist renvoie TOUTES les colonnes de valeur des
  # lignes cochées (séparées par \x1f) : nom puis slug, à plat -- on ne garde que le slug (une
  # colonne sur deux) pour retrouver le jeu dans les tableaux associatifs ci-dessus.
  IFS=$'\x1f' read -r -a selected_flat <<< "${selected}"
  for (( i=1; i<${#selected_flat[@]}; i+=2 )); do
    targets+=("${selected_flat[i]}")
  done

  [[ ${#targets[@]} -eq 0 ]] && exit 0
fi

# --- 5. Clé API SteamGridDB (voir docs/dernière feature.md pour le contexte complet) ---
#
# Strictement personnelle à l'utilisateur : jamais de clé partagée/embarquée dans lpm (un
# service à 10 millions d'utilisateurs sur une seule clé serait vite bloqué), et jamais de
# compte imposé pour le reste de lpm -- seule cette commande, qui dépend de ce service tiers,
# en a besoin. Testée avant d'être acceptée (jamais stockée sans avoir été validée par un
# appel réel à l'API), et rebouclée sur elle-même en cas de refus plutôt que d'échouer net.
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
  sgdb_key=$(zgp_sgdb_read_key)
  if [[ -n "${sgdb_key}" ]] && zgp_sgdb_key_valid "${sgdb_key}"; then
    return 0
  fi

  local candidate first_try=true
  while true; do
    if [[ "${will_use_zenity}" = true ]]; then
      [[ "${first_try}" = false ]] && zenity --error --text="$(t icon.key_invalid)" 2>/dev/null
      command -v xdg-open >/dev/null 2>&1 && xdg-open "https://www.steamgriddb.com/profile/preferences" >/dev/null 2>&1 &
      candidate=$(zenity --entry --title="$(t icon.key_title)" --text="$(t icon.key_text)" --width=500 2>/dev/null)
    else
      [[ "${first_try}" = false ]] && t icon.key_invalid >&2
      t icon.key_text_cli
      read -r -p "$(t icon.key_prompt_cli)" candidate
    fi
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

# --- 6. Appels SteamGridDB ---
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

# Sortie : une ligne par icône candidate, "url_pleine_resolution<TAB>url_vignette" -- le champ
# "thumb" de SteamGridDB (confirmé réel via la structure JSON documentée par un client officiel
# tiers, node-steamgriddb/le wrapper Go steam-shortcut-manager : chaque icône a "url" ET "thumb")
# est une vignette déjà réduite par SteamGridDB, bien plus légère et rapide à télécharger que
# l'image pleine résolution -- utilisée uniquement pour l'aperçu visuel du sélecteur, jamais pour
# l'icône finalement posée (qui reste toujours "url", en pleine qualité). Repli sur "url" si
# jamais "thumb" est absent d'une réponse (ne devrait pas arriver, mais mieux vaut ne jamais
# afficher une icône manquante que de se fier aveuglément à un champ optionnel).
zgp_sgdb_icons() {
  local game_id="$1" g_name="$2"
  local endpoint="${sgdb_api}/icons/game/${game_id}"

  # Troisième source, différente des deux appels SteamGridDB ci-dessous : le vrai "Client
  # Icon" Steam (hash "clienticon"/"icon" + AppID Steam), pour les jeux dont SteamGridDB
  # n'héberge AUCUNE icône (0 Icons, quel que soit le style) -- ex: Crossbar Cards. SteamGridDB
  # affiche bien un bouton "View Original Steam Assets" pour ces jeux, mais construit ce lien à
  # partir d'une API interne au SITE steamgriddb.com ("/api/public/game/{id}"), non documentée
  # et qui répond 403 à toute requête qui n'est pas un vrai navigateur (confirmé par un test
  # direct) -- injouable depuis un script. La même donnée (mêmes hash "clienticon"/"icon",
  # vérifié identique) est en revanche accessible par script via DEUX API publiques, sans clé,
  # sans blocage anti-bot, faites précisément pour un usage programmatique :
  #  1. store.steampowered.com/api/storesearch/ (API officielle Steam) : nom du jeu -> AppID.
  #  2. api.steamcmd.net/v1/info/{appid} (projet open source "steamcmd/api",
  #     https://github.com/steamcmd/api, instance publique déjà en ligne, rien à héberger) :
  #     AppID -> hash "clienticon"/"icon" (dump JSON de app_info, exactement ce que lit le
  #     client Steam lui-même).
  # Ces deux hash sont ensuite combinés à l'AppID exactement comme le fait la page SteamGridDB :
  # "https://cdn.cloudflare.steamstatic.com/steamcommunity/public/images/apps/<appid>/<hash>.<ext>".
  # "clienticon" (un vrai .ico) est essayé en premier : c'est le format le plus proche de ce que
  # lpm pose déjà comme icône de raccourci. Best-effort à chaque étape : un jeu introuvable sur
  # le Store Steam, ou sans "clienticon"/"icon" dans app_info, laisse simplement cette source
  # vide -- on retombe alors sur les deux appels SteamGridDB seuls, jamais d'échec bloquant.
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
    # Second appel explicite avec "styles=official" : "official" est une valeur de style
    # confirmée réelle pour les icônes (vue dans le formulaire de filtre de la page d'un jeu sur
    # steamgriddb.com : "Any Style" / "Official" / "Custom"), donc pour un jeu qui a bien des
    # icônes "officielles" contribuées à la base SteamGridDB elle-même (par opposition à
    # "custom"), ce filtre peut en révéler que l'appel par défaut n'inclut pas. Fusionné avec le
    # premier (dédoublonné par URL côté Python ci-dessous), jamais en remplacement : si
    # "styles=official" échoue, ce bloc est silencieusement ignoré et on retombe sur le premier.
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
        # Forme des deux appels SteamGridDB (icons/game/{id}, avec ou sans ?styles=official).
        for i in data:
            add(i.get("url", ""), i.get("thumb", ""))
    elif isinstance(data, dict):
        # Forme de la réponse api.steamcmd.net/v1/info/{appid} : {"<appid>": {"appid":...,
        # "common": {"clienticon": "...", "icon": "...", ...}, ...}}.
        for entry in data.values():
            if not isinstance(entry, dict):
                continue
            appid = entry.get("appid")
            common = entry.get("common") or {}
            if not appid or not isinstance(common, dict):
                continue
            # "icon" (le petit favicon Steam, toujours basse resolution, ~32x32) est ajoute
            # SEULEMENT si "clienticon" (le vrai Client Icon, jusqu a 256x256) est absent --
            # jamais les deux en meme temps : proposer les deux dans le selecteur ne servait a
            # rien, "icon" n etant jamais meilleur que "clienticon" quand celui-ci existe. "icon"
            # reste un repli utile pour les (rares) jeux qui auraient "icon" sans "clienticon".
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

# --- 7. Traitement d'un jeu ---
#
# Retourne 0 si une icône a bien été posée, 1 sinon (jeu introuvable sur SteamGridDB, aucune
# icône disponible, téléchargement/conversion échoués, ou annulation par l'utilisateur en
# mode GUI) -- jamais de silence : chaque échec passe par zgp_icon_report_skip, affiché sur
# stderr en CLI et accumulé pour un résumé Zenity unique en fin de traitement du lot en GUI
# (même principe que zgp-game-isolator.sh).
declare -a gui_skip_messages=()
zgp_icon_report_skip() {
  local msg="$1"
  echo "${msg}" >&2
  [[ "${will_use_zenity}" = true ]] && gui_skip_messages+=("${msg}")
}

zgp_icon_process_one() {
  local slug="$1" g_name="$2" prefix_dir="$3" g_id="$4" g_exe="$5" g_configpath="$6"

  local search_results
  search_results=$(zgp_sgdb_search "${g_name}")
  if [[ -z "${search_results}" ]]; then
    zgp_icon_report_skip "$(t icon.not_found_on_sgdb "${g_name}")"
    zgu_log "icon" "ERREUR" "slug=${slug} raison=jeu_introuvable_sgdb"
    return 1
  fi

  local n_matches
  n_matches=$(printf '%s\n' "${search_results}" | grep -c . )

  local chosen_game_id="" chosen_game_name=""
  if [[ "${n_matches}" -gt 1 ]]; then
    if [[ "${will_use_zenity}" = true ]]; then
      local zargs=() g_gid g_sgdb_name first=true
      while IFS=$'\t' read -r g_gid g_sgdb_name; do
        [[ -z "${g_gid}" ]] && continue
        if [[ "${first}" = true ]]; then
          zargs+=("TRUE" "${g_gid}" "${g_sgdb_name}")
          first=false
        else
          zargs+=("FALSE" "${g_gid}" "${g_sgdb_name}")
        fi
      done <<< "${search_results}"

      chosen_game_id=$(zenity --list --radiolist \
        --title="$(t icon.pick_game_title)" \
        --text="$(t icon.pick_game_text "${g_name}")" \
        --column="" --column="ID" --column="$(t icon.pick_game_col)" \
        --hide-column=2 --print-column=2 \
        "${zargs[@]}" --width=550 --height=420 2>/dev/null)
    else
      t icon.pick_game_text_cli "${g_name}"
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
      read -r -p "$(t icon.pick_game_prompt_cli)" choice
      chosen_game_id="${idx_to_id[${choice}]:-}"
      chosen_game_name="${idx_to_name[${choice}]:-}"
    fi

    if [[ -z "${chosen_game_id}" ]]; then
      zgp_icon_report_skip "$(t icon.cancelled_by_user "${g_name}")"
      return 1
    fi
  else
    chosen_game_id=$(printf '%s\n' "${search_results}" | head -n1 | cut -f1)
    chosen_game_name=$(printf '%s\n' "${search_results}" | head -n1 | cut -f2)
  fi

  # Le nom SteamGridDB CONFIRMÉ (celui de la ligne choisie), jamais le nom brut Lutris ("g_name")
  # : Lutris peut contenir un nom personnalisé/mal orthographié par l'utilisateur (ex:
  # "Crossybara" au lieu de "Crossbar Cards") -- l'autocomplete SteamGridDB tolère ce genre
  # d'écart (recherche floue), mais la recherche officielle de store.steampowered.com utilisée
  # par zgp_sgdb_icons pour retrouver l'AppID Steam (voir plus haut) ne le tolère pas, et renvoie
  # alors 0 résultat -- confirmé réel : c'est exactement ce qui faisait échouer le Client Icon pour
  # Crossbar Cards malgré la correction précédente.
  #
  # Retrouvé ici en recherchant "chosen_game_id" dans "search_results" plutôt qu'en essayant de
  # le récupérer directement en sortie de Zenity (--radiolist) : ça évite de dépendre d'un
  # comportement de "--print-column=ALL" avec plusieurs colonnes de valeur qui n'a pas pu être
  # vérifié en direct de façon fiable, contrairement au cas de zgu_gui_checklist_with_states.
  # Cette recherche fonctionne quel que soit le mode (CLI ou GUI) et écrase toujours la valeur
  # déjà réglée par les branches ci-dessus -- une seule source de vérité. Repli sur "g_name"
  # seulement si l'ID choisi n'est, contre toute attente, pas retrouvé dans "search_results".
  local sr_gid sr_name
  while IFS=$'\t' read -r sr_gid sr_name; do
    if [[ "${sr_gid}" = "${chosen_game_id}" ]]; then
      chosen_game_name="${sr_name}"
      break
    fi
  done <<< "${search_results}"
  [[ -z "${chosen_game_name}" ]] && chosen_game_name="${g_name}"

  local icons_urls
  icons_urls=$(zgp_sgdb_icons "${chosen_game_id}" "${chosen_game_name}")
  if [[ -z "${icons_urls}" ]]; then
    zgp_icon_report_skip "$(t icon.no_icon_available "${g_name}")"
    zgu_log "icon" "ERREUR" "slug=${slug} raison=aucune_icone_disponible"
    return 1
  fi

  local n_icons
  n_icons=$(printf '%s\n' "${icons_urls}" | grep -c .)

  local chosen_url=""
  if [[ "${n_icons}" -gt 1 ]] && [[ "${will_use_zenity}" = true ]]; then
    # Sélection visuelle : chaque icône candidate est téléchargée en vignette locale, puis
    # affichée via "zenity --list --imagelist" (colonne image, voir "zenity --help-list").
    #
    # Deux optimisations pour un affichage rapide et des vignettes de taille homogène :
    #  1. Téléchargement de "thumb" (vignette déjà réduite par SteamGridDB, voir
    #     zgp_sgdb_icons ci-dessus) au lieu de "url" (pleine résolution) -- beaucoup plus léger,
    #     donc beaucoup plus rapide à récupérer. "url" en pleine qualité reste utilisée plus
    #     bas, une fois l'icône choisie.
    #  2. Téléchargements lancés en parallèle (en arrière-plan, "wait" ensuite) plutôt qu'un
    #     par un en séquence -- le temps d'attente devient celui du plus lent des
    #     téléchargements, pas leur somme.
    #  3. Chaque vignette est ensuite recadrée par ImageMagick sur un canevas carré fixe
    #     (fond transparent, image centrée) : les icônes SteamGridDB n'ont pas toutes les
    #     mêmes dimensions ni le même ratio, donc sans ça, l'aperçu affiche des cases de
    #     tailles visuellement différentes -- ce recadrage garantit que toutes les vignettes
    #     apparaissent avec exactement la même taille dans le sélecteur.
    local tmp_dir icon_urls_arr=() thumb_urls_arr=() thumb_paths=() line u thumb_u ext raw_thumb padded_thumb i
    tmp_dir=$(mktemp -d)
    i=0
    while IFS=$'\t' read -r u thumb_u; do
      [[ -z "${u}" ]] && continue
      [[ -z "${thumb_u}" ]] && thumb_u="${u}"
      icon_urls_arr+=("${u}")
      thumb_urls_arr+=("${thumb_u}")
      i=$((i + 1))
    done <<< "${icons_urls}"

    local -a dl_pids=()
    for i in "${!thumb_urls_arr[@]}"; do
      ext="${thumb_urls_arr[${i}]##*.}"
      raw_thumb="${tmp_dir}/${i}.raw.${ext}"
      (curl -sLf --max-time 15 "${thumb_urls_arr[${i}]}" -o "${raw_thumb}" 2>/dev/null) &
      dl_pids+=("$!")
    done
    for pid in "${dl_pids[@]}"; do
      wait "${pid}" 2>/dev/null
    done

    local frame_ref biggest
    for i in "${!thumb_urls_arr[@]}"; do
      ext="${thumb_urls_arr[${i}]##*.}"
      raw_thumb="${tmp_dir}/${i}.raw.${ext}"
      padded_thumb="${tmp_dir}/${i}.png"
      frame_ref="${raw_thumb}"
      if [[ -s "${raw_thumb}" ]] && [[ "${ext,,}" = "ico" ]]; then
        # Un ".ico" (notamment le "Client Icon" Steam, voir zgp_sgdb_icons plus haut) empile
        # souvent plusieurs résolutions dans un seul fichier. Sans préciser laquelle utiliser
        # ("[index]"), "convert" traite CHAQUE résolution empilée et, comme un ".png" ne peut
        # en contenir qu'une seule à la fois, écrit alors PLUSIEURS fichiers numérotés
        # ("nom-0.png", "nom-1.png", ...) au lieu du seul fichier "${padded_thumb}" attendu --
        # celui-ci n'est alors jamais créé, mais "convert" se termine quand même en succès (code
        # 0), donc rien ne signalait l'échec : Zenity affichait une vignette cassée/vide pour ce
        # candidat, alors que l'autre (une image à une seule résolution, ex: le petit "icon"
        # Steam en 32x32) s'affichait normalement -- confirmé réel avec le vrai ".ico" 256x256
        # de Crossbar Cards (6 résolutions empilées, de 16x16 à 256x256). Résultat concret :
        # l'utilisateur voyait une vignette valide et une vignette cassée, et choisissait sans
        # le savoir la moins bonne qualité des deux puisque la meilleure semblait indisponible.
        # Correction : sélectionner ici la plus grande résolution empilée (même méthode -
        # "identify" trié numériquement sur la géométrie - que celle déjà utilisée après coup
        # pour le téléchargement final en pleine qualité) et ne convertir QUE cette résolution
        # ("raw_thumb.ico[index]") -- un seul fichier en sortie, et l'aperçu reflète enfin
        # fidèlement ce qui sera vraiment posé comme icône si ce candidat est choisi.
        biggest=$("${identify_bin[@]}" "${raw_thumb}" 2>/dev/null | sort -n -k3 | tail -n1 | grep -oP '\[\K[^\]]+')
        [[ -n "${biggest}" ]] && frame_ref="${raw_thumb}[${biggest}]"
      fi
      # "96x96^" (recadrage "cover", jamais de bordure ajoutée) et pas "96x96" simple
      # (letterbox/pad) : Zenity rogne les marges unies (transparentes ou non) d'une vignette
      # au moment de l'afficher dans "--imagelist", donc une image simplement mise à l'échelle
      # PUIS paddée sur un canevas carré ressort quand même avec une taille visuelle différente
      # selon le ratio d'origine (confirmé par test réel) -- seul un remplissage intégral du
      # carré (comme un recadrage centré) donne une taille affichée réellement identique pour
      # toutes les icônes, quel que soit leur ratio de départ.
      # "-background none" explicite : sans lui, ImageMagick recompose l'image sur un fond
      # blanc opaque par défaut pendant le recadrage, et une icône avec des coins transparents
      # (ex: icône ronde) ressort avec un carré blanc plein autour -- confirmé par un test réel
      # (pixel de coin lu en srgb(255,255,255) sans lui, en srgba(0,0,0,0) avec).
      if [[ -s "${raw_thumb}" ]] && "${convert_bin[@]}" "${frame_ref}" -background none -resize 96x96^ -gravity center -extent 96x96 "${padded_thumb}" 2>/dev/null && [[ -s "${padded_thumb}" ]]; then
        thumb_paths+=("${padded_thumb}")
      else
        thumb_paths+=("")
      fi
    done

    local imglist_args=()
    for i in "${!icon_urls_arr[@]}"; do
      [[ -n "${thumb_paths[${i}]}" ]] || continue
      imglist_args+=("${thumb_paths[${i}]}" "$((i + 1))")
    done

    local chosen_idx
    chosen_idx=$(zenity --list --imagelist \
      --title="$(t icon.pick_icon_title)" \
      --text="$(t icon.pick_icon_text "${g_name}")" \
      --column="$(t icon.pick_icon_col_preview)" --column="$(t icon.pick_icon_col_num)" \
      --print-column=2 \
      "${imglist_args[@]}" --width=650 --height=450 2>/dev/null)

    rm -rf "${tmp_dir}"

    if [[ -z "${chosen_idx}" ]]; then
      zgp_icon_report_skip "$(t icon.cancelled_by_user "${g_name}")"
      return 1
    fi
    chosen_url="${icon_urls_arr[$((chosen_idx - 1))]}"
  else
    chosen_url=$(printf '%s\n' "${icons_urls}" | head -n1 | cut -f1)
  fi

  # --- Téléchargement + conversion .ico -> .png si nécessaire ---
  mkdir -p "${prefix_dir}/icon"
  # Purge les anciennes icônes (même filtre que zgu_write_game_shortcut ci-dessus -- jamais
  # autre chose dans ce dossier, ex: des extras packagés dans un .zgp ne vivent pas ici).
  find "${prefix_dir}/icon" -maxdepth 1 -type f \( -name "*.png" -o -name "*.ico" -o -name "*.svg" -o -name "*.xpm" \) -delete 2>/dev/null

  local ext="${chosen_url##*.}"
  ext="${ext,,}"
  local raw_file="${prefix_dir}/icon/.lpm-download.${ext}"

  if ! curl -sLf --max-time 30 "${chosen_url}" -o "${raw_file}" 2>/dev/null; then
    zgp_icon_report_skip "$(t icon.download_failed "${g_name}")"
    zgu_log "icon" "ERREUR" "slug=${slug} raison=telechargement_echoue"
    rm -f "${raw_file}"
    return 1
  fi

  if [[ "${ext}" = "ico" ]]; then
    # Un .ico peut empiler plusieurs résolutions dans un seul fichier -- on prend la plus
    # grande (3e colonne de "identify", triée numériquement), même méthode qu'un outil
    # comparable établi (steamtinkerlaunch) pour ce même problème.
    local biggest
    biggest=$("${identify_bin[@]}" "${raw_file}" 2>/dev/null | sort -n -k3 | tail -n1 | grep -oP '\[\K[^\]]+')
    [[ -z "${biggest}" ]] && biggest=0
    if ! "${convert_bin[@]}" "${raw_file}[${biggest}]" "${prefix_dir}/icon/icon.png" 2>/dev/null; then
      zgp_icon_report_skip "$(t icon.convert_failed "${g_name}")"
      zgu_log "icon" "ERREUR" "slug=${slug} raison=conversion_ico_echouee"
      rm -f "${raw_file}"
      return 1
    fi
    rm -f "${raw_file}"
  else
    mv "${raw_file}" "${prefix_dir}/icon/icon.${ext}"
  fi

  # --- Régénère les raccourcis existants (jamais n'en crée de nouveaux : seulement ceux
  # déjà présents pour ce jeu, menu et/ou bureau) pour qu'ils pointent vers la nouvelle
  # icône -- voir zgu_write_game_shortcut dans zgu-desktop-utils.sh, qui relit
  # <prefix_dir>/icon au moment de la (re)génération.
  local menu_file="${HOME}/.local/share/applications/net.lutris.${slug}.desktop"
  local desktop_dir desktop_file
  desktop_dir=$(zgu_get_desktop_dir)
  desktop_file="${desktop_dir}/${slug}.desktop"

  local has_menu=false has_desktop=false
  [[ -f "${menu_file}" ]] && has_menu=true
  [[ -f "${desktop_file}" ]] && has_desktop=true

  if [[ "${has_menu}" = true ]] || [[ "${has_desktop}" = true ]]; then
    zgu_write_game_shortcut "${g_name}" "${slug}" "${prefix_dir}" "${g_id}" "${version}" "${has_menu}" "${has_desktop}" "${g_exe}" "${g_configpath}" "${lutris_config_dir}" "${runner_dir}"
  fi

  zgu_log "icon" "OK" "slug=${slug} nom=${g_name}"
  [[ "${will_use_zenity}" = false ]] && t icon.done_cli "${g_name}"
  return 0
}

# --- 8. Exécution ---
zgp_sgdb_ensure_key || { zgp_icon_report_error_early "$(t icon.no_key_cancelled)"; exit 1; }

exit_code=0
for target_slug in "${targets[@]}"; do
  zgp_icon_process_one "${target_slug}" "${name_by_slug[${target_slug}]}" "${dir_by_slug[${target_slug}]}" "${id_by_slug[${target_slug}]}" "${exe_by_slug[${target_slug}]}" "${configpath_by_slug[${target_slug}]}" || exit_code=1
done

# Résumé Zenity des échecs éventuels (mode GUI uniquement) -- une seule fenêtre en fin de
# lot, même principe que zgp-game-isolator.sh, pour ne pas empiler les fenêtres si plusieurs
# jeux du lot échouent chacun pour une raison différente.
if [[ "${will_use_zenity}" = true ]] && [[ ${#gui_skip_messages[@]} -gt 0 ]]; then
  errors_text=$(printf '%s\n' "${gui_skip_messages[@]}")
  zenity --error --title="$(t icon.errors_gui_title)" --width=550 \
    --text="$(t icon.errors_gui_intro)

${errors_text}" 2>/dev/null
elif [[ "${will_use_zenity}" = true ]]; then
  zenity --info --text="$(t icon.done_gui "${#targets[@]}")" 2>/dev/null
fi

exit "${exit_code}"
