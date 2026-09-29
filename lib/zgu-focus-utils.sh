#!/bin/bash

# --- Utilitaire partagé : force les fenêtres Zenity au premier plan ---
#
# Constaté par l'utilisateur : les fenêtres Zenity de lpm s'ouvrent systématiquement
# en arrière-plan (comme si son gestionnaire de fenêtres refusait de leur donner le
# focus). Vérifié : Zenity lui-même n'a AUCUNE option pour ça (pas de
# --always-on-top, pas de --grab-focus, rien dans --help). Vérifié aussi que
# Winetricks (que l'utilisateur citait comme référence qui "le fait") n'a en réalité
# aucun mécanisme spécial non plus -- son code source utilise Zenity nu, exactement
# comme lpm. Le vrai problème est donc côté gestionnaire de fenêtres : une fenêtre
# ouverte par un processus qui n'est pas déjà "actif" (lancé depuis un fichier
# .desktop, un gestionnaire de fichiers, Lutris lui-même...) ne reçoit pas
# automatiquement le focus sur certains WM ("focus stealing prevention").
#
# La solution retenue : un petit processus en arrière-plan qui surveille la fenêtre
# Zenity au premier plan (sur son WM_CLASS "zenity") et l'active explicitement via
# "xdotool windowactivate" JUSQU'À CE QUE le focus soit confirmé -- puis arrête de la
# toucher : la fenêtre redevient une fenêtre normale, sur laquelle on peut reperdre
# le focus volontairement (par ex. cliquer ailleurs pour aller vérifier autre chose
# pendant qu'elle attend). Une nouvelle fenêtre Zenity relance le cycle pour elle
# seule.
#
# IMPORTANT (deux versions précédentes, deux bugs réels trouvés et corrigés
# successivement, chacun vérifié en conditions réelles avec Xvfb + openbox +
# xdotool) :
#   1. La toute première version n'activait une fenêtre qu'UNE SEULE FOIS, au moment
#      où son identifiant apparaissait pour la première fois. Sur l'écran "Review
#      before creating" (--list --checklist --editable, plus long à s'initialiser
#      que les autres), cette unique tentative arrivait parfois trop tôt -- avant que
#      la fenêtre soit prête à recevoir le focus -- et n'était jamais retentée : la
#      fenêtre restait visible au premier plan mais SANS le focus clavier.
#   2. Corrigée en réactivant en continu, à chaque tick, tant que la fenêtre Zenity
#      n'est pas la fenêtre active -- ce qui réglait la course, mais empêchait alors
#      TOUT changement de focus volontaire vers une autre fenêtre pendant que Zenity
#      est ouvert (le focus était repris de force même si l'utilisateur cliquait
#      ailleurs exprès).
#   3. Version actuelle : on ne force que jusqu'à la PREMIÈRE confirmation que le
#      focus a bien été pris pour cet identifiant de fenêtre précis (contourne la
#      course du point 1), puis on cesse d'intervenir sur cette fenêtre (règle le
#      problème du point 2) -- jusqu'à ce qu'une nouvelle fenêtre Zenity (nouvel
#      identifiant) apparaisse, qui relance le cycle pour elle.
#
# Nécessite xdotool -- absent, la fonction ne fait rien silencieusement (comportement
# actuel inchangé plutôt que de bloquer tout le script pour un outil optionnel).

ZGU_FOCUS_WATCHER_PID=""

# zgu_start_focus_watcher -- à appeler une fois, juste avant la première fenêtre
# Zenity d'un script interactif. Le processus de surveillance tourne jusqu'à
# zgu_stop_focus_watcher (ou la fin du script si l'appelant oublie de l'appeler : le
# trap EXIT posé ici s'en charge).
zgu_start_focus_watcher() {
  command -v xdotool >/dev/null 2>&1 || return 0
  [[ -n "${ZGU_FOCUS_WATCHER_PID}" ]] && return 0 # déjà démarré

  (
    confirmed_wid=""
    while true; do
      wid=$(xdotool search --class "zenity" 2>/dev/null | tail -1)
      if [[ -n "${wid}" ]]; then
        if [[ "${wid}" != "${confirmed_wid}" ]]; then
          active_wid=$(xdotool getactivewindow 2>/dev/null)
          if [[ "${wid}" = "${active_wid}" ]]; then
            # Focus confirmé pour cette fenêtre précise : on arrête de la forcer,
            # elle se comporte désormais comme une fenêtre normale.
            confirmed_wid="${wid}"
          else
            xdotool windowactivate "${wid}" 2>/dev/null
          fi
        fi
      else
        # Plus aucune fenêtre Zenity ouverte : on oublie la confirmation, pour que
        # la PROCHAINE fenêtre (même si Zenity réutilisait le même identifiant, ce
        # qui n'arrive pas en pratique, un nouveau processus = un nouvel identifiant)
        # reparte du cycle complet.
        confirmed_wid=""
      fi
      sleep 0.15
    done
  ) &
  ZGU_FOCUS_WATCHER_PID=$!
  disown "${ZGU_FOCUS_WATCHER_PID}" 2>/dev/null
  trap 'zgu_stop_focus_watcher' EXIT
}

zgu_stop_focus_watcher() {
  if [[ -n "${ZGU_FOCUS_WATCHER_PID}" ]]; then
    kill "${ZGU_FOCUS_WATCHER_PID}" 2>/dev/null
    wait "${ZGU_FOCUS_WATCHER_PID}" 2>/dev/null
    ZGU_FOCUS_WATCHER_PID=""
  fi
}
