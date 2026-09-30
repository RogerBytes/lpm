#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-github-release-utils.sh
source "${script_dir}/zgu-github-release-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-progress-utils.sh
source "${script_dir}/zgu-progress-utils.sh"
# shellcheck source=./zgu-focus-utils.sh
source "${script_dir}/zgu-focus-utils.sh"
# shellcheck source=./zgu-hash-utils.sh
source "${script_dir}/zgu-hash-utils.sh"

# --- Analyse des arguments transmis par bin/lpm ---
# $1 = mode ("click" = double-clic depuis le gestionnaire de fichiers, "cli" = commande
#      terminal explicite, vide/absent = menu interactif Zenity sans cible)
# $2 = confirm_flag ("yes" si -y)
# $3 = ignore_hash_flag ("yes" si --ignore-hash)
# $4, $5... = cibles (fichiers .zgr ou noms distants)
mode="${1:-}"
shift || true
confirm_flag="${1:-}"
shift || true
ignore_hash_flag="${1:-}"
shift || true
cli_targets=("$@")
is_double_click=false
[[ "${mode}" = "click" ]] && is_double_click=true

# zgr_hash_filter <nameref tableau de noms> <nameref tableau assoc chemin par nom> <"gui"|"cli">
# Vérifie le sidecar sha256 (s'il existe) de chaque runner LOCAL du tableau donné (voir
# zgu-hash-utils.sh) et retire du tableau, en place, ceux dont le hash ne correspond pas --
# sauf si l'utilisateur choisit explicitement de les installer quand même, ou si
# --ignore-hash a été passé (auquel cas la vérification est entièrement sautée). Un runner
# sans sidecar n'est jamais considéré comme invalide (voir zgu_find_hash_sidecar).
zgr_hash_filter() {
  local -n names_ref="$1"
  local -n paths_ref="$2"
  local display_mode="$3"

  [[ "${ignore_hash_flag}" = "yes" ]] && return 0

  local name filepath hash_file
  local mismatch_names=()
  for name in "${names_ref[@]}"; do
    filepath="${paths_ref[${name}]:-}"
    [[ -n "${filepath}" ]] && [[ -f "${filepath}" ]] || continue
    if hash_file=$(zgu_find_hash_sidecar "${filepath}"); then
      zgu_verify_archive_hash "${filepath}" "${hash_file}" || mismatch_names+=("${name}")
    fi
  done

  [[ ${#mismatch_names[@]} -eq 0 ]] && return 0

  local keep_invalid=false
  if [[ "${display_mode}" = "gui" ]]; then
    local recap="" n
    for n in "${mismatch_names[@]}"; do
      recap+="$(t install_runner.hash_mismatch_item "${n}")"
    done
    if zenity --question --title="$(t install_runner.hash_mismatch_title)" \
         --text="$(t install_runner.hash_mismatch_text)${recap}" \
         --ok-label="$(t install_runner.hash_mismatch_ok)" \
         --cancel-label="$(t install_runner.hash_mismatch_cancel)" \
         --width=500 2>/dev/null; then
      keep_invalid=true
    fi
  else
    local n
    zgu_cli_error "$(t install_runner.hash_mismatch_cli_header)"
    for n in "${mismatch_names[@]}"; do
      zgu_cli_error "$(t install_runner.hash_mismatch_cli_item "${n}")"
    done
    local hash_response
    read -r -p "$(t install_runner.hash_mismatch_cli_prompt)" hash_response
    case "${hash_response}" in
      [yY]) keep_invalid=true ;;
      *) keep_invalid=false ;;
    esac
  fi

  if [[ "${keep_invalid}" = false ]]; then
    local -A mismatch_set=()
    local n filtered=()
    for n in "${mismatch_names[@]}"; do
      mismatch_set["${n}"]=1
    done
    for name in "${names_ref[@]}"; do
      [[ -n "${mismatch_set[${name}]:-}" ]] || filtered+=("${name}")
    done
    names_ref=("${filtered[@]}")
  fi
}

# Configuration des chemins des runners Lutris
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# GITHUB_RELEASE_URL est définie dans zgu-github-release-utils.sh (sourcé plus haut),
# seul endroit à modifier pour changer le dépôt/la release des runners.

# Tags de source réutilisés (affichage ET comparaisons de logique) - traduits une seule fois
local_tag="$(t install_runner.source_local)"
online_tag="$(t install_runner.source_online)"
browse_label="$(t install_runner.browse_option_label)"
external_file_tag="$(t install_runner.source_external_file)"

# 1. Vérification de zenity et bsdtar
# zenity n'est requis que si on va effectivement afficher une fenêtre : c'est le cas
# partout SAUF en mode CLI strict avec au moins une cible fournie sur la ligne de commande
# (même logique que dans zgp-game-installer.sh).
will_use_zenity=true
if [[ "${mode}" = "cli" ]] && [[ ${#cli_targets[@]} -gt 0 ]]; then
  will_use_zenity=false
fi
if [[ "${will_use_zenity}" = true ]] && ! command -v zenity >/dev/null 2>&1; then
  t install_runner.zenity_missing
  exit 1
fi

if [[ "${will_use_zenity}" = true ]]; then
  zgu_start_focus_watcher
fi

# bsdtar (paquet "libarchive-tools" sur Debian/Ubuntu) remplace tar -I zstd pour l'extraction :
# ses protections par défaut ARCHIVE_EXTRACT_SECURE_NODOTDOT / ARCHIVE_EXTRACT_SECURE_SYMLINKS
# refusent tout membre d'archive tentant de sortir de son dossier de destination via "../" ou
# un lien symbolique piégé -- important ici puisqu'un .zgr peut être téléchargé depuis GitHub
# OU partagé/importé localement (voir mode "browse"), donc potentiellement non fiable dans les
# deux cas. bsdtar lit le zstd nativement (libzstd liée en dur), zstd externe n'est donc plus
# nécessaire pour ce script.
if ! command -v bsdtar >/dev/null 2>&1; then
  zgu_gui_error "$(t install_runner.bsdtar_missing_gui)" || t install_runner.bsdtar_missing_fallback
  exit 1
fi

if ! command -v pv >/dev/null 2>&1; then
  zgu_gui_error "$(t install_runner.pv_missing_gui)" || t install_runner.pv_missing_fallback
  exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  zgu_gui_error "$(t install_runner.sha256sum_missing_gui)" || t install_runner.sha256sum_missing_fallback
  exit 1
fi

# 2. Détection Flatpak vs Paquet natif pour les runners (fonction fournie par
# zgu-lutris-utils.sh -- résout aussi le cas des deux installées en même temps)
install_runner_display_mode="gui"
[[ "${mode}" = "cli" ]] && install_runner_display_mode="cli"
version=$(zgu_resolve_lutris_version "${install_runner_display_mode}" "" "${lutris_package_runner_dir}")
if [[ -z "${version}" ]]; then
  zgu_gui_error "$(t install_runner.lutris_missing_gui)"
  t install_runner.lutris_missing_cli
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_runner_dir="${lutris_flatpak_runner_dir}"
    ;;
  package)
    lutris_runner_dir="${lutris_package_runner_dir}"
    ;;
  *)
    # Ne devrait jamais arriver : $version n'est affecté qu'à "flatpak" ou "package"
    # ci-dessus (sinon exit 1). Garde-fou si cette invariant venait à changer.
    echo "Erreur interne : version Lutris inattendue '${version}'." >&2
    exit 1
    ;;
esac

mkdir -p "${lutris_runner_dir}"

# Mince wrapper autour de zgu_gui_download (voir zgu-progress-utils.sh) : pourcentage réel
# piloté par pv quand la taille de l'asset est connue (voir "size_by_name" plus bas, ajouté
# pour unifier ce comportement avec zgc-dependency-checker.sh qui l'avait déjà), barre
# indéterminée sinon (fichier local, pas d'appel réseau).
download_runner() {
  local url="$1"
  local dest="$2"
  local name="$3"
  local expected_size="${4:-0}"
  # Texte optionnel (compteur "N/Total : nom -- etape") utilise en mode lot -- voir
  # ZGU_BATCH_FD plus bas dans ce fichier. Vide hors lot : comportement inchange, texte
  # generique par defaut.
  local batch_text="${5:-}"
  local zen_text="${batch_text:-$(t install_runner.download_connecting)}"

  zgu_gui_download "${url}" "${dest}" "${expected_size}" \
    "$(t install_runner.download_title "${name}")" \
    "${zen_text}"
}

# Extrait une archive .zgr avec barre de progression Zenity réelle. Mince wrapper autour de
# zgu_gui_extract_zstd (voir zgu-progress-utils.sh) : pourcentage réel piloté par pv sur le
# flux compressé d'entrée, sans balayage périodique du dossier de sortie (un "du -sb" répété
# serait coûteux sur un runner volumineux). Factorise le bloc partagé par les 3 imports
# (import de masse, import externe, import en ligne).
# Codes de retour : 0 = succès | 1 = archive corrompue (déjà nettoyée + message affiché)
#                   2 = annulé par l'utilisateur (déjà nettoyé, PAS de message affiché : au
#                       caller de décider s'il informe l'utilisateur et/ou s'il quitte)
extract_runner_with_progress() {
  local runner_name="$1"
  local archive_path="$2"
  # Texte optionnel (compteur "N/Total : nom -- etape") utilise en mode lot -- voir
  # ZGU_BATCH_FD plus bas dans ce fichier. Vide hors lot : comportement inchange, texte
  # generique par defaut.
  local batch_text="${3:-}"
  local zen_text="${batch_text:-$(t install_runner.extract_start_text)}"
  local target_dir="${lutris_runner_dir}/${runner_name}"

  zgu_gui_extract_zstd "${archive_path}" "${lutris_runner_dir}" \
    "$(t install_runner.import_title "${runner_name}")" \
    "${zen_text}"
  local status=$?

  if [[ "${status}" -eq 2 ]]; then
    rm -rf "${target_dir}"
    return 2
  elif [[ "${status}" -ne 0 ]]; then
    zgu_gui_error "$(t install_runner.corrupt_archive_gui "${runner_name}" "${ZGU_LAST_TAR_EXIT:-1}")" "$(t install_runner.corrupt_archive_title)"
    rm -rf "${target_dir}"
    return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------------------------
# MODE CLI STRICT (Terminal, une ou plusieurs cibles : paquets locaux .zgr ET/OU noms distants GitHub)
if [[ ${#cli_targets[@]} -gt 0 ]] && [[ "${is_double_click}" = false ]]; then
  declare -A runner_source   # "local" ou "distant"
  declare -A runner_archive  # chemin local, ou nom de fichier ciblé pour le distant
  runners_to_install=()
  conflicts=()

  for target in "${cli_targets[@]}"; do
    if [[ -f "${target}" ]]; then
      runner_name=$(basename -- "${target}" .zgr)
      runner_source["${runner_name}"]="local"
      runner_archive["${runner_name}"]="${target}"
    else
      # basename() par cohérence défensive avec les autres cibles CLI du projet (jeux,
      # runners locaux/à supprimer/à empaqueter) : un nom distant ne devrait normalement
      # jamais matcher un asset GitHub réel s'il contient un séparateur de chemin, mais
      # on neutralise quand même toute tentative de traversée ("../", chemin absolu...)
      # avant construction de runner_dir/runner_name plus loin dans ce fichier.
      runner_name=$(basename -- "${target%.zgr}")
      runner_source["${runner_name}"]="distant"
      runner_archive["${runner_name}"]="${runner_name}.zgr"
    fi

    if [[ -d "${lutris_runner_dir}/${runner_name}" ]]; then
      conflicts+=("${runner_name}")
    fi

    runners_to_install+=("${runner_name}")
  done

  # Vérification stricte : si UN SEUL runner demandé est déjà installé, on annule tout, sans rien installer
  if [[ ${#conflicts[@]} -gt 0 ]]; then
    zgu_cli_error "$(t install_runner.conflict_header_cli)"
    for name in "${conflicts[@]}"; do
      zgu_cli_error "$(t install_runner.conflict_item_cli "${name}")"
    done
    zgu_cli_error "$(t install_runner.conflict_hint_cli)"
    exit 1
  fi

  # Vérification d'intégrité (sidecar sha256, voir zgu-hash-utils.sh) : seuls les runners
  # LOCAUX peuvent avoir un sidecar (un runner distant récupéré depuis GitHub est déjà
  # vérifié séparément, plus bas, via le digest fourni par l'API GitHub elle-même).
  local_names_for_hash=()
  for name in "${runners_to_install[@]}"; do
    [[ "${runner_source[${name}]}" = "local" ]] && local_names_for_hash+=("${name}")
  done
  if [[ ${#local_names_for_hash[@]} -gt 0 ]]; then
    zgr_hash_filter local_names_for_hash runner_archive "cli"
    declare -A kept_local_for_hash=()
    for name in "${local_names_for_hash[@]}"; do
      kept_local_for_hash["${name}"]=1
    done
    filtered_runners_to_install=()
    for name in "${runners_to_install[@]}"; do
      if [[ "${runner_source[${name}]}" = "distant" ]] || [[ -n "${kept_local_for_hash[${name}]:-}" ]]; then
        filtered_runners_to_install+=("${name}")
      fi
    done
    runners_to_install=("${filtered_runners_to_install[@]}")
    if [[ ${#runners_to_install[@]} -eq 0 ]]; then
      exit 0
    fi
  fi

  # Confirmation interactive si le flag -y n'est pas présent
  if [[ "${confirm_flag}" != "yes" ]]; then
    t install_runner.confirm_cli_header
    for name in "${runners_to_install[@]}"; do
      if [[ "${runner_source[${name}]}" = "local" ]]; then
        t install_runner.confirm_cli_item_local "${name}" "${runner_archive[${name}]}"
      else
        t install_runner.confirm_cli_item_remote "${name}"
      fi
    done
    read -r -p "$(t install_runner.confirm_cli_prompt)" response
    case "${response}" in
      [nN])
        t install_runner.cancelled_cli
        exit 0
        ;;
      *)
        ;;
    esac
  fi

  # Récupération unique des informations de la release GitHub si au moins un runner distant est demandé
  release_json=""
  for name in "${runners_to_install[@]}"; do
    if [[ "${runner_source[${name}]}" = "distant" ]]; then
      api_url=$(zgu_github_api_url "${GITHUB_RELEASE_URL}")
      release_json=$(zgu_fetch_url "${api_url}")
      break
    fi
  done

  for runner_name in "${runners_to_install[@]}"; do
    src="${runner_source[${runner_name}]}"

    expected_digest=""

    if [[ "${src}" = "local" ]]; then
      archive_path="${runner_archive[${runner_name}]}"
      t install_runner.installing_local_cli "${runner_name}"
    else
      target_filename="${runner_archive[${runner_name}]}"
      t install_runner.searching_remote_cli "${target_filename}"

      download_url=""
      if command -v python3 >/dev/null 2>&1; then
        asset_info=$(python3 -c '
import sys, json
try:
    data = json.loads(sys.argv[1])
    target = sys.argv[2]
    for asset in data.get("assets", []):
        if asset.get("name", "") == target:
            url = asset.get("browser_download_url", "")
            digest = asset.get("digest") or ""
            print(f"{url}\x1f{digest}")
            break
except Exception:
    pass
' "${release_json}" "${target_filename}")
        download_url="${asset_info%%$'\x1f'*}"
        expected_digest="${asset_info#*$'\x1f'}"
      fi

      if [[ -z "${download_url}" ]]; then
        zgu_cli_error "$(t install_runner.remote_not_found_cli "${target_filename}")"
        continue
      fi

      temp_cli_dir=$(mktemp -d)
      archive_path="${temp_cli_dir}/${target_filename}"

      t install_runner.downloading_cli "${runner_name}"
      if command -v wget >/dev/null 2>&1; then
        wget --show-progress -O "${archive_path}" "${download_url}"
      else
        curl -Lf -# -o "${archive_path}" "${download_url}"
      fi

      if [[ ! -f "${archive_path}" ]] || [[ ! -s "${archive_path}" ]]; then
        zgu_cli_error "$(t install_runner.download_failed_cli "${runner_name}")"
        rm -rf "${temp_cli_dir}"
        continue
      fi

      # Avertissement non bloquant : GitHub ne fournit pas toujours un digest pour chaque
      # asset. Sans lui, aucune vérification d'intégrité n'est possible (zgu_sha256_matches
      # retourne alors "succès" par convention) -- on le signale explicitement plutôt que
      # de laisser ce cas totalement silencieux.
      if [[ -z "${expected_digest}" ]]; then
        zgu_cli_error "$(t install_runner.checksum_missing_cli "${runner_name}")"
      fi

      if ! zgu_sha256_matches "${archive_path}" "${expected_digest}"; then
        zgu_cli_error "$(t install_runner.checksum_invalid_cli "${runner_name}")"
        rm -rf "${temp_cli_dir}"
        continue
      fi
    fi

    t install_runner.extracting_cli "${runner_name}"
    archive_size=$(stat -c%s "${archive_path}" 2>/dev/null || stat -f%z "${archive_path}" 2>/dev/null)
    # bsdtar (et non tar -I zstd) : voir le commentaire sur la vérification des dépendances
    # plus haut dans ce fichier pour le détail des protections SECURE_NODOTDOT/SECURE_SYMLINKS.
    # umask 022 le temps de l'extraction : même garde-fou que zgp-game-installer.sh contre
    # un .zgr forgé plantant un fichier trop permissif (777) ou illisible (000).
    _lpm_old_umask=$(umask)
    umask 022
    pv -s "${archive_size:-0}" "${archive_path}" | bsdtar -xf - -C "${lutris_runner_dir}"
    tar_exit="${PIPESTATUS[1]}"
    umask "${_lpm_old_umask}"

    [[ "${src}" = "distant" ]] && rm -rf "${temp_cli_dir}"

    # Vérification de l'intégrité de l'extraction : si tar a échoué (archive corrompue,
    # tronquée ou invalide), on nettoie ce qui a pu être extrait et on passe au runner suivant
    if [[ "${tar_exit}" -ne 0 ]]; then
      zgu_cli_error "$(t install_runner.corrupt_archive_cli "${runner_name}" "${tar_exit}")"
      rm -rf "${lutris_runner_dir:?}/${runner_name}"
      continue
    fi

    zgu_cli_ok "$(t install_runner.install_success_cli "${runner_name}")"
  done

  exit 0
fi

# ---------------------------------------------------------------------------------------------
# MODE DOUBLE-CLIC / FICHIER CIBLÉ (Scan UNIQUEMENT du dossier parent du fichier cliqué)
if [[ ${#cli_targets[@]} -eq 1 ]] && [[ "${is_double_click}" = true ]] && [[ -f "${cli_targets[0]}" ]]; then
  target_file="${cli_targets[0]}"
  search_dir="$(dirname "${target_file}")"

  shopt -s nullglob
  folder_zgr_files=("${search_dir}"/*.zgr)

  declare -A mass_file_by_name
  mass_zenity_args=()

  for f_path in "${folder_zgr_files[@]}"; do
    [[ -f "${f_path}" ]] || continue
    f_name=$(basename "${f_path}" .zgr)
    
    if [[ -d "${lutris_runner_dir}/${f_name}" ]]; then
      continue
    fi

    mass_file_by_name["${f_name}"]="${f_path}"
    mass_zenity_args+=( "TRUE" "${f_name}" "${local_tag}" )
  done

  if [[ ${#mass_file_by_name[@]} -eq 0 ]]; then
    zenity --info --text="$(t install_runner.no_other_found_gui)" 2>/dev/null
    exit 0
  fi

  selected_mass=$(zenity --list --checklist \
    --title="$(t install_runner.mass_import_title)" \
    --text="$(t install_runner.mass_import_text)" \
    --column="$(t install_runner.col_install)" --column="$(t install_runner.col_name)" --column="$(t install_runner.col_source)" \
    --separator=$'\x1f' \
    "${mass_zenity_args[@]}" \
    --width=600 --height=300 2>/dev/null)

  [[ -z "${selected_mass}" ]] && exit 0
  IFS=$'\x1f' read -r -a mass_to_install <<< "${selected_mass}"

  # Vérification d'intégrité (sidecar sha256, voir zgu-hash-utils.sh) : tous ces runners
  # sont locaux (trouvés dans le dossier du fichier double-cliqué).
  zgr_hash_filter mass_to_install mass_file_by_name "gui"
  [[ ${#mass_to_install[@]} -eq 0 ]] && exit 0

  # Fenêtre de progression PARTAGÉE (voir zgu_batch_progress_open dans zgu-progress-utils.sh) :
  # même raison et même mécanisme que zgp-game-installer.sh -- sans ça, plusieurs .zgr
  # sélectionnés ici ouvraient et refermaient une fenêtre par runner, avec le focus qui
  # revenait sans arrêt au premier plan.
  mass_using_batch=false
  if [[ ${#mass_to_install[@]} -gt 1 ]]; then
    mass_using_batch=true
    zgu_batch_progress_open "$(t install_runner.batch_progress_title "${#mass_to_install[@]}")"
  fi

  mass_success_file=$(mktemp)
  mass_idx=0
  for sub_runner_name in "${mass_to_install[@]}"; do
    mass_idx=$((mass_idx + 1))
    archive_path="${mass_file_by_name[${sub_runner_name}]}"
    [[ -f "${archive_path}" ]] || continue

    item_text=""
    if [[ "${mass_using_batch}" = true ]]; then
      item_text="$(t install_runner.batch_progress_item "${mass_idx}" "${#mass_to_install[@]}" "${sub_runner_name}" "$(t install_runner.extract_start_text)")"
    fi
    extract_runner_with_progress "${sub_runner_name}" "${archive_path}" "${item_text}"
    extract_status=$?

    if [[ "${extract_status}" -eq 2 ]]; then
      # Annulé par l'utilisateur : mêmes sémantiques que le mode "en ligne" plus bas dans
      # ce fichier. Le code retour doit être vérifié ici, sinon une annulation en cours
      # d'extraction passe inaperçue et le lot continue silencieusement avec le runner
      # suivant au lieu de s'arrêter.
      [[ "${mass_using_batch}" = true ]] && zgu_batch_progress_close
      rm -f "${mass_success_file}"
      zenity --info --title="$(t install_runner.cancel_title)" --text="$(t install_runner.import_cancelled_text)" 2>/dev/null
      exit 0
    fi
    # status 1 (archive corrompue) : message déjà affiché par la fonction elle-même,
    # on continue simplement avec le runner suivant du lot.
    [[ "${extract_status}" -eq 0 ]] && echo 1 >> "${mass_success_file}"
  done

  [[ "${mass_using_batch}" = true ]] && zgu_batch_progress_close

  # Notification finale reflétant le résultat RÉEL (même principe que zgp-game-installer.sh).
  mass_success_count=$(wc -l < "${mass_success_file}" 2>/dev/null)
  rm -f "${mass_success_file}"
  [[ -z "${mass_success_count}" ]] && mass_success_count=0
  mass_total_count=${#mass_to_install[@]}

  if [[ "${mass_success_count}" -eq "${mass_total_count}" ]] && [[ "${mass_total_count}" -gt 0 ]]; then
    notify-send "$(t install_runner.notify_title)" "$(t install_runner.notify_body_mass)" 2>/dev/null
  elif [[ "${mass_success_count}" -eq 0 ]]; then
    notify-send "$(t install_runner.notify_title_none)" "$(t install_runner.notify_body_none)" 2>/dev/null
  else
    notify-send "$(t install_runner.notify_title_partial)" "$(t install_runner.notify_body_partial "${mass_success_count}" "${mass_total_count}")" 2>/dev/null
  fi
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# MODE INTERACTIF NORMAL (Depuis le menu : Uniquement En Ligne, AUCUN scan local par défaut)
declare -A source_by_name
declare -A file_or_url_by_name
declare -A digest_by_name
declare -A size_by_name

if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
  api_url=$(zgu_github_api_url "${GITHUB_RELEASE_URL}")
  release_json=$(zgu_fetch_url "${api_url}")

  if command -v python3 >/dev/null 2>&1; then
    parsed_assets=$(python3 -c '
import sys, json
try:
    data = json.loads(sys.argv[1])
    for asset in data.get("assets", []):
        name = asset.get("name", "")
        url = asset.get("browser_download_url", "")
        size = asset.get("size", 0)
        digest = asset.get("digest") or ""
        if name.endswith(".zgr"):
            print(f"{name}\x1f{url}\x1f{size}\x1f{digest}")
except Exception:
    pass
' "${release_json}" 2>/dev/null)
    while IFS=$'\x1f' read -r asset_name download_url asset_size asset_digest; do
      [[ -z "${asset_name}" ]] && continue
      runner_name="${asset_name%.zgr}"

      if [[ -d "${lutris_runner_dir}/${runner_name}" ]]; then
        continue
      fi

      source_by_name["${runner_name}"]="${online_tag}"
      file_or_url_by_name["${runner_name}"]="${download_url}"
      digest_by_name["${runner_name}"]="${asset_digest}"
      size_by_name["${runner_name}"]="${asset_size}"
    done <<< "${parsed_assets}"
  fi
fi

# Tri alphabétique propre (même mécanisme que zgr-runner-lister.sh / zgr-runner-packer.sh /
# zgr-runner-uninstaller.sh) : l'ordre d'itération des clés d'un tableau associatif Bash
# ("${!array[@]}") n'est pas garanti alphabétique, contrairement à ce que suppose une simple
# boucle dessus -- sans ce tri, la liste des runners disponibles en ligne apparaissait dans un
# ordre arbitraire dans la fenêtre Zenity.
mapfile -t sorted_online_runner_names < <(printf '%s\n' "${!file_or_url_by_name[@]}" | sort)

zenity_args=()
for runner_name in "${sorted_online_runner_names[@]}"; do
  source_tag="${source_by_name[${runner_name}]}"
  zenity_args+=( "TRUE" "${runner_name}" "${source_tag}" )
done

zenity_args+=( "FALSE" "${browse_label}" "${external_file_tag}" )
file_or_url_by_name["${browse_label}"]=""

selected_runners=$(zenity --list --checklist \
  --title="$(t install_runner.online_title)" \
  --text="$(t install_runner.online_text)" \
  --column="$(t install_runner.col_install)" --column="$(t install_runner.col_name)" --column="$(t install_runner.col_source)" \
  --separator=$'\x1f' \
  "${zenity_args[@]}" \
  --width=700 --height=380 2>/dev/null)

if [[ -z "${selected_runners}" ]]; then
  exit 0
fi

IFS=$'\x1f' read -r -a runners_to_install <<< "${selected_runners}"
temp_dir=$(mktemp -d)

# Fenêtre de progression PARTAGÉE (voir zgu_batch_progress_open dans zgu-progress-utils.sh),
# même principe que zgp-game-installer.sh : sans ça, plusieurs runners sélectionnés ici
# ouvraient et refermaient DEUX fenêtres chacun (téléchargement puis extraction), avec le
# focus qui revenait sans arrêt au premier plan.
runner_using_batch=false
runner_total_count=${#runners_to_install[@]}
if [[ "${runner_total_count}" -gt 1 ]]; then
  runner_using_batch=true
  zgu_batch_progress_open "$(t install_runner.batch_progress_title "${runner_total_count}")"
fi

runner_success_file=$(mktemp)
runner_idx=0
for runner_name in "${runners_to_install[@]}"; do
  runner_idx=$((runner_idx + 1))
  if [[ "${runner_name}" = "${browse_label}" ]]; then
    if ! external_file=$(zenity --file-selection \
        --title="$(t install_runner.file_selection_title)" \
        --file-filter="$(t install_runner.file_selection_filter_name) (*.zgr) | *.zgr" 2>/dev/null) || [[ -z "${external_file}" ]]; then
      continue
    fi

    ext_dir="$(dirname "${external_file}")"
    
    declare -A ext_file_or_url_by_name
    
    shopt -s nullglob
    for ext_file in "${ext_dir}"/*.zgr; do
      [[ -f "${ext_file}" ]] || continue
      ext_filename=$(basename "${ext_file}")
      ext_r_name="${ext_filename%.zgr}"
      
      if [[ -d "${lutris_runner_dir}/${ext_r_name}" ]]; then
        continue
      fi
      
      ext_file_or_url_by_name["${ext_r_name}"]="${ext_file}"
    done

    if [[ ${#ext_file_or_url_by_name[@]} -eq 0 ]] && [[ -f "${external_file}" ]]; then
      ext_filename=$(basename "${external_file}")
      ext_r_name="${ext_filename%.zgr}"
      ext_file_or_url_by_name["${ext_r_name}"]="${external_file}"
    fi

    if [[ ${#ext_file_or_url_by_name[@]} -eq 0 ]]; then
      zgu_gui_error "$(t install_runner.no_valid_found_gui)"
      continue
    fi

    # Même correction de tri que pour la liste en ligne plus haut dans ce fichier (voir le
    # commentaire associé) : l'ordre des clés d'un tableau associatif Bash n'est pas garanti.
    mapfile -t ext_sorted_runner_names < <(printf '%s\n' "${!ext_file_or_url_by_name[@]}" | sort)

    ext_zenity_args=()
    for ext_r_name in "${ext_sorted_runner_names[@]}"; do
      ext_zenity_args+=( "TRUE" "${ext_r_name}" "${local_tag}" )
    done

    ext_selected_runners=$(zenity --list --checklist \
      --title="$(t install_runner.folder_found_title)" \
      --text="$(t install_runner.mass_import_text)" \
      --column="$(t install_runner.col_install)" --column="$(t install_runner.col_name)" --column="$(t install_runner.col_source)" \
      --separator=$'\x1f' \
      "${ext_zenity_args[@]}" \
      --width=600 --height=300 2>/dev/null)

    if [[ -z "${ext_selected_runners}" ]]; then
      continue
    fi

    IFS=$'\x1f' read -r -a ext_runners_to_install <<< "${ext_selected_runners}"

    # Vérification d'intégrité (sidecar sha256, voir zgu-hash-utils.sh) : tous ces runners
    # sont locaux (trouvés dans le dossier du fichier choisi via "Parcourir...").
    zgr_hash_filter ext_runners_to_install ext_file_or_url_by_name "gui"
    [[ ${#ext_runners_to_install[@]} -eq 0 ]] && continue

    # Si la fenêtre partagée du lot principal est déjà ouverte (plusieurs entrées cochées
    # dans le menu, "Parcourir..." étant l'une d'elles), ce sous-lot s'y ajoute directement --
    # sinon ("Parcourir..." était la SEULE entrée cochée), on ouvre une fenêtre partagée
    # dédiée à ce sous-lot précis, pour la même raison.
    ext_using_own_batch=false
    ext_total_count=${#ext_runners_to_install[@]}
    if [[ "${runner_using_batch}" = false ]] && [[ "${ext_total_count}" -gt 1 ]]; then
      ext_using_own_batch=true
      zgu_batch_progress_open "$(t install_runner.batch_progress_title "${ext_total_count}")"
    fi

    ext_idx=0
    for sub_runner_name in "${ext_runners_to_install[@]}"; do
      ext_idx=$((ext_idx + 1))
      archive_path="${ext_file_or_url_by_name[${sub_runner_name}]}"

      ext_item_text=""
      if [[ "${runner_using_batch}" = true ]]; then
        ext_item_text="$(t install_runner.batch_progress_item "${runner_idx}" "${runner_total_count}" "${sub_runner_name}" "$(t install_runner.extract_start_text)")"
      elif [[ "${ext_using_own_batch}" = true ]]; then
        ext_item_text="$(t install_runner.batch_progress_item "${ext_idx}" "${ext_total_count}" "${sub_runner_name}" "$(t install_runner.extract_start_text)")"
      fi
      extract_runner_with_progress "${sub_runner_name}" "${archive_path}" "${ext_item_text}"
      extract_status=$?

      if [[ "${extract_status}" -eq 2 ]]; then
        # Même correctif que pour l'import de masse par double-clic ci-dessus : sans
        # cette vérification, une annulation ici passait inaperçue et le lot continuait.
        [[ "${ext_using_own_batch}" = true ]] && zgu_batch_progress_close
        [[ "${runner_using_batch}" = true ]] && zgu_batch_progress_close
        rm -f "${runner_success_file}"
        rm -rf "${temp_dir}"
        zenity --info --title="$(t install_runner.cancel_title)" --text="$(t install_runner.import_cancelled_text)" 2>/dev/null
        exit 0
      fi
      [[ "${extract_status}" -eq 0 ]] && echo 1 >> "${runner_success_file}"
    done

    [[ "${ext_using_own_batch}" = true ]] && zgu_batch_progress_close
    continue
  else
    # Toujours un runner en ligne à ce stade : dans cette boucle (mode interactif normal),
    # runner_name provient uniquement de la liste construite depuis la release GitHub
    # (source_by_name ne contient jamais que online_tag) -- le cas d'un runner local est géré
    # séparément, dans le sous-flux "browse_label" ci-dessus (ext_file_or_url_by_name).
    download_url="${file_or_url_by_name[${runner_name}]}"
    archive_path="${temp_dir}/${runner_name}.zgr"
    rm -f "${archive_path}"

    item_text=""
    if [[ "${runner_using_batch}" = true ]]; then
      item_text="$(t install_runner.batch_progress_item "${runner_idx}" "${runner_total_count}" "${runner_name}" "$(t install_runner.download_connecting)")"
    fi
    download_runner "${download_url}" "${archive_path}" "${runner_name}" "${size_by_name[${runner_name}]}" "${item_text}"

    if [[ ! -f "${archive_path}" ]] || [[ ! -s "${archive_path}" ]] || ! bsdtar -tf "${archive_path}" >/dev/null 2>&1; then
      zgu_gui_error "$(t install_runner.download_or_archive_invalid_gui "${runner_name}")"
      continue
    fi

    expected_digest="${digest_by_name[${runner_name}]}"

    # Avertissement non bloquant (même remarque que le mode CLI plus haut dans ce fichier) :
    # info et non erreur, l'installation se poursuit normalement juste après.
    if [[ -z "${expected_digest}" ]]; then
      zenity --info --text="$(t install_runner.checksum_missing_gui "${runner_name}")" 2>/dev/null
    fi

    if ! zgu_sha256_matches "${archive_path}" "${expected_digest}"; then
      zgu_gui_error "$(t install_runner.checksum_invalid_gui "${runner_name}")"
      rm -f "${archive_path}"
      continue
    fi
  fi

  item_text=""
  if [[ "${runner_using_batch}" = true ]]; then
    item_text="$(t install_runner.batch_progress_item "${runner_idx}" "${runner_total_count}" "${runner_name}" "$(t install_runner.extract_start_text)")"
  fi
  extract_runner_with_progress "${runner_name}" "${archive_path}" "${item_text}"
  extract_status=$?

  if [[ "${extract_status}" -eq 2 ]]; then
    # Annulé par l'utilisateur dans la barre de progression : ici on quitte complètement
    # (contrairement aux autres modes d'import où on passe simplement au runner suivant)
    [[ "${runner_using_batch}" = true ]] && zgu_batch_progress_close
    rm -f "${runner_success_file}"
    rm -rf "${temp_dir}"
    zenity --info --title="$(t install_runner.cancel_title)" --text="$(t install_runner.import_cancelled_text)" 2>/dev/null
    exit 0
  elif [[ "${extract_status}" -ne 0 ]]; then
    continue
  fi
  echo 1 >> "${runner_success_file}"
done

[[ "${runner_using_batch}" = true ]] && zgu_batch_progress_close
rm -rf "${temp_dir}"

# Notification finale reflétant le résultat RÉEL (même principe que zgp-game-installer.sh) :
# succès total, aucun, ou partiel plutôt qu'un succès annoncé sans condition.
runner_success_count=$(wc -l < "${runner_success_file}" 2>/dev/null)
rm -f "${runner_success_file}"
[[ -z "${runner_success_count}" ]] && runner_success_count=0

if [[ "${runner_success_count}" -eq "${runner_total_count}" ]] && [[ "${runner_total_count}" -gt 0 ]]; then
  notify-send "$(t install_runner.notify_title)" "$(t install_runner.notify_body_final)" 2>/dev/null
elif [[ "${runner_success_count}" -eq 0 ]]; then
  notify-send "$(t install_runner.notify_title_none)" "$(t install_runner.notify_body_none)" 2>/dev/null
else
  notify-send "$(t install_runner.notify_title_partial)" "$(t install_runner.notify_body_partial "${runner_success_count}" "${runner_total_count}")" 2>/dev/null
fi
exit 0
