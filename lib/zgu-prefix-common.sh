#!/bin/bash

# --- Prefix creation helpers, shared by "lpm exe-install" and "lpm create-prefix" ---
#
# Library (no code runs when it is sourced): lib/zgp-exe-installer.sh and
# lib/zgp-prefix-creator.sh create a prefix the same way, so runner detection, umu-run lookup,
# slug generation, the wait for the registry files and the Lutris YAML writing exist once, here.
# The calling script defines "runner_dir" (runners folder), "lutris_umu" (umu-run fallback path)
# and "t" (zgl-lang-loader.sh) before calling them.

# shellcheck disable=SC2154 # runner_dir and lutris_umu are defined by the calling script
ZGP_REG_TIMEOUT_TICKS=360 # 360 x 0.5s = 180s max per prefix

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

# 12. Write the yml + insert into the DB (same as "blank prefix")
zgp_write_config_yml() {
  local yml_path="$1" p_dir="$2" p_slug="$3" p_name="$4" p_runner="$5" p_exe="${6:-}"
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

# --- Start-up steps shared by "lpm exe-install" and "lpm create-prefix" (they exit on failure) ---

# sqlite3, python3 and PyYAML are required.
zgp_prefix_require_tools() {
  local cmd
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
}

# Closes Lutris first, to release the database (pga.db is written directly).
zgp_prefix_close_lutris() {
  if flatpak list 2>/dev/null | grep -q lutris; then
    flatpak kill net.lutris.Lutris 2>/dev/null
  fi
  pkill -9 -x lutris 2>/dev/null
  pkill -9 -f "/usr/bin/lutris" 2>/dev/null
}

# Detects Lutris (zgu_load_lutris_env) and makes sure its folders and the runners folder exist.
zgp_prefix_setup_lutris() {
  zgu_load_lutris_env || {
    t create_prefix.lutris_missing_cli
    exit 1
  }
  mkdir -p "${lutris_config_dir}"
  mkdir -p "$(dirname "${lutris_db}")"
  mkdir -p "${games_dir}"
  if [[ ! -d "${runner_dir}" ]]; then
    zgu_cli_error "$(t create_prefix.no_runners_found_cli "${runner_dir}")"
    exit 1
  fi
}

# Runner / architecture choice from -r/--runner and -a/--arch (cli_runner, cli_arch), else the
# Lutris default runner and win64. Sets runner_choice, arch_choice, runner_type, umu_run_path.
# shellcheck disable=SC2034  # read by the calling scripts
zgp_prefix_choose_runner() {
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
}

# Slugs already in pga.db, into the global associative array existing_slugs.
# shellcheck disable=SC2034  # read by the calling scripts
zgp_prefix_load_existing_slugs() {
  declare -gA existing_slugs=()
  local s
  if [[ -f "${lutris_db}" ]]; then
    while IFS= read -r s; do
      [[ -n "${s}" ]] && existing_slugs["${s}"]=1
    done < <(sqlite3 "${lutris_db}" "SELECT slug FROM games;" 2>/dev/null)
  fi
}

# Replaces the game row in pga.db (Wine game, installed now). Args: name slug executable
# prefix_dir config_id.
zgp_register_game_row() {
  local safe_name="${1//\'/\'\'}" safe_slug="${2//\'/\'\'}" safe_exe="${3//\'/\'\'}"
  local safe_prefix_dir="${4//\'/\'\'}" safe_config_id="${5//\'/\'\'}"
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
}
