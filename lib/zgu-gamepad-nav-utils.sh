#!/bin/bash

# --- Utilitaire partagé : navigation manette dans TOUS les dialogues Zenity de lpm ---
#
# À l'origine, le pont manette->clavier (zgu-gamepad-bridge.py, voir ce fichier pour le
# détail du fonctionnement) n'était démarré que par l'écran de chargement d'un jeu
# (zgl-launcher-orchestrator.sh), le temps de naviguer le picker multi-entrées. Étendu ici
# à toute la session interactive de lpm : une manette permet désormais de naviguer
# n'importe quel menu/dialogue Zenity de l'outil (menu principal, listes, checklists,
# formulaires), pas seulement le picker au lancement d'un jeu.
#
# Démarré une seule fois par bin/lpm, juste avant la boucle du menu interactif principal --
# exactement le même point d'intégration que zgu_start_focus_watcher (voir
# zgu-focus-utils.sh), pour la même raison : bin/lpm ne fait pas "exec" vers les
# sous-commandes qu'il lance depuis ce menu (contrairement au dispatch direct en ligne de
# commande), donc son propre process survit d'un sous-menu à l'autre -- un seul appel ici
# couvre donc TOUTE la session interactive, sans câblage supplémentaire dans chaque script
# de sous-commande.
#
# Absence de python3-evdev, ou aucune manette détectée au démarrage : le script
# zgu-gamepad-bridge.py se termine de lui-même silencieusement (voir son propre code) --
# rien à vérifier de ce côté-ci, on le démarre inconditionnellement et on laisse le pont
# décider s'il y a quelque chose à faire.

ZGU_GAMEPAD_NAV_PID=""

# zgu_start_gamepad_nav -- à appeler une fois, juste avant la boucle du menu interactif
# principal. Le pont manette tourne jusqu'à zgu_stop_gamepad_nav (ou la fin du script si
# l'appelant oublie de l'appeler : le trap EXIT posé ici s'en charge).
zgu_start_gamepad_nav() {
  [[ -n "${ZGU_GAMEPAD_NAV_PID}" ]] && return 0 # déjà démarré
  command -v python3 >/dev/null 2>&1 || return 0

  local nav_script_dir
  nav_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  local session_kind="x11"
  if [[ "${XDG_SESSION_TYPE,,}" = "wayland" ]] || [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    session_kind="wayland"
  fi

  python3 "${nav_script_dir}/zgu-gamepad-bridge.py" "${session_kind}" >/dev/null 2>&1 &
  ZGU_GAMEPAD_NAV_PID=$!
  disown "${ZGU_GAMEPAD_NAV_PID}" 2>/dev/null

  # --- Ajout au trap EXIT existant plutôt que de l'écraser ---
  # bin/lpm démarre déjà zgu_start_focus_watcher (zgu-focus-utils.sh) au même endroit, qui
  # pose son propre "trap ... EXIT". Un "trap 'zgu_stop_gamepad_nav' EXIT" naïf ici
  # remplacerait purement et simplement ce trap existant (bash n'empile pas les traps) --
  # le focus watcher continuerait alors de tourner indéfiniment après la fin de bin/lpm.
  # On récupère donc le trap EXIT déjà posé (s'il y en a un) et on y ajoute notre propre
  # nettoyage, quel que soit l'ordre d'appel des deux fonctions "start_*".
  local existing_trap
  existing_trap="$(trap -p EXIT | sed -e "s/^trap -- '//" -e "s/' EXIT$//")"
  if [[ -n "${existing_trap}" ]]; then
    # shellcheck disable=SC2064
    # Expansion volontaire ICI (pas au moment du signal) : "existing_trap" est déjà le
    # texte littéral d'un trap précédemment posé (capturé via "trap -p" ci-dessus, aucune
    # variable dynamique dedans dans les cas réels de ce projet) -- on veut figer sa valeur
    # actuelle dans la nouvelle chaîne combinée, pas la réévaluer plus tard.
    trap "${existing_trap}; zgu_stop_gamepad_nav" EXIT
  else
    trap 'zgu_stop_gamepad_nav' EXIT
  fi
}

zgu_stop_gamepad_nav() {
  if [[ -n "${ZGU_GAMEPAD_NAV_PID}" ]]; then
    kill "${ZGU_GAMEPAD_NAV_PID}" 2>/dev/null
    wait "${ZGU_GAMEPAD_NAV_PID}" 2>/dev/null
    ZGU_GAMEPAD_NAV_PID=""
  fi
}
