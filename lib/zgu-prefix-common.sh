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
