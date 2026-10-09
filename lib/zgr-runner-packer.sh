#!/bin/bash

# --- Arguments passed by the lpm router ---
# $1 = optional compression level (e.g. "5" or empty)
# $2 = generate_hash_flag ("yes" if --hash)
# $3, $4, ... = target runners given on the CLI
compression_arg="${1:-}"
shift || true
generate_hash_flag="${1:-}"
shift || true
cli_runners=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-hash-utils.sh
source "${script_dir}/zgu-hash-utils.sh"

# --hash alone decides whether a sha256 sidecar is generated (no interactive prompt exists).
GENERATE_HASH=false
[[ "${generate_hash_flag}" = "yes" ]] && GENERATE_HASH=true

# Lutris runner paths
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

OUTPUT_DIR="${HOME}"

# 1. zstd check (always required)
if ! command -v zstd >/dev/null 2>&1; then
  zgu_cli_error "$(t pack_runner.zstd_missing)"
  exit 1
fi

# 2. Flatpak vs native Lutris detection (from zgu-lutris-utils.sh; also handles both being installed)
lutris_version=$(zgu_resolve_lutris_version "cli" "" "${lutris_package_runner_dir}")
if [[ -z "${lutris_version}" ]]; then
  # Explicit detection: a silent fallback to the default native path would give a misleading
  # "folder not found" error later instead of the real cause (Lutris not installed).
  zgu_cli_error "$(t pack_runner.lutris_missing_cli)"
  exit 1
fi
case "${lutris_version}" in
  flatpak) runner_dir="${lutris_flatpak_runner_dir}" ;;
  native) runner_dir="${lutris_package_runner_dir}" ;;
esac

if [[ ! -d "${runner_dir}" ]]; then
  zgu_cli_error "$(t pack_runner.dir_missing_cli "${runner_dir}")"
  exit 1
fi

cd "${runner_dir}" || exit 1

# --all: replaces the single "--all" argument with the sorted list of all runner folders on disk
# (nullglob + sort). Each name necessarily exists, so the [[ -d ... ]] check always passes; only the
# conflict check (existing .zgr archive) still applies.
if [[ ${#cli_runners[@]} -eq 1 ]] && [[ "${cli_runners[0]}" = "--all" ]]; then
  shopt -s nullglob
  all_runner_dirs=( */ )
  shopt -u nullglob
  mapfile -t all_sorted_runners < <(printf '%s\n' "${all_runner_dirs[@]}" | sed 's#/$##' | sort)
  if [[ ${#all_sorted_runners[@]} -eq 0 ]]; then
    zgu_cli_error "$(t pack_runner.no_runner_found "${runner_dir}")"
    exit 1
  fi
  cli_runners=("${all_sorted_runners[@]}")
fi

declare -A path_by_runner
runners_to_export=()

# 3. Runner selection: "lpm pack-runner" always requires names (or "--all") on the command line.
# No arguments: explicit error (not a false "completed successfully").
if [[ ${#cli_runners[@]} -eq 0 ]]; then
  zgu_cli_error "$(t common.missing_target_cli "lpm pack-runner")"
  exit 1
fi

LEVEL="${compression_arg:-3}"
missing=()
conflicts=()

for target_runner_raw in "${cli_runners[@]}"; do
  # basename() neutralizes path traversal ("../", absolute path) in a CLI runner name; otherwise a
  # name like "../../home/user/.ssh" could make an arbitrary system folder be read and archived.
  target_runner_arg=$(basename -- "${target_runner_raw}")
  if [[ ! -d "${runner_dir}/${target_runner_arg}" ]]; then
    missing+=("${target_runner_raw}")
    continue
  fi

  archive_path="${OUTPUT_DIR}/${target_runner_arg}.zgr"
  if [[ -f "${archive_path}" ]]; then
    conflicts+=("${target_runner_arg}")
  fi

  runners_to_export+=("${target_runner_arg}")
  path_by_runner["${target_runner_arg}"]="${runner_dir}/${target_runner_arg}"
done

# Strict check: any missing runner or already existing package aborts everything, nothing is exported
if [[ ${#missing[@]} -gt 0 ]] || [[ ${#conflicts[@]} -gt 0 ]]; then
  if [[ ${#missing[@]} -gt 0 ]]; then
    zgu_cli_error "$(t pack_runner.missing_header_cli "${runner_dir}")"
    for name in "${missing[@]}"; do
      zgu_cli_error "$(t pack_runner.missing_item_cli "${name}")"
    done
  fi
  if [[ ${#conflicts[@]} -gt 0 ]]; then
    zgu_cli_error "$(t pack_runner.conflict_header_cli "${OUTPUT_DIR}")"
    for name in "${conflicts[@]}"; do
      zgu_cli_error "$(t pack_runner.conflict_item_cli "${name}")"
    done
    zgu_cli_error "$(t pack_runner.conflict_hint)"
  fi
  zgu_cli_error "$(t pack_runner.nothing_exported)"
  exit 1
fi

# 4. Compression handling
cd "${runner_dir}" || exit 1

# FD 3 = real script output (for "[PROGRESS]" from inside the pipe).
exec 3>&1

# --- Cancellation (SIGTERM/SIGINT sent by the GUI "Cancel" button to the whole process group):
# removes the half-written .zgr archive of the current runner (and its hash file, if any).
# Archives already completed are untouched (the GUI offers to remove them, see "[EXPORTED]" lines).
# Exit code 130. ---
inprogress_archive=""
lpm_cancel_cleanup() {
  trap '' TERM INT
  [[ -n "${inprogress_archive}" ]] && rm -f -- "${inprogress_archive}" \
    "${OUTPUT_DIR}/hash/$(basename -- "${inprogress_archive}").sha256"
  echo "[CANCELLED]"
  t pack_runner.cancelled_run_cli
  exit 130
}
trap lpm_cancel_cleanup TERM INT
total_runners=${#runners_to_export[@]}
current=0

for runner in "${runners_to_export[@]}"; do
  current=$((current + 1))
  r_path="${path_by_runner[${runner}]}"

  ARCHIVE_NAME="${runner}"
  archive_path="${OUTPUT_DIR}/${ARCHIVE_NAME}.zgr"

  # Compression command as an array (not a single string): "zstd '--ultra -22'" passed ONE argument
  # that zstd rejected, so levels 20-22 always failed.
  if [[ "${LEVEL}" -gt 19 ]]; then
    zstd_args=(--ultra "-${LEVEL}")
  else
    zstd_args=("-${LEVEL}")
  fi

  # pv + zstd, text progress bar
  t pack_runner.compressing_cli "${current}" "${total_runners}" "${ARCHIVE_NAME}" "${LEVEL}"

  inprogress_archive="${archive_path}"
  source_size=$(du -sb "${r_path}" 2>/dev/null | cut -f1)
  [[ -z "${source_size}" ]] && source_size=0

  if command -v pv >/dev/null 2>&1; then
    # "pv -n" -> "[PROGRESS] <pct>" on FD 3 (real script output, see zgp-game-packer.sh); capped at
    # 100 because tar adds its headers.
    tar -C "${runner_dir}" -cf - "${runner}" | pv -n -s "${source_size}" 2> >(while IFS= read -r _lpm_pct; do
      [[ "${_lpm_pct}" =~ ^[0-9]+$ ]] || continue
      (( _lpm_pct > 100 )) && _lpm_pct=100
      printf '[PROGRESS] %s\n' "${_lpm_pct}" >&3
    done) | zstd "${zstd_args[@]}" > "${archive_path}"
    tar_exit="${PIPESTATUS[0]}"
  else
    tar -C "${runner_dir}" -cf - "${runner}" | zstd "${zstd_args[@]}" > "${archive_path}"
    tar_exit="${PIPESTATUS[0]}"
  fi

  if [[ "${tar_exit}" -ne 0 ]] || [[ ! -s "${archive_path}" ]]; then
    zgu_cli_error "$(t pack_runner.compression_failed_cli "${ARCHIVE_NAME}")"
    rm -f "${archive_path}"
    exit 1
  fi

  # Owner-only permissions, consistent with zgp-game-packer.sh.
  chmod 600 "${archive_path}"

  if [[ "${GENERATE_HASH}" = true ]]; then
    zgu_write_hash_sidecar "${archive_path}" "${OUTPUT_DIR}"
  fi

  inprogress_archive=""
  printf '[EXPORTED] %s\n' "${archive_path}"
  zgu_cli_ok "$(t pack_runner.done_cli "${archive_path}")"
done

zgu_cli_ok "$(t pack_runner.cli_done)"
exit 0
