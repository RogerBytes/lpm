#!/bin/bash

# --- lpm launcher : exécuté à chaque lancement du jeu, via system.prelaunch_command ---
#
# Appelé UNIQUEMENT par le petit script relais $GAMEDIR/scripts/lpm-launcher.sh (voir
# lib/zgl-launcher-manager.sh, "lpm launcher ... on"), jamais directement par l'utilisateur.
#
# Usage : zgl-launcher-runtime.sh <gamedir>
#
# Rôle, dans l'ordre (voir l'échange complet qui a mené à cette conception -- chaque étape
# a été discutée et validée séparément) :
#   1. Lit lpm-launcher.yml (SEUL chemin en dur : celui-ci, passé en argument).
#   2. Affiche un fond noir plein écran (écran principal sous X11, tous les écrans sous
#      Wayland -- voir zgu-launcher-blackscreen.py) et verrouille la/les manette(s)
#      détectée(s) en exclusivité, avec pont vers le clavier (voir
#      zgu-launcher-gamepad-bridge.py) -- actif du tout début (picker) jusqu'à la toute fin
#      (disparition du splash), jamais relâché entre les deux.
#   3. S'il y a plusieurs entrées dans le YAML : affiche le picker Zenity (clavier/souris
#      déjà natifs, manette via le pont) par-dessus le fond noir. Une seule entrée : aucun
#      menu, lancement direct.
#   4. Réécrit lpm-launch.bat (vidé puis réécrit) avec l'entrée choisie.
#   5. Bascule le fond noir sur l'image de splash, surveille l'apparition de la fenêtre du
#      jeu (X11 seulement -- voir limite documentée plus bas) pour la faire disparaître dès
#      que le jeu est visible, avec une limite de temps de sécurité dans tous les cas.
#   6. Relâche le verrou manette, sort -- Lutris enchaîne alors sur le vrai lancement (via
#      le .bat qu'on vient d'écrire).
#
# Ce script REND TOUJOURS LA MAIN (exit 0) même en cas de souci (YAML absent, aucun écran
# détecté, etc.) : system.prelaunch_command ne doit jamais bloquer indéfiniment le lancement
# du jeu -- une erreur est journalisée et, si possible, signalée par une boîte Zenity, mais
# le jeu doit pouvoir se lancer quand même (avec le .bat existant, potentiellement périmé).

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
entries = data.get("entries") or []
if not isinstance(entries, list):
    sys.exit(1)

print("TITLE\x1f" + title.replace("\x1f", " ").replace("\n", " "))
print("PROMPT\x1f" + prompt.replace("\x1f", " ").replace("\n", " "))
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

title="" prompt=""
entry_labels=() entry_workdirs=() entry_exes=()

while IFS=$'\x1f' read -r kind a b c; do
  case "${kind}" in
    TITLE) title="${a}" ;;
    PROMPT) prompt="${a}" ;;
    ENTRY)
      entry_labels+=("${a}")
      entry_workdirs+=("${b}")
      entry_exes+=("${c}")
      ;;
  esac
done <<< "${parsed}"

[[ ${#entry_labels[@]} -eq 0 ]] && bail "aucune_entree_valide"

# --- 2. Détection X11 / Wayland, fond noir + verrou manette ---
session_kind="x11"
if [[ "${XDG_SESSION_TYPE,,}" = "wayland" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  session_kind="wayland"
fi

has_display=false
if [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  has_display=true
fi

control_file=""
blackscreen_pid=""
bridge_pid=""

cleanup() {
  [[ -n "${control_file}" ]] && echo "STOP" > "${control_file}" 2>/dev/null
  [[ -n "${bridge_pid}" ]] && kill "${bridge_pid}" 2>/dev/null
  zgu_stop_focus_watcher 2>/dev/null
  sleep 0.3
  [[ -n "${blackscreen_pid}" ]] && kill "${blackscreen_pid}" 2>/dev/null
  [[ -n "${control_file}" ]] && rm -f "${control_file}" 2>/dev/null
}
trap cleanup EXIT

if [[ "${has_display}" = true ]] && command -v python3 >/dev/null 2>&1; then
  control_file=$(mktemp "${TMPDIR:-/tmp}/lpm-launcher-ctrl.XXXXXX")
  echo "NONE" > "${control_file}"

  python3 "${script_dir}/zgu-launcher-blackscreen.py" "${control_file}" >/dev/null 2>&1 &
  blackscreen_pid=$!
  disown "${blackscreen_pid}" 2>/dev/null

  python3 "${script_dir}/zgu-launcher-gamepad-bridge.py" "${session_kind}" >/dev/null 2>&1 &
  bridge_pid=$!
  disown "${bridge_pid}" 2>/dev/null

  sleep 0.3  # laisse le temps au fond noir de s'afficher avant le picker
fi

# --- 3. Picker (seulement si plusieurs entrées) ---
chosen_workdir="" chosen_exe=""

if [[ ${#entry_labels[@]} -gt 1 ]]; then
  [[ "${has_display}" = true ]] && zgu_start_focus_watcher

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
    if [[ -f "${gamedir}/lpm-launch.bat" ]]; then
      cleanup
      trap - EXIT
      exit 0
    fi
    chosen_idx=0
  fi
else
  chosen_idx=0
fi

chosen_workdir="${entry_workdirs[${chosen_idx}]}"
chosen_exe="${entry_exes[${chosen_idx}]}"

# --- 4. Écriture de lpm-launch.bat (vidé puis réécrit, voir modèle validé par
# l'utilisateur -- start "" avec titre vide, pas d'appel direct, pour gérer proprement les
# chemins avec espaces et rendre la main correctement à cmd) ---
bat_path="${gamedir}/lpm-launch.bat"
{
  printf '@echo off\r\n'
  printf 'cd /d "%s"\r\n' "${chosen_workdir}"
  printf 'start "" "%s"\r\n' "${chosen_exe}"
} > "${bat_path}" 2>/dev/null || bail "ecriture_bat_echouee"

# --- 5. Bascule sur le splash, détection de la fenêtre du jeu ---
if [[ -n "${control_file}" ]]; then
  splash_image="${gamedir}/splash/splash.png"
  [[ -f "${splash_image}" ]] || splash_image="${script_dir}/launcher-splash-default.png"
  echo "${splash_image}" > "${control_file}" 2>/dev/null

  max_wait_s=60
  waited=0

  if [[ "${session_kind}" = "x11" ]] && command -v xdotool >/dev/null 2>&1; then
    before_windows=$(xdotool search --onlyvisible "" 2>/dev/null | sort)
    while [[ "${waited}" -lt "${max_wait_s}" ]]; do
      sleep 1
      waited=$(( waited + 1 ))
      after_windows=$(xdotool search --onlyvisible "" 2>/dev/null | sort)
      new_windows=$(comm -13 <(echo "${before_windows}") <(echo "${after_windows}"))
      [[ -n "${new_windows}" ]] && break
    done
  else
    # Wayland : xdotool ne fonctionne pas pour lister/détecter les fenêtres d'autres
    # applications (limite du protocole, pas de notre fait -- voir l'échange à ce sujet).
    # Repli : attente fixe raisonnable, le temps que la plupart des jeux affichent leur
    # fenêtre, puis fermeture du splash quoi qu'il arrive.
    sleep 12
  fi
fi

zgu_log "launcher-runtime" "OK" "gamedir=${gamedir} entree=${entry_labels[${chosen_idx}]}"

exit 0
