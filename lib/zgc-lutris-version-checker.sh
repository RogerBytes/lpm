#!/bin/bash

# --- lpm lutris-version ---
#
# Affiche les versions de Lutris détectées sur la machine (Flatpak / paquet natif), avec leur
# numéro de version et un statut à jour/dépassé, et permet de forcer/réinitialiser le choix
# utilisé par lpm quand les deux sont installées en même temps (voir zgu_resolve_lutris_version
# dans zgu-lutris-utils.sh, qui applique ce choix silencieusement à chaque lancement une fois
# sauvegardé). Cette commande ne fait QUE de l'affichage/configuration : la résolution
# effective utilisée par les autres commandes de lpm reste centralisée là-bas.

# --- Récupération des arguments du routeur lpm ---
# $1 = mode ("cli" ou "gui", même convention que zgc-dependency-checker.sh)
# $2 = sous-commande optionnelle : "flatpak", "native", "reset", ou vide (affichage seul)
mode="${1:-gui}"
sub_arg="${2:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

say() {
  if [[ "${mode}" = "cli" ]]; then
    echo "$1"
  else
    zenity --info --text="$1" --width=480 2>/dev/null
  fi
}

say_err() {
  if [[ "${mode}" = "cli" ]]; then
    echo "$1" >&2
  else
    zenity --error --text="$1" --width=480 2>/dev/null
  fi
}

if [[ "${mode}" != "cli" ]] && ! command -v zenity >/dev/null 2>&1; then
  zgu_cli_error "$(t lutris_version.zenity_missing)"
  exit 1
fi

# --- 1. Détection des installations réelles (mêmes chemins que les autres commandes) ---
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

# --- 2. Numéro de version installé, par méthode ---
# Flatpak : lu directement depuis "flatpak info", jamais deviné.
flatpak_version=""
if [[ "${has_flatpak}" = true ]]; then
  flatpak_version=$(flatpak info net.lutris.Lutris 2>/dev/null | awk -F': ' '/^ *Version:/ {print $2; exit}')
fi

# Paquet natif : en chaîne selon le gestionnaire de paquets réellement présent -- jamais une
# valeur de repli devinée si aucun des trois ne répond (voir docs/dernière feature.md pour la
# même philosophie ailleurs dans le projet : échouer proprement plutôt que deviner).
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

# --- 3. Dernière version connue en amont (GitHub, meilleur effort, jamais bloquant) ---
# Pas de nouvelle dépendance : curl/wget est déjà requis ailleurs dans lpm (runners). Un échec
# ici (hors ligne, rate-limit GitHub) ne doit jamais empêcher l'affichage des versions locales,
# seul le statut à jour/dépassé est alors simplement omis.
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

# Compare une version installée à latest_version. Écrit un statut traduit sur stdout, ou rien
# si la comparaison est impossible (version installée ou distante inconnue) -- l'appelant
# n'affiche alors que le numéro de version, sans statut, plutôt qu'une supposition.
# $2 = "native" ou "flatpak", pour le libellé "dépassée" adapté (voir décision : le paquet
# natif Debian/dérivés traîne structurellement derrière l'upstream, ce n'est pas une erreur
# utilisateur -- message court, sans détailler pourquoi, l'utilisateur saura chercher).
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
    # Version installée plus récente que le dernier tag GitHub connu (ex: build de dev,
    # pré-version) : pas "dépassée", mais "à jour" serait trompeur -- on n'affiche rien de
    # plus que le numéro, comme pour une comparaison impossible.
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

# --- 4. Sous-commandes : forcer un choix, ou le réinitialiser ---
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

# --- 5. Sans sous-commande : affichage, et proposition de choix si les deux sont présentes ---
if [[ "${mode}" = "cli" ]]; then
  print_detected_list
else
  full_text="$(print_detected_list)"
  zenity --text-info --title="$(t lutris_version.header)" --width=500 --height=250 <<< "${full_text}" 2>/dev/null
fi

if [[ "${has_flatpak}" = true ]] && [[ "${has_native}" = true ]]; then
  if [[ "${mode}" = "cli" ]]; then
    echo ""
    t lutris_version.hint_cli
  else
    selected=$(zenity --list --radiolist \
      --title="$(t lutris_version.select_title)" \
      --text="$(t lutris_version.select_text)" \
      --column="" --column="$(t lutris_version.select_col)" \
      FALSE "$(t lutris_version.label_flatpak)" \
      FALSE "$(t lutris_version.label_native)" \
      --width=420 --height=250 2>/dev/null)
    if [[ "${selected}" = "$(t lutris_version.label_flatpak)" ]]; then
      mkdir -p "$(dirname "${ZGU_LUTRIS_VERSION_CONFIG}")"
      echo "flatpak" > "${ZGU_LUTRIS_VERSION_CONFIG}"
      say "$(t lutris_version.forced_saved "$(t lutris_version.label_flatpak)")"
    elif [[ "${selected}" = "$(t lutris_version.label_native)" ]]; then
      mkdir -p "$(dirname "${ZGU_LUTRIS_VERSION_CONFIG}")"
      echo "native" > "${ZGU_LUTRIS_VERSION_CONFIG}"
      say "$(t lutris_version.forced_saved "$(t lutris_version.label_native)")"
    fi
  fi
else
  if [[ "${has_flatpak}" = true ]]; then
    say "$(t lutris_version.only_one_cli "$(t lutris_version.label_flatpak)")"
  else
    say "$(t lutris_version.only_one_cli "$(t lutris_version.label_native)")"
  fi
fi

exit 0
