#!/bin/bash

# --- lpm logo [slug...|--all] ---
#
# Récupère automatiquement un logo transparent ("Logo" SteamGridDB -- image du titre du jeu,
# détourée/transparente, pensée pour être superposée à une bannière, PAS un fond plein écran)
# pour un ou plusieurs jeux déjà installés, et le pose comme $GAMEDIR/splash/logo.png --
# l'image affichée en permanence, par-dessus tout (écran noir, picker, bannière), pendant le
# LPM Launcher (voir zgl-launcher-orchestrator.sh / zgu-launcher-logo.py).
#
# Commande à part, jamais greffée automatiquement à "lpm launcher ... on" : même principe que
# "lpm icon"/"lpm splash" (voir zgp-game-icon.sh et zgp-game-splash.sh, dont ce fichier reprend
# la structure quasi à l'identique) -- seule fonctionnalité qui dépend d'un service tiers
# (réseau + clé API), une panne de SteamGridDB ou l'absence de clé ne doit jamais bloquer
# l'activation du launcher, qui reste 100% autonome sans cette commande : l'absence de
# $GAMEDIR/splash/logo.png donne simplement l'absence de logo côté orchestrateur (aucune
# fenêtre zgu-launcher-logo.py n'est lancée dans ce cas, voir zgl-launcher-orchestrator.sh).
#
# Indépendant de l'état d'activation du launcher : $GAMEDIR/splash/ est créé ici si absent,
# que "lpm launcher ... on" ait déjà été lancé pour ce jeu ou non -- rien n'oblige à activer
# le launcher avant de choisir son logo, ni l'inverse.
#
# $1, $2... = slugs de jeux cibles en CLI, ou "--all" pour tous les jeux éligibles. Vide =>
# mode interactif Zenity, liste à cocher de tous les jeux installés, pré-cochant uniquement
# ceux qui n'ont pas encore de logo (voir zgp_logo_has_custom_logo plus bas -- simple présence
# de $GAMEDIR/splash/logo.png).
cli_targets=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-checklist-utils.sh
source "${script_dir}/zgu-checklist-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

will_use_zenity=true
[[ ${#cli_targets[@]} -gt 0 ]] && will_use_zenity=false

# Même principe que zgp-game-icon.sh/zgp-game-splash.sh : clé strictement personnelle, jamais
# partagée/embarquée dans lpm, réutilise le MÊME fichier de clé que "lpm icon"/"lpm splash" --
# un seul compte SteamGridDB suffit pour les trois commandes.
sgdb_key_file="${XDG_CONFIG_HOME:-${HOME}/.config}/lpm/steamgriddb.key"
sgdb_api="https://www.steamgriddb.com/api/v2"
sgdb_key=""

# --- 1. Vérification des dépendances ---
zgp_logo_report_error_early() {
  local msg="$1"
  if [[ "${will_use_zenity}" = true ]] && command -v zenity >/dev/null 2>&1; then
    zenity --error --text="${msg}" 2>/dev/null
  fi
  echo "${msg}" >&2
}

for cmd in sqlite3 curl python3 realpath; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgp_logo_report_error_early "$(t logo.cmd_missing "${cmd}")"
    exit 1
  fi
done

if [[ "${will_use_zenity}" = true ]] && ! command -v zenity >/dev/null 2>&1; then
  zgu_cli_error "$(t logo.zenity_missing)"
  exit 1
fi

# ImageMagick : toute image récupérée (png/jpeg/webp) est systématiquement repassée par
# "convert"/"magick" avant d'être posée en "logo.png" -- garantit un vrai PNG valide en
# sortie quel que soit le format d'origine, ET préserve la transparence (pas de fond ajouté,
# contrairement au recadrage carré de "lpm icon" : un logo doit rester détouré). "cairo.
# ImageSurface.create_from_png()" (zgu-launcher-logo.py) n'accepte QUE du PNG.
convert_bin=()
if command -v magick >/dev/null 2>&1; then
  convert_bin=(magick)
elif command -v convert >/dev/null 2>&1; then
  convert_bin=(convert)
else
  zgp_logo_report_error_early "$(t logo.imagemagick_missing)"
  exit 1
fi

if ! python3 -c "import sys" >/dev/null 2>&1; then
  zgp_logo_report_error_early "$(t logo.cmd_missing "python3")"
  exit 1
fi

# --- 2. Détection Flatpak vs Paquet natif + résolution des chemins Lutris ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"
games_dir="${HOME}/Games"

logo_display_mode="gui"
[[ "${will_use_zenity}" = false ]] && logo_display_mode="cli"
version=$(zgu_resolve_lutris_version "${logo_display_mode}" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgp_logo_report_error_early "$(t logo.lutris_missing)"
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_system_file="${lutris_flatpak_system_file}"
    ;;
  package)
    lutris_db="${lutris_package_db}"
    lutris_system_file="${lutris_package_system_file}"
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
  zgp_logo_report_error_early "$(t logo.db_missing "${lutris_db}")"
  exit 1
fi

# --- 3. Récupération des jeux Wine depuis la base Lutris ---
games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(name,'') || char(31) || COALESCE(slug,'') || char(31) || COALESCE(directory,'') FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgp_logo_report_error_early "$(t logo.none_found)"
  exit 0
fi

declare -A name_by_slug
declare -A dir_by_slug

# Jeux vivant dans un préfixe de store partagé (Epic Games Store, EA App, Ubisoft Connect...)
# : hors du principe un-jeu-un-préfixe de lpm, jamais proposés ici -- même filtre que
# zgp-game-icon.sh/zgp-game-splash.sh (voir zgu_get_blacklisted_slugs).
declare -A blacklisted_slugs
while IFS= read -r bl_slug; do
  [[ -n "${bl_slug}" ]] && blacklisted_slugs["${bl_slug}"]=1
done < <(zgu_get_blacklisted_slugs "${lutris_db}")

sorted_slugs=()

while IFS=$'\x1f' read -r g_name g_slug g_dir; do
  [[ -z "${g_slug}" ]] && continue
  [[ -n "${blacklisted_slugs[${g_slug}]:-}" ]] && continue
  [[ -z "${g_dir}" ]] && g_dir="${games_dir}/${g_slug}"

  name_by_slug["${g_slug}"]="${g_name}"
  dir_by_slug["${g_slug}"]="${g_dir}"
  sorted_slugs+=("${g_slug}")
done <<< "${games_list}"

if [[ ${#sorted_slugs[@]} -eq 0 ]]; then
  zgp_logo_report_error_early "$(t logo.none_found)"
  exit 0
fi

# Un logo compte comme "personnalisé" dès que $GAMEDIR/splash/logo.png existe -- ce fichier
# n'a jamais pu être posé que par l'utilisateur lui-même (à la main, ou via "lpm logo").
zgp_logo_has_custom_logo() {
  local f="${1}/splash/logo.png"
  [[ -f "${f}" ]]
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
        zgu_cli_error "$(t logo.slug_blacklisted "${target_slug}")"
        exit 1
      else
        zgu_cli_error "$(t logo.slug_not_found "${target_slug}")"
        exit 1
      fi
    done
  fi
else
  # --- MODE INTERACTIF (Zenity) ---
  # Précoche uniquement les jeux sans logo personnalisé -- voir
  # zgu_gui_checklist_with_states dans zgu-checklist-utils.sh pour la mécanique d'états
  # différenciés par ligne (même usage que zgp-game-icon.sh/zgp-game-splash.sh).
  checklist_values=()
  for g_slug in "${sorted_slugs[@]}"; do
    if zgp_logo_has_custom_logo "${dir_by_slug[${g_slug}]}"; then
      checklist_values+=("FALSE" "${name_by_slug[${g_slug}]}" "${g_slug}")
    else
      checklist_values+=("TRUE" "${name_by_slug[${g_slug}]}" "${g_slug}")
    fi
  done

  selected=$(zgu_gui_checklist_with_states 2 \
    "$(t logo.select_title)" \
    "$(t logo.select_text)" \
    650 450 \
    "$(t logo.select_col_fetch)" "$(t logo.select_col_game)" "$(t logo.select_col_slug)" \
    -- \
    "${checklist_values[@]}")

  [[ -z "${selected}" ]] && exit 0

  IFS=$'\x1f' read -r -a selected_flat <<< "${selected}"
  for (( i=1; i<${#selected_flat[@]}; i+=2 )); do
    targets+=("${selected_flat[i]}")
  done

  [[ ${#targets[@]} -eq 0 ]] && exit 0
fi

# --- 5. Clé API SteamGridDB (identique à zgp-game-icon.sh/zgp-game-splash.sh -- même
# fichier de clé, même logique de validation avant stockage) ---
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
      [[ "${first_try}" = false ]] && zenity --error --text="$(t logo.key_invalid)" 2>/dev/null
      command -v xdg-open >/dev/null 2>&1 && xdg-open "https://www.steamgriddb.com/profile/preferences/api" >/dev/null 2>&1 &
      candidate=$(zenity --entry --title="$(t logo.key_title)" --text="$(t logo.key_text)" --width=500 2>/dev/null)
    else
      [[ "${first_try}" = false ]] && t logo.key_invalid >&2
      t logo.key_text_cli
      read -r -p "$(t logo.key_prompt_cli)" candidate
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

# Sortie : une ligne par logo candidat, "url_pleine_resolution<TAB>url_vignette".
# Endpoint "/logos/..." (et pas "/heroes/..." ni "/grids/..." ni "/icons/...") : catégorie
# d'asset propre que SteamGridDB donne exactement à ce nom -- une image détourée/transparente
# du titre du jeu, pensée pour être superposée à une bannière ou un fond, par opposition aux
# "Heroes" (fond plein écran, déjà utilisées par "lpm splash") et aux "Icons" (déjà utilisées
# par "lpm icon"). "types=static" exclut les logos animés (webm) -- injouables tels quels par
# ImageMagick/Cairo. "mimes=image/png,image/webp" (pas de jpeg ici : un jpeg n'a jamais de
# canal alpha, donc jamais de vraie transparence -- un logo qui en dépend n'a aucun intérêt à
# être proposé dans ce format).
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

# --- Repli Steam (comme zgp-game-icon.sh -- même principe : chercher l'AppID via le nom, puis
# construire une URL de CDN Steam connue) ---
#
# Steam n'a pas d'équivalent exact du "Client Icon" utilisé par zgp-game-icon.sh, mais héberge
# de longue date un asset "logo.png" par jeu sur son CDN public (utilisé historiquement par la
# vue Bibliothèque de Steam pour superposer le titre à la bannière -- exactement le même usage
# que ce que "lpm logo" cherche à faire ici). Contrairement au Client Icon, cet asset n'est pas
# exposé par l'API SteamCMD sous forme de hash à assembler : on construit directement l'URL et
# on vérifie qu'elle répond, un simple "curl -f" suffit à détecter son absence (404).
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

zgp_steam_logo_url() {
  local appid="$1"
  printf 'https://cdn.cloudflare.steamstatic.com/steam/apps/%s/logo.png' "${appid}"
}

# --- 7. Traitement d'un jeu ---
#
# Retourne 0 si un logo a bien été posé, 1 sinon (jeu introuvable sur SteamGridDB et sur
# Steam, aucun logo disponible, téléchargement/conversion échoués, ou annulation par
# l'utilisateur en mode GUI) -- jamais de silence : chaque échec passe par
# zgp_logo_report_skip, affiché sur stderr en CLI et accumulé pour un résumé Zenity unique en
# fin de lot en GUI (même principe que zgp-game-icon.sh/zgp-game-splash.sh).
declare -a gui_skip_messages=()
zgp_logo_report_skip() {
  local msg="$1"
  echo "${msg}" >&2
  [[ "${will_use_zenity}" = true ]] && gui_skip_messages+=("${msg}")
}

zgp_logo_save_from_url() {
  local slug="$1" game_dir="$2" chosen_url="$3"

  mkdir -p "${game_dir}/splash"

  local ext="${chosen_url##*.}"
  ext="${ext,,}"
  local raw_file="${game_dir}/splash/.lpm-download.${ext}"

  if ! curl -sLf --max-time 30 "${chosen_url}" -o "${raw_file}" 2>/dev/null; then
    rm -f "${raw_file}"
    return 1
  fi

  # "-background none" au lieu d'une simple conversion sèche (contrairement à
  # zgp-game-splash.sh) : préserve la transparence d'origine du logo plutôt que de la
  # remplacer par un fond -- une bannière plein écran n'a pas ce souci (toujours opaque), un
  # logo si.
  if ! "${convert_bin[@]}" "${raw_file}" -background none "${game_dir}/splash/logo.png" 2>/dev/null; then
    rm -f "${raw_file}"
    return 1
  fi
  rm -f "${raw_file}"
  return 0
}

zgp_logo_process_one() {
  local slug="$1" g_name="$2" game_dir="$3"

  local search_results
  search_results=$(zgp_sgdb_search "${g_name}")

  local chosen_game_id="" chosen_game_name="" logos_urls=""

  if [[ -n "${search_results}" ]]; then
    local n_matches
    n_matches=$(printf '%s\n' "${search_results}" | grep -c .)

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
          --title="$(t logo.pick_game_title)" \
          --text="$(t logo.pick_game_text "${g_name}")" \
          --column="" --column="ID" --column="$(t logo.pick_game_col)" \
          --hide-column=2 --print-column=2 \
          "${zargs[@]}" --width=550 --height=420 2>/dev/null)
      else
        t logo.pick_game_text_cli "${g_name}"
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
        read -r -p "$(t logo.pick_game_prompt_cli)" choice
        chosen_game_id="${idx_to_id[${choice}]:-}"
        chosen_game_name="${idx_to_name[${choice}]:-}"
      fi

      if [[ -z "${chosen_game_id}" ]]; then
        zgp_logo_report_skip "$(t logo.cancelled_by_user "${g_name}")"
        return 1
      fi
    else
      chosen_game_id=$(printf '%s\n' "${search_results}" | head -n1 | cut -f1)
      chosen_game_name=$(printf '%s\n' "${search_results}" | head -n1 | cut -f2)
    fi

    local sr_gid sr_name
    while IFS=$'\t' read -r sr_gid sr_name; do
      if [[ "${sr_gid}" = "${chosen_game_id}" ]]; then
        chosen_game_name="${sr_name}"
        break
      fi
    done <<< "${search_results}"
    [[ -z "${chosen_game_name}" ]] && chosen_game_name="${g_name}"

    logos_urls=$(zgp_sgdb_logos "${chosen_game_id}")
  fi

  local chosen_url=""

  if [[ -n "${logos_urls}" ]]; then
    local n_logos
    n_logos=$(printf '%s\n' "${logos_urls}" | grep -c .)

    if [[ "${n_logos}" -gt 1 ]] && [[ "${will_use_zenity}" = true ]]; then
      # Sélection visuelle : même mécanique que zgp-game-icon.sh/zgp-game-splash.sh --
      # vignettes "thumb" légères, téléchargées en parallèle. Recadrage "-background none"
      # (transparence préservée dans l'aperçu aussi, pas de fond blanc/noir trompeur), format
      # large ("300x120") proche du ratio habituel d'un logo, sans forcer de crop carré comme
      # pour les icônes.
      local tmp_dir icon_urls_arr=() thumb_urls_arr=() thumb_paths=() u thumb_u ext raw_thumb padded_thumb i
      tmp_dir=$(mktemp -d)
      i=0
      while IFS=$'\t' read -r u thumb_u; do
        [[ -z "${u}" ]] && continue
        [[ -z "${thumb_u}" ]] && thumb_u="${u}"
        icon_urls_arr+=("${u}")
        thumb_urls_arr+=("${thumb_u}")
        i=$((i + 1))
      done <<< "${logos_urls}"

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

      for i in "${!thumb_urls_arr[@]}"; do
        ext="${thumb_urls_arr[${i}]##*.}"
        raw_thumb="${tmp_dir}/${i}.raw.${ext}"
        padded_thumb="${tmp_dir}/${i}.png"
        if [[ -s "${raw_thumb}" ]] && "${convert_bin[@]}" "${raw_thumb}" -background none -resize 300x120 -gravity center -extent 300x120 "${padded_thumb}" 2>/dev/null && [[ -s "${padded_thumb}" ]]; then
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
        --title="$(t logo.pick_logo_title)" \
        --text="$(t logo.pick_logo_text "${g_name}")" \
        --column="$(t logo.pick_logo_col_preview)" --column="$(t logo.pick_logo_col_num)" \
        --print-column=2 \
        "${imglist_args[@]}" --width=650 --height=450 2>/dev/null)

      rm -rf "${tmp_dir}"

      if [[ -z "${chosen_idx}" ]]; then
        zgp_logo_report_skip "$(t logo.cancelled_by_user "${g_name}")"
        return 1
      fi
      chosen_url="${icon_urls_arr[$((chosen_idx - 1))]}"
    else
      chosen_url=$(printf '%s\n' "${logos_urls}" | head -n1 | cut -f1)
    fi
  fi

  # --- Repli Steam : uniquement si SteamGridDB n'a rien donné (jeu introuvable, ou trouvé
  # mais sans logo publié) -- même logique de repli que zgp-game-icon.sh pour les Client
  # Icons. ---
  if [[ -z "${chosen_url}" ]]; then
    local steam_appid
    steam_appid=$(zgp_steam_find_appid "${g_name}")
    if [[ -n "${steam_appid}" ]]; then
      local steam_url
      steam_url=$(zgp_steam_logo_url "${steam_appid}")
      if curl -sLf --max-time 15 -o /dev/null "${steam_url}" 2>/dev/null; then
        chosen_url="${steam_url}"
      fi
    fi
  fi

  if [[ -z "${chosen_url}" ]]; then
    zgp_logo_report_skip "$(t logo.no_logo_available "${g_name}")"
    zgu_log "logo" "ERREUR" "slug=${slug} raison=aucun_logo_disponible"
    return 1
  fi

  if ! zgp_logo_save_from_url "${slug}" "${game_dir}" "${chosen_url}"; then
    zgp_logo_report_skip "$(t logo.download_failed "${g_name}")"
    zgu_log "logo" "ERREUR" "slug=${slug} raison=telechargement_ou_conversion_echoue"
    return 1
  fi

  zgu_log "logo" "OK" "slug=${slug} nom=${g_name}"
  [[ "${will_use_zenity}" = false ]] && t logo.done_cli "${g_name}"
  return 0
}

# --- 8. Exécution ---
zgp_sgdb_ensure_key || { zgp_logo_report_error_early "$(t logo.no_key_cancelled)"; exit 1; }

exit_code=0
for target_slug in "${targets[@]}"; do
  zgp_logo_process_one "${target_slug}" "${name_by_slug[${target_slug}]}" "${dir_by_slug[${target_slug}]}" || exit_code=1
done

if [[ "${will_use_zenity}" = true ]] && [[ ${#gui_skip_messages[@]} -gt 0 ]]; then
  errors_text=$(printf '%s\n' "${gui_skip_messages[@]}")
  zenity --error --title="$(t logo.errors_gui_title)" --width=550 \
    --text="$(t logo.errors_gui_intro)

${errors_text}" 2>/dev/null
elif [[ "${will_use_zenity}" = true ]]; then
  zenity --info --text="$(t logo.done_gui "${#targets[@]}")" 2>/dev/null
fi

exit "${exit_code}"
