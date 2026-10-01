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
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

# --- 0. Validation de la syntaxe CLI (bin/lpm n'a plus aucun point d'entrée interactif :
# plus de menu/sélection Zenity, uniquement cette commande explicite en terminal) ---
cli_action=""
cli_slugs=()

last_arg="${cli_args[-1]:-}"
if [[ "${last_arg}" = "off" ]] || [[ "${last_arg}" = "on" ]]; then
  cli_action="${last_arg}"
  cli_slugs=("${cli_args[@]:0:$(( ${#cli_args[@]} - 1 ))}")
fi
if [[ -z "${cli_action}" ]] || [[ ${#cli_slugs[@]} -eq 0 ]]; then
  zgu_cli_error "$(t launcher.cli_usage)"
  exit 1
fi

zgp_launcher_report_error_early() {
  local msg="$1"
  echo "${msg}" >&2
}

for cmd in python3 sqlite3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgp_launcher_report_error_early "$(t launcher.cmd_missing "${cmd}")"
    exit 1
  fi
done
if ! python3 -c "import yaml" >/dev/null 2>&1; then
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

version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
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

# --- 2. Choix activer/désactiver (CLI uniquement) ---
action="${cli_action}"

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

# --- Sélection des cibles (CLI uniquement : sélection graphique via Zenity retirée) ---
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

  # Écrit lpm-launch.bat DÈS CETTE ACTIVATION -- pas seulement au premier lancement réel
  # (voir zgl-launcher-runtime.sh, qui le réécrira de toute façon avec l'entrée alors
  # choisie). Nécessaire : "game.exe" est pointé vers ce chemin plus bas, DANS CETTE MÊME
  # activation -- si le fichier n'existe pas encore à ce moment-là, Lutris le signale comme
  # introuvable/bugue (constaté réel) avant même le premier lancement. Contenu identique au
  # modèle utilisé par zgl-launcher-runtime.sh, avec l'entrée auto-remplie par défaut
  # (win_workdir/win_exe, résolus plus haut).
  mkdir -p "${bat_dir}" 2>/dev/null
  {
    printf '@echo off\r\n'
    printf 'cd /d "%s"\r\n' "${win_workdir}"
    printf 'start "" "%s"\r\n' "${win_exe}"
  } > "${bat_path_linux}" 2>/dev/null

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
#
# Ce relais vit TOUJOURS sous \$HOME (donc visible même dans le bac à sable d'un Lutris
# Flatpak qui ne partage pas "/usr" par défaut). Le vrai script ("${script_dir}/
# zgl-launcher-runtime.sh") peut lui être invisible dans ce bac à sable si lpm est
# installé sous /usr -- MÊME quand la permission "host"/"host-os" est accordée à
# Lutris : cette permission ne remplace PAS le "/usr" du bac à sable (qui reste
# TOUJOURS celui du runtime Flatpak, jamais celui de l'hôte, pour la compatibilité des
# bibliothèques) -- elle rend le "/usr" de l'hôte visible à un AUTRE endroit,
# "/run/host/usr" (confirmé : c'est le comportement documenté de Flatpak pour "host"/
# "host-os"). Donc on essaie le chemin direct, PUIS ce second chemin avant d'abandonner.
# Si aucun des deux ne marche, RIEN n'était loggué avant ce correctif -- ce bloc écrit
# directement une ligne dans lpm.log (même format que zgu_log, mais sans dépendre du
# reste de l'installation lpm, justement injoignable dans ce cas précis) pour que
# "lpm log --grep launcher-runtime" dise clairement que le picker n'a pas pu
# s'afficher, et pourquoi.
runtime_script=""
for candidate in "${script_dir}/zgl-launcher-runtime.sh" "/run/host${script_dir}/zgl-launcher-runtime.sh"; do
  if [[ -r "\${candidate}" ]]; then
    runtime_script="\${candidate}"
    break
  fi
done

if [[ -z "\${runtime_script}" ]]; then
  # Chemin EN DUR sur \$HOME, jamais via \$XDG_DATA_HOME : Lutris en Flatpak redéfinit
  # cette variable vers son propre dossier de données privé (confirmé réel :
  # "XDG_DATA_HOME=~/.var/app/net.lutris.Lutris/data" dans son environnement) -- si ce
  # relais héritait de cette valeur, la ligne serait écrite dans un fichier que "lpm
  # log" ne lit jamais. lpm.log doit rester au même endroit partout, qu'on l'écrive
  # depuis un shell normal ou depuis l'intérieur d'un bac à sable Flatpak.
  log_dir="\${HOME}/.local/share/lpm"
  mkdir -p "\${log_dir}" 2>/dev/null
  printf '%s\t%s\t%s\t%s\n' \
    "\$(date +%FT%T%z 2>/dev/null)" "launcher-runtime" "ERREUR" \
    "gamedir=${game_dir} raison=runtime_introuvable_bac_a_sable script_dir=${script_dir}" \
    >> "\${log_dir}/lpm.log" 2>/dev/null
  # Pas de notification graphique ici (ancien "zenity --error" retiré, même principe que
  # zgl-launcher-runtime.sh) : déjà entièrement journalisé ci-dessus, et ce relais ne doit
  # jamais bloquer le lancement du jeu pour un souci qu'il ne peut pas afficher de façon
  # fiable (c'est précisément le cas où zenity lui-même serait injoignable aussi).
  exit 0
fi

exec bash "\${runtime_script}" "${game_dir}"
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

  # Le chemin de lpm-launcher.yml à éditer à la main est déjà donné tel quel par
  # zgu_cli_ok dans la boucle appelante -- plus de proposition d'ouverture de dossier
  # via Zenity ici, bin/lpm n'a plus aucun point d'entrée interactif.

  # --- Lutris Flatpak : rappel de permission, best-effort ---
  #
  # Un Lutris installé en Flatpak tourne dans un bac à sable qui ne voit PAS forcément
  # "/usr/lib/lpm" (ou l'installation de lpm en cours d'exécution, quel que soit son
  # emplacement réel) -- sans permission adéquate, le relais ($GAMEDIR/scripts/
  # lpm-launcher.sh, TOUJOURS visible car sous $HOME) ne peut pas atteindre le vrai
  # script runtime, et échouait silencieusement avant le correctif ci-dessus (qui logue
  # désormais ce cas précis dans lpm.log, voir plus haut).
  #
  # IMPORTANT (confirmé réel : "Not sharing "/usr/lib/lpm" with sandbox: Path "/usr" is
  # reserved by Flatpak") -- Flatpak refuse TOUJOURS un "--filesystem=<chemin>" précis
  # quand ce chemin est sous /usr, même après un "override" qui a l'air d'avoir réussi
  # (la commande elle-même ne renvoie aucune erreur, seul le montage réel au lancement
  # est refusé). Installer lpm sous /usr (cas par défaut de install.sh, /usr/local/
  # lib/lpm) rend donc l'ancien rappel ("--filesystem=${script_dir}:ro") inefficace : la
  # seule permission qui fonctionne pour un chemin sous /usr est la permission large
  # "host"/"host-os" (voir doc Flatpak : elle monte le vrai système hôte tel quel,
  # contournant la restriction propre aux chemins /usr précis). Donc : si lpm est
  # installé sous /usr, on demande/applique "host-os" ; sinon (install non standard
  # hors /usr), le chemin précis reste suffisant et plus restrictif, donc préféré.
  # Simple rappel informatif, jamais bloquant.
  if [[ "${version}" = "flatpak" ]] && command -v flatpak >/dev/null 2>&1; then
    local fp_perms="" fp_ok=false fp_needs_hostos=false
    fp_perms=$(flatpak info --show-permissions net.lutris.Lutris 2>/dev/null)
    case "${script_dir}" in
      /usr/*) fp_needs_hostos=true ;;
    esac
    if printf '%s' "${fp_perms}" | grep -Eq "filesystems=.*host(-os)?(:ro)?(;|$)"; then
      fp_ok=true
    elif [[ "${fp_needs_hostos}" = false ]] && printf '%s' "${fp_perms}" | grep -qF "${script_dir}"; then
      fp_ok=true
    fi
    if [[ "${fp_ok}" = false ]]; then
      # On propose de l'appliquer nous-mêmes plutôt que de simplement afficher la commande
      # -- l'utilisateur confirme, lpm exécute "flatpak override" lui-même. Repli sur le
      # rappel manuel (ancien comportement) si la confirmation est refusée, ou si aucun
      # terminal interactif n'est disponible pour la demander.
      local flatpak_question apply_now=false
      if [[ "${fp_needs_hostos}" = true ]]; then
        flatpak_question="$(t launcher.flatpak_permission_question_hostos "${script_dir}")"
      else
        flatpak_question="$(t launcher.flatpak_permission_question "${script_dir}")"
      fi

      if [[ -t 0 ]]; then
        echo "${flatpak_question}" >&2
        local reponse=""
        read -r -p "[o/N] " reponse </dev/tty 2>/dev/null
        [[ "${reponse,,}" =~ ^(o|oui|y|yes)$ ]] && apply_now=true
      fi

      if [[ "${apply_now}" = true ]]; then
        local override_target="${script_dir}"
        [[ "${fp_needs_hostos}" = true ]] && override_target="host-os"
        if flatpak override --user net.lutris.Lutris --filesystem="${override_target}:ro" >/dev/null 2>&1; then
          local ok_msg
          ok_msg="$(t launcher.flatpak_permission_applied_ok)"
          echo "${ok_msg}" >&2
          zgu_log "launcher" "OK" "slug=${slug} action=flatpak_override_applique cible=${override_target}"
        else
          local fail_msg
          if [[ "${fp_needs_hostos}" = true ]]; then
            fail_msg="$(t launcher.flatpak_permission_applied_fail_hostos)"
          else
            fail_msg="$(t launcher.flatpak_permission_applied_fail "${script_dir}")"
          fi
          echo "${fail_msg}" >&2
          zgu_log "launcher" "ERREUR" "slug=${slug} raison=flatpak_override_echoue cible=${override_target}"
        fi
      else
        local flatpak_hint
        if [[ "${fp_needs_hostos}" = true ]]; then
          flatpak_hint="$(t launcher.flatpak_permission_hint_hostos "${script_dir}")"
        else
          flatpak_hint="$(t launcher.flatpak_permission_hint "${script_dir}")"
        fi
        echo "${flatpak_hint}" >&2
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
  return 0
}

exit_code=0
n_ok=0
for target_slug in "${targets[@]}"; do
  if [[ "${action}" = "on" ]]; then
    if zgp_launcher_apply_on "${target_slug}" "${dir_by_slug[${target_slug}]}" "${configpath_by_slug[${target_slug}]}"; then
      n_ok=$(( n_ok + 1 ))
      zgu_cli_ok "$(t launcher.done_one_on_cli "${name_by_slug[${target_slug}]}" "${dir_by_slug[${target_slug}]}/lpm-launcher.yml")"
    else
      exit_code=1
    fi
  else
    if zgp_launcher_apply_off "${target_slug}" "${dir_by_slug[${target_slug}]}" "${configpath_by_slug[${target_slug}]}"; then
      n_ok=$(( n_ok + 1 ))
      zgu_cli_ok "$(t launcher.done_one_off_cli "${name_by_slug[${target_slug}]}")"
    else
      exit_code=1
    fi
  fi
done

exit "${exit_code}"
