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
# IND_HIDE/IND_SHOW autour du picker -- jamais pour le créer, jamais pour le fermer. Si le
# jeu a plusieurs entrées, ce script remplace aussi le titre affiché (ligne 3 du fichier de
# contrôle, posé au nom du jeu par l'orchestrateur) par le libellé de l'entrée choisie, une
# fois le picker résolu -- un jeu à une seule entrée garde le nom du jeu tel quel. S'il
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
# shellcheck source=./zgu-gamepad-nav-utils.sh
source "${script_dir}/zgu-gamepad-nav-utils.sh"

bail() {
  local msg="$1"
  # Pas de notification graphique ici (ancien "zenity --error" retiré) : ce cas est
  # anormal mais déjà entièrement journalisé, et ce script ne doit JAMAIS bloquer le
  # lancement du jeu (voir en-tête de fichier) -- une fenêtre d'erreur en plus n'aiderait
  # pas à diagnostiquer après coup, le log ("lpm log") le fait déjà.
  zgu_log "launcher-runtime" "ERREUR" "gamedir=${gamedir} raison=${msg}"
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

# Relit les lignes 1 (fond) et 3 (titre) telles quelles depuis le fichier de contrôle --
# utilisé par set_indicator/set_title ci-dessous pour ne modifier QUE la ligne qui les
# concerne, sans jamais effacer l'autre (l'orchestrateur est seul à écrire la ligne 1, ce
# script est seul à écrire les lignes 2 et 3, mais les trois doivent survivre à chaque
# réécriture du fichier, qui remplace tout son contenu).
read_ctrl_lines() {
  local mapfile_lines=()
  mapfile -t mapfile_lines < "${control_file}" 2>/dev/null
  ctrl_bg_line="${mapfile_lines[0]:-NONE}"
  ctrl_title_line="${mapfile_lines[2]:-}"
  [[ -z "${ctrl_bg_line}" ]] && ctrl_bg_line="NONE"
}

set_indicator() {
  # Best-effort : le fichier de contrôle peut ne pas exister (jeu lancé autrement que via
  # le raccourci lpm, ou écran de chargement désactivé pour ce jeu) -- dans ce cas, on ne
  # touche à rien, le picker s'affiche quand même, juste sans fond derrière.
  [[ -f "${control_file}" ]] || return 0
  local ctrl_bg_line ctrl_title_line
  read_ctrl_lines
  {
    printf '%s\n' "${ctrl_bg_line}"
    printf '%s\n' "$1"
    printf '%s\n' "${ctrl_title_line}"
  } > "${control_file}" 2>/dev/null
}

set_title() {
  # Même principe : remplace uniquement la ligne 3 (titre), préserve le fond et l'état de
  # l'indicateur tels qu'ils sont au moment de l'appel.
  [[ -f "${control_file}" ]] || return 0
  local ctrl_bg_line ctrl_title_line ctrl_indicator_line
  read_ctrl_lines
  ctrl_indicator_line=$(sed -n '2p' "${control_file}" 2>/dev/null)
  [[ -z "${ctrl_indicator_line}" ]] && ctrl_indicator_line="IND_SHOW"
  {
    printf '%s\n' "${ctrl_bg_line}"
    printf '%s\n' "${ctrl_indicator_line}"
    printf '%s\n' "$1"
  } > "${control_file}" 2>/dev/null
}

# --- 2. Picker (seulement si plusieurs entrées) ---
chosen_workdir="" chosen_exe=""

if [[ ${#entry_labels[@]} -gt 1 ]]; then
  # Choix déjà fait par l'orchestrateur (cas normal, lancement via le raccourci lpm) --
  # voir zgl-launcher-orchestrator.sh : c'est LUI qui affiche désormais le picker, sur la
  # machine hôte, AVANT même de lancer Lutris -- jamais ce script-ci, qui tourne (pour un
  # Lutris Flatpak) à l'intérieur de son bac à sable, où ni la manette ni même la souris
  # n'atteignaient fiablement Zenity malgré plusieurs contournements successifs (voir
  # l'échange qui a mené à ce choix).
  #
  # PAS sous /tmp (confirmé réel : le bac à sable Flatpak de Lutris a son PROPRE /tmp,
  # totalement invisible depuis l'hôte et réciproquement -- ni directement, ni via
  # "/run/host/tmp", qui n'existe pas du tout, contrairement à "/run/host/usr". Le
  # fichier de choix doit donc vivre dans "${gamedir}", qui LUI est forcément visible des
  # deux côtés : Lutris a besoin d'y lire/écrire pour lancer le jeu, avec ou sans Flatpak.
  choice_file="${gamedir}/.lpm-launcher-choice"

  if [[ -f "${choice_file}" ]]; then
    selection=$(cat "${choice_file}" 2>/dev/null)
    rm -f "${choice_file}" 2>/dev/null

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
      # Picker annulé côté orchestrateur, ou libellé introuvable (YAML modifié entre les
      # deux) : même repli que ci-dessous.
      zgu_log "launcher-runtime" "INFO" "gamedir=${gamedir} raison=picker_annule"
      if [[ -f "${bat_path}" ]]; then
        exit 0
      fi
      chosen_idx=0
    fi
  else
    # --- Repli : l'orchestrateur n'a pas tourné (raccourci lpm contourné, jeu lancé
    # autrement) -- ce script affiche son propre picker, comme avant l'introduction du
    # fichier de choix, en mode dégradé (manette/focus best-effort, pas garantis fiables
    # dans un Lutris Flatpak). Même picker maison que l'orchestrateur (zgu-launcher-
    # picker.py, GTK3, PAS Zenity -- voir zgl-launcher-orchestrator.sh pour le détail de ce
    # choix) : dernier appel à zenity de tout le flux lancement retiré, pour rester cohérent
    # même dans ce cas dégradé. Le picker gère lui-même son focus (set_keep_above +
    # grab_focus, voir zgu-launcher-picker.py) : plus besoin du va-et-vient xdotool de
    # zgu-focus-utils.sh ici (celui-ci ne surveillait de toute façon qu'une fenêtre
    # Zenity, jamais une fenêtre GTK maison). ---
    set_indicator "IND_HIDE"
    zgu_start_gamepad_nav

    selection=$(python3 "${script_dir}/zgu-launcher-picker.py" \
      "${title}" "${prompt}" \
      "$(t launcher.picker_validate_button)" "$(t launcher.picker_cancel_button)" \
      "${entry_labels[@]}" 2>/dev/null)
    picker_rc=$?

    zgu_stop_gamepad_nav 2>/dev/null
    set_indicator "IND_SHOW"

    chosen_idx=-1
    if [[ "${picker_rc}" -eq 0 ]] && [[ -n "${selection}" ]]; then
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
  fi
else
  chosen_idx=0
fi

chosen_workdir="${entry_workdirs[${chosen_idx}]}"
chosen_exe="${entry_exes[${chosen_idx}]}"

# Titre affiché sur l'écran de chargement (voir zgu-launcher-blackscreen.py) : remplacé par
# le libellé de l'entrée choisie SEULEMENT si le jeu a plusieurs entrées LPM Launcher
# actives -- un jeu "normal" (une seule entrée, jamais de picker) garde le nom du jeu déjà
# posé par l'orchestrateur, plus pertinent ici qu'un libellé générique ("Lancement"/"Launch").
if [[ ${#entry_labels[@]} -gt 1 ]]; then
  set_title "${entry_labels[${chosen_idx}]}"
fi

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
