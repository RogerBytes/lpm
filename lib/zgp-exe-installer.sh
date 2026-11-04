#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-prefix-common.sh
source "${script_dir}/zgu-prefix-common.sh"

# --- lpm exe-install: create a prefix (like "blank prefix"), then run a Windows installer
# (.exe/.msi/.bat/.cmd) inside it, in the foreground, like the Lutris "Install a Windows
# executable" wizard:
#   - prefix initialisation identical to "blank prefix" (wineboot / umu-run createprefix, wait for
#     the .reg files);
#   - the file is run via "wine <file>" (regular runner) or "umu-run <file>" (Proton), without
#     redirecting stdout/stderr (Wine maps .msi to msiexec and .bat/.cmd to cmd.exe itself);
#   - non-zero exit code: offer to delete everything (as Lutris' "Remove game files");
#   - exit code 0: optional choice of the game's final .exe (file chooser opened in the prefix),
#     then write the yml + pga.db.
#
# $1 = mode (always "cli"; kept for consistency with the other lib/ scripts)
# $2 = confirm_flag ("yes" if -y; only the launch confirmation, never the deletion prompt on
#      failure, which is always asked)
# $3 = CLI target ("path/to/setup.exe" or "path/to/setup.exe|Custom name")
# $4+ = optional options after the target, so that an automated caller (GTK4 UI, scripts) can
# supply the choices up front and no interactive prompt blocks:
#   -r, --runner=<name>             runner to use (default: zgu_get_default_runner)
#   -a, --arch=<win32|win64>        prefix architecture (default: win64)
#   -f, --final-exe=<path|none>     installed game's final executable ("none" = none; the question
#                                    is never asked in CLI)
shift || true
confirm_flag="${1:-}"
shift || true
cli_target="${1:-}"
shift || true

cli_runner=""
cli_arch=""
cli_final_exe=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--runner)
      cli_runner="${2:-}"
      shift $(( $# >= 2 ? 2 : 1 ))
      ;;
    --runner=*)
      cli_runner="${1#--runner=}"
      shift
      ;;
    -a|--arch)
      cli_arch="${2:-}"
      shift $(( $# >= 2 ? 2 : 1 ))
      ;;
    --arch=*)
      cli_arch="${1#--arch=}"
      shift
      ;;
    -f|--final-exe)
      cli_final_exe="${2:-}"
      shift $(( $# >= 2 ? 2 : 1 ))
      ;;
    --final-exe=*)
      cli_final_exe="${1#--final-exe=}"
      shift
      ;;
    *)
      # Unrecognised argument: ignored rather than failing the whole script (same tolerance
      # as the rest of the lpm router).
      shift
      ;;
  esac
done

if [[ -n "${cli_arch}" ]] && [[ "${cli_arch}" != "win32" ]] && [[ "${cli_arch}" != "win64" ]]; then
  zgu_cli_error "$(t exe_install.invalid_arch_cli "${cli_arch}")"
  exit 1
fi

# 1. Dependency check
zgp_prefix_require_tools

# 2. Close Lutris first to release the DB
zgp_prefix_close_lutris

# 3. Flatpak vs native package detection (same as zgp-prefix-creator.sh)






zgp_prefix_setup_lutris

# 4. Runner and architecture choice (CLI only)
zgp_prefix_choose_runner

# 5. Installer file, display name and slug (CLI only)
exe_path=""
display_name=""
explicit_slug=""

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

exe_path="${exe_path/#\~/${HOME}}"

if [[ -z "${exe_path}" ]] || [[ ! -f "${exe_path}" ]]; then
  zgu_cli_error "$(t exe_install.exe_not_found_cli "${exe_path}")"
  exit 1
fi

if [[ -z "${display_name}" ]]; then
  zgu_cli_error "$(t create_prefix.no_names_error_cli)"
  exit 1
fi

# 6. Slug generation (dedup against pga.db only; one game at a time, no batch). A slug given
# after the 2nd "|" is always re-run through zgp_slugify, so a hand-edited value can never
# contain an invalid character.
zgp_prefix_load_existing_slugs

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
  zgu_cli_error "$(t exe_install.prefix_exists_cli "${prefix_dir}")"
  exit 1
fi

# 7. Confirmation (only for starting creation + installation; the deletion prompt on
# failure, further down, is always asked regardless of -y).
if [[ "${confirm_flag}" != "yes" ]]; then
  t exe_install.confirm_cli_header "${display_name}" "${final_slug}" "${exe_path}" "${runner_choice}" "${arch_choice}"
  read -r -p "$(t exe_install.confirm_cli_prompt)" response || response="n"  # EOF (no terminal) = cancel
  case "${response}" in
    ""|[oOyY]) : ;;
    *)
      t exe_install.cancelled_cli
      exit 0
      ;;
  esac
fi

# 8. Prefix initialisation (same as "blank prefix")

mkdir -p "${prefix_dir}"

t exe_install.init_progress_cli "${display_name}"

if [[ "${runner_type}" = "wine" ]]; then
  env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="winemenubuilder=" \
    "${runner_dir}/${runner_choice}/bin/wineboot" >/dev/null 2>&1
else
  env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" PROTONPATH="${runner_dir}/${runner_choice}" GAMEID="0" \
    "${umu_run_path}" createprefix >/dev/null 2>&1
fi

if ! zgp_wait_for_prefix "${prefix_dir}"; then
  zgu_cli_error "$(t exe_install.init_failed_cli)"
  rm -rf "${prefix_dir}"
  exit 1
fi

# 9. Run the installer in the foreground with a visible window, wait for it to close (like
# Lutris), then check its exit code.
if [[ "${runner_type}" = "wine" ]]; then
  env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" \
    "${runner_dir}/${runner_choice}/bin/wine" "${exe_path}"
  install_exit_code=$?
else
  env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" PROTONPATH="${runner_dir}/${runner_choice}" GAMEID="0" \
    "${umu_run_path}" "${exe_path}"
  install_exit_code=$?
fi

# 10. Non-zero exit code -> offer to delete everything (always asked, even with -y:
# destructive and irreversible).
if [[ "${install_exit_code}" -ne 0 ]]; then
  wants_delete=false
  t exe_install.error_delete_cli "${install_exit_code}"
  read -r -p "$(t exe_install.error_delete_prompt)" del_response
  case "${del_response}" in
    [oOyY]) wants_delete=true ;;
    *) wants_delete=false ;;
  esac

  if [[ "${wants_delete}" = true ]]; then
    rm -rf "${prefix_dir}"
    zgu_cli_ok "$(t exe_install.deleted_cli)"
    exit 0
  fi
  # Otherwise continue anyway (the user considers it worked despite the exit code).
fi

# 11. Optional selection of the installed game's final .exe (CLI only)
final_executable=""
if [[ -n "${cli_final_exe}" ]]; then
  # Explicit "none": no final executable, never ask.
  [[ "${cli_final_exe}" != "none" ]] && final_executable="${cli_final_exe}"
else
  t exe_install.pick_exe_cli
  read -r -p "$(t exe_install.pick_exe_prompt)" final_executable
fi

timestamp=$(date +%s%N)
config_id="${final_slug}-${timestamp}"
yml_config_file="${lutris_config_dir}/${config_id}.yml"
zgp_write_config_yml "${yml_config_file}" "${prefix_dir}" "${final_slug}" "${display_name}" "${runner_choice}" "${final_executable}"

zgp_register_game_row "${display_name}" "${final_slug}" "${final_executable}" "${prefix_dir}" "${config_id}"

# 13. Final summary
zgu_cli_ok "$(t exe_install.summary_done "${display_name}")"

# Best-effort update of the native Lutris media (banner/icon/cover art, see "lpm
# sync-media") for the newly installed game. Run in the background and detached ("&" +
# "disown"), as in zgp-game-installer.sh: purely cosmetic, so nothing waits on it, and a
# lutris.net network problem must never fail this command. Results are viewable via "lpm
# log".
bash "${script_dir}/zgp-game-sync-media.sh" "${final_slug}" >/dev/null 2>&1 3>&- </dev/null &
disown

exit 0