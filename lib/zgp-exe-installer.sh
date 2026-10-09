#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

# --- lpm exe-install: create a prefix (like "blank prefix"), then run a Windows
# installer (.exe/.msi/.bat/.cmd) inside it, in the foreground and waiting for it to
# close, like the Lutris "Install a Windows executable" wizard:
#   - prefix initialisation identical to "blank prefix" (wineboot / umu-run
#     createprefix, wait for the .reg files)
#   - the file is run via "wine <file>" (regular runner) or "umu-run <file>" (Proton),
#     without redirecting stdout/stderr. Wine natively maps .msi -> msiexec and
#     .bat/.cmd -> cmd.exe, so the file is passed directly whatever its type.
#   - non-zero exit code -> offer to delete everything (same as Lutris "Remove game
#     files" on failure, see lutris/gui/installerwindow.py)
#   - exit code 0 -> optional selection of the installed game's final .exe (file chooser
#     opened in the prefix), then write the yml + pga.db
#
# $1 = mode (always "cli"; kept only so the positional layout matches the other lib/
#      scripts, its value is not read here)
# $2 = confirm_flag ("yes" if -y; applies only to the launch confirmation, never to the
#      deletion prompt on failure, which is always asked)
# $3 = CLI target ("path/to/setup.exe" or "path/to/setup.exe|Custom name")
# $4+ = optional options after the CLI target (defaults apply when absent). They let an
# automated caller (GTK4 UI, scripts...) supply these choices up front so that no
# interactive prompt blocks execution:
#   -r, --runner=<name>             runner to use (default: zgu_get_default_runner)
#   -a, --arch=<win32|win64>        prefix architecture (default: win64)
#   -f, --final-exe=<path|none>     installed game's final executable ("none" = none, and
#                                    the question is never asked in CLI)
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
for cmd in sqlite3 python3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    t create_prefix.cmd_missing "${cmd}"
    exit 1
  fi
done

if ! python3 -c "import yaml" >/dev/null 2>&1; then
  zgu_cli_error "$(t create_prefix.pyyaml_missing_cli)"
  exit 1
fi

# 2. Close Lutris first to release the DB
if flatpak list 2>/dev/null | grep -q lutris; then
  flatpak kill net.lutris.Lutris 2>/dev/null
fi
pkill -9 -x lutris 2>/dev/null
pkill -9 -f "/usr/bin/lutris" 2>/dev/null

# 3. Flatpak vs native package detection (same as zgp-prefix-creator.sh)
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

version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "${lutris_package_runner_dir}")
if [[ -z "${version}" ]]; then
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
  zgu_cli_error "$(t create_prefix.no_runners_found_cli "${runner_dir}")"
  exit 1
fi

# --- Runner type detection / usable runners list / umu-run lookup / slugification: same as
# zgp-prefix-creator.sh ---
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

# 4. Runner and architecture choice (CLI only)
runner_choice="${cli_runner:-$(zgu_get_default_runner)}"
arch_choice="${cli_arch:-win64}"

runner_type=$(zgp_detect_runner_type "${runner_dir}/${runner_choice}")
if [[ "${runner_type}" = "unknown" ]]; then
  zgu_cli_error "$(t create_prefix.unknown_runner_type_cli "${runner_choice}")"
  exit 1
fi

umu_run_path=""
if [[ "${runner_type}" = "proton" ]]; then
  if ! umu_run_path=$(zgp_find_umu_run); then
    zgu_cli_error "$(t create_prefix.umu_missing_cli)"
    exit 1
  fi
fi

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

# 12. Write the yml + insert into the DB (same as "blank prefix")
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

# 13. Final summary
zgu_cli_ok "$(t exe_install.summary_done "${display_name}")"

# Best-effort update of the native Lutris media (banner/icon/cover art, see "lpm
# sync-media") for the newly installed game. Run in the background and detached ("&" +
# "disown"), as in zgp-game-installer.sh: purely cosmetic, so nothing waits on it, and a
# lutris.net network problem must never fail this command. Results are viewable via "lpm
# log".
bash "${script_dir}/zgp-game-sync-media.sh" "${final_slug}" >/dev/null 2>&1 &
disown

exit 0