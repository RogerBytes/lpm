#!/bin/bash

# --- lpm log ---
#
# Views the journal written by zgu_log (lib/zgu-log-utils.sh). Never modifies it, except
# with --clear (explicit confirmation required, never a single -y command like
# install/uninstall: losing the journal has no functional safeguard equivalent to
# "slug already installed", so a systematic confirmation is deliberately stricter here).
#
# Usage:
#   lpm log                    Show the last 50 lines (most recent last)
#   lpm log -n <N>              Show the last N lines
#   lpm log --all                Show the whole journal
#   lpm log --grep <pattern>     Filter lines containing <pattern> (command, status, slug...)
#   lpm log --clear               Empty the journal (confirmation asked)

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

lines_count=50
show_all=false
grep_pattern=""
do_clear=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n)
      shift
      if [[ -z "${1:-}" ]] || [[ ! "$1" =~ ^[0-9]+$ ]]; then
        zgu_cli_error "$(t log.bad_n_arg)"
        exit 1
      fi
      lines_count="$1"
      shift
      ;;
    --all)
      show_all=true
      shift
      ;;
    --grep)
      shift
      if [[ -z "${1:-}" ]]; then
        zgu_cli_error "$(t log.missing_grep_arg)"
        exit 1
      fi
      grep_pattern="$1"
      shift
      ;;
    --clear)
      do_clear=true
      shift
      ;;
    *)
      zgu_cli_error "$(t log.unknown_option "$1")"
      exit 1
      ;;
  esac
done

if [[ "${do_clear}" = true ]]; then
  if [[ ! -f "${ZGU_LOG_FILE}" ]] && [[ ! -f "${ZGU_LOG_FILE}.1" ]]; then
    t log.already_empty
    exit 0
  fi
  t log.clear_confirm_prompt "${ZGU_LOG_FILE}"
  read -r -p "$(t log.clear_confirm_input) " response
  case "${response}" in
    [oOyY]|[oO][uU][iI]|[yY][eE][sS])
      # Also purge the rotation file (lpm.log.1, see zgu_log_rotate_if_needed): "clear the
      # journal" must clear everything "lpm log" can reference, not only the current file.
      : > "${ZGU_LOG_FILE}"
      rm -f -- "${ZGU_LOG_FILE}.1" 2>/dev/null || true
      zgu_cli_ok "$(t log.cleared)"
      ;;
    *)
      t log.clear_cancelled
      ;;
  esac
  exit 0
fi

if [[ ! -f "${ZGU_LOG_FILE}" ]] || [[ ! -s "${ZGU_LOG_FILE}" ]]; then
  t log.empty "${ZGU_LOG_FILE}"
  exit 0
fi

# Optional filtering (--grep), then line-count limit (unless --all), in this order:
# filtering first ensures "-n 50" applies to the last 50 MATCHING lines, not to the last 50
# raw lines of which only a few might match.
if [[ -n "${grep_pattern}" ]]; then
  filtered=$(grep -F -- "${grep_pattern}" "${ZGU_LOG_FILE}")
else
  filtered=$(cat -- "${ZGU_LOG_FILE}")
fi

if [[ -z "${filtered}" ]]; then
  t log.no_match "${grep_pattern}"
  exit 0
fi

if [[ "${show_all}" = true ]]; then
  printf '%s\n' "${filtered}"
else
  printf '%s\n' "${filtered}" | tail -n "${lines_count}"
fi
