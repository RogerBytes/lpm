#!/bin/bash

# --- lpm launcher : exécuté à chaque lancement du jeu, via system.prelaunch_command ---
#
# Appelé UNIQUEMENT par le petit script relais $GAMEDIR/scripts/lpm-launcher.sh (voir
# lib/zgl-launcher-manager.sh, "lpm launcher ... on"), jamais directement par l'utilisateur.
#
# Usage : zgl-launcher-runtime.sh <gamedir>
#
# Rôle, dans l'ordre (voir l'échange complet qui a mené à cette conception) :
#   1. Lit lpm-launcher.yml (SEUL chemin en dur : celui-ci, passé en argument).
#   2. S'il y a plusieurs entrées dans le YAML : affiche le picker Zenity. Une seule entrée :
#      aucun menu, lancement direct.
#   3. Réécrit lpm-launch.bat (vidé puis réécrit) avec l'entrée choisie.
#
# CE QUE CE SCRIPT NE FAIT PLUS (voir lib/zgl-launcher-orchestrator.sh) : le fond noir/
# splash, l'indicateur "chargement", le verrou manette et la détection de la fenêtre du jeu
# sont désormais TOUJOURS gérés par l'orchestrateur, point d'entrée unique de tous les
# raccourcis .desktop créés par lpm -- déjà en cours d'exécution (fond déjà affiché) par le
# temps que CE script démarre, dans le cas normal. Ce script se contente de retrouver le
# fichier de contrôle déjà ouvert (chemin fixe, dérivé de "gamedir" -- IDENTIQUE au calcul
# fait par l'orchestrateur, les deux scripts partent de la même résolution "directory" de la
# base Lutris, voir zgp-game-shortcutter.sh / zgl-launcher-manager.sh) pour y écrire
# IND_HIDE/IND_SHOW autour du picker -- jamais pour le créer, jamais pour le fermer. S'il
# n'existe pas (jeu lancé autrement que via le raccourci lpm, ou écran de chargement
# désactivé pour ce jeu via ".lpm-no-loadingscreen"), le picker fonctionne quand même, juste
# sans fond derrière -- dégradation gracieuse, jamais une erreur.
#
# Ce script REND TOUJOURS LA MAIN (exit 0) même en cas de souci (YAML absent, etc.) :
# system.prelaunch_command ne doit jamais bloquer indéfiniment le lancement du jeu -- une
# erreur est journalisée et, si possible, signalée par une boîte Zenity, mais le jeu doit
# pouvoir se lancer quand même (avec le .bat existant, potentiellement périmé).

set -u

gamedir="${1:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"
# shellcheck source=./zgu-focus-utils.sh
source "${script_dir}/zgu-focus-utils.sh"

bail() {
  local msg="$1"
  zgu_log "launcher-runtime" "ERREUR" "gamedir=${gamedir} raison=${msg}"
  command -v zenity >/dev/null 2>&1 && zenity --error --text="$(t launcher.runtime_error "${msg}")" --width=480 2>/dev/null &
  exit 0
}

[[ -n "${gamedir}" ]] || bail "gamedir_manquant"
[[ -d "${gamedir}" ]] || bail "gamedir_introuvable"

yaml_path="${gamedir}/lpm-launcher.yml"
[[ -f "${yaml_path}" ]] || bail "yaml_introuvable"

# --- 1. Lecture du YAML (titre, prompt, entrées actives -- les entrées commentées avec
# "#" sont naturellement ignorées par yaml.safe_load, aucun traitement spécial requis) ---
parsed=$(YML_PATH="${yaml_path}" python3 -c '
import os, sys, yaml

try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
except Exception as e:
    sys.stderr.write(str(e))
    sys.exit(1)

if not isinstance(data, dict):
    sys.exit(1)

title = str(data.get("title") or "")
prompt = str(data.get("prompt") or "")
bat_path = str(data.get("bat_path") or "")
entries = data.get("entries") or []
if not isinstance(entries, list):
    sys.exit(1)

print("TITLE\x1f" + title.replace("\x1f", " ").replace("\n", " "))
print("PROMPT\x1f" + prompt.replace("\x1f", " ").replace("\n", " "))
print("BATPATH\x1f" + bat_path.replace("\x1f", " ").replace("\n", " "))
for e in entries:
    if not isinstance(e, dict):
        continue
    label = str(e.get("label") or "").replace("\x1f", " ").replace("\n", " ")
    workdir = str(e.get("workdir") or "").replace("\x1f", " ").replace("\n", " ")
    exe = str(e.get("exe") or "").replace("\x1f", " ").replace("\n", " ")
    if not label or not workdir or not exe:
        continue
    print("ENTRY\x1f" + label + "\x1f" + workdir + "\x1f" + exe)
' 2>/dev/null)

[[ -z "${parsed}" ]] && bail "yaml_invalide_ou_vide"

title="" prompt="" bat_path_yaml=""
entry_labels=() entry_workdirs=() entry_exes=()

while IFS=$'\x1f' read -r kind a b c; do
  case "${kind}" in
    TITLE) title="${a}" ;;
    PROMPT) prompt="${a}" ;;
    BATPATH) bat_path_yaml="${a}" ;;
    ENTRY)
      entry_labels+=("${a}")
      entry_workdirs+=("${b}")
      entry_exes+=("${c}")
      ;;
  esac
done <<< "${parsed}"

[[ ${#entry_labels[@]} -eq 0 ]] && bail "aucune_entree_valide"

# Repli pour un lpm-launcher.yml généré avant l'ajout de la clé "bat_path" (compatibilité
# ascendante) : ancien emplacement, à la racine de $gamedir.
bat_path="${bat_path_yaml:-${gamedir}/lpm-launch.bat}"

# --- Fichier de contrôle de l'orchestrateur (déjà ouvert, ou pas -- voir l'en-tête de
# fichier). Même dérivation EXACTE que lib/zgl-launcher-orchestrator.sh : sha256sum de
# gamedir, chemin fixe, pas de mktemp -- pour retrouver le même fichier sans coordination
# explicite entre les deux scripts. ---
ctrl_key=$(printf '%s' "${gamedir}" | sha256sum | cut -c1-24)
control_file="${TMPDIR:-/tmp}/lpm-launcher-ctrl-${ctrl_key}"

set_indicator() {
  # Best-effort : le fichier de contrôle peut ne pas exister (jeu lancé autrement que via
  # le raccourci lpm, ou écran de chargement désactivé pour ce jeu) -- dans ce cas, on ne
  # touche à rien, le picker s'affiche quand même, juste sans fond derrière.
  [[ -f "${control_file}" ]] || return 0
  local bg_line
  bg_line=$(head -n 1 "${control_file}" 2>/dev/null)
  [[ -z "${bg_line}" ]] && bg_line="NONE"
  {
    printf '%s\n' "${bg_line}"
    printf '%s\n' "$1"
  } > "${control_file}" 2>/dev/null
}

# --- 2. Picker (seulement si plusieurs entrées) ---
chosen_workdir="" chosen_exe=""

if [[ ${#entry_labels[@]} -gt 1 ]]; then
  set_indicator "IND_HIDE"
  zgu_start_focus_watcher

  zenity_values=()
  for lbl in "${entry_labels[@]}"; do
    zenity_values+=("${lbl}")
  done

  selection=$(zenity --list \
    --title="${title}" \
    --text="${prompt}" \
    --column="$(t launcher.picker_column)" \
    "${zenity_values[@]}" \
    --width=500 --height=400 2>/dev/null)

  zgu_stop_focus_watcher 2>/dev/null
  set_indicator "IND_SHOW"

  chosen_idx=-1
  if [[ -n "${selection}" ]]; then
    for i in "${!entry_labels[@]}"; do
      if [[ "${entry_labels[$i]}" = "${selection}" ]]; then
        chosen_idx="${i}"
        break
      fi
    done
  fi

  if [[ "${chosen_idx}" -eq -1 ]]; then
    # Picker annulé (fenêtre fermée sans choix) : par sécurité, on NE TOUCHE PAS à
    # lpm-launch.bat -- s'il existe déjà (lancement précédent), le jeu relance le même
    # épisode que la dernière fois plutôt que de rester avec un .bat vide ou incohérent.
    # S'il n'existe pas encore (tout premier lancement jamais validé), on retombe sur la
    # première entrée du YAML plutôt que de ne rien lancer du tout.
    zgu_log "launcher-runtime" "INFO" "gamedir=${gamedir} raison=picker_annule"
    if [[ -f "${bat_path}" ]]; then
      exit 0
    fi
    chosen_idx=0
  fi
else
  chosen_idx=0
fi

chosen_workdir="${entry_workdirs[${chosen_idx}]}"
chosen_exe="${entry_exes[${chosen_idx}]}"

# --- 3. Écriture de lpm-launch.bat (vidé puis réécrit, voir modèle validé par
# l'utilisateur -- start "" avec titre vide, pas d'appel direct, pour gérer proprement les
# chemins avec espaces et rendre la main correctement à cmd). Écrit dans "${bat_path}"
# (résolu plus haut depuis le YAML, avec repli) -- CE chemin doit être à l'intérieur de
# drive_c du préfixe Wine pour que Lutris/cmd.exe puisse l'exécuter (voir
# zgl-launcher-manager.sh pour le détail de ce choix). ---
mkdir -p "$(dirname "${bat_path}")" 2>/dev/null
{
  printf '@echo off\r\n'
  printf 'cd /d "%s"\r\n' "${chosen_workdir}"
  printf 'start "" "%s"\r\n' "${chosen_exe}"
} > "${bat_path}" 2>/dev/null || bail "ecriture_bat_echouee"

zgu_log "launcher-runtime" "OK" "gamedir=${gamedir} entree=${entry_labels[${chosen_idx}]}"

exit 0
