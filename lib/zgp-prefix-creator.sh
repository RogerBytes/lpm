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

# --- lpm create-prefix: create one or more blank wineprefixes registered in Lutris, without the
# install wizard (no script, no executable to run) ---
#
# Directly reproduces the internal mechanism Lutris uses to initialize a prefix (checked in its
# source, lutris/runners/commands/wine.py::create_prefix):
#   - Classic Wine runner: runs the chosen runner's "wineboot" with WINEARCH/WINEPREFIX/WINEDLLOVERRIDES, then waits for user.reg/userdef.reg/system.reg to appear (proof the prefix is initialized). Tested in real conditions (no $DISPLAY): takes ~13s.
#   - Proton runner: Lutris does not run wineboot for Proton, it shells out to "umu-run createprefix" (variables WINEPREFIX/PROTONPATH/GAMEID). Tested with a real umu-run 1.4.4: "createprefix" is a supported keyword and umu-run validates PROTONPATH itself by looking for toolmanifest.vdf, the same signal used here to tell a classic Wine runner (bin/wine present) from Proton (toolmanifest.vdf present, no bin/ at the root).
#
# $1 = mode (always "cli"; kept for consistency with the other lib/ scripts)
# $2 = confirm_flag ("yes" if -y)
# Remaining arguments = CLI targets ("Display name" or "Display name|custom-slug"), plus
# optionally -r|--runner <name> and -a|--arch <win32|win64> (same convention as
# zgp-exe-installer.sh) to choose the runner/architecture explicitly; otherwise falls back to
# zgu_get_default_runner / "win64".
mode="${1:-}"
shift || true
confirm_flag="${1:-}"
shift || true

cli_runner=""
cli_arch=""
cli_targets=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -r|--runner) cli_runner="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    --runner=*) cli_runner="${1#--runner=}"; shift ;;
    -a|--arch) cli_arch="${2:-}"; shift $(( $# >= 2 ? 2 : 1 )) ;;
    --arch=*) cli_arch="${1#--arch=}"; shift ;;
    *) cli_targets+=("$1"); shift ;;
  esac
done

if [[ "${mode}" = "cli" ]] && [[ -n "${cli_arch}" ]] && [[ "${cli_arch}" != "win32" ]] && [[ "${cli_arch}" != "win64" ]]; then
  zgu_cli_error "$(t create_prefix.invalid_arch_cli "${cli_arch}")"
  exit 1
fi

# 1. Dependency check: sqlite3/python3/PyYAML always (the specific wine/wineboot or umu-run is
# only checked when creating a prefix, once the runner is chosen: no need to require wine if
# only Proton runners are used, and vice versa).
zgp_prefix_require_tools

# 2. Close Lutris first to release the database (same as the installer and uninstaller: pga.db
# is written directly).
zgp_prefix_close_lutris

# 3. Detect Flatpak vs native package




# Location of the umu-run bundled by Lutris itself (checked on a real Flatpak install:
# data/lutris/runtime/umu/umu-run, a normal file on disk, not hidden in the Flatpak sandbox, so
# callable directly without "flatpak run"). The native path follows the same principle as all
# other Flatpak/native path pairs in this file.


zgp_prefix_setup_lutris

# 4. Runner and architecture choice
#
# The runner/architecture can only come from -r/--runner and -a/--arch (or Lutris default runner
# / "win64" otherwise).
zgp_prefix_choose_runner

# 5. Display names input
declare -a raw_names=()

for target in "${cli_targets[@]}"; do
  [[ -z "${target}" ]] && continue
  raw_names+=("${target}")
done

if [[ ${#raw_names[@]} -eq 0 ]]; then
  zgu_cli_error "$(t create_prefix.no_names_error_cli)"
  exit 1
fi

# 6. Slug generation (deduplicated against pga.db and the current batch). A custom slug after
# "|" is also passed through zgp_slugify, to guarantee its validity (forbidden characters,
# spaces...) rather than trusting manual input as is.
zgp_prefix_load_existing_slugs

declare -a batch_names=()
declare -a batch_slugs=()
declare -A used_slugs=()

for entry in "${raw_names[@]}"; do
  display_name=""
  explicit_slug=""
  if [[ "${entry}" == *"|"* ]]; then
    display_name="${entry%%|*}"
    explicit_slug="${entry#*|}"
  else
    display_name="${entry}"
  fi

  [[ -z "${display_name}" ]] && continue

  if [[ -n "${explicit_slug}" ]]; then
    base_slug=$(zgp_slugify "${explicit_slug}")
  else
    base_slug=$(zgp_slugify "${display_name}")
  fi

  final_slug="${base_slug}"
  suffix=2
  while [[ -n "${existing_slugs[${final_slug}]:-}" ]] || [[ -n "${used_slugs[${final_slug}]:-}" ]]; do
    final_slug="${base_slug}-${suffix}"
    suffix=$(( suffix + 1 ))
  done
  used_slugs["${final_slug}"]=1

  batch_names+=("${display_name}")
  batch_slugs+=("${final_slug}")
done

# 7. Summary + confirmation (CLI). The slug was already validated/deduplicated in step 6 (via
# "|" or automatic fallback).
if [[ "${confirm_flag}" != "yes" ]]; then
  t create_prefix.confirm_cli_header
  for (( i=0; i<${#batch_names[@]}; i++ )); do
    t create_prefix.confirm_cli_item "${batch_names[i]}" "${batch_slugs[i]}"
  done
  read -r -p "$(t create_prefix.confirm_cli_prompt)" response || response="n"  # EOF (no terminal) = cancel
  case "${response}" in
    ""|[oOyY]) : ;;
    *)
      t create_prefix.cancelled_cli
      exit 0
      ;;
  esac
fi

if [[ ${#batch_names[@]} -eq 0 ]]; then
  exit 0
fi

# 8. Actual prefix creation
#
# wineboot (classic Wine runner) and umu-run createprefix (Proton runner) are launched in the
# background without waiting for their exit code: Lutris itself does not rely on it (umu-run
# exits 0 even when PROTONPATH is invalid) but polls for the 3 registry files to confirm
# success. Reproduced exactly here.

total="${#batch_names[@]}"

# Four temporary files carry the results out of the loop below. created_slugs_file is reused
# afterwards for the best-effort update of Lutris native media (see the comment after the
# zgp_run_creation_batch call).
created_count_file=$(mktemp)
created_slugs_file=$(mktemp)
skipped_file=$(mktemp)
failed_file=$(mktemp)
echo "0" > "${created_count_file}"

# Creates the Wine/Proton prefix with the chosen runner. Arg: prefix_dir.
zgp_boot_prefix() {
  local prefix_dir="$1"
  if [[ "${runner_type}" = "wine" ]]; then
    env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="winemenubuilder=" \
      "${runner_dir}/${runner_choice}/bin/wineboot" >/dev/null 2>&1
  else
    env WINEARCH="${arch_choice}" WINEPREFIX="${prefix_dir}" PROTONPATH="${runner_dir}/${runner_choice}" GAMEID="0" \
      "${umu_run_path}" createprefix >/dev/null 2>&1
  fi
}

# Writes the Lutris yml and the DB row of a new prefix. Args: c_name c_slug prefix_dir.
zgp_register_prefix() {
  local c_name="$1" c_slug="$2" prefix_dir="$3"
  local config_id yml_config_file
  config_id="${c_slug}-$(date +%s%N)"
  yml_config_file="${lutris_config_dir}/${config_id}.yml"
  zgp_write_config_yml "${yml_config_file}" "${prefix_dir}" "${c_slug}" "${c_name}" "${runner_choice}"
  zgp_register_game_row "${c_name}" "${c_slug}" "" "${prefix_dir}" "${config_id}"
}

zgp_run_creation_batch() {
  local created=0
  local i c_name c_slug prefix_dir step_num

  for (( i=0; i<total; i++ )); do
    c_name="${batch_names[i]}"
    c_slug="${batch_slugs[i]}"
    prefix_dir="${games_dir}/${c_slug}"
    step_num=$(( i + 1 ))

    t create_prefix.creating_cli "${c_name}" "${c_slug}" "${step_num}" "${total}"

    # Strict refusal if the prefix already exists (same guard as the installer): this entry
    # is skipped rather than overwriting an existing folder, and the rest of the batch
    # continues.
    if [[ -d "${prefix_dir}" ]]; then
      echo "${c_name}" >> "${skipped_file}"
      continue
    fi

    mkdir -p "${prefix_dir}"
    zgp_boot_prefix "${prefix_dir}"
    if ! zgp_wait_for_prefix "${prefix_dir}"; then
      echo "${c_name}" >> "${failed_file}"
      continue
    fi
    zgp_register_prefix "${c_name}" "${c_slug}" "${prefix_dir}"

    created=$(( created + 1 ))
    # Written on EACH success, not only once at the end of the loop: if this function were
    # interrupted early, created_count_file still holds the exact count of prefixes created
    # so far instead of staying at "0".
    echo "${created}" > "${created_count_file}"
    echo "${c_slug}" >> "${created_slugs_file}"
  done
}

zgp_run_creation_batch

created_count=$(cat "${created_count_file}" 2>/dev/null)
[[ -z "${created_count}" ]] && created_count=0

skipped_existing=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && skipped_existing+=("${line}")
done < "${skipped_file}"

failed_names=()
while IFS= read -r line; do
  [[ -n "${line}" ]] && failed_names+=("${line}")
done < "${failed_file}"

created_slugs=()
if [[ -f "${created_slugs_file}" ]]; then
  mapfile -t created_slugs < "${created_slugs_file}" 2>/dev/null
fi

rm -f "${created_count_file}" "${created_slugs_file}" "${skipped_file}" "${failed_file}"

# 9. Final summary
zgu_cli_ok "$(t create_prefix.summary_created "${created_count}")"
if [[ ${#skipped_existing[@]} -gt 0 ]]; then
  t create_prefix.summary_skipped "${#skipped_existing[@]}"
fi
if [[ ${#failed_names[@]} -gt 0 ]]; then
  t create_prefix.summary_failed "${#failed_names[@]}"
fi

# Best-effort update of Lutris native media (banner/icon/cover, see "lpm sync-media") for the
# prefixes just created. Outside the creation loop: a lutris.net network problem must never fail
# a prefix creation. A freshly created prefix has no executable configured yet, so it is
# unlikely to be referenced on lutris.net, but calling "sync-media" here is harmless and becomes
# useful once the game is configured in Lutris itself.
if [[ ${#created_slugs[@]} -gt 0 ]]; then
  # Run in the background, detached ("&" + "disown"), for the same reason as
  # zgp-game-installer.sh: nothing here needs to wait for "sync-media" (purely cosmetic);
  # results are available afterwards via "lpm log".
  bash "${script_dir}/zgp-game-sync-media.sh" "${created_slugs[@]}" >/dev/null 2>&1 &
  disown
fi

# Exit code reflects the real outcome: 1 if at least one prefix could not be created.
if [[ ${#failed_names[@]} -gt 0 ]]; then
  exit 1
fi
exit 0
