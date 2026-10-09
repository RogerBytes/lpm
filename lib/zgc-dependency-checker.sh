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
# shellcheck source=./zgu-lsfg-utils.sh
source "${script_dir}/zgu-lsfg-utils.sh"

# --- Arguments passed by the lpm router ---
# $1 = mode (always "cli"; kept for positional consistency with other lib/ scripts)
# $2 = confirm_flag ("yes" if -y, same convention as zgc-wine-killer.sh): skips the only real
# question of this script (install the lsfg-vk Flatpak runtime?) so automated callers (GUI,
# scripts) are never blocked by an interactive prompt.
mode="${1:-cli}"
confirm_flag="${2:-}"

# Lutris paths
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# GITHUB_RELEASE_URL is defined in zgu-github-release-utils.sh; change the repo/release there.

say() {
  echo "$1"
}

# FD 3 = real script output (for "[PROGRESS]" from inside a pipe or command substitution, see
# zgp-game-installer.sh).
exec 3>&1

# Lines read by the GUI (see CommandPage.run_command / page_check):
#   "[STEP] <n> <total> <label>" = current check step (progress bar);
#   "[REPORT] <ok|warn|error>|<text>" = one line of the final summary shown in a window.
check_total_steps=5
step() {
  printf '[STEP] %s %s %s\n' "$1" "${check_total_steps}" "$2"
}
report() {
  printf '[REPORT] %s|%s\n' "$1" "$2"
}

say_err() {
  # Single point for all errors of this script: one "zgu_log" here is enough.
  zgu_log "zgc-dependency-checker" "ERREUR" "$1"
  report error "$1"
  echo "$1" >&2
}

# AntimicroX presence (maintained fork of "antimicro", see https://github.com/AntiMicroX/antimicrox):
# native binary under either name (the original "antimicro" is unmaintained but still installable
# on some distros), or the Flatpak "io.github.antimicrox.antimicrox" (id checked on Flathub).
# Presence only, like zgu_lsfg_vk_present: no version check.
zgu_antimicro_present() {
  command -v antimicrox >/dev/null 2>&1 && return 0
  command -v antimicro >/dev/null 2>&1 && return 0
  flatpak list --app --columns=application 2>/dev/null | grep -qx "io.github.antimicrox.antimicrox" && return 0
  return 1
}

# 1. Required dependencies check
step 1 "$(t check.step_tools)"
# bsdtar (libarchive-tools) replaces tar -I zstd to extract downloaded runners: its default
# ARCHIVE_EXTRACT_SECURE_NODOTDOT / _SYMLINKS protections reject archive members escaping the
# destination via "../" or a malicious symlink. bsdtar reads zstd natively, so no external zstd.
for cmd in sqlite3 python3 bsdtar sha256sum; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    say_err "$(t check.cmd_missing "${cmd}")"
    exit 1
  fi
done

# curl OR wget is required to query the runners GitHub release (section 5 below). Without this
# explicit check (as in zgr-runner-remote-lister.sh and zgr-runner-installer.sh), zgu_fetch_url
# would fail silently, release_json would stay empty and ALL missing runners would be reported as
# "unresolved" without hinting that the real cause is the missing network tool.
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  say_err "$(t check.network_tool_missing)"
  exit 1
fi

# PyYAML is required to read the wine.version key of installed games' YAML. Without it every game
# would silently be treated as needing no runner, making `lpm check` useless without any warning.
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  say_err "$(t check.pyyaml_missing)"
  exit 1
fi

# xdotool on an X11 session: optional (never blocking), but its absence silently degrades several
# things -- gamepad combos during play (alt-tab, quit game; see zgu-gamepad-alttab-watcher.py /
# zgu-gamepad-exit-watcher.py) and the real game-window detection of the loading-screen
# orchestrator (lib/zgl-launcher-orchestrator.sh), which then falls back to a fixed 12s wait.
# Gamepad navigation inside the picker does not use xdotool (read directly via SDL2).
# Not applicable on Wayland (xdotool does not work there; ydotool is the equivalent, already used
# where possible).
session_kind_check="x11"
if [[ "${XDG_SESSION_TYPE,,}" = "wayland" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  session_kind_check="wayland"
fi
if [[ "${session_kind_check}" = "x11" ]] && ! command -v xdotool >/dev/null 2>&1; then
  say "$(t check.xdotool_missing)"
  report warn "$(t check.report_xdotool_missing)"
fi
report ok "$(t check.report_tools_ok)"

step 2 "$(t check.step_lutris)"
# 2. Flatpak vs native Lutris detection (from zgu-lutris-utils.sh; also handles both being installed,
# see zgu_resolve_lutris_version)
lutris_version=$(zgu_resolve_lutris_version "${mode}" "${lutris_package_db}" "${lutris_package_runner_dir}")
if [[ -z "${lutris_version}" ]]; then
  say_err "$(t check.lutris_missing)"
  exit 1
fi
case "${lutris_version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    runner_dir="${lutris_flatpak_runner_dir}"
    ;;
  native)
    lutris_db="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    runner_dir="${lutris_package_runner_dir}"
    ;;
esac

if [[ ! -f "${lutris_db}" ]]; then
  say_err "$(t check.db_missing "${lutris_db}")"
  exit 1
fi

mkdir -p "${runner_dir}"
report ok "$(t check.report_lutris_ok "${lutris_version}")"

# ---------------------------------------------------------------------------------------------
# 3. Required runners of installed games (wine.version key of the YAML files)
# ---------------------------------------------------------------------------------------------

step 3 "$(t check.step_games)"
games_list=$(sqlite3 "${lutris_db}" "SELECT name || char(31) || slug || char(31) || configpath FROM games WHERE runner='wine';" 2>/dev/null)

declare -A games_needing_runner   # runner_name -> "game1, game2, ..."
required_runners=()

# Games referencing lsfg-vk (LSFGVK_ENV=1 in system.env) and/or AntimicroX (system.antimicro_config
# key, handled natively by Lutris) -- filled in the SAME loop as the required runner below, so
# each YAML is read once (one python3 per game, not three).
lsfg_games=()
antimicro_games=()

while IFS=$'\x1f' read -r game_name game_slug configpath; do
  [[ -z "${game_slug}" ]] && continue
  [[ -z "${configpath}" ]] && continue

  yml_path="${lutris_config_dir}/${configpath}.yml"
  [[ -f "${yml_path}" ]] || continue

  yml_fields=$(YML_PATH="${yml_path}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        wine_version = data.get("wine", {}).get("version", "")
        system = data.get("system") or {}
        env = system.get("env") or {}
        lsfg_on = "1" if str(env.get("LSFGVK_ENV", "")) == "1" else ""
        antimicro_on = "1" if system.get("antimicro_config") else ""
        print(f"{wine_version}\x1f{lsfg_on}\x1f{antimicro_on}")
except Exception:
    pass
' 2>/dev/null)

  IFS=$'\x1f' read -r required_runner lsfg_on antimicro_on <<< "${yml_fields}"

  [[ -n "${lsfg_on}" ]] && lsfg_games+=("${game_name}")
  [[ -n "${antimicro_on}" ]] && antimicro_games+=("${game_name}")

  [[ -z "${required_runner}" ]] && continue

  # Hardening, consistent with the filtering applied to "slug" in zgp-game-installer.sh:
  # required_runner (wine.version key) comes from the game's Lutris YAML, possibly from a third-party
  # .zgp and not validated at install time for this field. It is used below to build paths under
  # runner_dir (existence test, and rm -rf on extraction failure/cancellation), so a value like
  # "../../.." must be rejected here.
  case "${required_runner}" in
    */*|.|..)
      continue
      ;;
  esac

  if [[ -z "${games_needing_runner[${required_runner}]}" ]]; then
    games_needing_runner["${required_runner}"]="${game_name}"
    required_runners+=("${required_runner}")
  else
    games_needing_runner["${required_runner}"]="${games_needing_runner[${required_runner}]}, ${game_name}"
  fi
done <<< "${games_list}"

# ---------------------------------------------------------------------------------------------
# 3bis. lsfg-vk and AntimicroX check -- placed BEFORE the early "exit 0" of the runners section
# below: these dependencies are independent of runners, so this block must never be short-circuited
# by "no runner required"/"all runners present". Each one is only checked if at least one installed
# game references it (LSFGVK_ENV=1 for lsfg-vk, system.antimicro_config for AntimicroX).
# ---------------------------------------------------------------------------------------------

step 4 "$(t check.step_extras)"
if [[ ${#lsfg_games[@]} -gt 0 ]]; then
  lutris_is_flatpak_bool=false
  [[ "${lutris_version}" = "flatpak" ]] && lutris_is_flatpak_bool=true

  if zgu_lsfg_vk_present "${lutris_is_flatpak_bool}"; then
    report ok "$(t check.report_lsfg_ok)"
  else
    lsfg_game_list=$(IFS=', '; echo "${lsfg_games[*]}")

    t check.lsfg_missing_cli "${lsfg_game_list}"

    if [[ "${lutris_is_flatpak_bool}" = true ]]; then
      lsfg_runtime_version=$(zgu_lsfg_resolve_freedesktop_runtime_version)
      if [[ -z "${lsfg_runtime_version}" ]]; then
        say_err "$(t lsfg.flatpak_runtime_unknown)"
      else
        lsfg_do_install=false
        if [[ "${confirm_flag}" = "yes" ]]; then
          # -y already given at launch: this question is never asked.
          lsfg_do_install=true
        else
          t lsfg.install_flatpak_confirm_cli "${lsfg_runtime_version}"
          read -r -p "$(t lsfg.confirm_prompt_cli)" lsfg_response
          [[ "${lsfg_response}" =~ ^[oOyY] ]] && lsfg_do_install=true
        fi

        if [[ "${lsfg_do_install}" = true ]]; then
          lsfg_install_err=$(zgu_lsfg_install_flatpak_do "${lsfg_runtime_version}")
          if [[ $? -eq 0 ]]; then
            say "$(t check.lsfg_installed_success)"
            report ok "$(t check.lsfg_installed_success)"
          else
            say_err "$(t lsfg.flatpak_install_failed "${lsfg_install_err}")"
          fi
        else
          report warn "$(t check.report_lsfg_missing "${lsfg_game_list}")"
        fi
      fi
    else
      # Native: no automatic install possible (no universal lsfg-vk package), same limit as "lpm lsfg";
      # just point to where the instructions are.
      say "$(t check.lsfg_native_hint)"
      report warn "$(t check.report_lsfg_missing "${lsfg_game_list}")"
    fi
  fi
fi

if [[ ${#antimicro_games[@]} -gt 0 ]]; then
  if zgu_antimicro_present; then
    report ok "$(t check.report_antimicro_ok)"
  else
    antimicro_game_list=$(IFS=', '; echo "${antimicro_games[*]}")

    t check.antimicro_missing_cli "${antimicro_game_list}"
    report warn "$(t check.report_antimicro_missing "${antimicro_game_list}")"
  fi
fi

step 5 "$(t check.step_runners)"
if [[ ${#required_runners[@]} -eq 0 ]]; then
  say "$(t check.no_games_reference_runner)"
  report ok "$(t check.no_games_reference_runner)"
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# 4. Comparison with the runners actually installed
# ---------------------------------------------------------------------------------------------

missing_runners=()
for runner_name in "${required_runners[@]}"; do
  if [[ ! -d "${runner_dir}/${runner_name}" ]]; then
    missing_runners+=("${runner_name}")
  fi
done

if [[ ${#missing_runners[@]} -eq 0 ]]; then
  say "$(t check.all_runners_present)"
  report ok "$(t check.all_runners_present)"
  exit 0
fi

t check.missing_detected_header
for r in "${missing_runners[@]}"; do
  t check.missing_detected_item "${r}" "${games_needing_runner[${r}]}"
done
echo ""

# ---------------------------------------------------------------------------------------------
# 5. Single fetch of the release asset list (with size and SHA256 digest)
# ---------------------------------------------------------------------------------------------

declare -A release_asset_url     # runner_name (without .zgr) -> download URL
declare -A release_asset_size    # runner_name (without .zgr) -> size in bytes (for progress)
declare -A release_asset_digest  # runner_name (without .zgr) -> "sha256:<hash>" (empty if not provided by GitHub)

api_url=$(zgu_github_api_url "${GITHUB_RELEASE_URL}")
release_json=$(zgu_fetch_url "${api_url}")

if [[ -n "${release_json}" ]]; then
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
    release_asset_url["${asset_name%.zgr}"]="${download_url}"
    release_asset_digest["${asset_name%.zgr}"]="${asset_digest}"
    release_asset_size["${asset_name%.zgr}"]="${asset_size}"
  done <<< "${parsed_assets}"
fi

# ---------------------------------------------------------------------------------------------
# 6. Download and extraction functions with real progress bars
# ---------------------------------------------------------------------------------------------

download_cli() {
  local url="$1" runner_name="$2"
  local dest
  # No "-u": "-u" only picks a name without creating the file, leaving a window before wget/curl
  # writes in which another user could plant a symlink in /tmp (shared, world-writable) and redirect
  # the write to an arbitrary path (classic TOCTOU). Without "-u", mktemp atomically creates the file
  # under our own permissions before anything is downloaded into it.
  dest=$(mktemp "/tmp/${runner_name}-XXXXXX.zgr")

  t check.download_cli_start "${runner_name}"
  # Background download + file size polling: "[PROGRESS] <pct>" (0-50 % of this runner's bar;
  # extraction takes 50-100 %). Expected size: "size" field of the asset (GitHub API). Same
  # mechanism as zgr-runner-installer.sh.
  local expected_size="${release_asset_size[${runner_name}]:-0}"
  if command -v curl >/dev/null 2>&1; then
    curl -Lfs -o "${dest}" "${url}" &
  else
    wget -q -O "${dest}" "${url}" &
  fi
  local dl_pid=$! cur pct
  while kill -0 "${dl_pid}" 2>/dev/null; do
    if [[ "${expected_size}" =~ ^[0-9]+$ ]] && (( expected_size > 0 )); then
      cur=$(stat -c%s "${dest}" 2>/dev/null || echo 0)
      pct=$(( cur * 50 / expected_size ))
      (( pct > 50 )) && pct=50
      printf '[PROGRESS] %s\n' "${pct}" >&3
    fi
    sleep 0.3
  done
  wait "${dl_pid}" || rm -f "${dest}"

  if [[ ! -f "${dest}" ]] || [[ ! -s "${dest}" ]]; then
    rm -f "${dest}"
    return 1
  fi
  echo "${dest}"
}

# Checks the SHA256 of a downloaded archive against the GitHub release digest (computation in
# zgu_sha256_matches, see lib/zgu-github-release-utils.sh). Returns 0 if the check passes (or no
# digest is available for this asset), 1 if a digest is present but does not match.
verify_checksum() {
  local archive_path="$1" runner_name="$2"
  local expected_digest="${release_asset_digest[${runner_name}]}"

  if [[ -z "${expected_digest}" ]]; then
    # Non-blocking warning (extraction continues right after): say() rather than say_err() to avoid a
    # misleading "error" message -- no check failed, GitHub simply provided no digest for this asset.
    say "$(t check.checksum_missing "${runner_name}")"
  fi

  if ! zgu_sha256_matches "${archive_path}" "${expected_digest}"; then
    say_err "$(t check.checksum_invalid "${runner_name}")"
    return 1
  fi
  return 0
}

extract_cli() {
  local archive_path="$1" runner_name="$2"
  t check.extract_cli_start "${runner_name}"
  local archive_size
  archive_size=$(stat -c%s "${archive_path}" 2>/dev/null || stat -f%z "${archive_path}" 2>/dev/null)
  # umask 022 during extraction: same safeguard as zgp-game-installer.sh/zgr-runner-installer.sh
  # against a forged .zgr planting overly permissive files.
  local _lpm_old_umask
  _lpm_old_umask=$(umask)
  umask 022
  if command -v pv >/dev/null 2>&1; then
    pv -n -s "${archive_size:-0}" "${archive_path}" 2> >(while IFS= read -r pct; do
      printf '[PROGRESS] %s\n' "$(( 50 + ${pct:-0} / 2 ))" >&3
    done) | bsdtar -xf - -C "${runner_dir}"
    local tar_exit="${PIPESTATUS[1]}"
  else
    bsdtar -xf "${archive_path}" -C "${runner_dir}"
    local tar_exit=$?
  fi
  umask "${_lpm_old_umask}"
  [[ "${tar_exit}" -eq 0 ]] && [[ -d "${runner_dir}/${runner_name}" ]]
}

# ---------------------------------------------------------------------------------------------
# 7. Processing of each missing runner: remote lookup only, no local question
# ---------------------------------------------------------------------------------------------

resolved_runners=()
unresolved_runners=()
missing_total=${#missing_runners[@]}
missing_idx=0

for runner_name in "${missing_runners[@]}"; do
  missing_idx=$((missing_idx + 1))
  install_ok=false
  # "[n/total] ..." parsed by the GUI (shown after the current step).
  t check.runner_item_cli "${missing_idx}" "${missing_total}" "${runner_name}"

  if [[ -n "${release_asset_url[${runner_name}]}" ]]; then
    archive_path=$(download_cli "${release_asset_url[${runner_name}]}" "${runner_name}")

    if [[ -n "${archive_path}" ]]; then
      if verify_checksum "${archive_path}" "${runner_name}"; then
        extract_cli "${archive_path}" "${runner_name}" && install_ok=true
      fi
      rm -f "${archive_path}"
    fi
  fi

  if [[ "${install_ok}" = true ]]; then
    resolved_runners+=("${runner_name}")
    t check.runner_installed_success "${runner_name}"
    report ok "$(t check.report_runner_installed "${runner_name}")"
  else
    unresolved_runners+=("${runner_name}")
    # Structured line "runner|<name>|<games>": each frontend (GUI, terminal) builds its own sentence
    # (the GUI points to its pages, the terminal to "lpm install-runner").
    report runner "${runner_name}|${games_needing_runner[${runner_name}]}"
  fi
done

# ---------------------------------------------------------------------------------------------
# 8. Final summary
# ---------------------------------------------------------------------------------------------

if [[ ${#unresolved_runners[@]} -eq 0 ]]; then
  say "$(t check.all_resolved "${resolved_runners[*]}")"
  exit 0
fi

# Raw names block, one per line, for easy copy-paste
recap_names=""
for r in "${unresolved_runners[@]}"; do
  recap_names+="${r}
"
done

recap_details=""
for r in "${unresolved_runners[@]}"; do
  recap_details+="$(t check.unresolved_detail_item "${r}" "${games_needing_runner[${r}]}")
"
done

echo ""
echo "=== $(t check.unresolved_header_cli) ==="
echo "${recap_names}"
t check.detail_label
echo "${recap_details}"
t check.manual_install_hint

exit 0
