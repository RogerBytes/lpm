#!/bin/bash

# --- Utilitaire partagé : liste à cocher Zenity avec bouton "Tout cocher/décocher" ---
#
# zenity --list --checklist n'offre aucun moyen natif de cocher/décocher toutes les lignes
# d'un coup : avec une liste longue (des dizaines/centaines de jeux ou runners), cocher
# chaque ligne une par une est fastidieux. Ce fichier factorise l'ajout d'un bouton dédié
# ("--extra-button" de Zenity, affiché à côté d'OK/Annuler, PAS une ligne de plus dans la
# liste) qui bascule l'état de TOUTES les lignes en une fois, sans jamais toucher aux cases
# à cocher individuelles de chaque jeu/runner : l'utilisateur peut toujours affiner sa
# sélection ligne par ligne après (ou avant) avoir cliqué sur ce bouton.
#
# Mécanique : zenity ne peut pas modifier une fenêtre déjà ouverte, donc "basculer tout" est
# implémenté en relançant la même fenêtre avec un nouvel état par défaut (tout coché / tout
# décoché) à chaque clic sur le bouton -- une vraie sélection (OK avec au moins une ligne
# cochée, ou Annuler) sort de la boucle et retourne le résultat normalement.

# zgu_gui_checklist_toggle_all <initial_state> <n_value_cols> <title> <text> <width> <height> <col_header_checkbox> <col_header_2> [<col_header_3>...] -- <row1_val1> [<row1_val2>...] <row2_val1> ...
#
# <initial_state> : "TRUE" ou "FALSE" -- état des cases à l'ouverture de la fenêtre, AVANT
#                    tout clic sur le bouton toggle (ex: "TRUE" pour une liste de fichiers
#                    trouvés dans un dossier où tout cocher par défaut est le comportement
#                    attendu, "FALSE" pour une liste de suppression où rien ne doit être
#                    coché par mégarde).
# <n_value_cols>  : nombre de colonnes de VALEUR par ligne (hors case à cocher). 1 pour une
#                   liste simple (ex: nom du runner), 2 pour une liste à 2 colonnes de
#                   valeur (ex: nom du jeu + slug).
# Les en-têtes de colonnes passés avant "--" doivent inclure la colonne case à cocher en
# premier, comme pour un --column classique (n_value_cols + 1 en-têtes au total).
# Les valeurs après "--" sont à plat, n_value_cols par ligne (pas de case à cocher dedans :
# elle est gérée entièrement par cette fonction).
#
# Retourne sur stdout exactement ce que renverrait l'appel --list --checklist classique
# qu'elle remplace (valeurs séparées par \x1f, une ligne cochée par entrée), vide si annulé
# ou rien sélectionné -- donc aucun changement requis côté appelant pour parser le résultat.
zgu_gui_checklist_toggle_all() {
  local initial_state="$1"; shift
  local n_value_cols="$1"; shift
  local title="$1"; shift
  local text="$1"; shift
  local width="$1"; shift
  local height="$1"; shift

  local col_headers=()
  while [[ "$1" != "--" ]]; do
    col_headers+=("$1")
    shift
  done
  shift # consomme le "--" séparateur

  local -a values=("$@")
  local n_rows=$(( ${#values[@]} / n_value_cols ))

  local all_checked=false
  [[ "${initial_state}" = "TRUE" ]] && all_checked=true
  local check_label uncheck_label
  check_label="$(t common.checklist_check_all)"
  uncheck_label="$(t common.checklist_uncheck_all)"

  local toggle_label result col_args row_args h i c idx bool_state

  while true; do
    if [[ "${all_checked}" = true ]]; then
      toggle_label="${uncheck_label}"
      bool_state="TRUE"
    else
      toggle_label="${check_label}"
      bool_state="FALSE"
    fi

    col_args=()
    for h in "${col_headers[@]}"; do
      col_args+=( --column="${h}" )
    done

    row_args=()
    for (( i=0; i<n_rows; i++ )); do
      idx=$(( i * n_value_cols ))
      row_args+=( "${bool_state}" )
      for (( c=0; c<n_value_cols; c++ )); do
        row_args+=( "${values[idx + c]}" )
      done
    done

    result=$(zenity --list --checklist \
      --title="${title}" \
      --text="${text}" \
      "${col_args[@]}" \
      --separator=$'\x1f' \
      --extra-button="${toggle_label}" \
      "${row_args[@]}" \
      --width="${width}" --height="${height}" 2>/dev/null)

    # Clic sur le bouton "Tout cocher/décocher" (--extra-button) : Zenity renvoie alors
    # UNIQUEMENT le libellé de ce bouton sur stdout (pas la sélection des lignes), ce qui le
    # distingue sans ambiguïté d'une vraie validation -- on bascule l'état et on rouvre la
    # même fenêtre avec les nouvelles valeurs par défaut, sans quitter la fonction.
    if [[ "${result}" = "${toggle_label}" ]]; then
      if [[ "${all_checked}" = true ]]; then
        all_checked=false
      else
        all_checked=true
      fi
      continue
    fi

    echo "${result}"
    return 0
  done
}

# zgu_gui_checklist_with_states <n_value_cols> <title> <text> <width> <height> <col_header_checkbox> <col_header_2> [<col_header_3>...] -- <row1_state TRUE|FALSE> <row1_val1> [<row1_val2>...] <row2_state> <row2_val1> ...
#
# Variante de zgu_gui_checklist_toggle_all ci-dessus pour le cas où les lignes n'ont PAS
# toutes le même état initial (ex: "lpm icon" ne précoche que les jeux qui n'ont pas encore
# d'icône personnalisée, les autres restent décochés) : l'état de chaque case est fourni
# ligne par ligne dans les valeurs, au lieu d'un seul état global appliqué à toutes.
#
# Le bouton "Tout cocher/décocher" reste disponible : un clic force alors TOUTES les lignes
# au même état (cochées, puis décochées au clic suivant, etc.), écrasant volontairement les
# états individuels différenciés -- l'utilisateur peut toujours réaffiner ligne par ligne
# après coup, exactement comme pour zgu_gui_checklist_toggle_all.
zgu_gui_checklist_with_states() {
  local n_value_cols="$1"; shift
  local title="$1"; shift
  local text="$1"; shift
  local width="$1"; shift
  local height="$1"; shift

  local col_headers=()
  while [[ "$1" != "--" ]]; do
    col_headers+=("$1")
    shift
  done
  shift # consomme le "--" séparateur

  local -a raw_values=("$@")
  local stride=$(( n_value_cols + 1 ))
  local n_rows=$(( ${#raw_values[@]} / stride ))

  local check_label uncheck_label
  check_label="$(t common.checklist_check_all)"
  uncheck_label="$(t common.checklist_uncheck_all)"

  # États individuels de départ, extraits une seule fois -- modifiés en place seulement si
  # l'utilisateur clique sur le bouton "Tout cocher/décocher".
  local -a current_states=()
  local i idx
  for (( i=0; i<n_rows; i++ )); do
    idx=$(( i * stride ))
    current_states+=( "${raw_values[idx]}" )
  done

  local toggle_label result col_args row_args h c toggle_target="TRUE"

  while true; do
    if [[ "${toggle_target}" = "TRUE" ]]; then
      toggle_label="${check_label}"
    else
      toggle_label="${uncheck_label}"
    fi

    col_args=()
    for h in "${col_headers[@]}"; do
      col_args+=( --column="${h}" )
    done

    row_args=()
    for (( i=0; i<n_rows; i++ )); do
      idx=$(( i * stride ))
      row_args+=( "${current_states[i]}" )
      for (( c=1; c<=n_value_cols; c++ )); do
        row_args+=( "${raw_values[idx + c]}" )
      done
    done

    result=$(zenity --list --checklist \
      --title="${title}" \
      --text="${text}" \
      "${col_args[@]}" \
      --separator=$'\x1f' \
      --print-column=ALL \
      --extra-button="${toggle_label}" \
      "${row_args[@]}" \
      --width="${width}" --height="${height}" 2>/dev/null)

    if [[ "${result}" = "${toggle_label}" ]]; then
      for (( i=0; i<n_rows; i++ )); do
        current_states[i]="${toggle_target}"
      done
      if [[ "${toggle_target}" = "TRUE" ]]; then
        toggle_target="FALSE"
      else
        toggle_target="TRUE"
      fi
      continue
    fi

    echo "${result}"
    return 0
  done
}
