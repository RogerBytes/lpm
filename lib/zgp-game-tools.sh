#!/bin/bash

# --- lpm tools : menu d'outils Wine pour un jeu (winetricks, éditeur de registre,
# winecfg, console DOS, exécuter un .exe, ouvrir le dossier du prefixe) ---
#
# Objectif : reproduire EXACTEMENT le comportement de Lutris pour ces outils (même
# binaire wine, mêmes variables d'environnement), vérifié dans son code source
# (lutris/runners/commands/wine.py et lutris/util/wine/wine.py) plutôt que deviné :
#   - Pas de flatpak-spawn/host-spawn : Lutris appelle le binaire wine directement, que
#     Lutris (et donc lpm) tourne en Flatpak ou en paquet natif.
#   - Le binaire utilisé est celui du runner CONFIGURÉ POUR CE JEU (wine.version dans son
#     YAML), jamais un "wine" générique du PATH -- winecfg/regedit/winetricks tournant
#     avec une version différente de celle utilisée pour lancer le jeu donnerait un
#     comportement incohérent (clés de registre, DLL builtin différentes...).
#   - WINEDLLOVERRIDES est reconstruit avec le MÊME algorithme que get_overrides_env()
#     de Lutris (buckets par valeur normalisée, "winemenubuilder" toujours désactivé).
#   - Winetricks : le binaire embarqué par Lutris (RUNTIME_DIR/winetricks/winetricks)
#     est préféré, sauf si le jeu a l'option "system_winetricks" activée -- exactement le
#     choix que ferait Lutris pour CE jeu.
#
# Simplification assumée (pas une approximation au hasard, un choix délibéré) : Lutris
# ajoute aussi LD_LIBRARY_PATH vers son "Lutris Runtime" (libs de compatibilité qu'il
# télécharge lui-même). La structure exacte de ce dossier n'est pas stable/documentée
# assez précisément pour être reproduite sans risque de se tromper -- et elle sert
# surtout à faire tourner des JEUX (DXVK/VKD3D/etc.), pas des utilitaires Win32 basiques
# comme winecfg/regedit/cmd. Elle n'est donc PAS reproduite ici : en cas de souci precis
# lié à ça sur une distro exotique, à revoir plus tard avec un vrai cas concret.
#
# WINEARCH n'est pas non plus forcé : le prefixe existe déjà (créé par Lutris ou par lpm),
# Wine détecte son architecture depuis system.reg tout seul. Le forcer risquerait au
# contraire de casser un prefixe si jamais la valeur lue diffère de la réalité.

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-focus-utils.sh
source "${script_dir}/zgu-focus-utils.sh"

# --- Arguments ---
# $1 = slug ciblé (optionnel -- sélection interactive dans une liste si absent)
# $2 = outil ciblé, CLI pur, sans aucun zenity (optionnel -- menu radiolist si absent) :
#      winetricks | regedit | winecfg | console | exe | folder
# $3 = chemin de l'exécutable (uniquement pour $2=exe en CLI pur)
cli_slug="${1:-}"
cli_tool="${2:-}"
cli_exe_path="${3:-}"

# Cette feature a toujours besoin de zenity pour au moins une étape (sélection du jeu
# et/ou du fichier .exe), SAUF quand slug ET outil sont fournis en CLI (et, pour "exe",
# le chemin aussi) : dans ce cas précis, tout se fait sans aucune fenêtre.
will_use_zenity=true
if [[ -n "${cli_slug}" ]] && [[ -n "${cli_tool}" ]]; then
  if [[ "${cli_tool}" != "exe" ]] || [[ -n "${cli_exe_path}" ]]; then
    will_use_zenity=false
  fi
fi

if [[ "${will_use_zenity}" = true ]] && ! command -v zenity >/dev/null 2>&1; then
  t game_tools.zenity_missing
  exit 1
fi
if [[ "${will_use_zenity}" = true ]]; then
  zgu_start_focus_watcher
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  zgu_cli_error "$(t game_tools.sqlite3_missing)"
  exit 1
fi

# --- Détection Flatpak vs paquet natif (mêmes chemins/conventions que le reste du projet) ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"

lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# RUNTIME_DIR de Lutris : DATA_DIR/runtime (settings.py de Lutris, vérifié dans son code
# source) -- c'est là que vit son winetricks embarqué (RUNTIME_DIR/winetricks/winetricks).
lutris_flatpak_runtime_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runtime"
lutris_package_runtime_dir="${HOME}/.local/share/lutris/runtime"

game_tools_display_mode="gui"
[[ "${will_use_zenity}" = false ]] && game_tools_display_mode="cli"
lutris_version=$(zgu_resolve_lutris_version "${game_tools_display_mode}" "${lutris_package_db}" "${lutris_package_runner_dir}")
if [[ -z "${lutris_version}" ]]; then
  zenity --error --text="$(t game_tools.lutris_missing_gui)" 2>/dev/null
  zgu_cli_error "$(t game_tools.lutris_missing_cli)"
  exit 1
fi

case "${lutris_version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_system_file="${lutris_flatpak_system_file}"
    runner_dir="${lutris_flatpak_runner_dir}"
    runtime_dir="${lutris_flatpak_runtime_dir}"
    ;;
  native)
    lutris_db="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    lutris_system_file="${lutris_package_system_file}"
    runner_dir="${lutris_package_runner_dir}"
    runtime_dir="${lutris_package_runtime_dir}"
    ;;
esac

games_dir="${HOME}/Games"
if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
fi

if ! command -v sqlite3 >/dev/null 2>&1 || [[ ! -f "${lutris_db}" ]]; then
  zenity --info --text="$(t game_tools.no_games_found "${games_dir}")" 2>/dev/null
  zgu_cli_error "$(t game_tools.no_games_found_cli "${games_dir}")"
  exit 1
fi

# Résout le chemin réel et sûr du prefixe d'un slug (même garde anti-évasion que
# zgp-game-packer.sh : le chemin doit rester un sous-dossier réel de games_dir).
resolve_prefix_dir_by_slug() {
  local slug="$1" safe_slug raw_dir real_dir real_games_dir
  safe_slug="${slug//\'/\'\'}"
  raw_dir=$(sqlite3 "${lutris_db}" "SELECT directory FROM games WHERE slug='${safe_slug}' AND runner='wine' LIMIT 1;" 2>/dev/null)
  [[ -z "${raw_dir}" ]] && return 1

  real_dir=$(realpath -e "${raw_dir}" 2>/dev/null)
  real_games_dir=$(realpath -e "${games_dir}" 2>/dev/null)
  if [[ -z "${real_dir}" ]] || [[ -z "${real_games_dir}" ]] || [[ "${real_dir}" != "${real_games_dir}/"* ]]; then
    return 1
  fi
  echo "${real_dir}"
}

# --- 1. Sélection du jeu (slug CLI fourni, ou liste interactive) ---
#
# Pas d'exclusion des jeux en prefixe partagé (Epic/EA/Ubisoft...) ici : contrairement
# au pack (export) ou à l'uninstall, cette feature ne touche/n'exporte rien, elle se
# contente de lancer des outils DANS le prefixe existant -- confirmé voulu ainsi.
target_slug="" target_name="" target_configpath=""

if [[ -n "${cli_slug}" ]]; then
  target_slug=$(basename -- "${cli_slug}")
  row=$(sqlite3 "${lutris_db}" "SELECT name || char(31) || configpath FROM games WHERE slug='${target_slug//\'/\'\'}' AND runner='wine' LIMIT 1;" 2>/dev/null)
  if [[ -z "${row}" ]]; then
    zgu_cli_error "$(t game_tools.slug_not_found_cli "${target_slug}")"
    exit 1
  fi
  IFS=$'\x1f' read -r target_name target_configpath <<< "${row}"
else
  games_rows=$(sqlite3 "${lutris_db}" "SELECT slug || char(31) || name || char(31) || configpath FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)
  if [[ -z "${games_rows}" ]]; then
    zenity --info --text="$(t game_tools.no_games_found "${games_dir}")" 2>/dev/null
    exit 0
  fi

  declare -A slug_by_name configpath_by_name
  radio_rows=()
  first=true
  while IFS=$'\x1f' read -r row_slug row_name row_configpath; do
    [[ -z "${row_slug}" ]] && continue
    resolved=$(resolve_prefix_dir_by_slug "${row_slug}") || continue
    slug_by_name["${row_name}"]="${row_slug}"
    configpath_by_name["${row_name}"]="${row_configpath}"
    if [[ "${first}" = true ]]; then
      radio_rows+=("TRUE" "${row_name}")
      first=false
    else
      radio_rows+=("FALSE" "${row_name}")
    fi
  done <<< "${games_rows}"

  if [[ ${#radio_rows[@]} -eq 0 ]]; then
    zenity --info --text="$(t game_tools.no_games_found "${games_dir}")" 2>/dev/null
    exit 0
  fi

  selected_name=$(zenity --list --radiolist \
    --title="$(t game_tools.select_title)" \
    --text="$(t game_tools.select_text)" \
    --column="" --column="$(t game_tools.select_col_name)" \
    --width=500 --height=450 \
    "${radio_rows[@]}" 2>/dev/null)

  [[ -z "${selected_name}" ]] && exit 0

  target_name="${selected_name}"
  target_slug="${slug_by_name[${selected_name}]}"
  target_configpath="${configpath_by_name[${selected_name}]}"
fi

prefix_dir=$(resolve_prefix_dir_by_slug "${target_slug}")
if [[ -z "${prefix_dir}" ]]; then
  zenity --error --text="$(t game_tools.prefix_not_found_gui "${target_name}")" 2>/dev/null
  zgu_cli_error "$(t game_tools.prefix_not_found_cli "${target_name}")"
  exit 1
fi

# --- 2. Lecture de la config Wine du jeu (version du runner, system_winetricks, overrides) ---
wine_version=""
system_winetricks="0"
overrides_env="winemenubuilder="

if [[ -n "${target_configpath}" ]]; then
  yml_config_file="${lutris_config_dir}/${target_configpath}.yml"
  if [[ -f "${yml_config_file}" ]] && command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then
    parsed=$(YML_PATH="${yml_config_file}" python3 -c '
import os
import yaml

yml_path = os.environ["YML_PATH"]
version = ""
system_winetricks = "0"
overrides_str = "winemenubuilder="

try:
    with open(yml_path, "r") as f:
        data = yaml.safe_load(f) or {}
    wine_cfg = data.get("wine")
    if isinstance(wine_cfg, dict):
        version = wine_cfg.get("version") or ""
        if wine_cfg.get("system_winetricks"):
            system_winetricks = "1"

        # Reproduction fidele de get_overrides_env() de Lutris
        # (lutris/util/wine/wine.py) : memes buckets, meme normalisation,
        # "winemenubuilder" toujours force a desactive (ecrase une eventuelle
        # valeur utilisateur, exactement comme le fait Lutris).
        overrides = wine_cfg.get("overrides")
        overrides = dict(overrides) if isinstance(overrides, dict) else {}
        overrides["winemenubuilder"] = ""

        buckets = {"n,b": [], "b,n": [], "b": [], "n": [], "d": [], "": []}
        for dll, value in overrides.items():
            v = value or ""
            v = v.replace(" ", "").replace("builtin", "b").replace("native", "n").replace("disabled", "")
            if v in buckets:
                buckets[v].append(dll)

        parts = []
        for value, dlls in buckets.items():
            if dlls:
                parts.append("{}={}".format(",".join(sorted(dlls)), value))
        overrides_str = ";".join(parts)
except Exception:
    pass

print(f"{version}\x1f{system_winetricks}\x1f{overrides_str}")
' 2>/dev/null)
    IFS=$'\x1f' read -r wine_version system_winetricks overrides_env <<< "${parsed}"
  fi
fi

[[ -z "${wine_version}" ]] && wine_version=$(zgu_get_default_runner)

wine_bin=$(zgu_get_wine_binary "${runner_dir}" "${wine_version}")
if [[ -z "${wine_bin}" ]]; then
  zenity --error --text="$(t game_tools.runner_missing_gui "${wine_version}")" 2>/dev/null
  zgu_cli_error "$(t game_tools.runner_missing_cli "${wine_version}")"
  exit 1
fi

# --- 3. Résolution du binaire winetricks (embarqué Lutris, sauf si le jeu utilise
# explicitement le winetricks système -- exactement le choix que ferait Lutris pour ce
# jeu, voir find_winetricks() dans son code source) ---
embedded_winetricks="${runtime_dir}/winetricks/winetricks"
winetricks_bin=""
if [[ "${system_winetricks}" = "1" ]] || [[ ! -x "${embedded_winetricks}" ]]; then
  winetricks_bin=$(command -v winetricks 2>/dev/null || true)
else
  winetricks_bin="${embedded_winetricks}"
fi

# --- 4. Lancement en tâche de fond, détaché de ce script (setsid) -- confirmé voulu
# ainsi pour les 5 outils qui ouvrent une fenêtre (winetricks/regedit/winecfg/
# console/exe) : lpm ne doit jamais bloquer en attendant leur fermeture.
zgt_launch_detached() {
  setsid "$@" >/dev/null 2>&1 </dev/null &
  disown
}

# zgt_already_running <motif_pgrep>
# Vérifie si un process correspondant au motif donné (ex: "winecfg\.exe") tourne DÉJÀ
# pour CE prefixe précis (${prefix_dir}) -- pas juste "un winecfg quelque part sur la
# machine", qui pourrait très bien appartenir à un AUTRE jeu en cours d'édition en
# parallèle, ce qui ne doit surtout pas être bloqué. Le filtre se fait en lisant
# /proc/<pid>/environ (WINEPREFIX exact), pas en devinant depuis la ligne de commande
# (qui ne contient pas le prefixe pour winecfg.exe/regedit.exe -- seul WINEDLLOVERRIDES/
# WINEPREFIX sont passés en variables d'environnement, pas en argument).
# Code de retour 0 si un process tourne déjà pour ce prefixe, 1 sinon.
zgt_already_running() {
  local pattern="$1" pid environ_file
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    environ_file="/proc/${pid}/environ"
    [[ -r "${environ_file}" ]] || continue
    if tr '\0' '\n' < "${environ_file}" 2>/dev/null | grep -qxF "WINEPREFIX=${prefix_dir}"; then
      return 0
    fi
  done < <(pgrep -f -- "${pattern}" 2>/dev/null)
  return 1
}

run_winetricks() {
  if [[ -z "${winetricks_bin}" ]]; then
    zenity --error --text="$(t game_tools.winetricks_missing_gui)" 2>/dev/null
    zgu_cli_error "$(t game_tools.winetricks_missing_cli)"
    return 1
  fi
  if zgt_already_running "${winetricks_bin}"; then
    zenity --error --text="$(t game_tools.already_running_gui "${target_name}")" 2>/dev/null
    zgu_cli_error "$(t game_tools.already_running_cli "${target_name}")"
    return 1
  fi
  zgt_launch_detached env WINEPREFIX="${prefix_dir}" WINE="${wine_bin}" WINEDLLOVERRIDES="${overrides_env}" "${winetricks_bin}"
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

run_regedit() {
  if zgt_already_running 'regedit\.exe'; then
    zenity --error --text="$(t game_tools.already_running_gui "${target_name}")" 2>/dev/null
    zgu_cli_error "$(t game_tools.already_running_cli "${target_name}")"
    return 1
  fi
  zgt_launch_detached env WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="${overrides_env}" "${wine_bin}" regedit.exe
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

run_winecfg() {
  if zgt_already_running 'winecfg\.exe'; then
    zenity --error --text="$(t game_tools.already_running_gui "${target_name}")" 2>/dev/null
    zgu_cli_error "$(t game_tools.already_running_cli "${target_name}")"
    return 1
  fi
  zgt_launch_detached env WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="${overrides_env}" "${wine_bin}" winecfg.exe
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

run_console() {
  # CORRIGÉ après vérification directe dans le code source de Lutris (lutris/runners/
  # wine.py) : l'entrée "Ouvrir la console Wine" de son menu (le bouton verre de vin)
  # appelle run_wineconsole(), qui fait juste :
  #     self._run_executable("wineconsole")
  # et _run_executable() lance : wineexec("wineconsole", wine_path=self.get_executable(), ...)
  # -- c'est-à-dire, au final, simplement : "<binaire wine résolu> wineconsole". PAS de
  # cmd.exe en argument, PAS de recherche d'un fichier "wineconsole" séparé sur le disque.
  #
  # "wineconsole" est un composant INTÉGRÉ à Wine lui-même (comme "wine notepad" ou
  # "wine cmd") -- présent dans absolument tous les builds Wine, Proton inclus, même
  # quand aucun fichier "bin/wineconsole" séparé n'existe sur le disque (constaté : les
  # runners Proton de l'utilisateur n'ont pas ce fichier, contrairement aux vrais builds
  # Wine -- mais ça n'a jamais été la bonne piste : Lutris ne cherche jamais ce fichier
  # non plus, il passe toujours par le binaire wine principal).
  #
  # Explique aussi pourquoi la version précédente (repli sur "wine cmd.exe" en lancement
  # détaché, sans wineconsole) n'affichait rien : cmd.exe est une appli console qui
  # cherche à s'attacher à un terminal existant, alors que "wine wineconsole" ouvre son
  # PROPRE hôte de console graphique intégré à Wine -- comportement totalement différent,
  # qui n'a besoin d'aucun terminal hôte pour s'afficher. "cmd" est passé explicitement en
  # argument (plutôt que de compter sur un défaut non documenté) pour garantir le shell
  # attendu par l'utilisateur (une vraie console MS-DOS), au lieu du comportement par
  # défaut de wineconsole seul, jamais confirmé avec certitude dans sa documentation.
  #
  # Répertoire de démarrage : Wine calque son "répertoire courant" Windows sur le
  # répertoire courant UNIX du process au moment du lancement -- rien à voir avec
  # WINEPREFIX. Sans intervention, le script hérite du répertoire courant de lpm
  # lui-même (typiquement la racine du système ou le dossier d'où lpm a été lancé), donc
  # la console s'ouvrait là, hors du prefixe. On se place explicitement dans
  # "<prefixe>/drive_c" (le lecteur C: du prefixe) avant de lancer, pour que la console
  # démarre bien dans le prefixe du jeu -- avec repli sur la racine du prefixe si
  # "drive_c" n'existe pas pour une raison quelconque (prefixe non standard/corrompu).
  local console_start_dir="${prefix_dir}/drive_c"
  [[ -d "${console_start_dir}" ]] || console_start_dir="${prefix_dir}"
  (
    cd "${console_start_dir}" 2>/dev/null || cd "${prefix_dir}"
    zgt_launch_detached env WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="${overrides_env}" "${wine_bin}" wineconsole cmd
  )
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

run_exe() {
  local exe_path="$1"
  if [[ -z "${exe_path}" ]]; then
    exe_path=$(zenity --file-selection --title="$(t game_tools.exe_selection_title)" \
      --filename="${prefix_dir}/" 2>/dev/null)
    [[ -z "${exe_path}" ]] && return 0
  fi
  if [[ ! -f "${exe_path}" ]]; then
    zenity --error --text="$(t game_tools.exe_not_found_gui "${exe_path}")" 2>/dev/null
    zgu_cli_error "$(t game_tools.exe_not_found_cli "${exe_path}")"
    return 1
  fi
  zgt_launch_detached env WINEPREFIX="${prefix_dir}" WINEDLLOVERRIDES="${overrides_env}" "${wine_bin}" "${exe_path}"
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

run_folder() {
  zgt_launch_detached xdg-open "${prefix_dir}"
  zgu_cli_ok "$(t game_tools.launched_cli "${target_name}")"
}

# --- 5. Choix de l'outil (CLI pur si déjà fourni, sinon menu radiolist) ---
if [[ -n "${cli_tool}" ]]; then
  case "${cli_tool}" in
    winetricks) run_winetricks ;;
    regedit) run_regedit ;;
    winecfg) run_winecfg ;;
    console) run_console ;;
    exe) run_exe "${cli_exe_path}" ;;
    folder) run_folder ;;
    *)
      zgu_cli_error "$(t game_tools.invalid_tool_cli "${cli_tool}")"
      exit 1
      ;;
  esac
  exit $?
fi

opt_winetricks="$(t game_tools.action_winetricks)"
opt_regedit="$(t game_tools.action_regedit)"
opt_winecfg="$(t game_tools.action_winecfg)"
opt_console="$(t game_tools.action_console)"
opt_exe="$(t game_tools.action_exe)"
opt_folder="$(t game_tools.action_folder)"

# Boucle sur le menu d'outils (au lieu d'un lancement unique suivi d'un exit) --
# confirmé voulu ainsi : les outils se lancent en arrière-plan (zgt_launch_detached),
# donc rien n'empêche d'en enchaîner plusieurs pour LE MÊME jeu (ex: winecfg puis
# winetricks) sans avoir à retraverser tout le menu principal de lpm et re-sélectionner
# le jeu à chaque fois. Le menu ne se referme (et lpm ne rend la main au menu principal)
# que quand l'utilisateur annule explicitement (Annuler/Échap -- action_choice vide).
while true; do
  # Ré-évalué à CHAQUE tour (pas une seule fois avant la boucle) : l'état "en cours"
  # peut changer entre deux affichages (l'utilisateur ferme Winetricks pendant qu'il
  # regarde le menu, ou vient d'en ouvrir un autre juste avant). Uniquement pour les 3
  # outils confirmés concernés (winetricks/regedit/winecfg) -- pas console/exe/folder,
  # qui peuvent légitimement s'ouvrir plusieurs fois en parallèle sans conflit.
  label_winetricks="${opt_winetricks}"
  label_regedit="${opt_regedit}"
  label_winecfg="${opt_winecfg}"
  [[ -n "${winetricks_bin}" ]] && zgt_already_running "${winetricks_bin}" && \
    label_winetricks="${opt_winetricks}$(t game_tools.running_suffix)"
  zgt_already_running 'regedit\.exe' && \
    label_regedit="${opt_regedit}$(t game_tools.running_suffix)"
  zgt_already_running 'winecfg\.exe' && \
    label_winecfg="${opt_winecfg}$(t game_tools.running_suffix)"

  action_choice=$(zenity --list --radiolist \
    --title="$(t game_tools.action_title "${target_name}")" \
    --text="$(t game_tools.action_text)" \
    --column="" --column="$(t game_tools.action_col)" \
    --width=450 --height=350 \
    TRUE "${label_winetricks}" \
    FALSE "${label_regedit}" \
    FALSE "${label_winecfg}" \
    FALSE "${opt_console}" \
    FALSE "${opt_exe}" \
    FALSE "${opt_folder}" 2>/dev/null)

  [[ -z "${action_choice}" ]] && break

  case "${action_choice}" in
    "${label_winetricks}") run_winetricks ;;
    "${label_regedit}") run_regedit ;;
    "${label_winecfg}") run_winecfg ;;
    "${opt_console}") run_console ;;
    "${opt_exe}") run_exe "" ;;
    "${opt_folder}") run_folder ;;
  esac
done

exit 0
