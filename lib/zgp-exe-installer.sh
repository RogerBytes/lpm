#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-focus-utils.sh
source "${script_dir}/zgu-focus-utils.sh"

# --- lpm exe-install : créer un prefix (comme "prefix vierge") puis lancer un
# installateur Windows (.exe/.msi/.bat/.cmd) DEDANS, en conditions réelles (fenêtre
# visible, attente de la fermeture), exactement comme l'assistant "Installer un
# exécutable Windows" de Lutris (vérifié dans son code source) :
#   - initialisation du prefix identique à "prefix vierge" (wineboot / umu-run
#     createprefix, attente des .reg)
#   - puis lancement du fichier choisi via "wine <fichier>" (runner classique) ou
#     "umu-run <fichier>" (Proton) au premier plan, sans rediriger stdout/stderr :
#     Wine associe nativement .msi -> msiexec et .bat/.cmd -> cmd.exe, donc appeler
#     directement le fichier suffit quel que soit son type (même logique que Lutris,
#     qui appelle simplement "wine %s" sans distinguer l'extension)
#   - code de sortie non-zéro -> proposition de tout supprimer (même geste que la
#     case "Supprimer les fichiers du jeu" de Lutris sur annulation/échec, vérifié
#     dans lutris/gui/installerwindow.py)
#   - code de sortie 0 -> sélection optionnelle du .exe final du jeu installé
#     (sélecteur de fichier ouvert dans le prefix), puis écriture yml + pga.db
#
# $1 = mode ("cli" = commande terminal explicite, vide/absent = menu interactif Zenity)
# $2 = confirm_flag ("yes" si -y -- ne s'applique qu'à la confirmation de lancement,
#      jamais à la proposition de suppression en cas d'échec, qui est toujours posée)
# $3 = cible CLI ("chemin/vers/setup.exe" ou "chemin/vers/setup.exe|Nom perso")
mode="${1:-}"
shift || true
confirm_flag="${1:-}"
shift || true
cli_target="${1:-}"

will_use_zenity=true
if [[ "${mode}" = "cli" ]] && [[ -n "${cli_target}" ]]; then
  will_use_zenity=false
fi

# 1. Vérification des dépendances
for cmd in sqlite3 python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    t create_prefix.cmd_missing "${cmd}"
    exit 1
  fi
done

if [[ "${will_use_zenity}" = true ]] && ! command -v zenity >/dev/null 2>&1; then
  t create_prefix.zenity_missing
  exit 1
fi

if [[ "${will_use_zenity}" = true ]]; then
  zgu_start_focus_watcher
fi

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  if [[ "${will_use_zenity}" = true ]]; then
    zenity --error --text="$(t create_prefix.pyyaml_missing_gui)" 2>/dev/null
  fi
  zgu_cli_error "$(t create_prefix.pyyaml_missing_cli)"
  exit 1
fi

# 2. Fermeture préalable de Lutris pour libérer la BDD
if flatpak list 2>/dev/null | grep -q lutris; then
  flatpak kill net.lutris.Lutris 2>/dev/null
fi
pkill -9 -x lutris 2>/dev/null
pkill -9 -f "/usr/bin/lutris" 2>/dev/null

# 3. Détection Flatpak vs paquet natif (identique à zgp-prefix-creator.sh)
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"

lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

lutris_flatpak_umu="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runtime/umu/umu-run"
lutris_package_umu="${HOME}/.local/share/lutris/runtime/umu/umu-run"

games_dir="${HOME}/Games"

exe_install_display_mode="gui"
[[ "${mode}" = "cli" ]] && exe_install_display_mode="cli"
version=$(zgu_resolve_lutris_version "${exe_install_display_mode}" "${lutris_package_db}" "${lutris_package_runner_dir}")
if [[ -z "${version}" ]]; then
  zenity --error --text="$(t create_prefix.lutris_missing_gui)" 2>/dev/null
  t create_prefix.lutris_missing_cli
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_db="${lutris_flatpak_db}"
    lutris_system_file="${lutris_flatpak_system_file}"
    runner_dir="${lutris_flatpak_runner_dir}"
    lutris_umu="${lutris_flatpak_umu}"
    ;;
  package)
    lutris_config_dir="${lutris_package_config_dir}"
    lutris_db="${lutris_package_db}"
    lutris_system_file="${lutris_package_system_file}"
    runner_dir="${lutris_package_runner_dir}"
    lutris_umu="${lutris_package_umu}"
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

mkdir -p "${lutris_config_dir}"
mkdir -p "$(dirname "${lutris_db}")"
mkdir -p "${games_dir}"

if [[ ! -d "${runner_dir}" ]]; then
  zenity --error --text="$(t create_prefix.no_runners_found "${runner_dir}")" 2>/dev/null
  zgu_cli_error "$(t create_prefix.no_runners_found_cli "${runner_dir}")"
  exit 1
fi

# --- Détection du type de runner / liste des runners utilisables / recherche de
# umu-run / slugification : identiques à zgp-prefix-creator.sh ---
zgp_detect_runner_type() {
  local r_dir="$1"
  if [[ -x "${r_dir}/bin/wine" ]]; then
    echo "wine"
  elif [[ -f "${r_dir}/toolmanifest.vdf" ]]; then
    echo "proton"
  else
    echo "unknown"
  fi
}

zgp_list_usable_runners() {
  local entry r_type
  for entry in "${runner_dir}"/*/; do
    [[ -d "${entry}" ]] || continue
    entry="${entry%/}"
    r_type=$(zgp_detect_runner_type "${entry}")
    [[ "${r_type}" = "unknown" ]] && continue
    echo "$(basename "${entry}")"
  done
}

zgp_find_umu_run() {
  if command -v umu-run >/dev/null 2>&1; then
    command -v umu-run
    return 0
  fi
  local candidate
  for candidate in \
    "/usr/local/share/umu/umu-run" \
    "/usr/share/umu/umu-run" \
    "/opt/umu/umu-run" \
    "${lutris_umu}"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}

zgp_slugify() {
  SLUG_INPUT="$1" python3 -c '
import os, re, unicodedata, uuid

value = os.environ.get("SLUG_INPUT", "")
v = unicodedata.normalize("NFD", value).encode("ascii", "ignore").decode("utf-8")
v = re.sub(r"[^\w\s-]", "", v).strip().lower()
slug = re.sub(r"[-\s]+", "-", v)
if not slug:
    slug = str(uuid.uuid5(uuid.NAMESPACE_URL, str(value)))
print(slug)
'
}

# 4. Choix du runner et de l'architecture
#
# IMPORTANT : "zenity --forms --add-combo" n'a AUCUN moyen de présélectionner une
# valeur (vérifié : --help-forms ne liste aucune option de valeur par défaut pour un
# --add-combo). Le premier essai (placer le runner par défaut en tête de liste)
# reposait sur l'idée que Zenity affiche la première valeur d'un menu déroulant par
# défaut -- pas garanti sur toutes les versions de Zenity : rapporté vide par
# l'utilisateur sur sa machine. Remplacé par "--list --radiolist", qui a un vrai
# mécanisme de présélection explicite (TRUE/FALSE par ligne) -- vérifié avec un clic
# automatisé réel (xdotool) sous Xvfb.
runner_choice=""
arch_choice="win64"

if [[ "${will_use_zenity}" = true ]]; then
  mapfile -t usable_runners < <(zgp_list_usable_runners)
  if [[ ${#usable_runners[@]} -eq 0 ]]; then
    zenity --error --text="$(t create_prefix.no_runners_found "${runner_dir}")" 2>/dev/null
    exit 1
  fi

  default_runner=$(zgu_get_default_runner)
  is_default_usable=false
  for r in "${usable_runners[@]}"; do
    if [[ "${r}" = "${default_runner}" ]]; then
      is_default_usable=true
    fi
  done

  runner_rows=()
  marked=false
  for r in "${usable_runners[@]}"; do
    if [[ "${is_default_usable}" = true ]] && [[ "${r}" = "${default_runner}" ]] && [[ "${marked}" = false ]]; then
      runner_rows+=("TRUE" "${r}")
      marked=true
    else
      runner_rows+=("FALSE" "${r}")
    fi
  done
  if [[ "${marked}" = false ]] && [[ ${#runner_rows[@]} -gt 0 ]]; then
    runner_rows[0]="TRUE"
  fi

  runner_choice=$(zenity --list --radiolist \
    --title="$(t exe_install.forms_title)" \
    --text="$(t create_prefix.runner_select_text)" \
    --column="" --column="$(t create_prefix.forms_runner_label)" \
    --width=500 --height=400 \
    "${runner_rows[@]}" 2>/dev/null)

  if [[ -z "${runner_choice}" ]]; then
    exit 0
  fi

  arch_choice=$(zenity --list --radiolist \
    --title="$(t exe_install.forms_title)" \
    --text="$(t create_prefix.arch_select_text)" \
    --column="" --column="$(t create_prefix.forms_arch_label)" \
    --width=400 --height=220 \
    TRUE "win64" FALSE "win32" 2>/dev/null)

  if [[ -z "${arch_choice}" ]]; then
    exit 0
  fi
else
  runner_choice=$(zgu_get_default_runner)
  arch_choice="win64"
fi

runner_type=$(zgp_detect_runner_type "${runner_dir}/${runner_choice}")
if [[ "${runner_type}" = "unknown" ]]; then
  zenity --error --text="$(t create_prefix.unknown_runner_type "${runner_choice}")" 2>/dev/null
  zgu_cli_error "$(t create_prefix.unknown_runner_type_cli "${runner_choice}")"
  exit 1
fi

umu_run_path=""
if [[ "${runner_type}" = "proton" ]]; then
  if ! umu_run_path=$(zgp_find_umu_run); then
    zenity --error --text="$(t create_prefix.umu_missing_gui)" 2>/dev/null
    zgu_cli_error "$(t create_prefix.umu_missing_cli)"
    exit 1
  fi
fi

# 5. Choix du fichier d'installation + nom d'affichage + slug
#
# Zenity ne propose pas de champ "chemin + bouton Parcourir" combiné dans une même
# fenêtre (vérifié : --help-forms ne liste aucun --add-file-selection). Et --forms
# --add-entry ne permet pas non plus de pré-remplir un champ (aucune option de
# valeur par défaut, contrairement à --add-combo). L'équivalent réaliste qui couvre
# les deux usages demandés (choisir visuellement OU taper/corriger le chemin à la
# main) est donc : un sélecteur de fichier standard, suivi de champs --entry
# distincts (qui eux acceptent --entry-text pour pré-remplir), pour le chemin, le nom
# ET le slug (calculé automatiquement à partir du nom, mais affiché et modifiable
# avant de continuer -- même principe que le tableau de révision de "prefix vierge").
exe_path=""
display_name=""
explicit_slug=""

if [[ "${will_use_zenity}" = true ]]; then
  picked_path=$(zenity --file-selection --title="$(t exe_install.browse_title)" \
    --file-filter="$(t exe_install.browse_filter_label) | *.exe *.msi *.bat *.cmd" \
    --file-filter="*" 2>/dev/null)

  guessed_name=""
  if [[ -n "${picked_path}" ]]; then
    guessed_name="$(basename "${picked_path}")"
    guessed_name="${guessed_name%.*}"
  fi

  entered_path=$(zenity --entry --title="$(t exe_install.edit_title)" \
    --text="$(t exe_install.edit_path_label)" \
    --entry-text="${picked_path}" --width=500 2>/dev/null)
  path_status=$?
  if [[ "${path_status}" -ne 0 ]]; then
    exit 0
  fi

  entered_name=$(zenity --entry --title="$(t exe_install.edit_title)" \
    --text="$(t exe_install.edit_name_label)" \
    --entry-text="${guessed_name}" --width=500 2>/dev/null)
  name_status=$?
  if [[ "${name_status}" -ne 0 ]]; then
    exit 0
  fi

  guessed_slug=$(zgp_slugify "${entered_name}")

  entered_slug=$(zenity --entry --title="$(t exe_install.edit_title)" \
    --text="$(t exe_install.edit_slug_label)" \
    --entry-text="${guessed_slug}" --width=500 2>/dev/null)
  slug_status=$?
  if [[ "${slug_status}" -ne 0 ]]; then
    exit 0
  fi

  exe_path="${entered_path}"
  display_name="${entered_name}"
  explicit_slug="${entered_slug}"
else
  if [[ -z "${cli_target}" ]]; then
    zgu_cli_error "$(t exe_install.no_path_error_cli)"
    exit 1
  fi
  if [[ "${cli_target}" == *"|"* ]]; then
    exe_path="${cli_target%%|*}"
    rest="${cli_target#*|}"
    if [[ "${rest}" == *"|"* ]]; then
      display_name="${rest%%|*}"
      explicit_slug="${rest#*|}"
    else
      display_name="${rest}"
    fi
  else
    exe_path="${cli_target}"
    display_name="$(basename "${exe_path}")"
    display_name="${display_name%.*}"
  fi
fi

exe_path="${exe_path/#\~/${HOME}}"

if [[ -z "${exe_path}" ]] || [[ ! -f "${exe_path}" ]]; then
  zenity --error --text="$(t exe_install.exe_not_found_gui "${exe_path}")" 2>/dev/null
  zgu_cli_error "$(t exe_install.exe_not_found_cli "${exe_path}")"
  exit 1
fi

if [[ -z "${display_name}" ]]; then
  zenity --error --text="$(t create_prefix.no_names_error)" 2>/dev/null
  zgu_cli_error "$(t create_prefix.no_names_error_cli)"
  exit 1
fi

# 6. Génération du slug (déduplication contre pga.db uniquement -- un seul jeu à la
# fois ici, pas de lot). Le slug saisi/affiché à l'étape précédente (GUI) ou fourni
# après le 2e "|" (CLI) est toujours repassé par zgp_slugify avant usage -- même
# principe que le tableau de révision de "prefix vierge" : une valeur éditée à la
# main ne doit jamais pouvoir contenir un caractère invalide.
declare -A existing_slugs=()
if [[ -f "${lutris_db}" ]]; then
  while IFS= read -r s; do
    [[ -n "${s}" ]] && existing_slugs["${s}"]=1
  done < <(sqlite3 "${lutris_db}" "SELECT slug FROM games;" 2>/dev/null)
fi

if [[ -n "${explicit_slug}" ]]; then
  base_slug=$(zgp_slugify "${explicit_slug}")
else
  base_slug=$(zgp_slugify "${display_name}")
fi
final_slug="${base_slug}"
suffix=2
while [[ -n "${existing_slugs[${final_slug}]:-}" ]]; do
  final_slug="${base_slug}-${suffix}"
  suffix=$(( suffix + 1 ))
done

prefix_dir="${games_dir}/${final_slug}"

if [[ -d "${prefix_dir}" ]]; then
  zenity --error --text="$(t exe_install.prefix_exists_gui "${prefix_dir}")" 2>/dev/null
  zgu_cli_error "$(t exe_install.prefix_exists_cli "${prefix_dir}")"
  exit 1
fi

# 7. Confirmation (uniquement pour lancer la création + l'installation -- la
# proposition de suppression en cas d'échec, plus loin, est toujours posée quel que
# soit -y).
if [[ "${will_use_zenity}" = false ]] && [[ "${confirm_flag}" != "yes" ]]; then
  t exe_install.confirm_cli_header "${display_name}" "${final_slug}" "${exe_path}" "${runner_choice}" "${arch_choice}"
  read -r -p "$(t exe_install.confirm_cli_prompt)" response
  case "${response}" in
    [oOyY]) : ;;
    *)
      t create_prefix.cancelled_cli
      exit 0
      ;;
  esac
fi

# 8. Initialisation du prefix (identique à "prefix vierge")
ZGP_REG_TIMEOUT_TICKS=360 # 360 x 0.5s = 180s max

zgp_wait_for_prefix() {
  local p_dir="$1"
  local ticks=0
  while [[ "${ticks}" -lt "${ZGP_REG_TIMEOUT_TICKS}" ]]; do
    if [[ -f "${p_dir}/user.reg" ]] && [[ -f "${p_dir}/userdef.reg" ]] && [[ -f "${p_dir}/system.reg" ]]; then
      return 0
    fi
    sleep 0.5
    ticks=$(( ticks + 1 ))
  done
  [[ -f "${p_dir}/user.reg" ]] && [[ -f "${p_dir}/system.reg" ]]
}

mkdir -p "${prefix_dir}"

if [[ "${will_use_zenity}" = true ]]; then
  t exe_install.init_progress_text "${display_name}"
else
  t exe_install.init_progress_cli "${display_name}"
fi

if [[ "${runner_type}" = "wine" ]]; then
  env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="winemenubuilder=" \
    "${runner_dir}/${runner_choice}/bin/wineboot" >/dev/null 2>&1
else
  env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" PROTONPATH="${runner_dir}/${runner_choice}" GAMEID="0" \
    "${umu_run_path}" createprefix >/dev/null 2>&1
fi

if ! zgp_wait_for_prefix "${prefix_dir}"; then
  zenity --error --text="$(t exe_install.init_failed_gui)" 2>/dev/null
  zgu_cli_error "$(t exe_install.init_failed_cli)"
  rm -rf "${prefix_dir}"
  exit 1
fi

# 9. Lancement réel de l'installateur, au premier plan, fenêtre visible -- on
# attend sa fermeture (comme Lutris) puis on regarde son code de sortie.
pulsate_pid=""
if [[ "${will_use_zenity}" = true ]]; then
  ( while true; do echo "#$(t exe_install.waiting_progress_text)"; sleep 1; done ) \
    | zenity --progress --pulsate --no-cancel --title="$(t exe_install.waiting_title)" \
      --text="$(t exe_install.waiting_progress_text)" 2>/dev/null &
  pulsate_pid=$!
fi

if [[ "${runner_type}" = "wine" ]]; then
  env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" \
    "${runner_dir}/${runner_choice}/bin/wine" "${exe_path}"
  install_exit_code=$?
else
  env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" PROTONPATH="${runner_dir}/${runner_choice}" GAMEID="0" \
    "${umu_run_path}" "${exe_path}"
  install_exit_code=$?
fi

if [[ -n "${pulsate_pid}" ]]; then
  kill "${pulsate_pid}" 2>/dev/null
  wait "${pulsate_pid}" 2>/dev/null
fi

# 10. Code de sortie non-zéro -> proposition de tout supprimer (toujours posée,
# indépendamment de -y : c'est une action destructive irréversible).
if [[ "${install_exit_code}" -ne 0 ]]; then
  wants_delete=false
  if [[ "${will_use_zenity}" = true ]]; then
    if zenity --question --title="$(t exe_install.error_title)" \
      --text="$(t exe_install.error_delete_question "${install_exit_code}")" 2>/dev/null; then
      wants_delete=true
    fi
  else
    t exe_install.error_delete_cli "${install_exit_code}"
    read -r -p "$(t exe_install.error_delete_prompt)" del_response
    case "${del_response}" in
      [oOyY]) wants_delete=true ;;
      *) wants_delete=false ;;
    esac
  fi

  if [[ "${wants_delete}" = true ]]; then
    rm -rf "${prefix_dir}"
    if [[ "${will_use_zenity}" = true ]]; then
      zenity --info --text="$(t exe_install.deleted_gui)" 2>/dev/null
    else
      zgu_cli_ok "$(t exe_install.deleted_cli)"
    fi
    exit 0
  fi
  # Sinon, on continue quand même (l'utilisateur estime que ça a fonctionné malgré
  # le code de sortie).
fi

# 11. Sélection optionnelle du .exe final du jeu installé (ouverte dans le prefix)
final_executable=""
if [[ "${will_use_zenity}" = true ]]; then
  final_executable=$(zenity --file-selection --title="$(t exe_install.pick_exe_title)" \
    --filename="${prefix_dir}/" \
    --file-filter="$(t exe_install.browse_filter_label) | *.exe" \
    --file-filter="*" 2>/dev/null)
else
  t exe_install.pick_exe_cli
  read -r -p "$(t exe_install.pick_exe_prompt)" final_executable
fi

# 12. Écriture du yml + insertion en base (identique à "prefix vierge")
zgp_write_config_yml() {
  local yml_path="$1" p_dir="$2" p_slug="$3" p_name="$4" p_runner="$5" p_exe="$6"
  YML_PATH="${yml_path}" P_DIR="${p_dir}" P_SLUG="${p_slug}" P_NAME="${p_name}" P_RUNNER="${p_runner}" P_EXE="${p_exe}" python3 -c '
import os, yaml

data = {
    "game": {"exe": os.environ.get("P_EXE", ""), "prefix": os.environ["P_DIR"]},
    "game_slug": os.environ["P_SLUG"],
    "name": os.environ["P_NAME"],
    "system": {"env": {"LC_ALL": ""}},
    "wine": {"version": os.environ["P_RUNNER"]},
}
with open(os.environ["YML_PATH"], "w") as f:
    yaml.dump(data, f, sort_keys=False)
' 2>/dev/null
}

timestamp=$(date +%s%N)
config_id="${final_slug}-${timestamp}"
yml_config_file="${lutris_config_dir}/${config_id}.yml"
zgp_write_config_yml "${yml_config_file}" "${prefix_dir}" "${final_slug}" "${display_name}" "${runner_choice}" "${final_executable}"

safe_name="${display_name//\'/\'\'}"
safe_slug="${final_slug//\'/\'\'}"
safe_exe="${final_executable//\'/\'\'}"
safe_prefix_dir="${prefix_dir//\'/\'\'}"
safe_config_id="${config_id//\'/\'\'}"

sqlite3 "${lutris_db}" "DELETE FROM games WHERE slug='${safe_slug}';"
sqlite3 "${lutris_db}" <<EOF
INSERT INTO games (name, slug, installer_slug, parent_slug, runner, executable, directory, configpath, updated, installed, installed_at)
VALUES (
  '${safe_name}',
  '${safe_slug}',
  '${safe_slug}',
  '',
  'wine',
  '${safe_exe}',
  '${safe_prefix_dir}',
  '${safe_config_id}',
  strftime('%s','now'),
  1,
  strftime('%s','now')
);
EOF

# 13. Résumé final
if [[ "${will_use_zenity}" = true ]]; then
  zenity --info --title="$(t exe_install.summary_title)" --text="$(t exe_install.summary_done "${display_name}")" 2>/dev/null
  notify-send "$(t exe_install.summary_title)" "$(t exe_install.summary_done "${display_name}")" 2>/dev/null
else
  zgu_cli_ok "$(t exe_install.summary_done "${display_name}")"
fi

exit 0
