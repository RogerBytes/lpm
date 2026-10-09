#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

# --- Arguments passed by the lpm router ---
# $1 = confirmation flag ("yes" if -y)
# $2, $3, ... = runners to remove, given on the CLI
confirm_flag="${1:-}"
shift || true
cli_runners=("$@")

# Lutris runner paths
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# 1. Flatpak vs native Lutris detection (from zgu-lutris-utils.sh; also handles both being installed)
lutris_version=$(zgu_resolve_lutris_version "cli" "" "${lutris_package_runner_dir}")
if [[ -z "${lutris_version}" ]]; then
  # Explicit detection (as in zgr-runner-packer.sh): a silent fallback to the default native path
  # would give a misleading "folder not found" error later instead of the real cause (Lutris not
  # installed). Reuses the pack_runner.lutris_missing_* keys (same message).
  zgu_cli_error "$(t pack_runner.lutris_missing_cli)"
  exit 1
fi
case "${lutris_version}" in
  flatpak) runner_dir="${lutris_flatpak_runner_dir}" ;;
  native) runner_dir="${lutris_package_runner_dir}" ;;
  *) runner_dir="${HOME}/.local/share/lutris/runners/wine" ;;
esac

if [[ ! -d "${runner_dir}" ]]; then
  zgu_cli_error "$(t uninstall_runner.dir_missing_cli "${runner_dir}")"
  exit 1
fi

cd "${runner_dir}" || exit 1

declare -A path_by_runner
runners_to_delete=()

# 2. Runner selection: "lpm uninstall-runner" always requires names on the command line.
# No arguments: explicit error (not a false "completed successfully").
if [[ ${#cli_runners[@]} -eq 0 ]]; then
  zgu_cli_error "$(t common.missing_target_cli "lpm uninstall-runner")"
  exit 1
fi

missing=()

for target_runner_raw in "${cli_runners[@]}"; do
  # basename() neutralizes path traversal ("../", absolute path) in a CLI runner name; otherwise
  # "lpm uninstall-runner ../../Games/x" could point r_path outside runner_dir and trigger an
  # rm -rf on an arbitrary folder.
  target_runner_arg=$(basename -- "${target_runner_raw}")
  r_path="${runner_dir}/${target_runner_arg}"
  if [[ ! -d "${r_path}" ]]; then
    missing+=("${target_runner_raw}")
    continue
  fi
  runners_to_delete+=("${target_runner_arg}")
  path_by_runner["${target_runner_arg}"]="${r_path}"
done

# Strict check: any missing runner aborts everything, nothing is removed
if [[ ${#missing[@]} -gt 0 ]]; then
  zgu_cli_error "$(t uninstall_runner.missing_cli_header "${runner_dir}")"
  for name in "${missing[@]}"; do
    zgu_cli_error "$(t uninstall_runner.missing_cli_item "${name}")"
  done
  zgu_cli_error "$(t uninstall_runner.missing_cli_footer)"
  exit 1
fi

# Interactive confirmation unless -y
if [[ "${confirm_flag}" != "yes" ]]; then
  t uninstall_runner.confirm_cli_header
  for name in "${runners_to_delete[@]}"; do
    t uninstall_runner.confirm_cli_item "${name}" "${path_by_runner[${name}]}"
  done
  read -r -p "$(t uninstall_runner.confirm_cli_prompt)" response || response="n"  # EOF (no terminal) = cancel, never an implicit confirmation
  case "${response}" in
    [nN])
      t uninstall_runner.confirm_cli_cancelled
      exit 0
      ;;
    *)
      ;;
  esac
fi

# 3. Removal (plain text output)
total_runners=${#runners_to_delete[@]}

# Cancellation (SIGTERM/SIGINT sent by the GUI to the script process only, not its children): the
# runner being removed is finished normally (never a half-deleted folder), then the script stops
# before the next one. Exit code 130.
cancel_requested=0
trap 'cancel_requested=1' TERM INT

current=0
for runner in "${runners_to_delete[@]}"; do
  if [[ "${cancel_requested}" -eq 1 ]]; then
    echo "[CANCELLED]"
    t uninstall_runner.cancelled_run_cli
    exit 130
  fi
  current=$((current + 1))
  t uninstall_runner.progress_cli "${current}" "${total_runners}" "${runner}"

  r_path="${path_by_runner[${runner}]}"
  if [[ -d "${r_path}" ]]; then
    rm -rf "${r_path}"
  fi
  printf '[REMOVED] %s\n' "${runner}"
done

zgu_cli_ok "$(t uninstall_runner.done_cli)"

exit 0
