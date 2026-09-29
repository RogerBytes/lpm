#!/bin/bash

# --- Journal des actions lpm ---
#
# Fichier texte, append-only, une ligne par événement, colonnes séparées par une
# tabulation : TIMESTAMP <TAB> COMMANDE <TAB> STATUT <TAB> DÉTAIL
#   - STATUT ∈ OK / ERREUR / INFO
#   - DÉTAIL est une chaîne libre "cle=valeur cle2=valeur2 ..."
#
# Objectif : déboguer a posteriori un install/isolate/pack/uninstall raté (voir
# lpm log, lib/zgp-log-viewer.sh) -- pas un journal exhaustif de toute la sortie
# stdout/stderr, seulement les décisions clé (début de commande, succès/échec par
# élément traité, avec la raison).
#
# Emplacement XDG : $XDG_DATA_HOME/lpm/lpm.log (repli ~/.local/share/lpm/lpm.log),
# cohérent avec l'emplacement déjà utilisé par les données Lutris elles-mêmes.
#
# Rotation : au-delà de ZGU_LOG_MAX_LINES lignes, lpm.log est renommé lpm.log.1 (en
# écrasant un éventuel lpm.log.1 précédent -- un seul niveau de sauvegarde, pas une
# pile façon logrotate : ce journal sert à déboguer l'action la plus récente, pas à
# archiver un historique long terme) et un nouveau lpm.log vide est repris. "lpm log
# --all"/"--grep" ne portent que sur lpm.log actuel, jamais sur lpm.log.1 -- volontaire,
# pour rester cohérent avec la portée "déboguer un raté a posteriori" documentée
# ci-dessus plutôt que de devenir un historique permanent à consulter.
#
# Best-effort : une erreur d'écriture du journal (disque plein, dossier en lecture
# seule, permissions...) ne doit JAMAIS faire échouer la commande lpm elle-même,
# d'où le "|| true"/"|| return 0" systématique ci-dessous -- le journal est un
# outil de confort, pas une garantie, sa perte ne doit pas dégrader le service.

ZGU_LOG_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/lpm"
ZGU_LOG_FILE="${ZGU_LOG_DIR}/lpm.log"
ZGU_LOG_MAX_LINES=10000

# Rotation best-effort : appelée avant chaque écriture (zgu_log), jamais depuis la
# lecture (zgp-log-viewer.sh) -- la rotation est un effet de bord de l'écriture, pas de
# la consultation. "wc -l" sur un fichier plafonné à ZGU_LOG_MAX_LINES lignes reste
# négligeable (quelques Ko à quelques centaines de Ko), pas besoin d'optimiser plus.
zgu_log_rotate_if_needed() {
  [[ -f "${ZGU_LOG_FILE}" ]] || return 0
  local current_lines
  current_lines=$(wc -l < "${ZGU_LOG_FILE}" 2>/dev/null) || return 0
  [[ "${current_lines}" -gt "${ZGU_LOG_MAX_LINES}" ]] || return 0
  mv -f -- "${ZGU_LOG_FILE}" "${ZGU_LOG_FILE}.1" 2>/dev/null || true
}

# zgu_log <commande> <statut> <détail>
# Ajoute une ligne au journal. Neutralise tabulations/sauts de ligne dans chaque
# champ avant écriture : "commande" et "statut" sont toujours des constantes
# internes à lpm, mais "détail" peut embarquer un slug/nom de jeu potentiellement
# forgé par un tiers (paquet .zgp partagé, voir zgp-game-installer.sh) -- sans ce
# filtre, un \t ou \n dedans casserait le format à 4 colonnes en tabulations pour
# toute lecture ultérieure (lpm log --grep, awk, etc.).
zgu_log() {
  local command="$1" status="$2" detail="$3"
  mkdir -p "${ZGU_LOG_DIR}" 2>/dev/null || return 0
  zgu_log_rotate_if_needed
  command="${command//[$'\t\n']/ }"
  status="${status//[$'\t\n']/ }"
  detail="${detail//[$'\t\n']/ }"
  local ts
  ts=$(date +%FT%T%z 2>/dev/null) || ts="?"
  printf '%s\t%s\t%s\t%s\n' "${ts}" "${command}" "${status}" "${detail}" >> "${ZGU_LOG_FILE}" 2>/dev/null || true
}
