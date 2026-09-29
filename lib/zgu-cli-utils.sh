#!/bin/bash

# --- Utilitaire partagé : coloration ANSI des messages CLI (succès en vert, erreur en rouge) ---
#
# Ne concerne QUE les messages effectivement imprimés sur le terminal en mode CLI : un texte
# capturé via "$(t ...)" pour un --text=... de Zenity ne passe jamais par ces fonctions, donc
# aucun risque d'afficher des codes ANSI bruts dans une boîte de dialogue graphique.
#
# Désactivé automatiquement si la sortie/l'erreur standard n'est pas un vrai terminal
# (redirection vers un fichier, pipe vers une autre commande...) via "[[ -t N ]]" : sans ce
# garde-fou, "lpm list > jeux.txt" ou "lpm log --grep foo | less" se retrouverait avec des
# séquences d'échappement littérales (\033[32m...) polluant le fichier ou cassant le pager.
#
# zgu_cli_ok <texte> : imprime <texte> en vert sur stdout (succès/confirmation finale d'une
# opération CLI -- pas les messages de progression intermédiaires, qui restent neutres).
zgu_cli_ok() {
  if [[ -t 1 ]]; then
    printf '\033[32m%s\033[0m\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

# zgu_cli_error <texte> : imprime <texte> en rouge sur stderr (tous les messages d'erreur CLI,
# déjà systématiquement redirigés vers stderr dans tout le projet -- c'est ce signal existant
# qui permet de coloriser les erreurs de façon mécanique, sans avoir à rejuger au cas par cas
# si un message donné est "une erreur").
zgu_cli_error() {
  if [[ -t 2 ]]; then
    printf '\033[31m%s\033[0m\n' "$1" >&2
  else
    printf '%s\n' "$1" >&2
  fi
}
