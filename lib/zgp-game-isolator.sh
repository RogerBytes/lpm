#!/bin/bash

# --- lpm isolate ---
#
# Isole TOUT un store d'un coup : sépare chaque jeu vivant dans un giga-préfixe partagé
# (Epic Games Store, EA App/EA Desktop, Ubisoft Connect, Battle.net) en son propre wineprefix
# indépendant -- un jeu = un préfixe, pour chacun des jeux du store visé, jamais un seul jeu
# isolé en laissant les autres derrière. Distinction centrale utilisée dans tout ce fichier :
# le "socle" (launcher partagé -- binaires, config, credentials, session, identique et copié
# pour chaque instance) vs le "dossier du jeu" (sous-dossier propre à un jeu précis, inclus
# uniquement dans son instance, exclu de toutes les autres).
#
# --- Récupération des arguments du routeur lpm ---
# $1 = store à isoler entièrement (optionnel) : code interne (egs/ea/ubisoft/battlenet), alias
#      courant (ex. "epic", "blizzard"), ou slug d'un jeu actuellement détecté dans ce
#      giga-préfixe (juste pour retrouver le store à viser, tous les jeux de ce store seront
#      isolés, pas seulement celui nommé). Vide => mode interactif Zenity qui liste les STORES
#      actuellement détectés comme partagés (voir zgu_get_blacklisted_slugs), pas les jeux un
#      par un.
cli_store_arg="${1:-}"
cli_slug="${cli_store_arg}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-desktop-utils.sh
source "${script_dir}/zgu-desktop-utils.sh"
# shellcheck source=./zgu-progress-utils.sh
source "${script_dir}/zgu-progress-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

will_use_zenity=true
[[ -n "${cli_slug}" ]] && will_use_zenity=false

# Erreurs d'isolation accumulées pour un résumé Zenity affiché en fin d'exécution en mode
# GUI (voir zgp_isolate_report_error ci-dessous) -- sans ça, un échec pendant "lpm isolate"
# sans argument (mode Zenity) ne remontait auparavant que sur stderr, invisible pour
# l'utilisateur : aucune fenêtre d'erreur, aucune notification, juste "rien ne s'est passé".
declare -a gui_error_messages=()

# 1. Vérification des dépendances
for cmd in sqlite3 realpath; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgu_cli_error "$(t isolate.cmd_missing "${cmd}")"
    exit 1
  fi
done

if [[ "${will_use_zenity}" = true ]] && ! command -v zenity >/dev/null 2>&1; then
  zgu_cli_error "$(t isolate.zenity_missing)"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  zgu_cli_error "$(t isolate.cmd_missing "python3")"
  exit 1
fi
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  if [[ "${will_use_zenity}" = true ]]; then
    zgu_gui_error "$(t isolate.pyyaml_missing_gui)"
  fi
  zgu_cli_error "$(t isolate.pyyaml_missing_cli)"
  exit 1
fi

# 2. Fermeture préalable de Lutris pour libérer la BDD (même geste qu'install/uninstall/pack)
if flatpak list 2>/dev/null | grep -q lutris; then
  flatpak kill net.lutris.Lutris 2>/dev/null
fi
pkill -9 -x lutris 2>/dev/null
pkill -9 -f "/usr/bin/lutris" 2>/dev/null

# 3. Détection Flatpak vs paquet natif + résolution des chemins Lutris (voir
# zgu_get_default_runner ci-dessus pour la même logique de détection centralisée)
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"
lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"
games_dir="${HOME}/Games"

isolate_display_mode="gui"
[[ "${will_use_zenity}" = false ]] && isolate_display_mode="cli"
version=$(zgu_resolve_lutris_version "${isolate_display_mode}" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  if [[ "${will_use_zenity}" = true ]]; then
    zgu_gui_error "$(t isolate.lutris_missing_gui)"
  fi
  zgu_cli_error "$(t isolate.lutris_missing_cli)"
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_db="${lutris_flatpak_db}"
    lutris_system_file="${lutris_flatpak_system_file}"
    ;;
  package)
    lutris_config_dir="${lutris_package_config_dir}"
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
  if [[ "${will_use_zenity}" = true ]]; then
    zgu_gui_error "$(t isolate.db_missing "${lutris_db}")"
  fi
  zgu_cli_error "$(t isolate.db_missing "${lutris_db}")"
  exit 1
fi

mkdir -p "${lutris_config_dir}"
mkdir -p "${games_dir}"

real_games_dir=$(realpath -e "${games_dir}" 2>/dev/null)
if [[ -z "${real_games_dir}" ]]; then
  zgu_cli_error "$(t isolate.db_missing "${games_dir}")"
  exit 1
fi

# ---------------------------------------------------------------------------------------------
# --- Détection du store (Epic/EA/Ubisoft/Battle.net) pour un giga-préfixe donné ---
# Voir zgu_detect_isolation_store dans zgu-lutris-utils.sh (déjà sourcé plus haut) : partagée
# avec zgp-isolable-lister.sh ("lpm list-isolable") pour que les deux commandes s'accordent
# toujours sur le store détecté.

# Transforme un nom de jeu libre en identifiant de slug sûr (minuscules, [a-z0-9-] uniquement,
# tirets collapsés) -- utilisé uniquement pour le suffixe de renommage EA App (décision n°3 du
# document de spec : slug partagé "ea-app" entre le launcher et chaque jeu EA, donc renommé à
# l'isolation en "ea-app-<suffixe>" plutôt que ciblé par rowid).
zgp_slugify() {
  local s="$1"
  s="${s,,}"
  s=$(printf '%s' "${s}" | tr -c 'a-z0-9' '-')
  s=$(printf '%s' "${s}" | sed -E 's/-+/-/g; s/^-//; s/-$//')
  printf '%s' "${s}"
}

# Résout, pour un store et un giga-préfixe donnés, l'ensemble des chemins relatifs (à
# giga_dir) appartenant EN PROPRE au jeu ciblé -- jamais le socle, jamais les autres jeux.
# Écrit les chemins trouvés (un par ligne) sur stdout, ne fait aucune copie ni suppression.
# Retourne 1 si rien de spécifique au jeu n'a été trouvé (le jeu ne peut alors pas être isolé
# en toute sécurité : mieux vaut échouer proprement que de deviner un mauvais dossier).
#
# Repose sur un relevé empirique par store (motifs de dossiers observés pour chaque launcher) ;
# certains motifs (ex: Ubisoft "AppData/Roaming/<Variant>Air") n'ont pas de règle générique
# confirmée et sont donc volontairement omis plutôt que devinés.
zgp_resolve_game_paths() {
  local store="$1" giga_dir="$2" game_name="$3" old_args="$4"
  local found=0 p

  case "${store}" in
    egs)
      # Le dossier du jeu (MandatoryAppFolderName) se lit dans le manifeste .item dont
      # DisplayName correspond au nom du jeu -- pas de scan de dossier "à l'aveugle".
      local manifests_dir="${giga_dir}/drive_c/ProgramData/Epic/EpicGamesLauncher/Data/Manifests"
      local folder_name=""
      if [[ -d "${manifests_dir}" ]]; then
        folder_name=$(GAME_NAME="${game_name}" MANIFESTS_DIR="${manifests_dir}" python3 -c '
import json, os, glob
target = os.environ["GAME_NAME"].strip().lower()
for path in glob.glob(os.path.join(os.environ["MANIFESTS_DIR"], "*.item")):
    try:
        with open(path, "r", encoding="utf-8", errors="ignore") as f:
            data = json.load(f)
        if str(data.get("DisplayName", "")).strip().lower() == target:
            print(data.get("MandatoryAppFolderName", ""))
            break
    except Exception:
        continue
' 2>/dev/null)
      fi
      if [[ -n "${folder_name}" ]]; then
        p="drive_c/Program Files/Epic Games/${folder_name}"
        [[ -d "${giga_dir}/${p}" ]] && { echo "${p}"; found=1; }
      fi
      ;;

    ea)
      local candidate
      for candidate in \
        "drive_c/Program Files/EA Games/${game_name}" \
        "drive_c/ProgramData/EA Desktop/InstallData/${game_name}" \
        "drive_c/Program Files/Common Files/EAInstaller/${game_name}" \
        "drive_c/users/steamuser/Documents/Electronic Arts/${game_name}"; do
        if [[ -e "${giga_dir}/${candidate}" ]]; then
          echo "${candidate}"
          found=1
        fi
      done
      for candidate in \
        "drive_c/proton_shortcuts/${game_name}.desktop" \
        "drive_c/users/Public/Desktop/${game_name}.lnk"; do
        [[ -e "${giga_dir}/${candidate}" ]] && echo "${candidate}"
      done
      ;;

    ubisoft)
      p="drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/games/${game_name}"
      if [[ -d "${giga_dir}/${p}" ]]; then
        echo "${p}"
        found=1
      fi
      # L'ID numérique (dossier data/<ID>/) est le même identifiant que celui utilisé dans
      # l'argument de lancement "uplay://launch/<ID>", déjà présent dans les args existants
      # du jeu -- on le relit de là plutôt que de le deviner.
      local uid
      uid=$(printf '%s' "${old_args}" | grep -oE 'uplay://launch/[0-9]+' | head -n1 | grep -oE '[0-9]+$')
      if [[ -n "${uid}" ]]; then
        p="drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher/data/${uid}"
        [[ -d "${giga_dir}/${p}" ]] && { echo "${p}"; found=1; }
      fi
      for candidate in \
        "drive_c/proton_shortcuts/${game_name}.desktop" \
        "drive_c/users/${USER}/Desktop/${game_name}.url"; do
        [[ -e "${giga_dir}/${candidate}" ]] && echo "${candidate}"
      done
      ;;

    battlenet)
      # Un jeu = un dossier top-level sous "Program Files (x86)/", au même niveau que
      # "Battle.net/" (pas imbriqué dedans). "Battle.net" lui-même est explicitement
      # exclu (c'est le socle).
      p="drive_c/Program Files (x86)/${game_name}"
      if [[ -d "${giga_dir}/${p}" ]] && [[ "${game_name}" != "Battle.net" ]]; then
        echo "${p}"
        found=1
      fi
      ;;
  esac

  [[ "${found}" -eq 1 ]]
}

# Chemins "socle" (partagés, à dupliquer intégralement pour chaque jeu isolé) par store.
# Cas particulier Ubisoft : traité séparément dans zgp_copy_socle (le socle EST le dossier
# du launcher moins les sous-dossiers per-jeu "games/" et "data/", jamais une liste figée).
zgp_socle_paths() {
  local store="$1"
  case "${store}" in
    egs)
      echo "drive_c/Program Files/Epic Games/Launcher"
      echo "drive_c/Program Files/Epic Games/DirectXRedist"
      echo "drive_c/Program Files/Epic Games/GameInputRedist"
      echo "drive_c/users/${USER}/AppData/Local/EpicGamesLauncher"
      echo "drive_c/ProgramData/Epic/EpicGamesLauncher"
      ;;
    ea)
      echo "drive_c/Program Files/Electronic Arts/EA Desktop"
      echo "drive_c/users/steamuser/AppData/Roaming/Electronic Arts"
      echo "drive_c/users/steamuser/AppData/Local/Electronic Arts/EA Desktop/CEF"
      ;;
    battlenet)
      echo "drive_c/Program Files (x86)/Battle.net"
      echo "drive_c/ProgramData/Battle.net/Agent"
      echo "drive_c/ProgramData/Battle.net/Setup"
      echo "drive_c/ProgramData/Battle.net_components/battlenet_helpersvc"
      echo "drive_c/ProgramData/Blizzard Entertainment/Battle.net/Cache"
      echo "drive_c/users/${USER}/AppData/Roaming/Battle.net/Battle.net.config"
      ;;
  esac
}

# Copie une entrée (fichier ou dossier) de src_root/rel vers dst_root/rel, en préservant les
# attributs (cp -a) et en créant les dossiers parents nécessaires. Ne fait rien si la source
# est absente. Retourne 1 en cas d'échec de copie.
zgp_copy_rel_cli() {
  local src_root="$1" dst_root="$2" rel="$3"
  local src="${src_root}/${rel}" dst="${dst_root}/${rel}"
  [[ -e "${src}" ]] || return 0
  mkdir -p "$(dirname "${dst}")" || return 1
  cp -a -- "${src}" "${dst}"
}

# Équivalent GUI avec barre de progression Zenity réelle (voir zgu_gui_copy_tree dans
# zgu-progress-utils.sh, même mécanisme pv que l'extraction/compression des .zgp) pour les
# dossiers ; les fichiers isolés (raccourcis .desktop/.lnk/.url) sont copiés directement, une
# barre de progression n'apporte rien pour quelques kilo-octets.
zgp_copy_rel_gui() {
  local src_root="$1" dst_root="$2" rel="$3" zen_title="$4" zen_text="$5"
  local src="${src_root}/${rel}" dst="${dst_root}/${rel}"
  [[ -e "${src}" ]] || return 0
  mkdir -p "$(dirname "${dst}")" || return 1
  if [[ -d "${src}" ]]; then
    zgu_gui_copy_tree "${src}" "${dst}" "${zen_title}" "${zen_text}"
    return $?
  fi
  cp -a -- "${src}" "${dst}"
}

# ---------------------------------------------------------------------------------------------
# --- Construction de la liste des jeux blacklistés candidats (avec store détecté) ---
declare -A bl_name_by_slug
declare -A bl_dir_by_slug
sorted_bl_slugs=()

while IFS=$'\x1f' read -r b_slug b_name b_dir; do
  [[ -z "${b_slug}" ]] && continue
  bl_name_by_slug["${b_slug}"]="${b_name}"
  bl_dir_by_slug["${b_slug}"]="${b_dir}"
  sorted_bl_slugs+=("${b_slug}")
done < <(
  while IFS= read -r bl; do
    [[ -z "${bl}" ]] && continue
    safe_bl="${bl//\'/\'\'}"
    sqlite3 "${lutris_db}" "SELECT slug || char(31) || name || char(31) || directory FROM games WHERE runner='wine' AND slug='${safe_bl}' LIMIT 1;" 2>/dev/null
  done < <(zgu_get_blacklisted_slugs "${lutris_db}")
)

# ---------------------------------------------------------------------------------------------
# --- Regroupement des jeux blacklistés par store détecté ---
# "lpm isolate" opère par STORE, jamais par jeu isolé : tous les jeux actuellement vivants dans
# le giga-préfixe d'un même store sont isolés en une seule passe, chacun recevant son propre
# préfixe indépendant (s'il y a 200 jeux dans le store visé, 200 préfixes sont créés). Un
# store peut en théorie être réparti sur plusieurs giga-préfixes (dossier "directory" distinct
# en base) -- on les fusionne tous sous le même code de store ici, pour que "isoler le store X"
# couvre bien tous les jeux X, quel que soit le dossier où ils vivent.
declare -A store_slugs      # code de store -> slugs concernés, séparés par des espaces
declare -A dir_store_cache  # giga_dir résolu -> code de store (mémoïsation par dossier)

for b_slug in "${sorted_bl_slugs[@]}"; do
  b_dir="${bl_dir_by_slug[${b_slug}]}"
  real_b_dir=$(realpath -e "${b_dir}" 2>/dev/null)
  [[ -z "${real_b_dir}" ]] && continue

  if [[ -z "${dir_store_cache[${real_b_dir}]+x}" ]]; then
    dir_store_cache["${real_b_dir}"]=$(zgu_detect_isolation_store "${lutris_db}" "${real_b_dir}")
  fi
  b_store="${dir_store_cache[${real_b_dir}]}"
  [[ -z "${b_store}" ]] && continue

  # Le launcher lui-même (voir zgu_is_store_launcher_name) n'est jamais un jeu à isoler :
  # il est déjà dupliqué dans le préfixe de chaque jeu isolé du store -- l'exclure ici,
  # avant même la moindre tentative, plutôt que de le laisser échouer à chaque exécution.
  zgu_is_store_launcher_name "${b_store}" "${bl_name_by_slug[${b_slug}]}" && continue

  store_slugs["${b_store}"]+="${b_slug} "
done

# Traduit un argument utilisateur (code de store, alias courant, ou slug d'un jeu isolable) en
# code de store interne (egs/ea/ubisoft/battlenet). N'affiche rien, retourne 1 si rien ne
# correspond -- laisse l'appelant décider du message d'erreur.
zgp_resolve_store_arg() {
  local raw="$1" arg
  arg="${raw,,}"
  case "${arg}" in
    egs|epic|epicgames|epic-games|"epic games"|"epic games store")
      echo "egs"; return 0 ;;
    ea|eaapp|ea-app|eadesktop|ea-desktop|"ea app"|"ea desktop")
      echo "ea"; return 0 ;;
    ubisoft|uplay|ubisoftconnect|ubisoft-connect|"ubisoft connect")
      echo "ubisoft"; return 0 ;;
    battlenet|battle.net|"battle net"|blizzard)
      echo "battlenet"; return 0 ;;
  esac

  # Sinon : peut-être le slug d'un jeu actuellement isolable -- on réutilise le store déjà
  # résolu ci-dessus pour son dossier plutôt que de le redétecter une seconde fois.
  local slug_dir real_slug_dir slug_store
  slug_dir="${bl_dir_by_slug[${raw}]:-}"
  [[ -z "${slug_dir}" ]] && return 1
  real_slug_dir=$(realpath -e "${slug_dir}" 2>/dev/null)
  [[ -z "${real_slug_dir}" ]] && return 1
  slug_store="${dir_store_cache[${real_slug_dir}]:-}"
  [[ -z "${slug_store}" ]] && return 1
  echo "${slug_store}"
}

# ---------------------------------------------------------------------------------------------
# --- Sélection du store à isoler entièrement ---
target_store=""

if [[ -n "${cli_store_arg}" ]]; then
  target_store=$(zgp_resolve_store_arg "${cli_store_arg}")
  if [[ -z "${target_store}" ]] || [[ -z "${store_slugs[${target_store}]:-}" ]]; then
    zgu_cli_error "$(t isolate.store_arg_invalid "${cli_store_arg}")"
    exit 1
  fi
else
  if [[ ${#store_slugs[@]} -eq 0 ]]; then
    zenity --info --text="$(t isolate.none_found)" 2>/dev/null
    exit 0
  fi

  sorted_stores=($(printf '%s\n' "${!store_slugs[@]}" | sort))
  zenity_args=()
  for s_code in "${sorted_stores[@]}"; do
    s_count=$(wc -w <<< "${store_slugs[${s_code}]}")
    zenity_args+=("FALSE" "$(zgu_store_display_name "${s_code}")" "${s_count}")
  done

  # Sélection UNIQUE (radiolist) : on isole un store entier à la fois, jamais une sélection de
  # jeux au cas par cas -- colonne "print" = nom affiché (2e colonne), retraduit vers le code
  # interne juste après via zgu_store_display_name.
  selected_label=$(zenity --list --radiolist \
    --title="$(t isolate.select_title)" \
    --text="$(t isolate.select_text)" \
    --column="$(t isolate.select_col_isolate)" --column="$(t isolate.select_col_store)" --column="$(t isolate.select_col_count)" \
    "${zenity_args[@]}" \
    --width=550 --height=350 2>/dev/null)

  [[ -z "${selected_label}" ]] && exit 0

  for s_code in "${sorted_stores[@]}"; do
    if [[ "$(zgu_store_display_name "${s_code}")" = "${selected_label}" ]]; then
      target_store="${s_code}"
      break
    fi
  done
fi

if [[ -z "${target_store}" ]] || [[ -z "${store_slugs[${target_store}]:-}" ]]; then
  [[ "${will_use_zenity}" = true ]] && zenity --info --text="$(t isolate.none_found)" 2>/dev/null
  zgu_cli_error "$(t isolate.none_found)"
  exit 0
fi

slugs_to_isolate=(${store_slugs[${target_store}]})

# ---------------------------------------------------------------------------------------------
# --- Confirmation ---
if [[ "${will_use_zenity}" = false ]]; then
  t isolate.confirm_cli_store "$(zgu_store_display_name "${target_store}")" "${#slugs_to_isolate[@]}"
  for s in "${slugs_to_isolate[@]}"; do
    t isolate.confirm_cli_item "${bl_name_by_slug[${s}]}" "${s}"
  done
  read -r -p "$(t isolate.confirm_cli_prompt)" response
  case "${response}" in
    [nN]) t isolate.cancelled_cli; exit 0 ;;
    *) ;;
  esac
fi

# Signale l'échec d'isolation d'un jeu donné : toujours affiché sur stderr (visible en mode
# CLI), et en plus accumulé dans gui_error_messages en mode GUI pour un résumé Zenity montré
# une fois la boucle terminée -- voir la déclaration de gui_error_messages plus haut pour le
# problème que ça corrige (échec auparavant totalement invisible en mode Zenity).
zgp_isolate_report_error() {
  local msg="$1"
  echo "${msg}" >&2
  [[ "${will_use_zenity}" = true ]] && gui_error_messages+=("${msg}")
}

# ---------------------------------------------------------------------------------------------
# --- Isolation d'un jeu ---
#
# Retourne 0 en cas de succès, 1 sinon. Les erreurs passent par zgp_isolate_report_error
# ci-dessus (stderr en CLI, résumé Zenity en fin d'exécution en GUI) ; la progression normale
# (copie en cours, etc.) reste gérée séparément par l'appelant/zgu_gui_copy_tree.
zgp_isolate_one() {
  local slug="$1"
  local giga_dir="${bl_dir_by_slug[${slug}]}"
  local game_name="${bl_name_by_slug[${slug}]}"
  local safe_slug="${slug//\'/\'\'}"

  # Sécurité : le giga_dir vient de la base Lutris, potentiellement éditée à la main ou
  # provenant d'un jeu ajouté hors lpm -- même garde que resolve_prefix_dir_by_slug
  # (zgp-game-packer.sh) et safe_delete_prefix_dir (zgp-game-uninstaller.sh) : le chemin réel
  # doit rester un sous-dossier de games_dir.
  local real_giga_dir
  real_giga_dir=$(realpath -e "${giga_dir}" 2>/dev/null)
  if [[ -z "${real_giga_dir}" ]] || [[ "${real_giga_dir}" != "${real_games_dir}/"* ]]; then
    zgp_isolate_report_error "$(t isolate.game_paths_not_found "${game_name}")"
    zgu_log "isolate" "ERREUR" "slug=${slug} raison=giga_prefixe_invalide"
    return 1
  fi
  giga_dir="${real_giga_dir}"

  local store
  store=$(zgu_detect_isolation_store "${lutris_db}" "${giga_dir}")
  if [[ -z "${store}" ]]; then
    zgp_isolate_report_error "$(t isolate.store_unknown "${game_name}")"
    zgu_log "isolate" "ERREUR" "slug=${slug} raison=store_inconnu"
    return 1
  fi

  # Ligne existante complète (id, executable, configpath, installer_slug) -- un
  # UPDATE simple ne suffit pas pour le cas EA App (slug partagé "ea-app" entre le
  # launcher et chaque jeu, voir décision n°3 du document de spec) : cibler par "id"
  # plutôt que par "slug" pour le DELETE ci-dessous évite de toucher la ligne du
  # launcher partagé dans tous les cas, pas seulement pour EA.
  local old_row old_id old_executable old_configpath old_installer_slug
  old_row=$(sqlite3 "${lutris_db}" "SELECT COALESCE(id,'') || char(31) || COALESCE(executable,'') || char(31) || COALESCE(configpath,'') || char(31) || COALESCE(installer_slug,'') FROM games WHERE slug='${safe_slug}' AND directory='${giga_dir//\'/\'\'}' LIMIT 1;" 2>/dev/null)
  IFS=$'\x1f' read -r old_id old_executable old_configpath old_installer_slug <<< "${old_row}"
  # Sécurité : "id" vient lui aussi de la base Lutris, potentiellement éditée à la main
  # (même méfiance que pour "directory"/"configpath" ci-dessous). Contrairement à ces
  # deux-là, il n'était jusqu'ici interpolé nulle part avec échappement -- il est utilisé
  # sans guillemets dans un "DELETE ... WHERE id=${old_id}" plus bas (id est numérique,
  # jamais mis entre quotes). Sans cette validation, un id corrompu en base contenant du
  # SQL (ex: "1); DROP TABLE games; --") s'y injecterait directement.
  if [[ -z "${old_id}" ]] || [[ ! "${old_id}" =~ ^[0-9]+$ ]]; then
    zgp_isolate_report_error "$(t isolate.game_paths_not_found "${game_name}")"
    zgu_log "isolate" "ERREUR" "slug=${slug} raison=id_base_invalide"
    return 1
  fi

  # Sécurité : configpath vient de la base Lutris, potentiellement éditée à la main (même
  # méfiance que pour "directory" plus haut). Contrairement à "directory", ce n'est pas un
  # chemin absolu mais un simple identifiant sans composant de dossier (toujours généré ici
  # et à l'installation sous la forme "<slug>-<timestamp>", voir new_config_id ci-dessous et
  # config_id dans zgp-game-installer.sh) : on rejette donc tout ce qui contiendrait un "/"
  # avant de bâtir un chemin avec, pour empêcher un configpath du type "../../etc/cron.d/x"
  # de faire sortir old_yml -- et surtout le "rm -f" final -- de lutris_config_dir.
  if [[ -z "${old_configpath}" ]] || [[ "${old_configpath}" == *"/"* ]]; then
    zgp_isolate_report_error "$(t isolate.configpath_invalid "${game_name}")"
    zgu_log "isolate" "ERREUR" "slug=${slug} raison=configpath_invalide"
    return 1
  fi

  # Args de lancement (protocole propriétaire) lus depuis le YAML déjà en place -- jamais
  # reconstruits à la main (constat transversal à tous les stores gérés ici : le jeu est
  # toujours lancé via le launcher partagé + un identifiant de jeu en paramètre).
  local old_yml="${lutris_config_dir}/${old_configpath}.yml"
  local old_args=""
  if [[ -f "${old_yml}" ]]; then
    old_args=$(YML_PATH="${old_yml}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        print(data.get("game", {}).get("args", ""))
except Exception:
    pass
' 2>/dev/null)
  fi

  # Résolution des chemins propres au jeu (jamais le socle, jamais un autre jeu du même
  # giga-préfixe) : échec net plutôt que de deviner si rien n'est trouvé.
  local game_rel_paths=()
  local rp
  while IFS= read -r rp; do
    [[ -n "${rp}" ]] && game_rel_paths+=("${rp}")
  done < <(zgp_resolve_game_paths "${store}" "${giga_dir}" "${game_name}" "${old_args}")

  if [[ ${#game_rel_paths[@]} -eq 0 ]]; then
    zgp_isolate_report_error "$(t isolate.game_paths_not_found "${game_name}")"
    zgu_log "isolate" "ERREUR" "slug=${slug} store=${store} raison=chemins_jeu_introuvables"
    return 1
  fi

  # Slug du jeu isolé : renommé uniquement pour EA App (slug partagé "ea-app" entre le
  # launcher et chaque jeu -- voir décision n°3 du document de spec), inchangé pour les 3
  # autres stores (slug déjà unique par jeu, confirmé via pga.db).
  local new_slug="${slug}"
  if [[ "${store}" = "ea" ]]; then
    local suffix
    suffix=$(zgp_slugify "${game_name}")
    new_slug="${slug}-${suffix}"
    local n=2
    while [[ -d "${games_dir}/${new_slug}" ]] || [[ -n "$(sqlite3 "${lutris_db}" "SELECT 1 FROM games WHERE slug='${new_slug//\'/\'\'}' LIMIT 1;" 2>/dev/null)" ]]; do
      new_slug="${slug}-${suffix}-${n}"
      n=$((n + 1))
    done
  fi

  local new_prefix_dir="${games_dir}/${new_slug}"
  if [[ -e "${new_prefix_dir}" ]]; then
    zgp_isolate_report_error "$(t isolate.already_exists "${game_name}" "${new_prefix_dir}")"
    zgu_log "isolate" "ERREUR" "slug=${slug} store=${store} raison=prefixe_cible_deja_existant"
    return 1
  fi

  mkdir -p "${new_prefix_dir}" || {
    zgp_isolate_report_error "$(t isolate.mkdir_failed "${game_name}" "${new_prefix_dir}")"
    zgu_log "isolate" "ERREUR" "slug=${slug} store=${store} raison=mkdir_echoue"
    return 1
  }

  local zen_title="" zen_text=""
  [[ "${will_use_zenity}" = true ]] && zen_title="$(t isolate.copying_base_gui_title "${game_name}")"

  # Préfixe "N/Total : nom -- " ajouté devant le texte de la fenêtre PARTAGÉE quand plusieurs
  # jeux d'un même store sont isolés en une seule passe (voir isolate_using_batch, réglé plus
  # bas dans ce fichier avant la boucle "Exécution") -- même mécanisme que
  # zgp-game-installer.sh, pour éviter qu'un store de 200 jeux ouvre et referme une fenêtre
  # (et envoie une notification desktop) par jeu.
  zgp_isolate_batch_text() {
    local base_text="$1"
    if [[ "${isolate_using_batch:-false}" = true ]]; then
      t isolate.batch_progress_item "${isolate_idx}" "${isolate_total}" "${game_name}" "${base_text}"
    else
      echo "${base_text}"
    fi
  }

  # --- 1. Copie du socle (launcher, credentials, session) ---
  if [[ "${store}" = "ubisoft" ]]; then
    # Cas particulier : le socle EST "Ubisoft Game Launcher/" moins les sous-dossiers
    # per-jeu "games/" et "data/" (traités comme dossier du jeu ci-dessous).
    local ubi_root="drive_c/Program Files (x86)/Ubisoft/Ubisoft Game Launcher"
    local entry entry_rel
    while IFS= read -r entry; do
      entry_rel="${ubi_root}/$(basename "${entry}")"
      if [[ "${will_use_zenity}" = true ]]; then
        zen_text="$(zgp_isolate_batch_text "$(t isolate.copying_base_gui_text)")"
        zgp_copy_rel_gui "${giga_dir}" "${new_prefix_dir}" "${entry_rel}" "${zen_title}" "${zen_text}"
      else
        t isolate.copying_base_cli "${game_name}"
        zgp_copy_rel_cli "${giga_dir}" "${new_prefix_dir}" "${entry_rel}"
      fi || {
        copy_exit=$?
        if [[ "${copy_exit}" -eq 2 ]]; then
          rm -rf "${new_prefix_dir}"
          return 2
        fi
        zgp_isolate_report_error "$(t isolate.copy_failed "${game_name}")"
        zgu_log "isolate" "ERREUR" "slug=${slug} store=${store} raison=copie_echouee"
        rm -rf "${new_prefix_dir}"
        return 1
      }
    done < <(find "${giga_dir}/${ubi_root}" -mindepth 1 -maxdepth 1 ! -name games ! -name data 2>/dev/null)
  else
    local socle_rel
    while IFS= read -r socle_rel; do
      [[ -z "${socle_rel}" ]] && continue
      if [[ "${will_use_zenity}" = true ]]; then
        zen_text="$(zgp_isolate_batch_text "$(t isolate.copying_base_gui_text)")"
        zgp_copy_rel_gui "${giga_dir}" "${new_prefix_dir}" "${socle_rel}" "${zen_title}" "${zen_text}"
      else
        t isolate.copying_base_cli "${game_name}"
        zgp_copy_rel_cli "${giga_dir}" "${new_prefix_dir}" "${socle_rel}"
      fi || {
        copy_exit=$?
        if [[ "${copy_exit}" -eq 2 ]]; then
          rm -rf "${new_prefix_dir}"
          return 2
        fi
        zgp_isolate_report_error "$(t isolate.copy_failed "${game_name}")"
        zgu_log "isolate" "ERREUR" "slug=${slug} store=${store} raison=copie_echouee"
        rm -rf "${new_prefix_dir}"
        return 1
      }
    done < <(zgp_socle_paths "${store}")
  fi

  # --- 2. Copie du dossier du jeu (uniquement celui-ci, jamais les autres jeux) ---
  for rp in "${game_rel_paths[@]}"; do
    if [[ "${will_use_zenity}" = true ]]; then
      zen_text="$(zgp_isolate_batch_text "$(t isolate.copying_game_gui_text)")"
      zgp_copy_rel_gui "${giga_dir}" "${new_prefix_dir}" "${rp}" "${zen_title}" "${zen_text}"
    else
      t isolate.copying_game_cli "${game_name}"
      zgp_copy_rel_cli "${giga_dir}" "${new_prefix_dir}" "${rp}"
    fi || {
      copy_exit=$?
      if [[ "${copy_exit}" -eq 2 ]]; then
        rm -rf "${new_prefix_dir}"
        return 2
      fi
      zgp_isolate_report_error "$(t isolate.copy_failed "${game_name}")"
      zgu_log "isolate" "ERREUR" "slug=${slug} store=${store} raison=copie_echouee"
      rm -rf "${new_prefix_dir}"
      return 1
    }
  done

  mkdir -p "${new_prefix_dir}/dosdevices"
  ln -sf "../drive_c" "${new_prefix_dir}/dosdevices/c:"
  [[ ! -e "${new_prefix_dir}/pfx" ]] && ln -sf "." "${new_prefix_dir}/pfx"

  # --- 3. Clonage du YAML Lutris : mêmes clés que l'original (game.args notamment, qui
  # porte l'identifiant de jeu propriétaire -- AppName/offerIds/ID/code produit -- inchangé
  # par l'isolation, seul le chemin de préfixe change), chemins substitués giga_dir -> nouveau
  # prefix. Même filtre anti-hooks qu'à l'installation (zgp-game-installer.sh) : un YAML
  # d'origine potentiellement édité à la main ne doit pas pouvoir embarquer une commande
  # exécutée automatiquement par Lutris.
  [[ "${will_use_zenity}" = false ]] && t isolate.registering
  local timestamp new_config_id new_yml new_executable=""
  timestamp=$(date +%s%N)
  new_config_id="${new_slug}-${timestamp}"
  new_yml="${lutris_config_dir}/${new_config_id}.yml"

  if [[ -f "${old_yml}" ]]; then
    OLD_YML="${old_yml}" NEW_YML="${new_yml}" OLD_PREFIX="${giga_dir}" NEW_PREFIX="${new_prefix_dir}" python3 -c '
import os, yaml, re

old_prefix = os.environ["OLD_PREFIX"]
new_prefix = os.environ["NEW_PREFIX"]
prefix_pattern = re.escape(old_prefix)

def swap_prefix(obj):
    if isinstance(obj, dict):
        return {k: swap_prefix(v) for k, v in obj.items()}
    elif isinstance(obj, list):
        return [swap_prefix(v) for v in obj]
    elif isinstance(obj, str):
        return re.sub(prefix_pattern + r"(?=/|$)", new_prefix, obj)
    return obj

def strip_exec_hooks(obj):
    if isinstance(obj, dict):
        cleaned = {}
        for k, v in obj.items():
            kl = k.lower() if isinstance(k, str) else ""
            if kl.endswith("_command") or kl.endswith("_script") or kl.endswith("_wait") or "exec" in kl:
                continue
            cleaned[k] = strip_exec_hooks(v)
        return cleaned
    elif isinstance(obj, list):
        return [strip_exec_hooks(v) for v in obj]
    return obj

try:
    with open(os.environ["OLD_YML"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        data.pop("script", None)
        data.pop("version", None)
        data = swap_prefix(data)
        data = strip_exec_hooks(data)
        if "game" not in data or not isinstance(data["game"], dict):
            data["game"] = {}
        data["game"]["prefix"] = new_prefix
        with open(os.environ["NEW_YML"], "w") as f:
            yaml.dump(data, f, sort_keys=False)
except Exception:
    pass
' 2>/dev/null

    if [[ -f "${new_yml}" ]]; then
      new_executable=$(YML_PATH="${new_yml}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        print(data.get("game", {}).get("exe", ""))
except Exception:
    pass
' 2>/dev/null)
    fi
  fi

  # Repli si le YAML d'origine était absent/illisible ou n'a donné aucun exe : substitution
  # directe de préfixe sur le chemin déjà connu en base (old_executable), même logique.
  if [[ -z "${new_executable}" ]]; then
    new_executable="${old_executable/${giga_dir}/${new_prefix_dir}}"
  fi
  [[ "${new_executable}" != /* ]] && new_executable="${new_prefix_dir}/${new_executable}"

  local safe_name="${game_name//\'/\'\'}"
  local safe_new_slug="${new_slug//\'/\'\'}"
  local safe_new_config_id="${new_config_id//\'/\'\'}"
  local safe_prefix_dir="${new_prefix_dir//\'/\'\'}"
  local safe_executable="${new_executable//\'/\'\'}"
  local safe_installer_slug="${old_installer_slug//\'/\'\'}"

  # DELETE par id (jamais par slug) : le slug peut être partagé par plusieurs lignes (cas
  # EA App confirmé, voir décision n°3 du document de spec) -- cibler par id, valeur fraîche
  # relue juste au-dessus dans la même exécution, retire précisément la ligne du jeu isolé
  # sans jamais risquer de supprimer la ligne du launcher partagé, quel que soit le store.
  sqlite3 "${lutris_db}" "DELETE FROM games WHERE id=${old_id};"
  sqlite3 "${lutris_db}" <<EOF
INSERT INTO games (name, slug, installer_slug, parent_slug, runner, executable, directory, configpath, updated, installed, installed_at)
VALUES (
  '${safe_name}',
  '${safe_new_slug}',
  '${safe_installer_slug:-${safe_new_slug}}',
  '',
  'wine',
  '${safe_executable}',
  '${safe_prefix_dir}',
  '${safe_new_config_id}',
  strftime('%s','now'),
  1,
  strftime('%s','now')
);
EOF

  # --- 4. Purge des seuls dossiers propres au jeu dans le giga-préfixe d'origine (jamais le
  # socle, qui reste partagé par les jeux qui y vivent encore -- décision n°5 du document de
  # spec) : réalisée seulement après confirmation que la copie a bien produit un préfixe non
  # vide, pour ne jamais perdre les fichiers du jeu si la copie a échoué à mi-chemin.
  if [[ -n "$(find "${new_prefix_dir}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
    [[ "${will_use_zenity}" = false ]] && t isolate.purging
    for rp in "${game_rel_paths[@]}"; do
      local src="${giga_dir}/${rp}" real_src
      real_src=$(realpath -e "${src}" 2>/dev/null)
      if [[ -n "${real_src}" ]] && [[ "${real_src}" == "${giga_dir}/"* ]]; then
        rm -rf "${real_src}"
      fi
    done
  fi

  rm -f "${lutris_config_dir}/${old_configpath}.yml" 2>/dev/null

  zgu_log "isolate" "OK" "slug=${slug} nouveau_slug=${new_slug} store=${store} nom=${game_name}"
  if [[ "${will_use_zenity}" = true ]]; then
    # En mode lot (plusieurs jeux du même store), pas de notification desktop individuelle
    # par jeu -- un store de 200 jeux en enverrait 200 d'affilée. Un seul résumé final est
    # envoyé après la boucle "Exécution" plus bas dans ce fichier.
    if [[ "${isolate_using_batch:-false}" = false ]]; then
      notify-send "$(t isolate.notify_title)" "$(t isolate.notify_body "${game_name}")" 2>/dev/null
    fi
  else
    zgu_cli_ok "$(t isolate.done_cli "${game_name}")"
  fi
  return 0
}

# ---------------------------------------------------------------------------------------------
# --- Exécution ---

# Fenêtre de progression PARTAGÉE (voir zgu_batch_progress_open dans zgu-progress-utils.sh),
# même principe que zgp-game-installer.sh : "lpm isolate" traite TOUS les jeux d'un même store
# en une seule passe (potentiellement 100+ jeux), et chacun ouvrait/refermait sa propre fenêtre
# (une par étape de copie) sans ça -- en plus d'envoyer une notification desktop par jeu.
isolate_total=${#slugs_to_isolate[@]}
isolate_using_batch=false
if [[ "${will_use_zenity}" = true ]] && [[ "${isolate_total}" -gt 1 ]]; then
  isolate_using_batch=true
  zgu_batch_progress_open "$(t isolate.batch_progress_title "${isolate_total}")"
fi

exit_code=0
isolate_idx=0
isolate_success_count=0
isolate_cancelled=false
for target_slug in "${slugs_to_isolate[@]}"; do
  isolate_idx=$((isolate_idx + 1))
  zgp_isolate_one "${target_slug}"
  isolate_one_status=$?
  if [[ "${isolate_one_status}" -eq 0 ]]; then
    isolate_success_count=$((isolate_success_count + 1))
  elif [[ "${isolate_one_status}" -eq 2 ]]; then
    # Annulé par l'utilisateur dans la fenêtre partagée : on arrête tout le lot ici, plutôt
    # que de continuer (et d'accumuler une "erreur de copie" pour chacun des jeux restants,
    # qui n'ont jamais été tentés).
    isolate_cancelled=true
    exit_code=1
    break
  else
    exit_code=1
  fi
done

[[ "${isolate_using_batch}" = true ]] && zgu_batch_progress_close

if [[ "${will_use_zenity}" = true ]]; then
  if [[ "${isolate_cancelled}" = true ]]; then
    zenity --info --title="$(t isolate.cancel_title)" --text="$(t isolate.cancel_text "${isolate_success_count}" "${isolate_total}")" 2>/dev/null
  elif [[ "${isolate_using_batch}" = true ]]; then
    # Résumé final reflétant le résultat RÉEL (même principe que zgp-game-installer.sh).
    if [[ "${isolate_success_count}" -eq "${isolate_total}" ]] && [[ "${isolate_total}" -gt 0 ]]; then
      notify-send "$(t isolate.notify_title)" "$(t isolate.notify_body_batch "${isolate_success_count}")" 2>/dev/null
    elif [[ "${isolate_success_count}" -eq 0 ]]; then
      notify-send "$(t isolate.notify_title_none)" "$(t isolate.notify_body_none)" 2>/dev/null
    else
      notify-send "$(t isolate.notify_title_partial)" "$(t isolate.notify_body_partial "${isolate_success_count}" "${isolate_total}")" 2>/dev/null
    fi
  fi
fi

# Résumé Zenity des échecs éventuels (mode GUI uniquement) : voir la déclaration de
# gui_error_messages plus haut. Affiché une seule fois après toute la boucle (plutôt qu'un
# dialogue par jeu en échec) pour ne pas empiler les fenêtres si plusieurs jeux d'un même
# store échouent -- les succès restent, eux, notifiés individuellement (notify-send) au fil
# de la boucle, comme avant.
if [[ "${will_use_zenity}" = true ]] && [[ ${#gui_error_messages[@]} -gt 0 ]]; then
  errors_text=$(printf '%s\n' "${gui_error_messages[@]}")
  zenity --error --title="$(t isolate.errors_gui_title)" --width=550 \
    --text="$(t isolate.errors_gui_intro)

${errors_text}" 2>/dev/null
fi

exit "${exit_code}"
