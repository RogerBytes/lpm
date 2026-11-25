#!/bin/bash
# ludis doctor: read-only diagnosis of the machine. Looks at Lutris, Wine runners, the tools
# ludis needs and the optional ones (MangoHud, AntiMicroX, xdotool), and says what is missing and
# how to fix it. Changes nothing, downloads nothing, never asks a question (unlike "ludis check",
# which fetches missing runners).
#   [OK]   present      [WARN] optional or degraded      [FAIL] ludis cannot work without it
# Exit code: 1 if at least one [FAIL], else 0.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

fails=0
warns=0
ok()   { printf '[ OK ] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; warns=$((warns + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; fails=$((fails + 1)); }
hint() { printf '       %s\n' "$1"; }
section() { printf '\n%s\n' "$1"; }

section "$(t doctor.sec_session)"
session="x11"
if [[ "${XDG_SESSION_TYPE,,}" = "wayland" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  session="wayland"
fi
ok "$(t doctor.session "${session}")"

section "$(t doctor.sec_tools)"
for cmd in sqlite3 python3 bsdtar sha256sum tar zstd; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    ok "${cmd}"
  else
    fail "$(t doctor.tool_missing "${cmd}")"
    hint "$(t doctor.tool_hint)"
  fi
done
if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
  ok "curl / wget"
else
  fail "$(t doctor.tool_missing "curl / wget")"
  hint "$(t doctor.tool_hint)"
fi
if python3 -c "import yaml" >/dev/null 2>&1; then
  ok "PyYAML"
else
  fail "$(t doctor.tool_missing "PyYAML")"
  hint "$(t doctor.pyyaml_hint)"
fi
if python3 -c 'import gi; gi.require_version("Gtk","4.0"); gi.require_version("Adw","1"); from gi.repository import Gtk, Adw' >/dev/null 2>&1; then
  ok "$(t doctor.gui_ok)"
else
  warn "$(t doctor.gui_missing)"
  hint "$(t doctor.gui_hint)"
fi

section "Lutris"
found_lutris=0
for kind in flatpak native; do
  if [[ "${kind}" = "flatpak" ]]; then
    command -v flatpak >/dev/null 2>&1 && check_flatpak_lutris_installed || continue
  else
    check_native_lutris_installed || continue
  fi
  found_lutris=1
  zgu_set_lutris_paths "${kind}"
  ok "$(t doctor.lutris_found "${kind}")"
  if [[ -f "${lutris_db}" ]]; then
    ok "$(t doctor.lutris_db_ok "${lutris_db}")"
  else
    warn "$(t doctor.lutris_db_missing "${lutris_db}")"
    hint "$(t doctor.lutris_db_hint)"
  fi
  # Wine / Proton runners of this Lutris
  count=0
  if [[ -d "${runner_dir}" ]]; then
    count=$(find "${runner_dir}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
  fi
  default_runner="$(zgu_get_default_runner)"
  if (( count > 0 )); then
    ok "$(t doctor.runners_ok "${count}" "${kind}")"
  else
    warn "$(t doctor.runners_none "${kind}")"
    hint "$(t doctor.runners_hint)"
  fi
  if (( count > 0 )) && [[ ! -d "${runner_dir}/${default_runner}" ]]; then
    warn "$(t doctor.default_runner_missing "${default_runner}")"
    hint "$(t doctor.default_runner_hint)"
  fi
done
if (( found_lutris == 0 )); then
  fail "$(t doctor.lutris_missing)"
  hint "$(t doctor.lutris_hint)"
fi

section "Wine"
if command -v wine >/dev/null 2>&1; then
  ok "$(t doctor.wine_system "$(wine --version 2>/dev/null)")"
else
  ok "$(t doctor.wine_none)"
fi

section "$(t doctor.sec_optional)"
mango=0
command -v mangohud >/dev/null 2>&1 && mango=1
if (( mango == 0 )) && command -v flatpak >/dev/null 2>&1 \
   && flatpak list --runtime --columns=application 2>/dev/null | grep -qi 'MangoHud'; then
  mango=1
fi
if (( mango )); then
  ok "MangoHud"
else
  warn "$(t doctor.mangohud_missing)"
  hint "$(t doctor.mangohud_hint)"
fi
antimicro=0
command -v antimicrox >/dev/null 2>&1 && antimicro=1
command -v antimicro >/dev/null 2>&1 && antimicro=1
if (( antimicro == 0 )) && command -v flatpak >/dev/null 2>&1 \
   && flatpak list --app --columns=application 2>/dev/null | grep -qx "io.github.antimicrox.antimicrox"; then
  antimicro=1
fi
if (( antimicro )); then
  ok "AntiMicroX"
else
  warn "$(t doctor.antimicro_missing)"
  hint "$(t doctor.antimicro_hint)"
fi
if [[ "${session}" = "x11" ]]; then
  if command -v xdotool >/dev/null 2>&1; then
    ok "xdotool"
  else
    warn "$(t doctor.xdotool_missing)"
    hint "$(t doctor.xdotool_hint)"
  fi
fi

echo
if (( fails > 0 )); then
  printf '%s\n' "$(t doctor.summary_fail "${fails}" "${warns}")"
  exit 1
fi
printf '%s\n' "$(t doctor.summary_ok "${warns}")"
exit 0
