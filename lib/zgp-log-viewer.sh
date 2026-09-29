#!/bin/bash

# --- lpm log ---
#
# Consultation du journal écrit par zgu_log (lib/zgu-log-utils.sh). Ne modifie jamais le
# journal, sauf --clear (avec confirmation explicite, jamais en une seule commande -y comme
# install/uninstall : la perte du journal n'a pas de garde-fou fonctionnel équivalent au
# "slug déjà installé", une confirmation systématique est donc volontairement plus stricte
# ici qu'ailleurs dans lpm).
#
# Usage :
#   lpm log                    Affiche les 50 dernières lignes (les plus récentes en dernier)
#   lpm log -n <N>              Affiche les N dernières lignes
#   lpm log --all                Affiche tout le journal
#   lpm log --grep <motif>       Filtre les lignes contenant <motif> (commande, statut, slug...)
#   lpm log --clear               Vide le journal (confirmation demandée)

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
      # Purge aussi le fichier de rotation (lpm.log.1, voir zgu_log_rotate_if_needed) :
      # "vider le journal" doit vider tout ce que "lpm log" peut potentiellement
      # référencer, pas seulement le fichier courant.
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

# Filtrage éventuel (--grep), puis limitation du nombre de lignes (sauf --all) -- dans cet
# ordre : filtrer d'abord garantit que "-n 50" porte bien sur les 50 dernières lignes
# CORRESPONDANTES, pas sur les 50 dernières lignes brutes parmi lesquelles seules quelques-
# unes correspondraient.
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
