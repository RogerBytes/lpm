#!/bin/bash

# --- lpm lsfg [slug...] [on|off] ---
#
# Enables/disables lsfg-vk ("Lossless Scaling" frame generation) for one or more Lutris
# Wine/Proton games.
#
#   1. lsfg-vk detection (Flatpak: VulkanLayer extension installed; native: Vulkan
#      implicit_layer.d manifest present). The lsfg-vk project documents no version check, so
#      this only detects presence, not the 2.0+ scheme. With an old 1.0 install (LSFG_LEGACY
#      scheme, gone), activation looks successful in lpm but has no effect in game; there is no
#      reliable way to detect it.
#   2. Install missing:
#        - Flatpak: lpm installs the VulkanLayer.lsfgvk extension itself (with consent), no
#          sudo (--user), for the SAME runtime version as the detected Flatpak Lutris. No
#          "flatpak override" is needed: a freedesktop VulkanLayer extension is exposed to every
#          app using that runtime (same mechanism as MangoHud). The official lsfg-vk override
#          example (LSFGVK_CONFIG) only concerns a config path OUTSIDE the wineprefix, unused
#          here (lpm sets everything through the Lutris YAML system.env variables, which point
#          inside the game's wineprefix).
#        - Native: no auto-install (no universal package); AUR link if Arch is detected
#          (pacman present), otherwise the generic link of the official docs. The link is shown
#          in the terminal (never opened automatically), with Confirm/Cancel and a re-check
#          after Confirm.
#   3. Reference DLL: MUST be the "lsfg-vk.dll" file as-is (name checked, not renamed by the
#      user), from the Lossless Scaling Steam beta branch "lsfg-vk" (game Properties > Betas
#      > lsfg-vk). The "Lossless.dll" of the public branch is NOT ACCEPTED: it lacks the
#      "mipmaps" shader needed by the lsfg-vk 2.0 scheme (error "Unable to find base shader
#      'mipmaps' in DLL" at launch, also with a renamed copy of it). Copied as-is to
#      ~/.config/lpm/lsfg-vk/lsfg-vk.dll.
#   4. Enable/Disable screen, listing ONLY relevant games (enable: games without
#      LSFGVK_ENV=1 in their YAML; disable: games that have it). The YAML of each game is
#      re-read on every run, with no separate tracking file (single source of truth, stays in
#      sync if the user edits the YAML in Lutris).
#   5. Wine/Proton games only (runner='wine' in pga.db; Lutris does not distinguish them
#      otherwise, native Linux games have another runner). Shared prefixes
#      (Epic/EA/Ubisoft/Battle.net) INCLUDED: non-destructive, same principle as "lpm tools".
#   6. Enable: copies lsfg-vk.dll to the prefix root (overwrites without confirmation, the
#      reference copy wins), then merges into the YAML system.env: LSFGVK_ENV=1,
#      LSFGVK_DLL_PATH=<path>, and LSFGVK_MULTIPLIER=2 ONLY if that key does not exist yet
#      (never overwrite a user customization from the Lutris settings). No other system.env
#      key is touched. Disable: removes only those 3 keys (not DISABLE_LSFGVK, separate and
#      unneeded here) and never deletes the lsfg-vk.dll already copied into the prefix.

cli_args=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"
# shellcheck source=./zgu-lsfg-utils.sh
source "${script_dir}/zgu-lsfg-utils.sh"

# --- "lpm lsfg status": NON-interactive check of the lsfg-vk Vulkan layer presence
# (zgu_lsfg_vk_present, see zgu-lsfg-utils.sh), used by gui/*.py (page_lsfg) to show or hide
# the "file required" warning, without going through the interactive install flow
# ("read -p") below, reserved for "lpm lsfg <slug...> on|off". Placed before the
# "<slug...> on|off" syntax validation so this status needs no slug. Never a blocking error
# here (an impossible Lutris detection is reported as "installed": false).
if [[ "${#cli_args[@]}" -eq 1 ]] && [[ "${cli_args[0]}" = "status" ]]; then
  _lsfg_status_lutris_is_flatpak=false
  _lsfg_status_version=$(zgu_resolve_lutris_version "cli" "${HOME}/.local/share/lutris/pga.db" "")
  [[ "${_lsfg_status_version}" = "flatpak" ]] && _lsfg_status_lutris_is_flatpak=true
  if zgu_lsfg_vk_present "${_lsfg_status_lutris_is_flatpak}"; then
    echo '{"installed": true}'
  else
    echo '{"installed": false}'
  fi
  exit 0
fi

# --- "lpm lsfg install-info": NON-interactive info needed to offer the lsfg-vk install
# from the GUI (optional button of "page_lsfg", shown when "lsfg status" says
# "installed": false). Never installs here, detection only. Flatpak: also resolves the
# freedesktop runtime version (zgu_lsfg_resolve_freedesktop_runtime_version, see
# zgu-lsfg-utils.sh) so the GUI shows it in its confirmation window and passes it unchanged
# to "install-flatpak" below (single bash source of truth). Native: reuses
# zgu_lsfg_native_link_info (same as zgp_lsfg_install_native below).
if [[ "${#cli_args[@]}" -eq 1 ]] && [[ "${cli_args[0]}" = "install-info" ]]; then
  _lsfg_info_lutris_is_flatpak=false
  _lsfg_info_version=$(zgu_resolve_lutris_version "cli" "${HOME}/.local/share/lutris/pga.db" "")
  [[ "${_lsfg_info_version}" = "flatpak" ]] && _lsfg_info_lutris_is_flatpak=true

  if [[ "${_lsfg_info_lutris_is_flatpak}" = true ]]; then
    _lsfg_info_runtime=$(zgu_lsfg_resolve_freedesktop_runtime_version)
    RUNTIME="${_lsfg_info_runtime}" python3 -c '
import json, os
print(json.dumps({"flatpak": True, "runtime_version": os.environ.get("RUNTIME", "")}))
'
  else
    _lsfg_info_link=""
    _lsfg_info_label_key=""
    IFS=$'\t' read -r _lsfg_info_link _lsfg_info_label_key < <(zgu_lsfg_native_link_info)
    LINK="${_lsfg_info_link}" LABEL="$(t "${_lsfg_info_label_key}")" python3 -c '
import json, os
print(json.dumps({"flatpak": False, "link": os.environ.get("LINK", ""), "link_label": os.environ.get("LABEL", "")}))
'
  fi
  exit 0
fi

# --- "lpm lsfg install-flatpak <runtime_version>": real NON-interactive Flatpak install of
# the lsfg-vk extension, for a runtime version already confirmed by the user in the GUI
# ("install-info" above + confirmation window). No "read -p" here, unlike
# zgp_lsfg_install_flatpak() below (CLI usage of "lpm lsfg <slug...> on|off"). Reuses
# zgu_lsfg_install_flatpak_do (see zgu-lsfg-utils.sh).
if [[ "${#cli_args[@]}" -eq 2 ]] && [[ "${cli_args[0]}" = "install-flatpak" ]]; then
  _lsfg_doinstall_runtime="${cli_args[1]}"
  _lsfg_doinstall_err=$(zgu_lsfg_install_flatpak_do "${_lsfg_doinstall_runtime}")
  if [[ $? -eq 0 ]]; then
    python3 -c 'import json; print(json.dumps({"ok": True}))'
  else
    ERR="${_lsfg_doinstall_err}" python3 -c '
import json, os
print(json.dumps({"ok": False, "error": os.environ.get("ERR", "")}))
'
  fi
  exit 0
fi

# --- 0. CLI syntax validation (bin/lpm has no interactive entry point: no menu/Zenity
# selection, only this explicit terminal command) ---
cli_action=""
cli_slugs=()

last_arg="${cli_args[-1]:-}"
if [[ "${last_arg}" = "on" ]] || [[ "${last_arg}" = "off" ]]; then
  cli_action="${last_arg}"
  cli_slugs=("${cli_args[@]:0:$(( ${#cli_args[@]} - 1 ))}")
fi
if [[ -z "${cli_action}" ]] || [[ ${#cli_slugs[@]} -eq 0 ]]; then
  zgu_cli_error "$(t lsfg.cli_usage)"
  exit 1
fi

zgp_lsfg_report_error_early() {
  local msg="$1"
  echo "${msg}" >&2
}

for cmd in python3 sqlite3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgp_lsfg_report_error_early "$(t lsfg.cmd_missing "${cmd}")"
    exit 1
  fi
done
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  zgu_cli_error "$(t lsfg.pyyaml_missing_cli)"
  exit 1
fi

# --- 1. Flatpak vs native package detection + Lutris path resolution ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"
lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"
games_dir="${HOME}/Games"

version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgp_lsfg_report_error_early "$(t lsfg.lutris_missing)"
  exit 1
fi

lutris_is_flatpak=false
if [[ "${version}" = "flatpak" ]]; then
  lutris_is_flatpak=true
  lutris_db="${lutris_flatpak_db}"
  lutris_config_dir="${lutris_flatpak_config_dir}"
  lutris_system_file="${lutris_flatpak_system_file}"
else
  lutris_db="${lutris_package_db}"
  lutris_config_dir="${lutris_package_config_dir}"
  lutris_system_file="${lutris_package_system_file}"
fi

if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
fi

if [[ ! -f "${lutris_db}" ]]; then
  zgp_lsfg_report_error_early "$(t lsfg.db_missing "${lutris_db}")"
  exit 1
fi

# --- 2. Detect installed lsfg-vk (presence only, see the warning in the file header).
# Functions shared with "lpm check", see zgu-lsfg-utils.sh (sourced above). ---
zgp_lsfg_vk_present() {
  zgu_lsfg_vk_present "${lutris_is_flatpak}"
}

# --- 3. Install lsfg-vk if missing ---
zgp_lsfg_install_flatpak() {
  local runtime_version
  runtime_version=$(zgu_lsfg_resolve_freedesktop_runtime_version)

  if [[ -z "${runtime_version}" ]]; then
    zgp_lsfg_report_error_early "$(t lsfg.flatpak_runtime_unknown)"
    return 1
  fi

  t lsfg.install_flatpak_confirm_cli "${runtime_version}"
  local response
  read -r -p "$(t lsfg.confirm_prompt_cli)" response
  [[ "${response}" =~ ^[oOyY] ]] || return 1

  local install_err
  install_err=$(zgu_lsfg_install_flatpak_do "${runtime_version}")
  if [[ $? -ne 0 ]]; then
    zgp_lsfg_report_error_early "$(t lsfg.flatpak_install_failed "${install_err}")"
    return 1
  fi
  return 0
}

zgp_lsfg_install_native() {
  local link label_key label
  IFS=$'\t' read -r link label_key < <(zgu_lsfg_native_link_info)
  label="$(t "${label_key}")"

  t lsfg.install_native_confirm_cli "${label}" "${link}"
  local response
  read -r -p "$(t lsfg.confirm_prompt_cli)" response
  [[ "${response}" =~ ^[oOyY] ]] || return 1

  if ! zgp_lsfg_vk_present; then
    zgp_lsfg_report_error_early "$(t lsfg.native_still_missing)"
    return 1
  fi
  return 0
}

lsfg_dll_master="${XDG_CONFIG_HOME:-${HOME}/.config}/lpm/lsfg-vk/lsfg-vk.dll"

zgp_lsfg_ensure_dll() {
  [[ -f "${lsfg_dll_master}" ]] && return 0

  local candidate candidate_basename
  t lsfg.dll_select_text_cli
  read -r -p "$(t lsfg.dll_select_prompt_cli)" candidate

  [[ -z "${candidate}" ]] && return 1
  [[ -f "${candidate}" ]] || { zgp_lsfg_report_error_early "$(t lsfg.dll_not_found "${candidate}")"; return 1; }

  # The file name is authoritative (see file header): only a real "lsfg-vk.dll" from the Steam
  # beta branch "lsfg-vk" is accepted; "Lossless.dll" (public branch) lacks the "mipmaps"
  # shader required by lsfg-vk 2.0 and breaks game launch.
  candidate_basename="$(basename -- "${candidate}")"
  if [[ "${candidate_basename,,}" != "lsfg-vk.dll" ]]; then
    zgp_lsfg_report_error_early "$(t lsfg.dll_wrong_name "${candidate_basename}")"
    return 1
  fi

  mkdir -p "$(dirname "${lsfg_dll_master}")"
  if ! cp -f -- "${candidate}" "${lsfg_dll_master}"; then
    zgp_lsfg_report_error_early "$(t lsfg.dll_copy_failed)"
    return 1
  fi
  return 0
}

if ! zgp_lsfg_vk_present; then
  if [[ "${lutris_is_flatpak}" = true ]]; then
    # "exit 1", not "exit 0": a refused/failed install did nothing, so it must not look like a
    # success (the GUI would show "Done" despite the error already reported on stderr by
    # zgp_lsfg_report_error_early).
    zgp_lsfg_install_flatpak || exit 1
  else
    zgp_lsfg_install_native || exit 1
  fi
fi

# --- 4. Enable/disable choice (CLI only) ---
action="${cli_action}"

if [[ "${action}" = "on" ]]; then
  # Same as above: a missing/invalid/refused DLL must not look like a success.
  zgp_lsfg_ensure_dll || exit 1
fi

# --- 5. List of Wine/Proton games, filtered by current state in the YAML ---
games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(id,'') || char(31) || COALESCE(name,'') || char(31) || COALESCE(slug,'') || char(31) || COALESCE(directory,'') || char(31) || COALESCE(configpath,'') FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgp_lsfg_report_error_early "$(t lsfg.none_found)"
  exit 0
fi

declare -A name_by_slug dir_by_slug configpath_by_slug
sorted_slugs=()

while IFS=$'\x1f' read -r _g_id g_name g_slug g_dir g_configpath; do
  [[ -z "${g_slug}" ]] && continue
  [[ -z "${g_dir}" ]] && g_dir="${games_dir}/${g_slug}"
  name_by_slug["${g_slug}"]="${g_name}"
  dir_by_slug["${g_slug}"]="${g_dir}"
  configpath_by_slug["${g_slug}"]="${g_configpath}"
  sorted_slugs+=("${g_slug}")
done <<< "${games_list}"

# Returns 0 (true) if LSFGVK_ENV=1 is already in system.env of this game's YAML.
zgp_lsfg_is_active() {
  local configpath="$1" yml_file
  [[ -z "${configpath}" ]] && return 1
  yml_file="${lutris_config_dir}/${configpath}.yml"
  [[ -f "${yml_file}" ]] || return 1
  YML_PATH="${yml_file}" python3 -c '
import os, sys, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
    env = (data.get("system") or {}).get("env") or {}
    sys.exit(0 if str(env.get("LSFGVK_ENV", "")) == "1" else 1)
except Exception:
    sys.exit(1)
' 2>/dev/null
}

declare -A active_by_slug
for g_slug in "${sorted_slugs[@]}"; do
  if zgp_lsfg_is_active "${configpath_by_slug[${g_slug}]}"; then
    active_by_slug["${g_slug}"]=1
  fi
done

eligible_slugs=()
for g_slug in "${sorted_slugs[@]}"; do
  if [[ "${action}" = "on" ]]; then
    [[ -z "${active_by_slug[${g_slug}]:-}" ]] && eligible_slugs+=("${g_slug}")
  else
    [[ -n "${active_by_slug[${g_slug}]:-}" ]] && eligible_slugs+=("${g_slug}")
  fi
done

targets=()

# --- Target selection (CLI only) ---
declare -A eligible_lookup
for g_slug in "${eligible_slugs[@]}"; do
  eligible_lookup["${g_slug}"]=1
done

for target_slug in "${cli_slugs[@]}"; do
  if [[ -z "${name_by_slug[${target_slug}]:-}" ]]; then
    zgu_cli_error "$(t lsfg.slug_not_found "${target_slug}")"
    exit 1
  fi
  if [[ -z "${eligible_lookup[${target_slug}]:-}" ]]; then
    if [[ "${action}" = "on" ]]; then
      zgu_cli_error "$(t lsfg.already_active "${target_slug}")"
    else
      zgu_cli_error "$(t lsfg.already_inactive "${target_slug}")"
    fi
    exit 1
  fi
  targets+=("${target_slug}")
done

# --- 6. Apply: DLL copy + env variable merge/removal ---
#
# MESA_VK_DEVICE_SELECT (multi-GPU detection) was removed: unnecessary with the real
# lsfg-vk.dll (beta branch); the black screen once blamed on GPU selection came from the
# wrong DLL file (see item 3 of the file header).
zgp_lsfg_apply_one() {
  local slug="$1" prefix_dir="$2" configpath="$3" mode="$4"
  local yml_file="${lutris_config_dir}/${configpath}.yml"

  if [[ ! -f "${yml_file}" ]]; then
    zgp_lsfg_report_error_early "$(t lsfg.yml_missing "${slug}")"
    zgu_log "lsfg" "ERREUR" "slug=${slug} raison=yaml_introuvable"
    return 1
  fi

  if [[ "${mode}" = "on" ]]; then
    mkdir -p "${prefix_dir}/lsfg-vk"
    if ! cp -f -- "${lsfg_dll_master}" "${prefix_dir}/lsfg-vk/lsfg-vk.dll"; then
      zgp_lsfg_report_error_early "$(t lsfg.dll_copy_failed_for "${slug}")"
      zgu_log "lsfg" "ERREUR" "slug=${slug} raison=copie_dll_echouee"
      return 1
    fi
  fi

# Line-based text editing (zgu-env-edit.py): a yaml.dump round-trip would destroy the Lutris
# YAML comments, including hooks disabled by LPM ("# lpm:hook-disabled"). Falls back to the
# full rewrite below if targeted editing is not possible.
if {
  edit_py="${script_dir}/zgu-env-edit.py"
  if [[ "${mode}" = "on" ]]; then
    python3 "${edit_py}" "${yml_file}" set LSFGVK_ENV 1 &&
    python3 "${edit_py}" "${yml_file}" set LSFGVK_DLL_PATH "${prefix_dir}/lsfg-vk/lsfg-vk.dll" &&
    { python3 "${edit_py}" "${yml_file}" list | grep -q '^LSFGVK_MULTIPLIER=' ||
      python3 "${edit_py}" "${yml_file}" set LSFGVK_MULTIPLIER 2; }
  else
    python3 "${edit_py}" "${yml_file}" unset LSFGVK_ENV &&
    python3 "${edit_py}" "${yml_file}" unset LSFGVK_DLL_PATH &&
    python3 "${edit_py}" "${yml_file}" unset LSFGVK_MULTIPLIER
  fi
} >/dev/null 2>&1; then
  :
else
  YML_PATH="${yml_file}" DLL_PATH="${prefix_dir}/lsfg-vk/lsfg-vk.dll" LSFG_MODE="${mode}" python3 -c '
import os, yaml

yml_path = os.environ["YML_PATH"]
dll_path = os.environ["DLL_PATH"]
mode = os.environ["LSFG_MODE"]

try:
    with open(yml_path, "r") as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict):
        raise ValueError("YAML racine invalide")

    if "system" not in data or not isinstance(data.get("system"), dict):
        data["system"] = {}
    if "env" not in data["system"] or not isinstance(data["system"].get("env"), dict):
        data["system"]["env"] = {}

    env = data["system"]["env"]

    if mode == "on":
        env["LSFGVK_ENV"] = "1"
        env["LSFGVK_DLL_PATH"] = dll_path
        if "LSFGVK_MULTIPLIER" not in env:
            env["LSFGVK_MULTIPLIER"] = "2"
    else:
        env.pop("LSFGVK_ENV", None)
        env.pop("LSFGVK_DLL_PATH", None)
        env.pop("LSFGVK_MULTIPLIER", None)

    with open(yml_path, "w") as f:
        yaml.dump(data, f, sort_keys=False)
except Exception as e:
    print(str(e))
    raise SystemExit(1)
' 2>/dev/null
fi
  local py_status=$?
  if [[ "${py_status}" -ne 0 ]]; then
    zgp_lsfg_report_error_early "$(t lsfg.yaml_patch_failed "${slug}")"
    zgu_log "lsfg" "ERREUR" "slug=${slug} raison=patch_yaml_echoue"
    return 1
  fi

  zgu_log "lsfg" "OK" "slug=${slug} action=${mode}"
  return 0
}

exit_code=0
n_ok=0
for target_slug in "${targets[@]}"; do
  if zgp_lsfg_apply_one "${target_slug}" "${dir_by_slug[${target_slug}]}" "${configpath_by_slug[${target_slug}]}" "${action}"; then
    n_ok=$(( n_ok + 1 ))
    zgu_cli_ok "$(t lsfg.done_one_cli "${name_by_slug[${target_slug}]}")"
  else
    exit_code=1
  fi
done

exit "${exit_code}"
