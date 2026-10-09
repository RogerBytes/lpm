#!/bin/bash

# --- lpm lutris-version ---
#
# Shows the Lutris versions detected on the machine (Flatpak / native package) with their version
# number and an up-to-date/outdated status, and lets the user force/reset the choice lpm uses when
# both are installed (see zgu_resolve_lutris_version in zgu-lutris-utils.sh, which applies the saved
# choice silently on every run). This command ONLY displays/configures: the effective resolution
# used by other lpm commands stays centralized there.

# --- Arguments passed by the lpm router ---
# $1 = mode (always "cli")
# $2 = optional subcommand: "flatpak", "native", "reset", or empty (display only)
sub_arg="${2:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

say() {
  echo "$1"
}

say_err() {
  zgu_log "zgc-lutris-version-checker" "ERREUR" "$1"
  echo "$1" >&2
}

# --- 1. Detection of actual installations (same paths as the other commands) ---
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

has_flatpak=false
has_native=false
check_flatpak_lutris_installed && has_flatpak=true
check_native_lutris_installed "${lutris_package_db}" "${lutris_package_runner_dir}" && has_native=true

if [[ "${has_flatpak}" = false ]] && [[ "${has_native}" = false ]]; then
  say_err "$(t lutris_version.none_found)"
  exit 1
fi

# --- 2. Installed version number, per method ---
# Flatpak: read directly from "flatpak info", never guessed.
flatpak_version=""
if [[ "${has_flatpak}" = true ]]; then
  flatpak_version=$(flatpak info net.lutris.Lutris 2>/dev/null | awk -F': ' '/^ *Version:/ {print $2; exit}')
fi

# Native package: chained according to the package manager actually present -- never a guessed
# fallback value if none of the three answers.
native_version=""
if [[ "${has_native}" = true ]]; then
  if command -v dpkg-query >/dev/null 2>&1; then
    native_version=$(dpkg-query -W -f='${Version}' lutris 2>/dev/null | sed -E 's/^[0-9]+://; s/-[^-]*$//')
  fi
  if [[ -z "${native_version}" ]] && command -v rpm >/dev/null 2>&1; then
    native_version=$(rpm -q --qf '%{VERSION}' lutris 2>/dev/null)
  fi
  if [[ -z "${native_version}" ]] && command -v pacman >/dev/null 2>&1; then
    native_version=$(pacman -Q lutris 2>/dev/null | awk '{print $2}' | sed -E 's/-[0-9]+$//')
  fi
fi

# --- 3. Latest known upstream version (GitHub, best effort, never blocking) ---
# No new dependency: curl/wget is already required elsewhere in lpm (runners). A failure here
# (offline, GitHub rate limit) must not prevent showing local versions; only the up-to-date/outdated
# status is omitted.
latest_version=""
if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
  latest_json=""
  if command -v curl >/dev/null 2>&1; then
    latest_json=$(curl -sf "https://api.github.com/repos/lutris/lutris/releases/latest" 2>/dev/null)
  else
    latest_json=$(wget -qO- "https://api.github.com/repos/lutris/lutris/releases/latest" 2>/dev/null)
  fi
  if [[ -n "${latest_json}" ]] && command -v python3 >/dev/null 2>&1; then
    latest_version=$(printf '%s' "${latest_json}" | python3 -c '
import sys, json
try:
    data = json.load(sys.stdin)
    print(str(data.get("tag_name", "")).lstrip("vV"))
except Exception:
    pass
' 2>/dev/null)
  fi
fi

# Compares an installed version to latest_version. Writes a translated status on stdout, or nothing
# if the comparison is impossible (installed or remote version unknown) -- the caller then shows
# only the version number rather than a guess.
# $2 = "native" or "flatpak", for the matching "outdated" label (the native Debian-like package
# structurally lags behind upstream, which is not a user error -- hence a short message).
zgc_version_status() {
  local installed="$1" kind="$2"
  [[ -z "${installed}" ]] && return 0
  [[ -z "${latest_version}" ]] && { t lutris_version.status_check_unavailable; return 0; }

  if [[ "${installed}" = "${latest_version}" ]]; then
    t lutris_version.status_up_to_date
    return 0
  fi

  local lowest
  lowest=$(printf '%s\n%s\n' "${installed}" "${latest_version}" | sort -V | head -n1)
  if [[ "${lowest}" = "${installed}" ]]; then
    if [[ "${kind}" = "native" ]]; then
      t lutris_version.status_outdated_native
    else
      t lutris_version.status_outdated_flatpak
    fi
  else
    # Installed version newer than the latest known GitHub tag (e.g. dev build, pre-release): not
    # "outdated", but "up to date" would be misleading -- show only the number, as for an impossible
    # comparison.
    return 0
  fi
}

print_detected_list() {
  t lutris_version.header
  if [[ "${has_flatpak}" = true ]]; then
    local status
    status=$(zgc_version_status "${flatpak_version}" "flatpak")
    if [[ -n "${status}" ]]; then
      printf '  - %-14s: %s (%s)\n' "$(t lutris_version.label_flatpak)" "${flatpak_version:-$(t lutris_version.status_unknown)}" "${status}"
    else
      printf '  - %-14s: %s\n' "$(t lutris_version.label_flatpak)" "${flatpak_version:-$(t lutris_version.status_unknown)}"
    fi
  fi
  if [[ "${has_native}" = true ]]; then
    local status
    status=$(zgc_version_status "${native_version}" "native")
    if [[ -n "${status}" ]]; then
      printf '  - %-14s: %s (%s)\n' "$(t lutris_version.label_native)" "${native_version:-$(t lutris_version.status_unknown)}" "${status}"
    else
      printf '  - %-14s: %s\n' "$(t lutris_version.label_native)" "${native_version:-$(t lutris_version.status_unknown)}"
    fi
  fi
}

# --- 3bis. GUI-readable mode: "lpm lutris-version status" ---
# Lines "[LUTRIS] <flatpak|native>|<version>|<status>" for each DETECTED version, and
# "[LUTRIS-SAVED] <flatpak|native>" if a saved choice points to a version that is still installed.
if [[ "${sub_arg}" = "status" ]]; then
  if [[ "${has_flatpak}" = true ]]; then
    printf '[LUTRIS] flatpak|%s|%s\n' "${flatpak_version}" "$(zgc_version_status "${flatpak_version}" "flatpak")"
  fi
  if [[ "${has_native}" = true ]]; then
    printf '[LUTRIS] native|%s|%s\n' "${native_version}" "$(zgc_version_status "${native_version}" "native")"
  fi
  if [[ -f "${ZGU_LUTRIS_VERSION_CONFIG}" ]]; then
    saved_choice=$(<"${ZGU_LUTRIS_VERSION_CONFIG}")
    saved_choice="${saved_choice//[$'\t\r\n ']/}"
    if { [[ "${saved_choice}" = "flatpak" ]] && [[ "${has_flatpak}" = true ]]; } \
      || { [[ "${saved_choice}" = "native" ]] && [[ "${has_native}" = true ]]; }; then
      printf '[LUTRIS-SAVED] %s\n' "${saved_choice}"
    fi
  fi
  exit 0
fi

# --- 4. Subcommands: force a choice, or reset it ---
if [[ "${sub_arg}" = "reset" ]]; then
  if [[ -f "${ZGU_LUTRIS_VERSION_CONFIG}" ]]; then
    rm -f "${ZGU_LUTRIS_VERSION_CONFIG}"
    say "$(t lutris_version.reset_done)"
  else
    say "$(t lutris_version.reset_nothing)"
  fi
  exit 0
fi

if [[ "${sub_arg}" = "flatpak" ]] || [[ "${sub_arg}" = "native" ]]; then
  target_installed=false
  [[ "${sub_arg}" = "flatpak" ]] && [[ "${has_flatpak}" = true ]] && target_installed=true
  [[ "${sub_arg}" = "native" ]] && [[ "${has_native}" = true ]] && target_installed=true

  if [[ "${target_installed}" = false ]]; then
    if [[ "${sub_arg}" = "flatpak" ]]; then
      say_err "$(t lutris_version.target_not_installed "$(t lutris_version.label_flatpak)")"
    else
      say_err "$(t lutris_version.target_not_installed "$(t lutris_version.label_native)")"
    fi
    exit 1
  fi

  mkdir -p "$(dirname "${ZGU_LUTRIS_VERSION_CONFIG}")"
  echo "${sub_arg}" > "${ZGU_LUTRIS_VERSION_CONFIG}"
  if [[ "${sub_arg}" = "flatpak" ]]; then
    say "$(t lutris_version.forced_saved "$(t lutris_version.label_flatpak)")"
  else
    say "$(t lutris_version.forced_saved "$(t lutris_version.label_native)")"
  fi
  exit 0
fi

if [[ -n "${sub_arg}" ]]; then
  say_err "$(t lutris_version.invalid_arg "${sub_arg}")"
  exit 1
fi

# --- 5. No subcommand: display, and offer a choice if both are present ---
print_detected_list

if [[ "${has_flatpak}" = true ]] && [[ "${has_native}" = true ]]; then
  echo ""
  t lutris_version.hint_cli
else
  if [[ "${has_flatpak}" = true ]]; then
    say "$(t lutris_version.only_one_cli "$(t lutris_version.label_flatpak)")"
  else
    say "$(t lutris_version.only_one_cli "$(t lutris_version.label_native)")"
  fi
fi

exit 0
