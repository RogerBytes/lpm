#!/bin/bash

# --- Utilitaire partagé : navigation manette dans un picker GTK3 maison ---
#
# Le pont manette->clavier (zgu-gamepad-bridge.py, voir ce fichier pour le détail du
# fonctionnement) n'est plus démarré que par le repli dégradé de zgl-launcher-runtime.sh
# (l'orchestrateur n'a pas tourné), le temps de naviguer son picker multi-entrées
# (zgu-launcher-picker.py) -- l'ancien menu interactif Zenity de bin/lpm, qui le démarrait
# aussi pour toute la session, a été entièrement retiré (voir bin/lpm, plus aucun point
# d'entrée interactif : la nouvelle interface GTK4/Libadwaita, lpm-gui, gère sa propre
# navigation nativement).
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
  # Un "trap 'zgu_stop_gamepad_nav' EXIT" naïf ici remplacerait purement et simplement un
  # trap EXIT déjà posé par l'appelant (bash n'empile pas les traps) -- on récupère donc
  # celui déjà en place (s'il y en a un) et on y ajoute notre propre nettoyage, par
  # précaution, même si plus aucun autre appelant de ce projet n'en pose un au même point
  # d'intégration aujourd'hui.
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
