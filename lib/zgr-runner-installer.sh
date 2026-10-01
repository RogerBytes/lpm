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
# shellcheck source=./zgu-hash-utils.sh
source "${script_dir}/zgu-hash-utils.sh"

# --- Analyse des arguments transmis par bin/lpm ---
# $1 = mode (toujours "cli" désormais : bin/lpm n'a plus aucun point d'entrée interactif --
#      conservé en position pour rester cohérent avec les autres scripts de lib/, mais sa
#      valeur n'est plus lue ici)
# $2 = confirm_flag ("yes" si -y)
# $3 = ignore_hash_flag ("yes" si --ignore-hash)
# $4, $5... = cibles (fichiers .zgr ou noms distants)
shift || true
confirm_flag="${1:-}"
shift || true
ignore_hash_flag="${1:-}"
shift || true
cli_targets=("$@")

# zgr_hash_filter <nameref tableau de noms> <nameref tableau assoc chemin par nom>
# Vérifie le sidecar sha256 (s'il existe) de chaque runner LOCAL du tableau donné (voir
# zgu-hash-utils.sh) et retire du tableau, en place, ceux dont le hash ne correspond pas --
# sauf si l'utilisateur choisit explicitement de les installer quand même, ou si
# --ignore-hash a été passé (auquel cas la vérification est entièrement sautée). Un runner
# sans sidecar n'est jamais considéré comme invalide (voir zgu_find_hash_sidecar).
zgr_hash_filter() {
  local -n names_ref="$1"
  local -n paths_ref="$2"

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

# 1. Vérification de bsdtar
# bsdtar (paquet "libarchive-tools" sur Debian/Ubuntu) remplace tar -I zstd pour l'extraction :
# ses protections par défaut ARCHIVE_EXTRACT_SECURE_NODOTDOT / ARCHIVE_EXTRACT_SECURE_SYMLINKS
# refusent tout membre d'archive tentant de sortir de son dossier de destination via "../" ou
# un lien symbolique piégé -- important ici puisqu'un .zgr peut être téléchargé depuis GitHub
# OU partagé/importé localement (voir mode "browse"), donc potentiellement non fiable dans les
# deux cas. bsdtar lit le zstd nativement (libzstd liée en dur), zstd externe n'est donc plus
# nécessaire pour ce script.
if ! command -v bsdtar >/dev/null 2>&1; then
  zgu_cli_error "$(t install_runner.bsdtar_missing_fallback)"
  exit 1
fi

if ! command -v pv >/dev/null 2>&1; then
  zgu_cli_error "$(t install_runner.pv_missing_fallback)"
  exit 1
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  zgu_cli_error "$(t install_runner.sha256sum_missing_fallback)"
  exit 1
fi

# 2. Détection Flatpak vs Paquet natif pour les runners (fonction fournie par
# zgu-lutris-utils.sh -- résout aussi le cas des deux installées en même temps)
version=$(zgu_resolve_lutris_version "cli" "" "${lutris_package_runner_dir}")
if [[ -z "${version}" ]]; then
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

# ---------------------------------------------------------------------------------------------
# bin/lpm n'a plus aucun point d'entrée interactif : ce script ne traite donc plus que des
# cibles explicites données en ligne de commande (fichiers .zgr locaux et/ou noms distants
# GitHub) -- l'ancien mode double-clic (scan du dossier parent) et l'ancien menu interactif
# (liste en ligne + "Parcourir...") ont été retirés, avec les fonctions zenity dédiées
# (download_runner/extract_runner_with_progress) qu'ils étaient seuls à utiliser.
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
    zgr_hash_filter local_names_for_hash runner_archive
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
