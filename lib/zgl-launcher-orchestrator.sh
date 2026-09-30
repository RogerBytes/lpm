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
# shellcheck source=./zgu-focus-utils.sh
source "${script_dir}/zgu-focus-utils.sh"

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

# --- Fichier de contrôle à chemin FIXE (dérivé de game_dir, pas de mktemp aléatoire) --
# -- pour que zgl-launcher-runtime.sh (lancé séparément, plus tard, par Lutris) retrouve le
# même fichier sans qu'aucune donnée n'ait besoin de circuler explicitement entre les deux
# scripts. sha256sum de game_dir plutôt que son basename : robuste même si le nom du
# répertoire du jeu ne correspond pas exactement au slug (colonne "directory" de Lutris).
ctrl_key=$(printf '%s' "${game_dir}" | sha256sum | cut -c1-24)
control_file="${TMPDIR:-/tmp}/lpm-launcher-ctrl-${ctrl_key}"

# --- Écran de chargement désactivé pour ce jeu, ou dossier introuvable : lancement direct,
# rien d'autre (donc aussi pas de picker LPM Launcher -- voir zgl-launcher-runtime.sh pour
# son propre repli dans ce cas précis, en mode dégradé). ---
if [[ ! -d "${game_dir}" ]] || [[ -f "${game_dir}/.lpm-no-loadingscreen" ]]; then
  launch_lutris
fi

session_kind="x11"
if [[ "${XDG_SESSION_TYPE,,}" = "wayland" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
  session_kind="wayland"
fi

# --- LPM Launcher (picker multi-entrées) : le YAML est lu ICI, AVANT même le premier
# affichage du fond, uniquement pour savoir si un picker va être montré -- pas encore
# pour l'afficher (la manette n'est pas encore démarrée à ce stade, voir plus bas). Sert
# à décider le fond INITIAL juste en dessous : si un picker va suivre, le splash ne doit
# apparaître qu'APRÈS le choix, jamais avant pour disparaître aussitôt (clignotement
# constaté, corrigé ici plutôt que côté fond, qui ne peut pas deviner à l'avance).
launcher_yml="${game_dir}/lpm-launcher.yml"
# PAS sous /tmp : le /tmp du bac à sable Flatpak de Lutris est totalement invisible
# depuis l'hôte (confirmé réel), donc zgl-launcher-runtime.sh (qui tourne DEDANS pour un
# Lutris Flatpak) ne trouverait jamais ce fichier écrit ICI, sur l'hôte. "${game_dir}"
# est lui forcément visible des deux côtés -- voir zgl-launcher-runtime.sh.
launcher_choice_file="${game_dir}/.lpm-launcher-choice"
rm -f "${launcher_choice_file}" 2>/dev/null

picker_title="" picker_prompt=""
entry_labels=()
will_show_picker=false

if [[ -f "${launcher_yml}" ]] && [[ "${has_display}" = true ]] \
    && command -v python3 >/dev/null 2>&1; then
  parsed=$(YML_PATH="${launcher_yml}" python3 -c '
import os, sys, yaml

try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
except Exception:
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
    if not label:
        continue
    print("ENTRY\x1f" + label)
' 2>/dev/null)

  while IFS=$'\x1f' read -r kind a; do
    case "${kind}" in
      TITLE) picker_title="${a}" ;;
      PROMPT) picker_prompt="${a}" ;;
      ENTRY)  entry_labels+=("${a}") ;;
    esac
  done <<< "${parsed}"

  [[ ${#entry_labels[@]} -gt 1 ]] && will_show_picker=true
fi

# --- Fond : image splash si présente, sinon noir uni -- SAUF si un picker va être
# montré, auquel cas NONE jusqu'au choix (voir bloc ci-dessus). ---
splash_image="${game_dir}/splash/splash.png"
bg_state="NONE"
if [[ "${will_show_picker}" = false ]] && [[ -f "${splash_image}" ]]; then
  bg_state="${splash_image}"
fi

# --- Logo : à côté du splash (même dossier). Dessiné DIRECTEMENT par
# zgu-launcher-blackscreen.py dans sa propre fenêtre (voir son en-tête de fichier) --
# PAS de process séparé : le picker ne recouvre jamais cette zone (en haut de l'écran,
# au-dessus de son propre encadré toujours centré), donc pas besoin d'une fenêtre "toujours
# au sommet" en plus -- ça évite tous les problèmes de calques/focus d'un essai précédent
# (fenêtre logo séparée, voir l'historique). Si absent, zgu-launcher-blackscreen.py affiche
# le titre à cet emplacement à la place (voir son en-tête de fichier) -- passé même s'il
# n'existe pas, la vérification d'existence se fait côté Python.
logo_image="${game_dir}/splash/logo.png"

{
  printf '%s\n' "${bg_state}"
  printf '%s\n' "IND_SHOW"
  printf '%s\n' "${title_text}"
  printf '%s\n' ""
} > "${control_file}" 2>/dev/null

indicator_text="$(t launcher.loading_text)"

blackscreen_pid=""
bridge_pid=""

python3 "${script_dir}/zgu-launcher-blackscreen.py" "${control_file}" "${indicator_text}" "${logo_image}" >/dev/null 2>&1 &
blackscreen_pid=$!
disown "${blackscreen_pid}" 2>/dev/null

# Démarré ICI, AVANT le picker LPM Launcher ci-dessous (pas seulement pour le jeu une
# fois lancé) : la manette doit déjà être captée quand le picker s'affiche, par-dessus ce
# même fond noir/splash -- pas un second bac à sable ou pont séparé pour ça.
python3 "${script_dir}/zgu-gamepad-bridge.py" "${session_kind}" >/dev/null 2>&1 &
bridge_pid=$!
disown "${bridge_pid}" 2>/dev/null

sleep 0.3  # laisse le temps au fond de s'afficher avant que Lutris (ou le picker) ne fasse quoi que ce soit

zgu_log "launcher-orchestrator" "OK" "slug=${slug} action=fond_lance ctrl=${control_file}"

# --- LPM Launcher (picker multi-entrées) : résolu ICI, sur la machine hôte, PAS par
# zgl-launcher-runtime.sh (lancé plus tard par Lutris) -- ce dernier tourne, pour un
# Lutris Flatpak, à l'intérieur de son bac à sable, où ni la manette ni même la souris
# n'atteignaient fiablement Zenity, malgré plusieurs contournements successifs (voir
# l'échange qui a mené à ce choix). Le choix est donc fait ICI -- exactement comme le
# menu interactif de lpm, qui n'a jamais eu ce problème pour la même raison : hors de
# tout bac à sable, et avec le même pont manette déjà démarré ci-dessus -- et transmis à
# zgl-launcher-runtime.sh via un fichier à chemin fixe, dérivé de game_dir comme le
# fichier de contrôle. Ce dernier n'a alors plus qu'à le lire et écrire lpm-launch.bat,
# sans jamais avoir besoin d'afficher quoi que ce soit lui-même dans le cas normal (son
# propre picker reste en repli, voir ce script, pour le cas où CE script-ci n'aurait pas
# tourné -- raccourci lpm contourné, jeu lancé autrement).
#
# YAML déjà lu plus haut (entry_labels/picker_title/picker_prompt/will_show_picker),
# avant même le premier affichage du fond -- voir ce bloc pour pourquoi.
if [[ "${will_show_picker}" = true ]]; then
    # IND_HIDE : dit aussi au fond noir/splash de passer SOUS le picker le temps du choix
    # (voir zgu-launcher-blackscreen.py) -- sans ça, son "keep_above" le remet toujours
    # par-dessus. Fond déjà "NONE" depuis le tout premier affichage (voir plus haut) --
    # rien à changer ici, juste l'indicateur. Titre inchangé à ce stade.
    {
      printf '%s\n' "NONE"
      printf '%s\n' "IND_HIDE"
      printf '%s\n' "${title_text}"
      printf '%s\n' ""
    } > "${control_file}" 2>/dev/null

    # Laisse le temps au fond (sondage toutes les 150ms, voir zgu-launcher-blackscreen.py)
    # de lever son "keep_above" AVANT que le picker n'apparaisse -- sinon sa fenêtre se
    # retrouve créée pendant que le fond est encore sur le calque "toujours au-dessus", et
    # rien ne la fait remonter par-dessus ensuite (constaté réel : le focus peut être
    # confirmé côté WM sans que la fenêtre soit visuellement remontée au-dessus d'un
    # "always on top").
    sleep 0.3

    # Picker maison (zgu-launcher-picker.py), PAS Zenity : boutons Valider/Annuler définis
    # PAR CE SCRIPT (jamais ceux, imposés, de Zenity), ni croix de fermeture -- accessible
    # au clavier (flèches/Entrée/Échap), à la manette (A/B) ET à la souris (clic, double-
    # clic, ou les deux boutons) -- voir ce script pour le détail. Sa propre fenêtre se
    # maintient elle-même au-dessus (set_keep_above(True) et grab_focus() dans le script),
    # plus besoin du va-et-vient xdotool de zgu-focus-utils.sh ici.
    selection=$(python3 "${script_dir}/zgu-launcher-picker.py" \
      "${picker_title}" "${picker_prompt}" \
      "$(t launcher.picker_validate_button)" "$(t launcher.picker_cancel_button)" \
      "${entry_labels[@]}" 2>/dev/null)
    picker_rc=$?

    if [[ "${picker_rc}" -ne 0 ]] || [[ -z "${selection}" ]]; then
      # Annulé (bouton Annuler, Échap, bouton B, ou fermeture de la fenêtre -- toutes
      # traitées pareil, voir zgu-launcher-picker.py) OU erreur du picker : le flux est
      # arrêté ENTIÈREMENT, le jeu n'est PAS lancé. Avec Zenity, "Annuler" finissait quand
      # même par lancer le jeu (rien ne distinguait vraiment annulé de "choix par défaut") --
      # constaté réel, corrigé ici : annuler doit vouloir dire annuler.
      rm -f "${launcher_choice_file}" 2>/dev/null
      zgu_log "launcher-orchestrator" "INFO" "slug=${slug} raison=picker_annule action=arret_complet"
      echo "STOP" > "${control_file}" 2>/dev/null
      [[ -n "${bridge_pid}" ]] && kill "${bridge_pid}" 2>/dev/null
      sleep 0.3
      [[ -n "${blackscreen_pid}" ]] && kill "${blackscreen_pid}" 2>/dev/null
      rm -f "${control_file}" 2>/dev/null
      exit 0
    fi

    # Écrit ce fichier dès qu'un choix a été validé : sa seule PRÉSENCE dit à
    # zgl-launcher-runtime.sh que CE script a bien tourné et pris la décision -- absence =
    # repli sur son propre picker (voir plus haut), jamais une case à part à gérer côté
    # runtime.
    printf '%s' "${selection}" > "${launcher_choice_file}" 2>/dev/null

    # Fond APRÈS le choix : le splash (s'il existe) n'apparaît qu'à partir de maintenant --
    # jamais avant le picker (voir plus haut pourquoi bg_state valait "NONE" jusqu'ici).
    post_choice_bg="NONE"
    [[ -f "${splash_image}" ]] && post_choice_bg="${splash_image}"

    # Titre INCHANGÉ (toujours le nom du jeu, voir zgu-launcher-blackscreen.py) : le
    # libellé choisi vient s'ajouter EN PLUS, sur sa propre ligne, jamais à sa place.
    {
      printf '%s\n' "${post_choice_bg}"
      printf '%s\n' "IND_SHOW"
      printf '%s\n' "${title_text}"
      printf '%s\n' "${selection//[$'\n\r']/}"
    } > "${control_file}" 2>/dev/null
    zgu_log "launcher-orchestrator" "OK" "slug=${slug} action=picker_choix entree=${selection}"
fi

# --- Watcher détaché : détection de la fenêtre du jeu + durée minimum d'affichage, puis
# nettoyage complet -- tourne indépendamment, CE script fait "exec" juste après et disparaît
# (remplacé par le process lutris), le watcher continue de vivre en tâche de fond. ---
MIN_DISPLAY_MS=1000

# Marge de sécurité APRÈS la détection de la fenêtre du jeu (ou après l'attente fixe côté
# Wayland) : la fenêtre qui vient d'apparaître n'a pas forcément fini de s'initialiser --
# un outil de génération de frames comme LSFG, par exemple, peut provoquer un petit accroc
# juste après l'apparition de la fenêtre. Sans cette marge, le fond disparaissait pile au
# moment où ce genre de à-coup pouvait être visible.
POST_WINDOW_GRACE_MS=500

(
  start_ms=$(date +%s%3N 2>/dev/null || echo 0)
  max_wait_s=60
  waited=0
  window_detected=""

  if [[ "${session_kind}" = "x11" ]] && command -v xdotool >/dev/null 2>&1; then
    before_windows=$(xdotool search --onlyvisible "" 2>/dev/null | sort)
    while [[ "${waited}" -lt "${max_wait_s}" ]]; do
      sleep 1
      waited=$(( waited + 1 ))
      after_windows=$(xdotool search --onlyvisible "" 2>/dev/null | sort)
      new_windows=$(comm -13 <(echo "${before_windows}") <(echo "${after_windows}"))
      if [[ -n "${new_windows}" ]]; then
        window_detected="1"
        break
      fi
    done
  elif [[ "${session_kind}" = "x11" ]]; then
    # xdotool absent sur une session X11 : dégradation vers l'attente fixe Wayland, MAIS
    # journalisée -- avant ce correctif, cette dégradation était totalement silencieuse
    # (mêmes symptômes que Wayland : toujours 12s pile, même pour un jeu qui se lance en
    # 2s, sans aucun moyen de comprendre pourquoi depuis les logs). "lpm check" recommande
    # maintenant aussi l'installation de xdotool sur une session X11 -- voir
    # zgc-dependency-checker.sh.
    zgu_log "launcher-orchestrator" "AVERT" "slug=${slug} raison=xdotool_absent_degradation_attente_fixe"
    sleep 12
  else
    # Wayland : même limite documentée qu'avant (xdotool ne peut pas lister/détecter les
    # fenêtres d'autres applications) -- attente fixe raisonnable.
    sleep 12
  fi

  # Marge de sécurité post-détection (voir POST_WINDOW_GRACE_MS ci-dessus) -- s'applique
  # dans tous les cas (fenêtre détectée sur X11, ou attente fixe écoulée sur Wayland).
  sleep "$(awk -v ms="${POST_WINDOW_GRACE_MS}" 'BEGIN { printf "%.3f", ms / 1000 }')"

  # Durée minimum : évite un flash si le jeu démarre anormalement vite.
  if [[ "${start_ms}" != "0" ]]; then
    now_ms=$(date +%s%3N 2>/dev/null || echo 0)
    elapsed_ms=$(( now_ms - start_ms ))
    if [[ "${elapsed_ms}" -lt "${MIN_DISPLAY_MS}" ]]; then
      remaining_ms=$(( MIN_DISPLAY_MS - elapsed_ms ))
      sleep "$(awk -v ms="${remaining_ms}" 'BEGIN { printf "%.3f", ms / 1000 }')"
    fi
  fi

  # --- Délai dépassé sans qu'aucune fenêtre ne soit apparue (SEULEMENT détectable sur X11
  # avec xdotool -- aucun signal fiable équivalent sur Wayland ni sans xdotool, voir
  # ci-dessus, donc jamais de faux avertissement dans ces deux cas) : plutôt que de
  # disparaître en silence comme si tout s'était bien passé, affiche un avertissement
  # quelques secondes avant de fermer -- réutilise la ligne "titre" (voir
  # zgu-launcher-blackscreen.py) pour ça, aucune modification de ce script nécessaire.
  # L'indicateur "chargement"/spinner est masqué en même temps : ce n'est plus "en train de
  # charger" à ce stade, plus la peine de le prétendre. ---
  if [[ "${session_kind}" = "x11" ]] && command -v xdotool >/dev/null 2>&1 && [[ -z "${window_detected}" ]]; then
    zgu_log "launcher-orchestrator" "AVERT" "slug=${slug} raison=aucune_fenetre_detectee_apres_delai delai_s=${max_wait_s}"
    {
      printf '%s\n' "${bg_state}"
      printf '%s\n' "IND_HIDE"
      printf '%s\n' "$(t launcher.launch_timeout_warning)"
    } > "${control_file}" 2>/dev/null
    sleep 4
  fi

  echo "STOP" > "${control_file}" 2>/dev/null
  [[ -n "${bridge_pid}" ]] && kill "${bridge_pid}" 2>/dev/null
  sleep 0.3
  [[ -n "${blackscreen_pid}" ]] && kill "${blackscreen_pid}" 2>/dev/null
  rm -f "${control_file}" 2>/dev/null
) </dev/null >/dev/null 2>&1 &
disown $! 2>/dev/null

launch_lutris
