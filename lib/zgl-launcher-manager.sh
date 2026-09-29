#!/bin/bash

# --- lpm launcher [slug...] [on|off] ---
#
# Active/désactive le "LPM Launcher" (écran noir + splash + verrou manette, avec picker
# multi-exécutable optionnel) pour un ou plusieurs jeux Wine/Proton de Lutris. Conception
# validée en amont (voir échange complet) :
#
#   1. "on" ne demande AUCUN choix single/multi -- ça n'avait pas de sens : le nombre
#      d'entrées réellement utilisées au lancement est de toute façon relu dynamiquement
#      dans le YAML à chaque lancement du jeu (voir zgl-launcher-runtime.sh), jamais figé
#      par quoi que ce soit décidé ici. "on" écrit donc TOUJOURS la même chose : une
#      première entrée auto-remplie depuis le game.exe/working_dir déjà configurés dans
#      Lutris (rien à éditer à la main pour un jeu à un seul exécutable), PLUS une
#      deuxième entrée d'exemple commentée dans lpm-launcher.yml -- à décommenter/adapter
#      à la main si le jeu a plusieurs exécutables (épisodes, DLC, campagnes...). C'est
#      entièrement à l'utilisateur d'ajouter ou non des entrées ensuite, lpm ne lui
#      impose aucun choix à l'activation.
#   2. Détection "déjà actif" : un jeu "a" le launcher si son game.exe pointe vers
#      lpm-launch.bat -- relu directement depuis le YAML à chaque lancement de cette
#      commande, jamais de fichier de suivi séparé (source de vérité unique).
#   3. Activation : sauvegarde l'exe/working_dir d'origine (clé "original_exe" du nouveau
#      lpm-launcher.yml), convertit les chemins natifs Linux en chemins Windows (C:\...)
#      via winepath -w -- nécessaire uniquement pour l'entrée auto-remplie, l'utilisateur
#      tape lui-même en Windows pour toute entrée ajoutée à la main. Crée
#      $GAMEDIR/scripts/lpm-launcher.sh (relais, appelle zgl-launcher-runtime.sh). AUCUNE
#      image splash par défaut n'est copiée : l'absence de $GAMEDIR/splash/splash.png
#      signifie "écran de chargement noir uni" pour l'orchestrateur (voir
#      lib/zgl-launcher-orchestrator.sh) -- un splash.png déjà présent (personnalisation
#      existante) n'est jamais touché. Branche system.prelaunch_command et règle game.exe
#      sur lpm-launch.bat.
#   4. Désactivation : restaure l'exe d'origine depuis "original_exe", retire
#      system.prelaunch_command (seulement s'il référence bien notre script relais),
#      affiche une alerte invitant à vérifier l'exécutable dans Lutris. Ne supprime JAMAIS
#      lpm-launcher.yml/scripts//splash/ (non destructif, réactivable plus tard).
#   5. Jeux Wine/Proton uniquement (runner='wine'), préfixes partagés inclus (opération non
#      destructive, même principe que "lpm tools"/"lpm lsfg").

cli_args=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-checklist-utils.sh
source "${script_dir}/zgu-checklist-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

# --- 0. Mode CLI vs GUI, et validation de la syntaxe CLI ---
will_use_zenity=true
cli_action=""
cli_slugs=()

if [[ ${#cli_args[@]} -gt 0 ]]; then
  will_use_zenity=false
  last_arg="${cli_args[-1]}"
  if [[ "${last_arg}" = "off" ]] || [[ "${last_arg}" = "on" ]]; then
    cli_action="${last_arg}"
    cli_slugs=("${cli_args[@]:0:$(( ${#cli_args[@]} - 1 ))}")
  fi
  if [[ -z "${cli_action}" ]] || [[ ${#cli_slugs[@]} -eq 0 ]]; then
    zgu_cli_error "$(t launcher.cli_usage)"
    exit 1
  fi
fi

display_mode="gui"
[[ "${will_use_zenity}" = false ]] && display_mode="cli"

zgp_launcher_report_error_early() {
  local msg="$1"
  if [[ "${will_use_zenity}" = true ]] && command -v zenity >/dev/null 2>&1; then
    zenity --error --text="${msg}" 2>/dev/null
  fi
  echo "${msg}" >&2
}

# Message de succès/information (pas une erreur) : en GUI, une boîte --info ; en CLI, rien
# ici -- le message équivalent est déjà affiché par la boucle d'exécution via zgu_cli_ok,
# pas la peine de l'imprimer deux fois.
zgp_launcher_report_info() {
  local msg="$1"
  if [[ "${will_use_zenity}" = true ]] && command -v zenity >/dev/null 2>&1; then
    zenity --info --text="${msg}" --width=500 2>/dev/null
  fi
}

if [[ "${will_use_zenity}" = true ]] && ! command -v zenity >/dev/null 2>&1; then
  zgu_cli_error "$(t launcher.zenity_missing)"
  exit 1
fi

for cmd in python3 sqlite3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgp_launcher_report_error_early "$(t launcher.cmd_missing "${cmd}")"
    exit 1
  fi
done
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  if [[ "${will_use_zenity}" = true ]]; then
    zenity --error --text="$(t launcher.pyyaml_missing_gui)" 2>/dev/null
  fi
  zgu_cli_error "$(t launcher.pyyaml_missing_cli)"
  exit 1
fi

# --- 1. Détection Flatpak vs Paquet natif + résolution des chemins Lutris ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"
lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"
lutris_flatpak_runners_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runners_dir="${HOME}/.local/share/lutris/runners/wine"
games_dir="${HOME}/Games"

version=$(zgu_resolve_lutris_version "${display_mode}" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgp_launcher_report_error_early "$(t launcher.lutris_missing)"
  exit 1
fi

if [[ "${version}" = "flatpak" ]]; then
  lutris_db="${lutris_flatpak_db}"
  lutris_config_dir="${lutris_flatpak_config_dir}"
  lutris_system_file="${lutris_flatpak_system_file}"
  lutris_runners_dir="${lutris_flatpak_runners_dir}"
else
  lutris_db="${lutris_package_db}"
  lutris_config_dir="${lutris_package_config_dir}"
  lutris_system_file="${lutris_package_system_file}"
  lutris_runners_dir="${lutris_package_runners_dir}"
fi

if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
fi

if [[ ! -f "${lutris_db}" ]]; then
  zgp_launcher_report_error_early "$(t launcher.db_missing "${lutris_db}")"
  exit 1
fi

# --- 2. Choix activer/désactiver ---
if [[ -n "${cli_action}" ]]; then
  action="${cli_action}"
else
  choice=$(zenity --list --radiolist \
    --title="$(t launcher.action_title)" \
    --text="$(t launcher.action_text)" \
    --column="" --column="$(t launcher.action_col)" \
    TRUE "$(t launcher.action_activate)" \
    FALSE "$(t launcher.action_deactivate)" \
    --width=420 --height=250 2>/dev/null)
  if [[ "${choice}" = "$(t launcher.action_activate)" ]]; then
    action="on"
  elif [[ "${choice}" = "$(t launcher.action_deactivate)" ]]; then
    action="off"
  else
    exit 0
  fi
fi

# --- 3. Liste des jeux Wine/Proton, filtrée par état actuel dans le YAML ---
games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(id,'') || char(31) || COALESCE(name,'') || char(31) || COALESCE(slug,'') || char(31) || COALESCE(directory,'') || char(31) || COALESCE(configpath,'') FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgp_launcher_report_error_early "$(t launcher.none_found)"
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

# Retourne 0 (vrai) si game.exe pointe déjà vers lpm-launch.bat pour ce jeu.
zgp_launcher_is_active() {
  local configpath="$1" yml_file
  [[ -z "${configpath}" ]] && return 1
  yml_file="${lutris_config_dir}/${configpath}.yml"
  [[ -f "${yml_file}" ]] || return 1
  YML_PATH="${yml_file}" python3 -c '
import os, sys, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
    exe = (data.get("game") or {}).get("exe") or ""
    sys.exit(0 if os.path.basename(exe) == "lpm-launch.bat" else 1)
except Exception:
    sys.exit(1)
' 2>/dev/null
}

declare -A active_by_slug
for g_slug in "${sorted_slugs[@]}"; do
  if zgp_launcher_is_active "${configpath_by_slug[${g_slug}]}"; then
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

if [[ "${will_use_zenity}" = false ]]; then
  # --- MODE CLI ---
  declare -A eligible_lookup
  for g_slug in "${eligible_slugs[@]}"; do
    eligible_lookup["${g_slug}"]=1
  done

  for target_slug in "${cli_slugs[@]}"; do
    if [[ -z "${name_by_slug[${target_slug}]:-}" ]]; then
      zgu_cli_error "$(t launcher.slug_not_found "${target_slug}")"
      exit 1
    fi
    if [[ -z "${eligible_lookup[${target_slug}]:-}" ]]; then
      if [[ "${action}" = "on" ]]; then
        zgu_cli_error "$(t launcher.already_active "${target_slug}")"
      else
        zgu_cli_error "$(t launcher.already_inactive "${target_slug}")"
      fi
      exit 1
    fi
    targets+=("${target_slug}")
  done
else
  # --- MODE GUI ---
  if [[ ${#eligible_slugs[@]} -eq 0 ]]; then
    if [[ "${action}" = "on" ]]; then
      zenity --info --text="$(t launcher.nothing_to_activate)" 2>/dev/null
    else
      zenity --info --text="$(t launcher.nothing_to_deactivate)" 2>/dev/null
    fi
    exit 0
  fi

  declare -A slug_by_name_eligible=()
  checklist_values=()
  for g_slug in "${eligible_slugs[@]}"; do
    checklist_values+=("${name_by_slug[${g_slug}]}" "${g_slug}")
    slug_by_name_eligible["${name_by_slug[${g_slug}]}"]="${g_slug}"
  done

  select_title="$(t launcher.select_title_activate)"
  [[ "${action}" = "off" ]] && select_title="$(t launcher.select_title_deactivate)"

  selected=$(zgu_gui_checklist_toggle_all "FALSE" 2 \
    "${select_title}" \
    "$(t launcher.select_text)" \
    650 450 \
    "$(t launcher.select_col_check)" "$(t launcher.select_col_game)" "$(t launcher.select_col_slug)" \
    -- \
    "${checklist_values[@]}")

  [[ -z "${selected}" ]] && exit 0

  IFS=$'\x1f' read -r -a selected_names <<< "${selected}"
  for g_name in "${selected_names[@]}"; do
    [[ -n "${slug_by_name_eligible[${g_name}]:-}" ]] && targets+=("${slug_by_name_eligible[${g_name}]}")
  done

  [[ ${#targets[@]} -eq 0 ]] && exit 0
fi

# --- 4. Application : activation ---
zgp_launcher_apply_on() {
  local slug="$1" game_dir="$2" configpath="$3"
  local yml_file="${lutris_config_dir}/${configpath}.yml"

  if [[ ! -f "${yml_file}" ]]; then
    zgp_launcher_report_error_early "$(t launcher.yml_missing "${slug}")"
    zgu_log "launcher" "ERREUR" "slug=${slug} raison=yaml_introuvable"
    return 1
  fi

  # Lit exe/working_dir/prefix/version actuels, résout le working_dir effectif exactement
  # comme Lutris lui-même (working_dir explicite, sinon dossier de l'exe -- voir source
  # Lutris consultée en amont : lutris/runners/wine.py, _get_explicit_working_dir()).
  local current_data
  current_data=$(YML_PATH="${yml_file}" GAME_PATH="${game_dir}" python3 -c '
import os, sys, yaml

with open(os.environ["YML_PATH"], "r") as f:
    data = yaml.safe_load(f) or {}

game = data.get("game") or {}
exe = str(game.get("exe") or "")
if exe and not os.path.isabs(exe):
    exe = os.path.join(os.environ.get("GAME_PATH",""), exe)

working_dir = str(game.get("working_dir") or "")
if not working_dir and exe:
    working_dir = os.path.dirname(exe)

prefix = str(game.get("prefix") or "")
version = str((data.get("wine") or {}).get("version") or "")

if not exe:
    sys.exit(1)

print(exe)
print(working_dir)
print(prefix)
print(version)
' 2>/dev/null)

  if [[ -z "${current_data}" ]]; then
    zgp_launcher_report_error_early "$(t launcher.no_current_exe "${slug}")"
    zgu_log "launcher" "ERREUR" "slug=${slug} raison=pas_exe_actuel"
    return 1
  fi

  local current_exe current_workdir current_prefix current_version
  { IFS= read -r current_exe; IFS= read -r current_workdir; IFS= read -r current_prefix; IFS= read -r current_version; } <<< "${current_data}"

  [[ -z "${current_prefix}" ]] && current_prefix="${game_dir}"

  # Résolution du binaire winepath : à côté du binaire wine du runner utilisé par ce jeu en
  # priorité (garantit la même résolution de lettres de lecteur que Lutris lui-même pour ce
  # préfixe précis), repli sur un "winepath" générique du PATH sinon.
  local wine_bin winepath_bin=""
  wine_bin=$(zgu_get_wine_binary "${lutris_runners_dir}" "${current_version}" 2>/dev/null)
  if [[ -n "${wine_bin}" ]] && [[ -x "$(dirname "${wine_bin}")/winepath" ]]; then
    winepath_bin="$(dirname "${wine_bin}")/winepath"
  elif command -v winepath >/dev/null 2>&1; then
    winepath_bin="winepath"
  fi

  local win_exe="" win_workdir=""
  if [[ -n "${winepath_bin}" ]]; then
    win_exe=$(WINEPREFIX="${current_prefix}" "${winepath_bin}" -w "${current_exe}" 2>/dev/null | tr -d '\r')
    win_workdir=$(WINEPREFIX="${current_prefix}" "${winepath_bin}" -w "${current_workdir}" 2>/dev/null | tr -d '\r')
  fi

  if [[ -z "${win_exe}" ]] || [[ -z "${win_workdir}" ]]; then
    zgp_launcher_report_error_early "$(t launcher.winepath_failed "${slug}")"
    zgu_log "launcher" "ERREUR" "slug=${slug} raison=winepath_echoue"
    return 1
  fi

  # Emplacement FIXE de lpm-launch.bat -- DANS drive_c (jamais à la racine de $GAMEDIR
  # comme dans une version précédente). Vérifié réel avec un vrai jeu (Wine/Proton, Lutris
  # Flatpak) : Lutris exécute un ".bat" via "cmd /C <nom>", avec le dossier du ".bat" comme
  # répertoire de travail du processus -- si ce dossier est hors de drive_c (ex: la racine
  # du préfixe), il n'est atteignable depuis Wine que si le préfixe a un lecteur Z:
  # (mappage de "/"), souvent absent des préfixes isolés par jeu -- confirmé : le jeu ne
  # démarrait pas du tout dans ce cas.
  #
  # Racine choisie : le sous-dossier direct de "drive_c/Games/" qui contient l'exe (à sa
  # racine ou dans n'importe lequel de ses propres sous-dossiers, peu importe la
  # profondeur) -- PAS "working_dir" (peut ne pas être défini, et même défini il ne
  # correspond pas forcément à cette racine-là) ni "dirname(exe)" (peut être arbitrairement
  # profond). Exemple concret : exe dans
  #   drive_c/Games/Jeu/sous/sous/sous/sous/sous/exe
  # avec un autre dossier "drive_c/Games/Truc" à côté -- le ".bat" doit aller dans
  #   drive_c/Games/Jeu/lpm-launch.bat
  # c'est-à-dire le premier niveau sous "Games/" qui mène (directement ou via ses propres
  # sous-dossiers) jusqu'à l'exe, jamais plus profond. "Games/" est le dossier
  # d'installation standard utilisé par les installateurs Lutris/lpm.
  local drive_c games_root bat_dir bat_path_linux
  drive_c="${current_prefix}/drive_c"
  games_root="${drive_c}/Games"

  if [[ "${current_exe}" = "${games_root}/"* ]]; then
    local rel_to_games top_component
    rel_to_games="${current_exe#"${games_root}"/}"
    top_component="${rel_to_games%%/*}"
    bat_dir="${games_root}/${top_component}"
  else
    # Repli : installation hors de la convention drive_c/Games/<jeu>/... -- on ne peut pas
    # appliquer la règle ci-dessus sans connaître la convention réelle utilisée. On retombe
    # sur "current_workdir" (résolu plus haut, working_dir explicite de la config sinon
    # dirname(exe)), en le journalisant pour rester traçable.
    bat_dir="${current_workdir}"
    zgu_log "launcher" "AVERT" "slug=${slug} raison=exe_hors_convention_games bat_dir=${bat_dir}"
  fi

  bat_path_linux="${bat_dir}/lpm-launch.bat"

  # --- Écriture de lpm-launcher.yml (entrée auto-remplie + repli exemple commenté) ---
  local default_label
  default_label="$(t launcher.default_entry_label)"

  YML_PATH="${game_dir}/lpm-launcher.yml" TITLE="${name_by_slug[${slug}]}" PROMPT="$(t launcher.default_prompt)" \
    LABEL="${default_label}" WORKDIR="${win_workdir}" EXE="${win_exe}" ORIGINAL_EXE="${current_exe}" \
    BAT_PATH_LINUX="${bat_path_linux}" python3 -c '
import os, yaml

data = {
    "title": os.environ["TITLE"],
    "prompt": os.environ["PROMPT"],
    "original_exe": os.environ["ORIGINAL_EXE"],
    "bat_path": os.environ["BAT_PATH_LINUX"],
    "entries": [
        {"label": os.environ["LABEL"], "workdir": os.environ["WORKDIR"], "exe": os.environ["EXE"]},
    ],
}
with open(os.environ["YML_PATH"], "w") as f:
    yaml.dump(data, f, sort_keys=False, allow_unicode=True)
' 2>/dev/null
  if [[ $? -ne 0 ]]; then
    zgp_launcher_report_error_early "$(t launcher.yaml_write_failed "${slug}")"
    zgu_log "launcher" "ERREUR" "slug=${slug} raison=ecriture_yaml_echouee"
    return 1
  fi

  {
    echo "# $(t launcher.example_entry_comment)"
    echo "#  - label: \"$(t launcher.example_entry_label)\""
    echo "#    workdir: \"C:\\\\Games\\\\...\""
    echo "#    exe: \"C:\\\\Games\\\\...\\\\jeu.exe\""
  } >> "${game_dir}/lpm-launcher.yml"

  # --- Dossier scripts/ ---
  #
  # AUCUNE image splash par défaut n'est plus copiée ici : depuis l'introduction de
  # l'orchestrateur (lib/zgl-launcher-orchestrator.sh), l'absence de
  # "${game_dir}/splash/splash.png" signifie explicitement "écran de chargement noir uni"
  # -- copier une image par défaut ici irait à l'encontre de ce choix pour tout jeu activant
  # le LPM Launcher pour la première fois. Le dossier splash/ lui-même n'est donc plus créé
  # d'office non plus : il est créé par l'orchestrateur au moment où une vraie image y est
  # déposée par l'utilisateur (ou jamais, si le noir uni convient). Un splash.png déjà
  # présent (personnalisation existante, ou dossier splash/ d'un jeu activé avant ce
  # changement) n'est jamais touché ni supprimé par "lpm launcher ... on".
  mkdir -p "${game_dir}/scripts"

  cat > "${game_dir}/scripts/lpm-launcher.sh" <<EOF
#!/bin/bash
# Relais généré par "lpm launcher" -- ne modifie jamais ce fichier à la main, il est
# réécrit à chaque (ré)activation. La vraie logique vit dans l'installation de lpm.
exec bash "${script_dir}/zgl-launcher-runtime.sh" "${game_dir}"
EOF
  chmod +x "${game_dir}/scripts/lpm-launcher.sh"

  # --- Branchement dans la config Lutris : game.exe + system.prelaunch_command ---
  #
  # PAS de "bash" devant le chemin du relais : le fichier est déjà exécutable (chmod +x
  # ci-dessus) et porte son propre shebang -- l'ajouter est inutile et n'a jamais été la
  # cause d'un quelconque souci (vérifié).
  #
  # "prelaunch_wait: true" est INDISPENSABLE : par défaut (absent), Lutris lance
  # prelaunch_command EN ARRIÈRE-PLAN et enchaîne IMMÉDIATEMENT sur le vrai lancement, en
  # parallèle -- confirmé dans le code source de Lutris (lutris/game.py,
  # start_prelaunch_command(), et lutris/sysoptions.py où "prelaunch_wait" a bien
  # default=False). Sans ce réglage, Wine peut tenter d'exécuter lpm-launch.bat avant même
  # que ce script ait fini de l'écrire -- confirmé réel : c'est exactement ce qui rendait le
  # jeu injouable au tout premier lancement.
  YML_PATH="${yml_file}" BAT_PATH="${bat_path_linux}" \
    PRELAUNCH="${game_dir}/scripts/lpm-launcher.sh" python3 -c '
import os, yaml

yml_path = os.environ["YML_PATH"]
with open(yml_path, "r") as f:
    data = yaml.safe_load(f) or {}

if "game" not in data or not isinstance(data.get("game"), dict):
    data["game"] = {}
data["game"]["exe"] = os.environ["BAT_PATH"]

if "system" not in data or not isinstance(data.get("system"), dict):
    data["system"] = {}
data["system"]["prelaunch_command"] = os.environ["PRELAUNCH"]
data["system"]["prelaunch_wait"] = True

with open(yml_path, "w") as f:
    yaml.dump(data, f, sort_keys=False)
' 2>/dev/null
  if [[ $? -ne 0 ]]; then
    zgp_launcher_report_error_early "$(t launcher.yaml_patch_failed "${slug}")"
    zgu_log "launcher" "ERREUR" "slug=${slug} raison=patch_lutris_yaml_echoue"
    return 1
  fi

  zgu_log "launcher" "OK" "slug=${slug} action=on"
  zgp_launcher_report_info "$(t launcher.setup_done "${name_by_slug[${slug}]}" "${game_dir}/lpm-launcher.yml")"

  # --- Lutris Flatpak : rappel de permission, best-effort ---
  #
  # Un Lutris installé en Flatpak tourne dans un bac à sable qui ne voit PAS forcément
  # "/usr/lib/lpm" (ou l'installation de lpm en cours d'exécution, quel que soit son
  # emplacement réel) -- confirmé réel : sans "host"/"host:ro" ni ce chemin précis dans les
  # permissions Flatpak accordées, le relais ($GAMEDIR/scripts/lpm-launcher.sh, TOUJOURS
  # visible car sous $HOME) ne peut pas atteindre le vrai script runtime, et échoue
  # silencieusement -- rien dans le log de lpm, rien à l'écran, juste le jeu qui se lance
  # sans launcher, sans erreur visible. "flatpak info --show-permissions" est la seule
  # façon fiable de vérifier ça (voir doc Flatpak officielle : un chemin précis accordé via
  # "--filesystem=" est monté au MÊME chemin dans le bac à sable, jamais sous "/run/host/"
  # sauf pour les permissions larges "host"/"host-os"/"host-etc"). Simple rappel
  # informatif, jamais bloquant -- la commande reste utilisable telle quelle si ce rappel
  # ne s'affiche pas correctement pour une raison ou une autre (flatpak absent, etc.).
  if [[ "${version}" = "flatpak" ]] && command -v flatpak >/dev/null 2>&1; then
    local fp_perms="" fp_ok=false
    fp_perms=$(flatpak info --show-permissions net.lutris.Lutris 2>/dev/null)
    if printf '%s' "${fp_perms}" | grep -Eq "filesystems=.*host(:ro)?(;|$)"; then
      fp_ok=true
    elif printf '%s' "${fp_perms}" | grep -qF "${script_dir}"; then
      fp_ok=true
    fi
    if [[ "${fp_ok}" = false ]]; then
      # On propose de l'appliquer nous-mêmes plutôt que de simplement afficher la commande
      # -- l'utilisateur confirme, lpm exécute "flatpak override" lui-même. Repli sur le
      # rappel manuel (ancien comportement) si la confirmation est refusée, ou si aucun
      # moyen de la demander n'est disponible (ni zenity, ni terminal interactif).
      local flatpak_question apply_now=false
      flatpak_question="$(t launcher.flatpak_permission_question "${script_dir}")"

      if [[ "${will_use_zenity}" = true ]] && command -v zenity >/dev/null 2>&1; then
        zenity --question --text="${flatpak_question}" --width=550 2>/dev/null && apply_now=true
      elif [[ -t 0 ]]; then
        echo "${flatpak_question}" >&2
        local reponse=""
        read -r -p "[o/N] " reponse </dev/tty 2>/dev/null
        [[ "${reponse,,}" =~ ^(o|oui|y|yes)$ ]] && apply_now=true
      fi

      if [[ "${apply_now}" = true ]]; then
        if flatpak override --user net.lutris.Lutris --filesystem="${script_dir}:ro" >/dev/null 2>&1; then
          local ok_msg
          ok_msg="$(t launcher.flatpak_permission_applied_ok)"
          if [[ "${will_use_zenity}" = true ]] && command -v zenity >/dev/null 2>&1; then
            zenity --info --text="${ok_msg}" --width=400 2>/dev/null
          else
            echo "${ok_msg}" >&2
          fi
          zgu_log "launcher" "OK" "slug=${slug} action=flatpak_override_applique"
        else
          local fail_msg
          fail_msg="$(t launcher.flatpak_permission_applied_fail "${script_dir}")"
          if [[ "${will_use_zenity}" = true ]] && command -v zenity >/dev/null 2>&1; then
            zenity --error --text="${fail_msg}" --width=550 2>/dev/null
          else
            echo "${fail_msg}" >&2
          fi
          zgu_log "launcher" "ERREUR" "slug=${slug} raison=flatpak_override_echoue"
        fi
      else
        local flatpak_hint
        flatpak_hint="$(t launcher.flatpak_permission_hint "${script_dir}")"
        if [[ "${will_use_zenity}" = true ]] && command -v zenity >/dev/null 2>&1; then
          zenity --info --text="${flatpak_hint}" --width=550 2>/dev/null
        else
          echo "${flatpak_hint}" >&2
        fi
      fi
    fi
  fi

  return 0
}

# --- 5. Application : désactivation ---
zgp_launcher_apply_off() {
  local slug="$1" game_dir="$2" configpath="$3"
  local yml_file="${lutris_config_dir}/${configpath}.yml"
  local launcher_yml="${game_dir}/lpm-launcher.yml"

  if [[ ! -f "${launcher_yml}" ]]; then
    zgp_launcher_report_error_early "$(t launcher.launcher_yml_missing "${slug}")"
    zgu_log "launcher" "ERREUR" "slug=${slug} raison=lpm_launcher_yml_introuvable"
    return 1
  fi

  local original_exe
  original_exe=$(YML_PATH="${launcher_yml}" python3 -c '
import os, yaml
with open(os.environ["YML_PATH"], "r") as f:
    data = yaml.safe_load(f) or {}
print(data.get("original_exe") or "")
' 2>/dev/null)

  if [[ -z "${original_exe}" ]]; then
    zgp_launcher_report_error_early "$(t launcher.no_original_exe "${slug}")"
    zgu_log "launcher" "ERREUR" "slug=${slug} raison=original_exe_absent"
    return 1
  fi

  YML_PATH="${yml_file}" ORIGINAL_EXE="${original_exe}" RELAY_MARKER="scripts/lpm-launcher.sh" python3 -c '
import os, yaml

yml_path = os.environ["YML_PATH"]
with open(yml_path, "r") as f:
    data = yaml.safe_load(f) or {}

if "game" not in data or not isinstance(data.get("game"), dict):
    data["game"] = {}
data["game"]["exe"] = os.environ["ORIGINAL_EXE"]

system = data.get("system")
if isinstance(system, dict):
    current = str(system.get("prelaunch_command") or "")
    if os.environ["RELAY_MARKER"] in current:
        system.pop("prelaunch_command", None)
        system.pop("prelaunch_wait", None)

with open(yml_path, "w") as f:
    yaml.dump(data, f, sort_keys=False)
' 2>/dev/null
  if [[ $? -ne 0 ]]; then
    zgp_launcher_report_error_early "$(t launcher.yaml_patch_failed "${slug}")"
    zgu_log "launcher" "ERREUR" "slug=${slug} raison=patch_lutris_yaml_echoue"
    return 1
  fi

  zgu_log "launcher" "OK" "slug=${slug} action=off"
  zgp_launcher_report_info "$(t launcher.teardown_done "${name_by_slug[${slug}]}")"
  return 0
}

exit_code=0
n_ok=0
for target_slug in "${targets[@]}"; do
  if [[ "${action}" = "on" ]]; then
    if zgp_launcher_apply_on "${target_slug}" "${dir_by_slug[${target_slug}]}" "${configpath_by_slug[${target_slug}]}"; then
      n_ok=$(( n_ok + 1 ))
      [[ "${will_use_zenity}" = false ]] && zgu_cli_ok "$(t launcher.done_one_on_cli "${name_by_slug[${target_slug}]}" "${dir_by_slug[${target_slug}]}/lpm-launcher.yml")"
    else
      exit_code=1
    fi
  else
    if zgp_launcher_apply_off "${target_slug}" "${dir_by_slug[${target_slug}]}" "${configpath_by_slug[${target_slug}]}"; then
      n_ok=$(( n_ok + 1 ))
      [[ "${will_use_zenity}" = false ]] && zgu_cli_ok "$(t launcher.done_one_off_cli "${name_by_slug[${target_slug}]}")"
    else
      exit_code=1
    fi
  fi
done

if [[ "${will_use_zenity}" = true ]] && [[ "${n_ok}" -eq 0 ]] && [[ "${exit_code}" -eq 0 ]]; then
  exit 0
fi

exit "${exit_code}"
