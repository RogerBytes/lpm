#!/bin/bash

# --- lpm launcher : point d'entrée UNIQUE de tous les raccourcis (.desktop) créés par lpm ---
#
# Appelé directement par "Exec=" du .desktop (voir zgu_write_game_shortcut dans
# zgu-desktop-utils.sh) -- strictement identique pour tous les jeux Wine, avec ou sans
# LPM Launcher ("picker" multi-entrées) actif. Rôle : afficher le fond de chargement
# (noir, ou l'image splash/splash.png si présente) avec un petit indicateur "en cours de
# chargement" (texte traduit + spinner) en bas à droite -- jamais recouvert par une
# éventuelle bannière -- PUIS céder la place à Lutris pour le lancement réel.
#
# Usage : zgl-launcher-orchestrator.sh <game_id> <version:package|flatpak>
#
# Volontairement DEUX arguments seulement, tous deux toujours sûrs sans échappement (un
# entier, un mot fixe) -- "slug"/"game_dir" ne transitent jamais par Exec= du .desktop : ce
# champ suit les règles d'échappement du format Desktop Entry, distinctes de celles d'un
# shell, et un chemin avec espaces y serait un risque inutile. Ce script re-interroge donc
# lui-même la base Lutris (pga.db) pour retrouver "slug"/"directory" à partir de
# "game_id" -- même requête, mêmes chemins de base et même repli "games_dir/slug" que
# zgp-game-shortcutter.sh / zgp-game-installer.sh (voir zgu-lutris-utils.sh).
#
# Conception (voir l'échange complet qui y a mené) :
#   - Écran de chargement actif pour TOUS les raccourcis lpm par défaut ; désactivable par
#     jeu via la présence de "${game_dir}/.lpm-no-loadingscreen" (case "Écran de chargement"
#     décochée à la création/régénération du raccourci -- voir zgp-game-shortcutter.sh /
#     zgp-game-installer.sh). Dans ce cas : lancement direct, comportement identique à avant
#     l'introduction de l'orchestrateur, zéro overhead.
#   - Le picker multi-entrées (plusieurs exécutables possibles pour un même jeu) reste
#     entièrement gérée par zgl-launcher-runtime.sh, déclenché comme avant par Lutris via
#     system.prelaunch_command -- CE script-ci ne s'en occupe pas et ne vérifie même pas si
#     cette fonctionnalité est active : les deux sont indépendantes. Le picker réutilise le
#     fond déjà ouvert par CE script (voir le fichier de contrôle à chemin fixe ci-dessous),
#     il n'en ouvre jamais un second.
#   - Une fois le fond lancé, ce script fait "exec" vers la commande Lutris normale
#     (strictement la même que celle utilisée directement en Exec= avant l'orchestrateur) --
#     remplace le process bash par le process lutris (même PID), donc aucun wrapper ne
#     traîne dans l'arbre des process : zéro impact sur le suivi de fenêtre/dock (WM_CLASS,
#     StartupWMClass) qui fonctionne exactement comme avant.
#   - Aucune vérification/fermeture d'une instance Lutris déjà ouverte : inutile ici, la
#     détection de fin de chargement se fait par apparition de LA FENÊTRE du jeu (watcher
#     détaché ci-dessous), pas par la fin du process Lutris -- ce dernier signal n'est donc
#     jamais nécessaire, qu'une instance Lutris tourne déjà ou non (voir l'échange détaillé :
#     "lutris lutris:rungameid/<id>" fonctionne identiquement dans les deux cas pour lancer
#     RÉELLEMENT le jeu, seul le comportement de blocage du process appelant diffère, et on
#     ne s'en sert pas).

set -u

game_id="${1:-}"
version="${2:-}"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"

# --- Commande Lutris finale : strictement celle utilisée en Exec= avant l'orchestrateur ---
launch_lutris() {
  if [[ "${version}" = "flatpak" ]]; then
    exec env LUTRIS_SKIP_INIT=1 flatpak run net.lutris.Lutris "lutris:rungameid/${game_id}"
  else
    exec env LUTRIS_SKIP_INIT=1 lutris "lutris:rungameid/${game_id}"
  fi
  # "exec" ne rend jamais la main en cas de succès -- si on arrive ici, exec a échoué
  # (lutris/flatpak introuvable) : dernier recours, log et sortie en erreur.
  zgu_log "launcher-orchestrator" "ERREUR" "game_id=${game_id} raison=exec_lutris_echoue"
  exit 1
}

# --- Argument manquants : on ne bloque jamais un lancement pour si peu, repli direct ---
if [[ -z "${game_id}" ]] || [[ -z "${version}" ]]; then
  zgu_log "launcher-orchestrator" "AVERT" "raison=arguments_manquants argv=$*"
  launch_lutris
fi

has_display=false
if [[ -n "${DISPLAY:-}" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  has_display=true
fi

# --- Pas d'affichage possible (session sans GUI, python3 absent, sqlite3 absent...) :
# repli direct -- inutile d'aller interroger la base Lutris pour un écran qu'on ne pourra
# de toute façon pas afficher. ---
if [[ "${has_display}" = false ]] || ! command -v python3 >/dev/null 2>&1 || ! command -v sqlite3 >/dev/null 2>&1; then
  launch_lutris
fi

# --- Résolution de la base Lutris à interroger : mêmes chemins et même convention
# ("version" = "flatpak" ou "package", jamais "native" -- voir zgp-game-shortcutter.sh) que
# partout ailleurs dans le projet. Pas d'appel à zgu_resolve_lutris_version ici : la version
# à utiliser est déjà connue (reçue en argument, figée au moment de la création du
# raccourci), inutile de la redétecter/redemander à chaque lancement. ---
if [[ "${version}" = "flatpak" ]]; then
  lutris_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
  lutris_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
else
  lutris_db="${HOME}/.local/share/lutris/pga.db"
  lutris_system_file="${HOME}/.config/lutris/system.yml"
fi

# --- Base introuvable : repli direct, silencieux (juste un log) -- un lancement de jeu ne
# doit jamais échouer pour si peu. ---
if [[ ! -f "${lutris_db}" ]]; then
  zgu_log "launcher-orchestrator" "AVERT" "game_id=${game_id} raison=db_introuvable db=${lutris_db}"
  launch_lutris
fi

# --- slug + directory, par id -- même requête (colonnes) et même repli "games_dir/slug"
# que zgp-game-shortcutter.sh / zgp-game-installer.sh. game_id vient de Exec= (donc du
# .desktop lui-même, jamais d'une entrée utilisateur libre à ce stade), mais reste
# interpolé tel quel dans le SQL comme ailleurs dans le projet -- filtré ici pour rester un
# entier pur par précaution, avant toute utilisation. ---
game_id="${game_id//[^0-9]/}"
if [[ -z "${game_id}" ]]; then
  zgu_log "launcher-orchestrator" "AVERT" "raison=game_id_invalide"
  launch_lutris
fi

row=$(sqlite3 "${lutris_db}" "SELECT slug || char(31) || directory || char(31) || name FROM games WHERE id = ${game_id} AND runner = 'wine' LIMIT 1;" 2>/dev/null)

if [[ -z "${row}" ]]; then
  zgu_log "launcher-orchestrator" "AVERT" "game_id=${game_id} raison=jeu_introuvable_en_base"
  launch_lutris
fi

IFS=$'\x1f' read -r slug game_dir game_name <<< "${row}"

if [[ -z "${slug}" ]]; then
  zgu_log "launcher-orchestrator" "AVERT" "game_id=${game_id} raison=slug_vide_en_base"
  launch_lutris
fi

# Titre affiché dans le coin bas-droite de l'écran de chargement (voir
# zgu-launcher-blackscreen.py) : le nom du jeu tel quel par défaut -- remplacé par
# zgl-launcher-runtime.sh une fois le picker résolu, SEULEMENT si le jeu a plusieurs
# entrées LPM Launcher actives (voir ce script). \n/\r retirés : "name" vient de la base
# Lutris (donc potentiellement forgé par un tiers, paquet .zgp partagé), et le protocole du
# fichier de contrôle est ligne par ligne.
title_text="${game_name//[$'\n\r']/}"

# Chemin Games personnalisé (si défini dans Lutris) : même repli que zgp-game-shortcutter.sh
# / zgp-game-installer.sh, utilisé seulement si "directory" est vide en base.
games_dir="${HOME}/Games"
if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
fi
[[ -z "${game_dir}" ]] && game_dir="${games_dir}/${slug}"

# --- Écran de chargement désactivé pour ce jeu, ou dossier introuvable : lancement direct,
# rien d'autre. ---
if [[ ! -d "${game_dir}" ]] || [[ -f "${game_dir}/.lpm-no-loadingscreen" ]]; then
  launch_lutris
fi

session_kind="x11"
if [[ "${XDG_SESSION_TYPE,,}" = "wayland" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  session_kind="wayland"
fi

# --- Fichier de contrôle à chemin FIXE (dérivé de game_dir, pas de mktemp aléatoire) --
# -- pour que zgl-launcher-runtime.sh (lancé séparément, plus tard, par Lutris) retrouve le
# même fichier sans qu'aucune donnée n'ait besoin de circuler explicitement entre les deux
# scripts. sha256sum de game_dir plutôt que son basename : robuste même si le nom du
# répertoire du jeu ne correspond pas exactement au slug (colonne "directory" de Lutris).
ctrl_key=$(printf '%s' "${game_dir}" | sha256sum | cut -c1-24)
control_file="${TMPDIR:-/tmp}/lpm-launcher-ctrl-${ctrl_key}"

# --- Fond : image splash si présente, sinon noir uni ---
splash_image="${game_dir}/splash/splash.png"
bg_state="NONE"
[[ -f "${splash_image}" ]] && bg_state="${splash_image}"

{
  printf '%s\n' "${bg_state}"
  printf '%s\n' "IND_SHOW"
  printf '%s\n' "${title_text}"
} > "${control_file}" 2>/dev/null

indicator_text="$(t launcher.loading_text)"

blackscreen_pid=""
bridge_pid=""

python3 "${script_dir}/zgu-launcher-blackscreen.py" "${control_file}" "${indicator_text}" >/dev/null 2>&1 &
blackscreen_pid=$!
disown "${blackscreen_pid}" 2>/dev/null

python3 "${script_dir}/zgu-launcher-gamepad-bridge.py" "${session_kind}" >/dev/null 2>&1 &
bridge_pid=$!
disown "${bridge_pid}" 2>/dev/null

sleep 0.3  # laisse le temps au fond de s'afficher avant que Lutris ne fasse quoi que ce soit

zgu_log "launcher-orchestrator" "OK" "slug=${slug} action=fond_lance ctrl=${control_file}"

# --- Watcher détaché : détection de la fenêtre du jeu + durée minimum d'affichage, puis
# nettoyage complet -- tourne indépendamment, CE script fait "exec" juste après et disparaît
# (remplacé par le process lutris), le watcher continue de vivre en tâche de fond. ---
MIN_DISPLAY_MS=1000

(
  start_ms=$(date +%s%3N 2>/dev/null || echo 0)
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
    # Wayland : même limite documentée qu'avant (xdotool ne peut pas lister/détecter les
    # fenêtres d'autres applications) -- attente fixe raisonnable.
    sleep 12
  fi

  # Durée minimum : évite un flash si le jeu démarre anormalement vite.
  if [[ "${start_ms}" != "0" ]]; then
    now_ms=$(date +%s%3N 2>/dev/null || echo 0)
    elapsed_ms=$(( now_ms - start_ms ))
    if [[ "${elapsed_ms}" -lt "${MIN_DISPLAY_MS}" ]]; then
      remaining_ms=$(( MIN_DISPLAY_MS - elapsed_ms ))
      sleep "$(awk -v ms="${remaining_ms}" 'BEGIN { printf "%.3f", ms / 1000 }')"
    fi
  fi

  echo "STOP" > "${control_file}" 2>/dev/null
  [[ -n "${bridge_pid}" ]] && kill "${bridge_pid}" 2>/dev/null
  sleep 0.3
  [[ -n "${blackscreen_pid}" ]] && kill "${blackscreen_pid}" 2>/dev/null
  rm -f "${control_file}" 2>/dev/null
) </dev/null >/dev/null 2>&1 &
disown $! 2>/dev/null

launch_lutris
