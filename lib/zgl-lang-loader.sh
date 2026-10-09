#!/bin/bash

# --- Language loader for lpm ---
#
# Fills the associative array STRINGS[]:
#   1. Loads lang/en.lang as the base (mandatory, must contain every key).
#   2. Detects the system language ($LC_ALL > $LC_MESSAGES > $LANG).
#   3. If lang/<code>.lang exists for that language, loads it on top: only the keys
#      it defines are overridden, missing keys keep their English value.
#
# To add a translation: drop a "<code>.lang" file in the same "lang/" directory, format
# "key=Translated text" (one key per line, %s / %d for dynamic values). Nothing else to
# change.
#
# Language files are plain "key=value" text READ line by line, never sourced or executed,
# so a community-contributed translation can never run code.

# Same detection logic as bin/lpm (see the install-location comment there);
# Keep in sync: install.sh vs .deb/.rpm/Arch package vs dev mode.
_lpm_lang_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${_lpm_lang_script_dir}" in
    /usr/local/lib/lpm)             LANG_DIR="/usr/local/lib/lpm/lang" ;;
    /usr/lib/lpm)                   LANG_DIR="/usr/lib/lpm/lang" ;;
    # Used when zgl-launcher-runtime.sh is run through the "/run/host/..." fallback
    # ("lpm launcher ... on", Flatpak Lutris with lpm installed under /usr): same install
    # directory seen from inside the sandbox, so lang/ is again a direct subdirectory.
    /run/host/usr/local/lib/lpm)    LANG_DIR="/run/host/usr/local/lib/lpm/lang" ;;
    /run/host/usr/lib/lpm)          LANG_DIR="/run/host/usr/lib/lpm/lang" ;;
    *)                              LANG_DIR="${_lpm_lang_script_dir}/../lang" ;;
esac

declare -gA STRINGS=()

# Load a "key=value" file into STRINGS (overwrites existing keys)
_lpm_load_lang_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 1

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    # shellcheck disable=SC2249 # filter, not a dispatch: lines not matching
    # "#*" fall through to the key=value parsing below, as intended.
    case "${line}" in
      \#*) continue ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"
    [[ -z "${key}" ]] && continue

    STRINGS["${key}"]="${value}"
  done < "${file}"

  return 0
}

# 1. Mandatory English base
if ! _lpm_load_lang_file "${LANG_DIR}/en.lang"; then
  echo "Critical error: base language file not found: ${LANG_DIR}/en.lang" >&2
  exit 1
fi

# 2. Detect the system language, lowercase 2-letter code
_lpm_detected_locale="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
_lpm_detected_code="${_lpm_detected_locale%%[._]*}"
_lpm_detected_code="${_lpm_detected_code,,}"
[[ -z "${_lpm_detected_code}" ]] && _lpm_detected_code="en"

# 3. Override with the detected language if present (per-key fallback)
if [[ "${_lpm_detected_code}" != "en" ]]; then
  _lpm_load_lang_file "${LANG_DIR}/${_lpm_detected_code}.lang"
fi

# Translated-text accessor: t <key> [arguments for %s / %d...]
# Appends the trailing newline itself (like "echo"), so call it directly: t my.key "$arg".
# Output captured via "$(...)" is unaffected: command substitution strips that newline.
# Example: t list_games.db_missing "$lutris_db"
t() {
  local key="$1"
  shift
  local template="${STRINGS[${key}]:-${key}}"
  # Protect the real %s/%d specifiers (the only ones this project uses) with sentinels
  # (unlikely control bytes) BEFORE escaping the remaining lone '%' (e.g. a literal "50%"
  # in a translation, which would otherwise break the printf format). Doing it in this
  # order ensures only a %s/%d present verbatim in the translation source is kept as a
  # specifier.
  template="${template//%s/$'\x01'}"
  template="${template//%d/$'\x02'}"
  template="${template//%/%%}"
  template="${template//$'\x01'/%s}"
  template="${template//$'\x02'/%d}"
  # shellcheck disable=SC2059
  printf -- "${template}\n" "$@"
}
