#!/bin/bash

# --- Utilitaire partagé : coloration ANSI des messages CLI (succès en vert, erreur en rouge) ---
#
# Source aussi zgu-log-utils.sh : "zgu_cli_error" en a besoin (voir plus bas) pour journaliser
# automatiquement CHAQUE erreur CLI affichée, sans que le script appelant n'ait besoin de le
# sourcer lui-même -- ainsi, tout script qui source déjà zgu-cli-utils.sh (donc tous, "zgu_cli_error"
# étant utilisé partout dans le projet) obtient la journalisation gratuitement, y compris les
# ~24 scripts qui n'appelaient jamais "zgu_log" avant ce correctif, et tout futur message
# d'erreur ajouté plus tard dans le projet, sans jamais avoir besoin d'y repenser.
_zgu_cli_utils_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgu-log-utils.sh
source "${_zgu_cli_utils_dir}/zgu-log-utils.sh"
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
#
# Journalise AUSSI systématiquement chaque appel dans lpm.log (STATUT=ERREUR), avant même
# d'imprimer le message -- couvre d'un coup toutes les erreurs de pré-vérification (zenity/
# python3/pyyaml/zstd absents, base Lutris introuvable, argument invalide...) qui, avant ce
# correctif, n'étaient jamais loguées nulle part : seules les erreurs survenant DANS une
# boucle de traitement (via des appels "zgu_log" explicites ajoutés au cas par cas) l'étaient.
# "commande" est déduit automatiquement du script appelant (BASH_SOURCE[1], un niveau au-dessus
# de cette fonction) plutôt que d'exiger un paramètre supplémentaire à chaque site d'appel
# existant -- aucun des ~100+ appels à "zgu_cli_error" dans le projet n'a besoin d'être modifié.
zgu_cli_error() {
  local caller
  caller=$(basename -- "${BASH_SOURCE[1]:-inconnu}" .sh)
  zgu_log "${caller}" "ERREUR" "$1"
  if [[ -t 2 ]]; then
    printf '\033[31m%s\033[0m\n' "$1" >&2
  else
    printf '%s\n' "$1" >&2
  fi
}

# zgu_gui_error <texte> [<titre>] : affiche <texte> dans une boîte de dialogue Zenity d'erreur
# (avec <titre> si fourni), et journalise systématiquement l'appel dans lpm.log (STATUT=ERREUR)
# -- même mécanisme que zgu_cli_error, pour que TOUTE erreur affichée à l'utilisateur, en CLI
# comme en GUI, laisse une trace dans le journal, sans exception.
zgu_gui_error() {
  local text="$1" title="${2:-}"
  local caller
  caller=$(basename -- "${BASH_SOURCE[1]:-inconnu}" .sh)
  zgu_log "${caller}" "ERREUR" "${text}"
  if [[ -n "${title}" ]]; then
    zenity --error --title="${title}" --text="${text}" 2>/dev/null
  else
    zenity --error --text="${text}" 2>/dev/null
  fi
}
