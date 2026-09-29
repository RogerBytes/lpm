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

# --- lpm create-prefix : créer un ou plusieurs wineprefixes vierges enregistrés dans
# Lutris, sans passer par l'assistant d'installation (pas de script, pas d'exécutable
# à lancer) ---
#
# Reproduit directement le mécanisme interne que Lutris utilise pour initialiser un
# prefix (vérifié dans son code source, lutris/runners/commands/wine.py::create_prefix) :
#   - runner Wine classique : lance le "wineboot" du runner choisi avec
#     WINEARCH/WINEPREFIX/WINEDLLOVERRIDES, puis attend l'apparition de
#     user.reg/userdef.reg/system.reg (preuve que le prefix est initialisé). Testé
#     manuellement en conditions réelles (sans $DISPLAY) : fonctionne en ~13s.
#   - runner Proton : Lutris ne lance pas wineboot pour un Proton, il shell-out vers
#     "umu-run createprefix" (variables WINEPREFIX/PROTONPATH/GAMEID). Testé
#     manuellement avec un vrai umu-run 1.4.4 : confirme que "createprefix" est un
#     mot-clé supporté et que umu-run valide lui-même PROTONPATH en y cherchant
#     toolmanifest.vdf -- exactement le même signal utilisé ici pour distinguer un
#     runner Wine classique (bin/wine présent) d'un Proton (toolmanifest.vdf présent,
#     pas de bin/ à la racine).
#
# $1 = mode ("cli" = commande terminal explicite, vide/absent = menu interactif Zenity)
# $2 = confirm_flag ("yes" si -y)
# $3, $4... = cibles CLI ("Nom affiché" ou "Nom affiché|slug-personnalise")
mode="${1:-}"
shift || true
confirm_flag="${1:-}"
shift || true
cli_targets=("$@")

# zenity n'est requis que si on va effectivement afficher une fenêtre : cas de tout
# SAUF le mode CLI strict avec au moins une cible fournie sur la ligne de commande
# (même logique que zgp-game-installer.sh).
will_use_zenity=true
if [[ "${mode}" = "cli" ]] && [[ ${#cli_targets[@]} -gt 0 ]]; then
  will_use_zenity=false
fi

# 1. Vérification des dépendances : sqlite3/python3/PyYAML systématiquement (le
# wine/wineboot ou umu-run spécifique ne sont vérifiés qu'au moment de créer un
# prefix, une fois le runner effectivement choisi -- inutile d'exiger wine si la
# personne n'utilise que des runners Proton, et inversement).
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

# 2. Fermeture préalable de Lutris pour libérer la BDD (même geste que l'installeur
# et le désinstalleur : on écrit directement dans pga.db).
if flatpak list 2>/dev/null | grep -q lutris; then
  flatpak kill net.lutris.Lutris 2>/dev/null
fi
pkill -9 -x lutris 2>/dev/null
pkill -9 -f "/usr/bin/lutris" 2>/dev/null

# 3. Détection Flatpak vs paquet natif
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"

lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# Emplacement du umu-run embarqué par Lutris lui-même (vérifié en vrai : chez un
# utilisateur Flatpak, il vit sous data/lutris/runtime/umu/umu-run -- un fichier
# normal sur le disque, pas caché dans le bac à sable Flatpak, donc appelable
# directement sans passer par "flatpak run"). Le chemin natif est déduit du même
# principe que tous les autres chemins paire Flatpak/natif de ce fichier.
lutris_flatpak_umu="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runtime/umu/umu-run"
lutris_package_umu="${HOME}/.local/share/lutris/runtime/umu/umu-run"

games_dir="${HOME}/Games"

prefix_creator_display_mode="gui"
[[ "${mode}" = "cli" ]] && prefix_creator_display_mode="cli"
version=$(zgu_resolve_lutris_version "${prefix_creator_display_mode}" "${lutris_package_db}" "${lutris_package_runner_dir}")
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

# --- Détection du type d'un runner : "wine" (bin/wine présent -- runner Wine
# classique, initialisation via wineboot), "proton" (toolmanifest.vdf présent, pas
# de bin/ à la racine -- initialisation via umu-run createprefix) ou "unknown"
# (dossier incomplet/corrompu, ignoré). Ces deux signaux sont exactement ceux
# vérifiés en vrai : bin/wine+bin/wineboot pour un Wine-GE/Wine-Staging classique,
# toolmanifest.vdf pour un GE-Proton/proton-cachyos -- et umu-run lui-même valide
# PROTONPATH en cherchant ce même toolmanifest.vdf (confirmé par son message
# d'erreur exact quand ce fichier est absent).
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

# Liste des runners installés dont le type est reconnu (wine ou proton), un par
# ligne -- les dossiers "unknown" (incomplets) sont silencieusement exclus du choix
# proposé plutôt que de risquer une création de prefix qui échoue au milieu.
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

# Recherche de umu-run, dans l'ordre : PATH standard, emplacements connus vérifiés
# dans le code source de Lutris (lutris/util/wine/proton.py::get_umu_path), puis en
# dernier recours l'emplacement réel confirmé chez un utilisateur Lutris (Flatpak ou
# natif selon "${version}" détecté plus haut). Retourne le chemin sur stdout, ou
# rien (code 1) si introuvable.
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

# --- Slugification : reproduit exactement l'algorithme de Lutris (vérifié dans son
# code source, lutris/util/strings.py::slugify) -- normalisation Unicode NFD +
# encodage ASCII (retire les accents), minuscules, suppression de tout ce qui n'est
# ni lettre/chiffre/espace/tiret, espaces/tirets consécutifs réduits à un seul
# tiret. Si le résultat est vide (nom entièrement en caractères non-latins), repli
# sur un UUID déterministe (uuid5 sur l'espace de nom URL), comme Lutris.
#
# La valeur d'entrée passe par l'environnement plutôt que par interpolation directe
# dans le code Python : un nom de jeu (ou un slug tapé à la main dans le tableau de
# révision) contenant une apostrophe ou tout autre caractère spécial ne doit pas
# pouvoir casser la chaîne littérale ni injecter du code Python arbitraire.
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
# défaut -- vrai sur certaines versions de GTK4 (vérifié avec un GtkDropDown réel
# sous Xvfb), mais PAS garanti sur toutes les versions de Zenity : rapporté vide par
# l'utilisateur sur sa machine. Remplacé par "--list --radiolist", qui a un vrai
# mécanisme de présélection explicite (TRUE/FALSE par ligne, comme les cases à
# cocher utilisées ailleurs dans le projet) -- vérifié avec un clic automatisé réel
# (xdotool) sous Xvfb : la ligne marquée TRUE est bien celle sélectionnée et
# renvoyée, sans ambiguïté possible liée à la version de Zenity.
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
  # Si le runner par défaut de Lutris n'est pas (ou plus) installé/utilisable, on
  # présélectionne quand même le premier de la liste plutôt que de laisser un écran
  # sans aucune ligne cochée.
  if [[ "${marked}" = false ]] && [[ ${#runner_rows[@]} -gt 0 ]]; then
    runner_rows[0]="TRUE"
  fi

  runner_choice=$(zenity --list --radiolist \
    --title="$(t create_prefix.forms_title)" \
    --text="$(t create_prefix.forms_text)
$(t create_prefix.runner_select_text)" \
    --column="" --column="$(t create_prefix.forms_runner_label)" \
    --width=500 --height=400 \
    "${runner_rows[@]}" 2>/dev/null)

  if [[ -z "${runner_choice}" ]]; then
    exit 0
  fi

  arch_choice=$(zenity --list --radiolist \
    --title="$(t create_prefix.forms_title)" \
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

# 5. Saisie des noms d'affichage
declare -a raw_names=()

if [[ "${will_use_zenity}" = true ]]; then
  names_input=$(zenity --text-info --title="$(t create_prefix.names_title)" \
    --text="$(t create_prefix.names_text)" \
    --editable --width=550 --height=400 2>/dev/null)
  names_status=$?

  if [[ "${names_status}" -ne 0 ]]; then
    exit 0
  fi

  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "${line}" ]] && raw_names+=("${line}")
  done <<< "${names_input}"
else
  for target in "${cli_targets[@]}"; do
    [[ -z "${target}" ]] && continue
    raw_names+=("${target}")
  done
fi

if [[ ${#raw_names[@]} -eq 0 ]]; then
  zenity --error --text="$(t create_prefix.no_names_error)" 2>/dev/null
  zgu_cli_error "$(t create_prefix.no_names_error_cli)"
  exit 1
fi

# 6. Génération des slugs (avec déduplication contre pga.db et contre le lot en
# cours) -- en CLI, un slug personnalisé après "|" est repassé lui aussi par
# zgp_slugify, pour garantir sa validité (caractères interdits, espaces...) plutôt
# que de faire confiance à une saisie manuelle telle quelle.
declare -A existing_slugs=()
if [[ -f "${lutris_db}" ]]; then
  while IFS= read -r s; do
    [[ -n "${s}" ]] && existing_slugs["${s}"]=1
  done < <(sqlite3 "${lutris_db}" "SELECT slug FROM games;" 2>/dev/null)
fi

declare -a batch_names=()
declare -a batch_slugs=()
declare -A used_slugs=()

for entry in "${raw_names[@]}"; do
  display_name=""
  explicit_slug=""
  if [[ "${will_use_zenity}" = false ]] && [[ "${entry}" == *"|"* ]]; then
    display_name="${entry%%|*}"
    explicit_slug="${entry#*|}"
  else
    display_name="${entry}"
  fi

  [[ -z "${display_name}" ]] && continue

  if [[ -n "${explicit_slug}" ]]; then
    base_slug=$(zgp_slugify "${explicit_slug}")
  else
    base_slug=$(zgp_slugify "${display_name}")
  fi

  final_slug="${base_slug}"
  suffix=2
  while [[ -n "${existing_slugs[${final_slug}]:-}" ]] || [[ -n "${used_slugs[${final_slug}]:-}" ]]; do
    final_slug="${base_slug}-${suffix}"
    suffix=$(( suffix + 1 ))
  done
  used_slugs["${final_slug}"]=1

  batch_names+=("${display_name}")
  batch_slugs+=("${final_slug}")
done

# 7. Écran de révision (GUI) / récapitulatif + confirmation (CLI)
#
# IMPORTANT (deux bugs réels trouvés et corrigés successivement) :
#   1. "zenity --list --editable" seul (sans --checklist/--multiple) ne renvoie QUE la
#      ligne actuellement sélectionnée (celle sur laquelle on vient de cliquer pour
#      l'éditer), et sans "--print-column=ALL" il ne renvoie QUE la première colonne
#      (le nom, jamais le slug) -- d'où un seul prefix créé avec un slug de repli en
#      UUID à la place du slug affiché.
#   2. Correctif de "--checklist" ajouté pour forcer toutes les lignes cochées à
#      sortir : mais vérifié dans le vrai code source de Zenity (src/tree.c,
#      zenity_tree_dialog_toggle_get_selected -- "start at 1 because we're not
#      printing the checklist column string") que la colonne de case à cocher n'est
#      JAMAIS incluse dans la sortie, même avec --print-column=ALL : elle sert
#      uniquement de FILTRE (seules les lignes cochées sont renvoyées), sans jamais
#      imprimer elle-même de valeur TRUE/FALSE. Le code qui suit attendait donc à
#      tort un triplet (coché, nom, slug) par ligne alors que Zenity ne renvoie qu'une
#      paire (nom, slug) par ligne cochée -- ce qui décalait tout le parsing et
#      filtrait silencieusement la totalité du lot (aucune ligne ne semblait "TRUE"
#      là où le nom était en réalité attendu). Corrigé : on repasse à un pas de 2, la
#      case à cocher continue d'agir comme filtre côté Zenity lui-même (une ligne
#      décochée n'apparaît simplement pas du tout dans la sortie).
if [[ "${will_use_zenity}" = true ]]; then
  review_values=()
  for (( i=0; i<${#batch_names[@]}; i++ )); do
    review_values+=( "TRUE" "${batch_names[i]}" "${batch_slugs[i]}" )
  done

  review_result=$(zenity --list --checklist --editable \
    --title="$(t create_prefix.review_title)" \
    --text="$(t create_prefix.review_text)" \
    --column="$(t create_prefix.review_col_create)" \
    --column="$(t create_prefix.review_col_name)" --column="$(t create_prefix.review_col_slug)" \
    --separator=$'\x1f' \
    --print-column=ALL \
    --width=650 --height=450 \
    "${review_values[@]}" 2>/dev/null)

  if [[ -z "${review_result}" ]]; then
    exit 0
  fi

  # Reconstruction des paires nom/slug à partir de la sortie plate de Zenity (une
  # paire par ligne COCHÉE seulement -- les lignes décochées sont déjà absentes de
  # "${review_result}"), et re-normalisation systématique de chaque slug (même s'il
  # n'a pas été modifié) : garantit qu'un slug tapé/modifié à la main dans ce tableau
  # reste toujours valide (pas d'espace, de "/" ou de caractère spécial), sans code
  # de validation séparé.
  mapfile -t flat_fields < <(printf '%s' "${review_result}" | tr $'\x1f' '\n')

  final_names=()
  final_slugs=()
  declare -A final_used_slugs=()
  duplicate_found=""

  for (( i=0; i<${#flat_fields[@]}; i+=2 )); do
    r_name="${flat_fields[i]}"
    r_slug="${flat_fields[i+1]:-}"
    [[ -z "${r_name}" ]] && continue
    r_slug=$(zgp_slugify "${r_slug}")

    if [[ -n "${existing_slugs[${r_slug}]:-}" ]] || [[ -n "${final_used_slugs[${r_slug}]:-}" ]]; then
      duplicate_found="${r_slug}"
      break
    fi
    final_used_slugs["${r_slug}"]=1

    final_names+=("${r_name}")
    final_slugs+=("${r_slug}")
  done

  if [[ -n "${duplicate_found}" ]]; then
    zenity --error --text="$(t create_prefix.duplicate_slug_error "${duplicate_found}")" 2>/dev/null
    exit 1
  fi

  batch_names=("${final_names[@]}")
  batch_slugs=("${final_slugs[@]}")
else
  if [[ "${confirm_flag}" != "yes" ]]; then
    t create_prefix.confirm_cli_header
    for (( i=0; i<${#batch_names[@]}; i++ )); do
      t create_prefix.confirm_cli_item "${batch_names[i]}" "${batch_slugs[i]}"
    done
    read -r -p "$(t create_prefix.confirm_cli_prompt)" response
    case "${response}" in
      [oOyY]) : ;;
      *)
        t create_prefix.cancelled_cli
        exit 0
        ;;
    esac
  fi
fi

if [[ ${#batch_names[@]} -eq 0 ]]; then
  exit 0
fi

# 8. Création réelle des prefixes
#
# wineboot (runner Wine classique) comme umu-run createprefix (runner Proton) sont
# lancés en arrière-plan, sans attendre leur code de sortie : Lutris lui-même ne se
# fie pas au code de sortie (umu-run "exit 0" même quand PROTONPATH est invalide,
# voir le test manuel effectué plus haut dans la conversation), mais poll la
# présence des 3 fichiers de registre pour confirmer la réussite -- exactement
# reproduit ici.
ZGP_REG_TIMEOUT_TICKS=360 # 360 x 0.5s = 180s max par prefix

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

zgp_write_config_yml() {
  local yml_path="$1" p_dir="$2" p_slug="$3" p_name="$4" p_runner="$5"
  YML_PATH="${yml_path}" P_DIR="${p_dir}" P_SLUG="${p_slug}" P_NAME="${p_name}" P_RUNNER="${p_runner}" python3 -c '
import os, yaml

data = {
    "game": {"exe": "", "prefix": os.environ["P_DIR"]},
    "game_slug": os.environ["P_SLUG"],
    "name": os.environ["P_NAME"],
    "system": {"env": {"LC_ALL": ""}},
    "wine": {"version": os.environ["P_RUNNER"]},
}
with open(os.environ["YML_PATH"], "w") as f:
    yaml.dump(data, f, sort_keys=False)
' 2>/dev/null
}

total="${#batch_names[@]}"

# Trois fichiers temporaires pour faire remonter les résultats hors du sous-shell
# ci-dessous : quand cette boucle est branchée dans un pipe vers "zenity --progress"
# (mode GUI), toute variable qu'elle modifie reste locale à ce sous-shell et
# disparaît une fois le pipe terminé -- même contrainte, même solution, que
# zgu_gui_extract_zstd (tar_exit_file) dans zgu-progress-utils.sh.
created_count_file=$(mktemp)
skipped_file=$(mktemp)
failed_file=$(mktemp)
echo "0" > "${created_count_file}"

zgp_run_creation_batch() {
  local created=0
  local i c_name c_slug prefix_dir step_num percent
  local timestamp config_id yml_config_file safe_name safe_slug safe_prefix_dir safe_config_id

  for (( i=0; i<total; i++ )); do
    c_name="${batch_names[i]}"
    c_slug="${batch_slugs[i]}"
    prefix_dir="${games_dir}/${c_slug}"

    step_num=$(( i + 1 ))
    # Plafonné a 99, jamais 100, tant qu'on est dans la boucle : meme raison que dans
    # zgp-game-uninstaller.sh/zgr-runner-uninstaller.sh -- confirme reel que certaines versions
    # de Zenity referment la fenetre des qu'elles lisent un "100", meme avec "--auto-close" et
    # le flux d'entree encore ouvert. Le vrai "100" (ligne "echo 100" en fin de fonction,
    # plus bas) n'est ecrit qu'une fois CHAQUE prefix reellement cree (ou ignore/echoue et
    # consigne).
    percent=$(( (step_num * 99) / total ))

    if [[ "${will_use_zenity}" = true ]]; then
      echo "${percent}"
      echo "# $(t create_prefix.progress_text "${c_name}" "${step_num}" "${total}")"
    else
      t create_prefix.creating_cli "${c_name}" "${c_slug}" "${step_num}" "${total}"
    fi

    # Refus strict si le prefix existe déjà (même garde-fou que l'installeur) : on
    # ignore cette ligne plutôt que d'écraser un dossier déjà présent, et on
    # continue le reste du lot.
    if [[ -d "${prefix_dir}" ]]; then
      echo "${c_name}" >> "${skipped_file}"
      continue
    fi

    mkdir -p "${prefix_dir}"

    if [[ "${runner_type}" = "wine" ]]; then
      env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="winemenubuilder=" \
        "${runner_dir}/${runner_choice}/bin/wineboot" >/dev/null 2>&1
    else
      env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" PROTONPATH="${runner_dir}/${runner_choice}" GAMEID="0" \
        "${umu_run_path}" createprefix >/dev/null 2>&1
    fi

    if ! zgp_wait_for_prefix "${prefix_dir}"; then
      echo "${c_name}" >> "${failed_file}"
      continue
    fi

    timestamp=$(date +%s%N)
    config_id="${c_slug}-${timestamp}"
    yml_config_file="${lutris_config_dir}/${config_id}.yml"
    zgp_write_config_yml "${yml_config_file}" "${prefix_dir}" "${c_slug}" "${c_name}" "${runner_choice}"

    safe_name="${c_name//\'/\'\'}"
    safe_slug="${c_slug//\'/\'\'}"
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
  '',
  '${safe_prefix_dir}',
  '${safe_config_id}',
  strftime('%s','now'),
  1,
  strftime('%s','now')
);
EOF

    created=$(( created + 1 ))
    # Ecrit a CHAQUE reussite, pas seulement une fois a la fin de la boucle : si ce sous-shell
    # devait mourir prematurement (SIGPIPE d'une fenetre Zenity refermee trop tot -- voir le
    # commentaire sur le plafond a 99 plus haut), created_count_file garde quand meme le compte
    # exact des prefixes deja crees avec succes jusque-la, plutot que de rester bloque a "0".
    echo "${created}" > "${created_count_file}"
  done

  [[ "${will_use_zenity}" = true ]] && echo "100"
}

if [[ "${will_use_zenity}" = true ]]; then
  zgp_run_creation_batch | zenity --progress --title="$(t create_prefix.progress_title)" \
    --text="$(t create_prefix.progress_text "" 0 "${total}")" \
    --percentage=0 --auto-close --no-cancel --width=550 2>/dev/null
else
  zgp_run_creation_batch
fi

created_count=$(cat "${created_count_file}" 2>/dev/null)
[[ -z "${created_count}" ]] && created_count=0

skipped_existing=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && skipped_existing+=("${line}")
done < "${skipped_file}"

failed_names=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && failed_names+=("${line}")
done < "${failed_file}"

rm -f "${created_count_file}" "${skipped_file}" "${failed_file}"

# 9. Résumé final
if [[ "${will_use_zenity}" = true ]]; then
  summary_text="$(t create_prefix.summary_created "${created_count}")"
  if [[ ${#skipped_existing[@]} -gt 0 ]]; then
    summary_text+=$'\n'"$(t create_prefix.summary_skipped "${#skipped_existing[@]}")"
  fi
  if [[ ${#failed_names[@]} -gt 0 ]]; then
    summary_text+=$'\n'"$(t create_prefix.summary_failed "${#failed_names[@]}")"
  fi
  zenity --info --title="$(t create_prefix.summary_title)" --text="${summary_text}" 2>/dev/null
  notify-send "$(t create_prefix.notify_title)" "$(t create_prefix.notify_body "${created_count}")" 2>/dev/null
else
  zgu_cli_ok "$(t create_prefix.summary_created "${created_count}")"
  if [[ ${#skipped_existing[@]} -gt 0 ]]; then
    t create_prefix.summary_skipped "${#skipped_existing[@]}"
  fi
  if [[ ${#failed_names[@]} -gt 0 ]]; then
    t create_prefix.summary_failed "${#failed_names[@]}"
  fi
fi

exit 0