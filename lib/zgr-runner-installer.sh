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

# FD 3 = copy of the real stdout, taken before any pipe; needed for "[PROGRESS] <pct>" below
# (see "exec 3>&1" in zgp-game-installer.sh).
exec 3>&1

# --- Arguments passed by bin/lpm ---
# $1 = mode (always "cli"; kept for positional consistency with other lib/ scripts, not read here)
# $2 = confirm_flag ("yes" if -y)
# $3 = ignore_hash_flag ("yes" if --ignore-hash)
# $4, $5... = targets (.zgr files or remote names)
shift || true
confirm_flag="${1:-}"
shift || true
ignore_hash_flag="${1:-}"
shift || true
cli_targets=("$@")

# zgr_hash_filter <nameref names array> <nameref assoc array: path by name>
# Checks the sha256 sidecar (if any) of each LOCAL runner in the array (see zgu-hash-utils.sh) and
# removes from the array, in place, those whose hash does not match -- unless the user chooses to
# install them anyway, or --ignore-hash was passed (check skipped entirely). A runner without a
# sidecar is never considered invalid (see zgu_find_hash_sidecar).
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

# Lutris runner paths
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# GITHUB_RELEASE_URL is defined in zgu-github-release-utils.sh; change the repo/release there.

# 1. bsdtar check
# bsdtar (libarchive-tools) is used instead of tar -I zstd: its default
# ARCHIVE_EXTRACT_SECURE_NODOTDOT / _SYMLINKS protections reject archive members escaping the
# destination via "../" or a malicious symlink. A .zgr may be downloaded or imported locally, so it
# is untrusted. bsdtar reads zstd natively, so no external zstd is needed.
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

# 2. Flatpak vs native Lutris detection (from zgu-lutris-utils.sh; also handles both being installed)
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
    # Should never happen: $version is only set to "flatpak" or "package" above (else exit 1).
    echo "Erreur interne : version Lutris inattendue '${version}'." >&2
    exit 1
    ;;
esac

mkdir -p "${lutris_runner_dir}"

# ---------------------------------------------------------------------------------------------
# Only explicit command-line targets are handled (local .zgr files and/or remote GitHub names).
# No arguments: explicit error (not a silent exit 0).
if [[ ${#cli_targets[@]} -eq 0 ]]; then
  zgu_cli_error "$(t common.missing_target_cli "lpm install-runner")"
  exit 1
fi

declare -A runner_source   # "local" or "distant"
  declare -A runner_archive  # local path, or targeted file name for remote
  runners_to_install=()
  conflicts=()

  for target in "${cli_targets[@]}"; do
    if [[ -f "${target}" ]]; then
      runner_name=$(basename -- "${target}" .zgr)
      runner_source["${runner_name}"]="local"
      runner_archive["${runner_name}"]="${target}"
    else
      # basename() neutralizes path traversal ("../", absolute path) before runner_dir/runner_name are
      # built below, consistent with the other CLI targets.
      runner_name=$(basename -- "${target%.zgr}")
      runner_source["${runner_name}"]="distant"
      runner_archive["${runner_name}"]="${runner_name}.zgr"
    fi

    if [[ -d "${lutris_runner_dir}/${runner_name}" ]]; then
      conflicts+=("${runner_name}")
    fi

    runners_to_install+=("${runner_name}")
  done

  # Strict check: if ANY requested runner is already installed, abort without installing anything
  if [[ ${#conflicts[@]} -gt 0 ]]; then
    zgu_cli_error "$(t install_runner.conflict_header_cli)"
    for name in "${conflicts[@]}"; do
      zgu_cli_error "$(t install_runner.conflict_item_cli "${name}")"
    done
    zgu_cli_error "$(t install_runner.conflict_hint_cli)"
    exit 1
  fi

  # Integrity check (sha256 sidecar, see zgu-hash-utils.sh): only LOCAL runners can have a sidecar
  # (remote ones are verified later via the digest from the GitHub API).
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

  # Interactive confirmation unless -y
  if [[ "${confirm_flag}" != "yes" ]]; then
    t install_runner.confirm_cli_header
    for name in "${runners_to_install[@]}"; do
      if [[ "${runner_source[${name}]}" = "local" ]]; then
        t install_runner.confirm_cli_item_local "${name}" "${runner_archive[${name}]}"
      else
        t install_runner.confirm_cli_item_remote "${name}"
      fi
    done
    read -r -p "$(t install_runner.confirm_cli_prompt)" response || response="n"  # EOF (no terminal) = cancel, never an implicit confirmation
    case "${response}" in
      [nN])
        t install_runner.cancelled_cli
        exit 0
        ;;
      *)
        ;;
    esac
  fi

  # Fetch the GitHub release info once if at least one remote runner is requested
  release_json=""
  for name in "${runners_to_install[@]}"; do
    if [[ "${runner_source[${name}]}" = "distant" ]]; then
      api_url=$(zgu_github_api_url "${GITHUB_RELEASE_URL}")
      release_json=$(zgu_fetch_url "${api_url}")
      break
    fi
  done

  # Computed BEFORE the loop to display "[n/total]" during installation.
  runner_total_count=${#runners_to_install[@]}
  runner_idx=0
  install_failures=0

  # --- Cancellation (SIGTERM/SIGINT sent by the GUI "Cancel" button to the whole process group):
  # removes the temporary download and the half-extracted runner. Runners already completed are
  # untouched (the GUI offers to remove them, see "[INSTALLED]" lines). Exit code 130. ---
  temp_cli_dir=""
  inprogress_dir=""
  lpm_cancel_cleanup() {
    trap '' TERM INT
    if [[ -n "${temp_cli_dir}" ]] && [[ "${temp_cli_dir}" == "${TMPDIR:-/tmp}"/* ]]; then
      rm -rf -- "${temp_cli_dir}"
    fi
    if [[ -n "${inprogress_dir}" ]] && [[ "${inprogress_dir}" == "${lutris_runner_dir}/"* ]]; then
      rm -rf -- "${inprogress_dir}"
    fi
    echo "[CANCELLED]"
    t install_runner.cancelled_run_cli
    exit 130
  }
  trap lpm_cancel_cleanup TERM INT

  for runner_name in "${runners_to_install[@]}"; do
    runner_idx=$((runner_idx + 1))
    src="${runner_source[${runner_name}]}"

    expected_digest=""

    if [[ "${src}" = "local" ]]; then
      archive_path="${runner_archive[${runner_name}]}"
      t install_runner.installing_local_cli "${runner_name}"
    else
      target_filename="${runner_archive[${runner_name}]}"
      # Emit "[n/total] ..." at the START of the runner (before download) so the GUI shows
      # "n / total - name" immediately (see CommandPage.run_command).
      t install_runner.download_progress_cli "${runner_idx}" "${runner_total_count}" "${runner_name}"
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
            size = asset.get("size") or 0
            print(f"{url}\x1f{digest}\x1f{size}")
            break
except Exception:
    pass
' "${release_json}" "${target_filename}")
        IFS=$'\x1f' read -r download_url expected_digest asset_size <<< "${asset_info}"
      fi

      if [[ -z "${download_url}" ]]; then
        zgu_cli_error "$(t install_runner.remote_not_found_cli "${target_filename}")"
        install_failures=$((install_failures + 1))
        continue
      fi

      temp_cli_dir=$(mktemp -d)
      archive_path="${temp_cli_dir}/${target_filename}"

      t install_runner.downloading_cli "${runner_name}"
      # Background download + file size polling: "[PROGRESS] <pct>" (0-50 % of this runner's bar;
      # extraction takes 50-100 %). Expected size comes from the GitHub API asset "size".
      if command -v curl >/dev/null 2>&1; then
        curl -Lfs -o "${archive_path}" "${download_url}" &
      else
        wget -q -O "${archive_path}" "${download_url}" &
      fi
      _lpm_dl_pid=$!
      while kill -0 "${_lpm_dl_pid}" 2>/dev/null; do
        if [[ "${asset_size:-0}" =~ ^[0-9]+$ ]] && (( asset_size > 0 )); then
          _lpm_cur=$(stat -c%s "${archive_path}" 2>/dev/null || echo 0)
          _lpm_pct=$(( _lpm_cur * 50 / asset_size ))
          (( _lpm_pct > 50 )) && _lpm_pct=50
          printf '[PROGRESS] %s\n' "${_lpm_pct}" >&3
        fi
        sleep 0.3
      done
      wait "${_lpm_dl_pid}" || rm -f "${archive_path}"

      if [[ ! -f "${archive_path}" ]] || [[ ! -s "${archive_path}" ]]; then
        zgu_cli_error "$(t install_runner.download_failed_cli "${runner_name}")"
        rm -rf "${temp_cli_dir}"
        install_failures=$((install_failures + 1))
        continue
      fi

      # Non-blocking warning: GitHub does not always provide a digest per asset. Without it no integrity
      # check is possible (zgu_sha256_matches then returns success by convention).
      if [[ -z "${expected_digest}" ]]; then
        zgu_cli_error "$(t install_runner.checksum_missing_cli "${runner_name}")"
      fi

      if ! zgu_sha256_matches "${archive_path}" "${expected_digest}"; then
        zgu_cli_error "$(t install_runner.checksum_invalid_cli "${runner_name}")"
        rm -rf "${temp_cli_dir}"
        install_failures=$((install_failures + 1))
        continue
      fi
    fi

    # "[n/total] ..." is parsed by the GUI (CommandPage.run_command), same convention as
    # zgp-game-installer.sh/zgp-game-uninstaller.sh. Remote runner: already emitted before the download.
    [[ "${src}" = "local" ]] && t install_runner.progress_cli "${runner_idx}" "${runner_total_count}" "${runner_name}"
    archive_size=$(stat -c%s "${archive_path}" 2>/dev/null || stat -f%z "${archive_path}" 2>/dev/null)
    # bsdtar rather than tar -I zstd: see the dependency check above.
    # umask 022 during extraction: guards against a forged .zgr planting overly permissive (777) or
    # unreadable (000) files, as in zgp-game-installer.sh.
    inprogress_dir="${lutris_runner_dir}/${runner_name}"
    _lpm_old_umask=$(umask)
    umask 022
    # "pv -n" + process substitution on stderr: same mechanism as in zgp-game-installer.sh.
    pv -n -s "${archive_size:-0}" "${archive_path}" 2> >(while IFS= read -r _lpm_pct; do
      # Remote: extraction takes the 2nd half of the bar (50-100 %).
      [[ "${src}" = "distant" ]] && _lpm_pct=$(( 50 + ${_lpm_pct:-0} / 2 ))
      printf '[PROGRESS] %s\n' "${_lpm_pct}" >&3
    done) | bsdtar -xf - -C "${lutris_runner_dir}"
    tar_exit="${PIPESTATUS[1]}"
    umask "${_lpm_old_umask}"

    [[ "${src}" = "distant" ]] && rm -rf "${temp_cli_dir}" && temp_cli_dir=""

    # Check extraction integrity: if tar failed (corrupt/truncated/invalid archive), clean up what was
    # extracted and move on to the next runner
    if [[ "${tar_exit}" -ne 0 ]]; then
      zgu_cli_error "$(t install_runner.corrupt_archive_cli "${runner_name}" "${tar_exit}")"
      rm -rf "${lutris_runner_dir:?}/${runner_name}"
      inprogress_dir=""
      install_failures=$((install_failures + 1))
      continue
    fi
    inprogress_dir=""
    printf '[INSTALLED] %s\n' "${runner_name}"

    zgu_cli_ok "$(t install_runner.install_success_cli "${runner_name}")"
  done

  # Non-zero exit if at least one runner failed: the GUI only shows "installed" on exit code 0.
  [[ "${install_failures}" -gt 0 ]] && exit 1
  exit 0
