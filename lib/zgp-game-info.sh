#!/bin/bash

# --- lpm info <slug> ---
#
# Affiche les métadonnées connues d'un jeu Wine installé, en croisant la base Lutris
# (pga.db) et le fichier de configuration YAML du jeu (games/<configpath>.yml) : nom,
# slug, dossier du wineprefix, exécutable, version du runner Wine/Proton utilisée, date
# d'installation, et statut d'isolement (préfixe dédié, ou store partagé + store visé
# par "lpm isolate" le cas échéant).
#
# Un seul slug à la fois (contrairement à install/uninstall/pack qui acceptent une
# liste) : c'est une commande de consultation détaillée, pas d'action en lot.

# --- Récupération des arguments du routeur lpm ---
slug="${1:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"

if [[ -z "${slug}" ]]; then
  zgu_cli_error "$(t info.missing_slug)"
  exit 1
fi

lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

# 1. Vérification de sqlite3
if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t info.sqlite_missing)"
  exit 1
fi

# 2. Détection Flatpak vs Paquet natif (fonction fournie par zgu-lutris-utils.sh -- résout
# aussi le cas des deux installées en même temps)
lutris_version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
case "${lutris_version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    ;;
  native)
    lutris_db="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    ;;
  *)
    zgu_cli_error "$(t info.lutris_missing)"
    exit 1
    ;;
esac

if [[ ! -f "${lutris_db}" ]]; then
  zgu_cli_error "$(t info.db_missing "${lutris_db}")"
  exit 1
fi

# 3. Lecture de la ligne du jeu -- "runner='wine'" comme partout ailleurs dans lpm : un
# slug existant mais avec un autre runner (piste ajoutée manuellement à la base par
# l'utilisateur, hors lpm) n'est pas un jeu que lpm connaît.
safe_slug="${slug//\'/\'\'}"
row=$(sqlite3 "${lutris_db}" "SELECT COALESCE(name,'') || char(31) || COALESCE(directory,'') || char(31) || COALESCE(executable,'') || char(31) || COALESCE(configpath,'') || char(31) || COALESCE(installed_at,'') FROM games WHERE runner='wine' AND slug='${safe_slug}' LIMIT 1;" 2>/dev/null)

if [[ -z "${row}" ]]; then
  zgu_cli_error "$(t info.not_found "${slug}")"
  exit 1
fi

IFS=$'\x1f' read -r game_name game_dir game_exe game_configpath game_installed_at <<< "${row}"

# 4. Résolution en chemin réel du wineprefix (même prudence que le reste de lpm : la
# valeur vient de la base Lutris, potentiellement éditée à la main) -- purement pour
# affichage ici, jamais utilisée pour écrire ou supprimer quoi que ce soit.
real_dir=$(realpath -e "${game_dir}" 2>/dev/null)
[[ -z "${real_dir}" ]] && real_dir="${game_dir}"

# 5. Version du runner Wine/Proton effectivement utilisée par CE jeu (clé wine.version
# du YAML de config, même lecture que zgc-dependency-checker.sh) -- distincte du runner
# par défaut global (zgu_get_default_runner) : un jeu peut avoir été installé avec un
# runner spécifique différent du défaut actuel.
runner_version=""
if [[ -n "${game_configpath}" ]]; then
  # configpath vient de la base Lutris : même filtrage anti-traversée que
  # zgp-game-isolator.sh (pas de "/", sinon on refuse de construire le chemin) -- ici en
  # lecture seule, mais la prudence reste la même qu'ailleurs dans lpm.
  if [[ "${game_configpath}" != *"/"* ]]; then
    yml_path="${lutris_config_dir}/${game_configpath}.yml"
    if [[ -f "${yml_path}" ]] && command -v python3 >/dev/null 2>&1; then
      runner_version=$(YML_PATH="${yml_path}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        print(data.get("wine", {}).get("version", ""))
except Exception:
    pass
' 2>/dev/null)
    fi
  fi
fi
[[ -z "${runner_version}" ]] && runner_version="$(t info.unknown)"

# 6. Date d'installation (installed_at, timestamp Unix en secondes -- voir l'INSERT dans
# zgp-game-installer.sh/zgp-game-isolator.sh) -- repli sur la valeur brute si "date" ne
# sait pas la formater (locale/format inattendu) plutôt que d'afficher un champ vide.
installed_display="${game_installed_at}"
if [[ "${game_installed_at}" =~ ^[0-9]+$ ]]; then
  formatted=$(date -d "@${game_installed_at}" +%F 2>/dev/null)
  [[ -n "${formatted}" ]] && installed_display="${formatted}"
fi
[[ -z "${installed_display}" ]] && installed_display="$(t info.unknown)"

# 7. Statut d'isolement : préfixe dédié (un-jeu-un-préfixe, le cas normal), ou préfixe
# partagé -- auquel cas on précise le store visé si reconnu (même détection que "lpm
# isolate"/"lpm list-isolable", voir zgu_detect_isolation_store) pour ne jamais afficher
# une info qui divergerait de ce que ces commandes feraient réellement.
isolation_status="$(t info.isolation_dedicated)"
if [[ -n "${real_dir}" ]]; then
  shared_count=$(sqlite3 "${lutris_db}" "SELECT COUNT(*) FROM games WHERE runner='wine' AND directory='${real_dir//\'/\'\'}';" 2>/dev/null)
  if [[ "${shared_count:-0}" -gt 1 ]]; then
    store=$(zgu_detect_isolation_store "${lutris_db}" "${real_dir}")
    if [[ -n "${store}" ]]; then
      store_label=$(zgu_store_display_name "${store}")
      isolation_status="$(t info.isolation_shared_known "${store_label}" "${slug}")"
    else
      isolation_status="$(t info.isolation_shared_unknown)"
    fi
  fi
fi

# 8. Affichage
t info.field_name "${game_name}"
t info.field_slug "${slug}"
t info.field_directory "${real_dir}"
t info.field_executable "${game_exe:-$(t info.unknown)}"
t info.field_runner_version "${runner_version}"
t info.field_installed_at "${installed_display}"
t info.field_isolation "${isolation_status}"

exit 0
