#!/bin/bash

# --- Utilitaires partagés : barres de progression Zenity unifiées sur le modèle CLI ---
#
# GUI et CLI convergent vers un seul et même mécanisme de progression : pv, dont le
# comptage d'octets est gratuit (aucun balayage disque additionnel, il compte simplement
# ce qui transite déjà dans le pipe) :
#   - CLI  : pv lit le flux (compressé en entrée pour l'extraction, non compressé en
#            entrée pour la compression) et donne un pourcentage réel, exact, sans jamais
#            balayer le système de fichiers.
#   - GUI  : même flux pv, avec sa sortie numérique (-n) redirigée vers Zenity au lieu du
#            terminal. Un pourcentage GUI deviné en scrutant périodiquement le système de
#            fichiers (ex: "du -sb" répété sur le dossier de sortie pendant l'extraction)
#            serait un balayage récursif RÉPÉTÉ de tout l'arbre déjà extrait, à chaque tick,
#            en concurrence directe avec l'extraction elle-même -- pour un paquet de jeu de
#            plusieurs centaines de Go, ce coût devient non négligeable.
#
# Le seul balayage disque qui subsiste est le "du -sb" INITIAL et UNIQUE du dossier source
# avant compression (nécessaire pour connaître la taille totale à donner à "pv -s"), et
# n'est jamais répété pendant l'opération.
#
# Ce fichier ne fait AUCUNE decision d'affichage de message d'erreur/annulation : chaque
# appelant reste responsable de son propre message (traductions différentes selon le
# contexte jeu/runner), seule la mécanique de progression, identique partout, est
# factorisée ici.

# Variable de sortie annexe : après un appel à zgu_gui_extract_zstd, contient le code de
# sortie réel de tar (utile pour un message d'erreur détaillé). Non garantie après un
# retour 2 (annulation).
ZGU_LAST_TAR_EXIT=""

# zgu_gui_extract_zstd <archive_path> <dest_dir> <zenity_title> <zenity_text>
#
# Extrait une archive .tar.zst avec une barre de progression Zenity réelle, pilotée par
# le compteur d'octets de pv sur le FLUX COMPRESSÉ D'ENTRÉE (identique au mode CLI) :
# aucun balayage du dossier de sortie n'est jamais effectué, donc le coût de la barre
# reste constant et négligeable quelle que soit la taille du résultat extrait.
#
# Retourne 0 (succès), 1 (tar en échec -- archive corrompue/tronquée, rien n'est nettoyé
# ici, à l'appelant de le faire s'il le souhaite) ou 2 (annulé par l'utilisateur via le
# bouton Zenity).
#
# Extraction via bsdtar (libarchive) et non le tar GNU classique : bsdtar active par défaut
# ARCHIVE_EXTRACT_SECURE_NODOTDOT et ARCHIVE_EXTRACT_SECURE_SYMLINKS (voir tar/bsdtar.c dans
# libarchive), qui refusent respectivement tout membre d'archive dont le chemin contient
# ".." et tout piège par lien symbolique planté dans l'archive -- sans cela, un .zgp/.zgr
# partagé par un tiers pouvait contenir un membre du type "jeu/../../../.ssh/authorized_keys"
# et écrire hors de dest_dir dès l'extraction, avant même les vérifications de slug faites
# par l'appelant. bsdtar lit le zstd nativement (libzstd liée en dur), donc pas besoin de
# "-I zstd" ni de zstd en dépendance externe pour ce chemin de code. Ne JAMAIS ajouter
# --insecure à cet appel : cela désactiverait les deux protections ci-dessus.
zgu_gui_extract_zstd() {
  local archive_path="$1" dest_dir="$2" zen_title="$3" zen_text="$4"

  local archive_size
  archive_size=$(stat -c%s "${archive_path}" 2>/dev/null || stat -f%z "${archive_path}" 2>/dev/null)
  [[ -z "${archive_size}" ]] && archive_size=0

  local tar_exit_file
  tar_exit_file=$(mktemp)

  # Mode lot (voir zgu_batch_progress_open plus bas dans ce fichier) : si l'appelant a ouvert
  # une fenêtre de progression PARTAGÉE pour tout un lot, "${ZGU_BATCH_FD}" est renseigné --
  # on écrit alors dans CETTE fenêtre déjà ouverte au lieu d'en ouvrir une à nous (même flux
  # pv, juste redirigé) : c'est ce qui évite qu'un lot de plusieurs jeux ouvre et referme une
  # fenêtre par jeu. Rien ne change pour un appel hors lot (${ZGU_BATCH_FD} vide) : comportement
  # identique à avant, sa propre fenêtre.
  if [[ -n "${ZGU_BATCH_FD}" ]]; then
    zgu_batch_progress_label "${zen_text}"
    (
      umask 022
      pv -n -s "${archive_size}" "${archive_path}" | bsdtar -xf - -C "${dest_dir}"
      echo "${PIPESTATUS[1]}" > "${tar_exit_file}"
    ) >&"${ZGU_BATCH_FD}" 2>&1

    local tar_exit
    tar_exit=$(cat "${tar_exit_file}" 2>/dev/null)
    rm -f "${tar_exit_file}"
    [[ -z "${tar_exit}" ]] && tar_exit=1
    # shellcheck disable=SC2034 # lue par les scripts qui sourcent ce fichier (ex: zgp-game-installer.sh)
    ZGU_LAST_TAR_EXIT="${tar_exit}"

    # Annulation utilisateur (fenêtre partagée fermée) : détectée APRÈS coup ici, alors que le
    # cas hors lot la détecte via le code de sortie de zenity -- la fenêtre partagée n'étant
    # pas dans ce pipeline précis (elle vit dans le sous-shell de substitution de processus
    # ouvert par zgu_batch_progress_open), on vérifie explicitement qu'elle est toujours
    # vivante plutôt que de se fier à un statut de sortie qu'on ne peut pas récupérer ici.
    if ! zgu_batch_progress_alive; then
      ZGU_LAST_TAR_EXIT=""
      return 2
    fi
    [[ "${tar_exit}" -eq 0 ]] && return 0
    return 1
  fi

  (
    # umask 022 le temps de l'extraction : même garde-fou que les chemins CLI équivalents
    # (voir zgp-game-installer.sh) contre un .zgp/.zgr forgé plantant un fichier trop
    # permissif. Portée limitée à ce sous-shell, pas de restauration nécessaire.
    umask 022
    pv -n -s "${archive_size}" "${archive_path}" | bsdtar -xf - -C "${dest_dir}"
    echo "${PIPESTATUS[1]}" > "${tar_exit_file}"
  ) 2>&1 | zenity --progress --title="${zen_title}" --text="${zen_text}" --percentage=0 --auto-close --width=500 2>/dev/null

  local zenity_status=$?

  if [[ "${zenity_status}" -ne 0 ]]; then
    # Annulation utilisateur : pv reçoit SIGPIPE dès sa prochaine écriture (Zenity a fermé
    # le tube), ce qui coupe l'entrée de tar en cascade -- pas besoin de kill explicite.
    rm -f "${tar_exit_file}"
    ZGU_LAST_TAR_EXIT=""
    return 2
  fi

  local tar_exit
  tar_exit=$(cat "${tar_exit_file}" 2>/dev/null)
  rm -f "${tar_exit_file}"
  [[ -z "${tar_exit}" ]] && tar_exit=1
  # shellcheck disable=SC2034 # lue par les scripts qui sourcent ce fichier (ex: zgp-game-installer.sh)
  ZGU_LAST_TAR_EXIT="${tar_exit}"

  [[ "${tar_exit}" -eq 0 ]] && return 0
  return 1
}

# zgu_gui_compress_zstd <parent_dir> <item_name> <archive_path> <level> <zenity_title> <zenity_text>
#
# Compresse "<parent_dir>/<item_name>" en <archive_path> avec une barre de progression
# Zenity réelle, pilotée par pv sur le flux tar D'ENTRÉE (mesure ce qui a déjà été lu
# depuis le dossier source, comme en mode CLI).
#
# Le seul balayage disque effectué est le "du -sb" initial et unique sur le dossier
# source, identique à celui utilisé en mode CLI.
#
# Retourne 0 (succès), 1 (échec compression, archive déjà supprimée) ou 2 (annulé par
# l'utilisateur, archive déjà supprimée).
zgu_gui_compress_zstd() {
  local parent_dir="$1" item_name="$2" archive_path="$3" level="$4" zen_title="$5" zen_text="$6"

  local zstd_opt
  if [[ "${level}" -gt 19 ]]; then
    zstd_opt="--ultra -${level}"
  else
    zstd_opt="-${level}"
  fi

  local source_size
  source_size=$(du -sb "${parent_dir}/${item_name}" 2>/dev/null | cut -f1)
  [[ -z "${source_size}" ]] && source_size=0

  rm -f "${archive_path}"

  local tar_exit_file
  tar_exit_file=$(mktemp)

  # Mode lot (voir zgu_batch_progress_open plus bas dans ce fichier) : même principe que dans
  # zgu_gui_extract_zstd -- si l'appelant a ouvert une fenêtre PARTAGÉE pour tout un lot, on y
  # écrit directement au lieu d'en ouvrir une à nous. Évite qu'un export de plusieurs
  # jeux/runners ouvre et referme une fenêtre par élément.
  if [[ -n "${ZGU_BATCH_FD}" ]]; then
    zgu_batch_progress_label "${zen_text}"
    (
      tar -C "${parent_dir}" -cf - "${item_name}" | pv -n -s "${source_size}" | zstd "${zstd_opt}" > "${archive_path}"
      echo "${PIPESTATUS[0]}" > "${tar_exit_file}"
    ) >&"${ZGU_BATCH_FD}" 2>&1

    local batch_tar_exit
    batch_tar_exit=$(cat "${tar_exit_file}" 2>/dev/null)
    rm -f "${tar_exit_file}"
    [[ -z "${batch_tar_exit}" ]] && batch_tar_exit=1

    if ! zgu_batch_progress_alive; then
      rm -f "${archive_path}"
      return 2
    fi
    if [[ "${batch_tar_exit}" -ne 0 ]] || [[ ! -s "${archive_path}" ]]; then
      rm -f "${archive_path}"
      return 1
    fi
    chmod 600 "${archive_path}"
    return 0
  fi

  (
    tar -C "${parent_dir}" -cf - "${item_name}" | pv -n -s "${source_size}" | zstd "${zstd_opt}" > "${archive_path}"
    echo "${PIPESTATUS[0]}" > "${tar_exit_file}"
  ) 2>&1 | zenity --progress --title="${zen_title}" --text="${zen_text}" --percentage=0 --auto-close --width=500 2>/dev/null

  local zenity_status=$?

  if [[ "${zenity_status}" -ne 0 ]]; then
    rm -f "${tar_exit_file}" "${archive_path}"
    return 2
  fi

  local tar_exit
  tar_exit=$(cat "${tar_exit_file}" 2>/dev/null)
  rm -f "${tar_exit_file}"
  [[ -z "${tar_exit}" ]] && tar_exit=1

  if [[ "${tar_exit}" -ne 0 ]] || [[ ! -s "${archive_path}" ]]; then
    rm -f "${archive_path}"
    return 1
  fi

  # L'archive (.zgp/.zgr) peut embarquer des données sensibles (registre Wine : clés de
  # licence, chemins...) : restreint aux seuls droits du propriétaire, même raison que
  # les chemins CLI équivalents (voir zgp-game-packer.sh/zgr-runner-packer.sh).
  chmod 600 "${archive_path}"
  return 0
}

# zgu_gui_copy_tree <src_dir> <dst_dir> <zenity_title> <zenity_text>
#
# Copie récursivement <src_dir> vers <dst_dir> (dst_dir est le dossier de destination final,
# pas son parent) avec une barre de progression Zenity réelle, même mécanisme pv que
# l'extraction/compression ci-dessus : tar écrit le flux d'entrée, pv en compte les octets
# déjà lus, tar le réécrit tel quel en sortie (pas de (dé)compression, juste une copie qui
# préserve liens symboliques et permissions comme "cp -a"). Utilisée par lpm isolate pour
# dupliquer le socle (launcher) et le dossier propre au jeu d'un giga-préfixe partagé vers un
# nouveau wineprefix indépendant, sans balayage disque répété.
#
# Retourne 0 (succès), 1 (échec) ou 2 (annulé par l'utilisateur -- dst_dir est laissé tel
# quel dans les deux cas, à l'appelant de nettoyer s'il le souhaite).
zgu_gui_copy_tree() {
  local src_dir="$1" dst_dir="$2" zen_title="$3" zen_text="$4"

  [[ -d "${src_dir}" ]] || return 1
  mkdir -p "${dst_dir}" || return 1

  local source_size
  source_size=$(du -sb "${src_dir}" 2>/dev/null | cut -f1)
  [[ -z "${source_size}" ]] && source_size=0

  local tar_exit_file
  tar_exit_file=$(mktemp)

  # Mode lot (voir zgu_batch_progress_open plus bas dans ce fichier) : même principe que dans
  # zgu_gui_extract_zstd/zgu_gui_compress_zstd -- écrit dans la fenêtre PARTAGÉE déjà ouverte
  # par l'appelant au lieu d'en ouvrir une à nous. Utilisé par zgp-game-isolator.sh quand un
  # store isole plusieurs jeux en une seule passe.
  if [[ -n "${ZGU_BATCH_FD}" ]]; then
    zgu_batch_progress_label "${zen_text}"
    (
      tar -C "${src_dir}" -cf - . | pv -n -s "${source_size}" | tar -C "${dst_dir}" -xf -
      echo "${PIPESTATUS[0]}" > "${tar_exit_file}"
    ) >&"${ZGU_BATCH_FD}" 2>&1

    local batch_tar_exit
    batch_tar_exit=$(cat "${tar_exit_file}" 2>/dev/null)
    rm -f "${tar_exit_file}"
    [[ -z "${batch_tar_exit}" ]] && batch_tar_exit=1

    if ! zgu_batch_progress_alive; then
      return 2
    fi
    [[ "${batch_tar_exit}" -eq 0 ]] && return 0
    return 1
  fi

  (
    tar -C "${src_dir}" -cf - . | pv -n -s "${source_size}" | tar -C "${dst_dir}" -xf -
    echo "${PIPESTATUS[0]}" > "${tar_exit_file}"
  ) 2>&1 | zenity --progress --title="${zen_title}" --text="${zen_text}" --percentage=0 --auto-close --width=500 2>/dev/null

  local zenity_status=$?

  if [[ "${zenity_status}" -ne 0 ]]; then
    rm -f "${tar_exit_file}"
    return 2
  fi

  local tar_exit
  tar_exit=$(cat "${tar_exit_file}" 2>/dev/null)
  rm -f "${tar_exit_file}"
  [[ -z "${tar_exit}" ]] && tar_exit=1

  [[ "${tar_exit}" -eq 0 ]] && return 0
  return 1
}

# zgu_gui_download <url> <dest> <expected_size> <zenity_title> <zenity_text>
#
# Télécharge <url> vers <dest> avec une barre de progression Zenity réelle pilotée par pv,
# quand <expected_size> (en octets) est connue (digest/size fournis par l'API GitHub) :
# même mécanisme que l'extraction/compression ci-dessus. Se rabat sur une barre
# indéterminée (pulsate, non annulable) quand la taille est inconnue, sans jamais deviner
# ni pré-charger quoi que ce soit.
#
# Retourne 0 (succès), 1 (échec : fichier vide ou absent) ou 2 (annulé par l'utilisateur --
# uniquement possible quand la taille est connue, la barre indéterminée n'étant pas
# annulable).
zgu_gui_download() {
  local url="$1" dest="$2" expected_size="${3:-0}" zen_title="$4" zen_text="$5"

  rm -f "${dest}"

  # Mode lot (voir zgu_batch_progress_open plus bas dans ce fichier) : même principe que dans
  # zgu_gui_extract_zstd ci-dessus -- si l'appelant a ouvert une fenêtre PARTAGÉE pour tout un
  # lot, on y écrit directement au lieu d'en ouvrir une à nous. Seul le cas taille connue (pv)
  # donne une vraie progression ; taille inconnue se contente de mettre à jour le texte de la
  # fenêtre partagée sans faire bouger sa barre (elle est en mode pourcentage, pas pulsate --
  # Zenity ne permet pas de faire cohabiter les deux sans fermer/rouvrir la fenêtre, exactement
  # ce que le mode lot cherche à éviter).
  if [[ -n "${ZGU_BATCH_FD}" ]]; then
    zgu_batch_progress_label "${zen_text}"

    if [[ "${expected_size}" -gt 0 ]] 2>/dev/null; then
      (
        if command -v curl >/dev/null 2>&1; then
          curl -sLf "${url}" | pv -n -s "${expected_size}" > "${dest}"
        else
          wget -qO- "${url}" | pv -n -s "${expected_size}" > "${dest}"
        fi
      ) >&"${ZGU_BATCH_FD}" 2>&1
    else
      if command -v wget >/dev/null 2>&1; then
        wget -qO "${dest}" "${url}" 2>/dev/null
      else
        curl -sLf "${url}" -o "${dest}" 2>/dev/null
      fi
    fi

    if ! zgu_batch_progress_alive; then
      rm -f "${dest}"
      return 2
    fi

    if [[ ! -f "${dest}" ]] || [[ ! -s "${dest}" ]]; then
      rm -f "${dest}"
      return 1
    fi
    return 0
  fi

  if [[ "${expected_size}" -gt 0 ]] 2>/dev/null; then
    (
      if command -v curl >/dev/null 2>&1; then
        curl -sLf "${url}" | pv -n -s "${expected_size}" > "${dest}"
      else
        wget -qO- "${url}" | pv -n -s "${expected_size}" > "${dest}"
      fi
    ) 2>&1 | zenity --progress --title="${zen_title}" --text="${zen_text}" --percentage=0 --auto-close --width=450 2>/dev/null

    local zenity_status=$?
    if [[ "${zenity_status}" -ne 0 ]]; then
      rm -f "${dest}"
      return 2
    fi
  else
    (
      if command -v wget >/dev/null 2>&1; then
        wget -qO "${dest}" "${url}" 2>/dev/null
      else
        curl -sLf "${url}" -o "${dest}" 2>/dev/null
      fi
    ) &
    local dl_pid=$!

    (
      while kill -0 "${dl_pid}" 2>/dev/null; do
        echo "${zen_text}"
        sleep 0.5
      done
    ) | zenity --progress --title="${zen_title}" --text="${zen_text}" --pulsate --auto-close --no-cancel 2>/dev/null

    wait "${dl_pid}"
  fi

  if [[ ! -f "${dest}" ]] || [[ ! -s "${dest}" ]]; then
    rm -f "${dest}"
    return 1
  fi
  return 0
}

# --- Fenêtre de progression PARTAGEE pour un traitement par lots (plusieurs jeux/runners) ---
#
# Sans ça, un lot de N elements ouvre et referme N fenetres Zenity a la suite (chaque fonction
# ci-dessus, appelee une fois par element, ouvre son propre "zenity --progress --auto-close") :
# le focus revient sans arret au premier plan a chaque nouvelle fenetre, meme si l'utilisateur
# avait deplace la precedente dans un coin de l'ecran entre-temps -- experience genante pour un
# lot de plusieurs jeux. Ici, UNE SEULE fenetre est ouverte pour tout le lot, jamais refermee ni
# rouverte entre deux elements : l'utilisateur peut la deplacer une fois et elle y reste jusqu'a
# la fin du lot. Le texte au-dessus de la barre affiche le compteur ("3/12 : Half-Life 2 --
# extraction...") et la barre elle-meme reste pilotee par la progression REELLE (pv) de
# l'operation en cours -- rien n'est perdu par rapport aux fonctions ci-dessus, seule la
# fenetre change de portee (tout le lot, plutot qu'un seul element).
#
# zgu_batch_progress_open <titre>
#
# Ouvre la fenetre partagee. A cause de "{fd}> >(...)" (substitution de processus), CETTE
# FONCTION NE PEUT PAS ETRE APPELEE DANS UN SOUS-SHELL (ex: "resultat=$(zgu_batch_progress_open ...)")
# : le descripteur ouvert par "exec" ne survivrait pas a la fin du sous-shell. L'appelant doit
# donc la sourcer directement dans son propre shell, puis lire les deux variables de sortie :
#   zgu_batch_progress_open "Mon titre"
#   # $ZGU_BATCH_FD (descripteur a passer aux fonctions ci-dessus) et $ZGU_BATCH_PID
#   # (processus lecteur, pour zgu_batch_progress_alive) sont alors renseignes.
ZGU_BATCH_FD=""
ZGU_BATCH_PID=""
zgu_batch_progress_open() {
  local title="$1"
  # PAS de "--auto-close" ici (contrairement aux fenetres individuelles ci-dessus) : cette
  # fenetre est fermee EXPLICITEMENT par l'appelant en fin de lot (zgu_batch_progress_close),
  # jamais toute seule -- confirme reel qu'avec "--auto-close", certaines versions de Zenity
  # referment la fenetre DES que la barre atteint 100%, meme si le flux d'entree reste ouvert
  # (Zenity 4.0.1 attend bien la fermeture du flux, mais ce n'est pas garanti sur toutes les
  # versions). Sans lui, plus aucune ambiguite : la fenetre ne se referme QUE sur EOF explicite
  # (zgu_batch_progress_close) ou sur un clic reel de l'utilisateur sur "Annuler".
  exec {ZGU_BATCH_FD}> >(zenity --progress --title="${title}" --text="" --percentage=0 --width=500 2>/dev/null)
  ZGU_BATCH_PID=$!
}

# zgu_batch_progress_label <texte>
#
# Met a jour le texte affiche AU-DESSUS de la barre (typiquement "N/TOTAL : nom -- etape en
# cours") sans toucher au pourcentage -- a appeler avant de lancer l'operation reelle de
# l'element suivant du lot (extraction, telechargement...).
#
# L'ecriture se fait dans un SOUS-SHELL ("( ... )"), jamais directement dans ce shell-ci :
# "printf" est une commande interne bash, donc sans ce sous-shell, un SIGPIPE recu pendant
# son ecriture (fenetre partagee fermee par l'utilisateur entre-temps) tuerait CE PROCESSUS
# bash lui-meme -- confirme reel par un test direct (le script entier s'arretait net, avant
# meme d'atteindre la suite). Isole dans un sous-shell, seul CE sous-shell meurt du SIGPIPE ;
# le script appelant continue et detecte l'annulation via zgu_batch_progress_alive ci-dessous,
# comme prevu.
zgu_batch_progress_label() {
  local text="$1"
  [[ -n "${ZGU_BATCH_FD}" ]] && ( printf '#%s\n' "${text}" >&"${ZGU_BATCH_FD}" ) 2>/dev/null
  return 0
}

# zgu_batch_progress_alive
#
# Renvoie 0 si la fenetre partagee est toujours ouverte (l'utilisateur n'a pas clique sur
# "Annuler"), 1 sinon. A verifier par l'appelant apres CHAQUE element du lot pour arreter le
# traitement des elements suivants si l'utilisateur a annule en cours de route (une annulation
# ferme la fenetre : l'element en cours est alors coupe net par SIGPIPE a sa prochaine
# ecriture, exactement comme pour une fenetre individuelle -- voir zgu_gui_extract_zstd
# ci-dessus -- mais rien n'empecherait par lui-meme de continuer au dela de l'element courant
# sans cette verification explicite).
zgu_batch_progress_alive() {
  [[ -n "${ZGU_BATCH_PID}" ]] && kill -0 "${ZGU_BATCH_PID}" 2>/dev/null
}

# zgu_batch_progress_close
#
# Referme proprement la fenetre partagee en fin de lot (tous les elements traites, ou
# annulation detectee). Sans effet si deja fermee (annulation).
#
# Ferme le descripteur PUIS tue explicitement le processus zenity (confirme reel : sans ce
# kill, fermer uniquement le descripteur -- EOF sur stdin -- laisse Zenity DESACTIVER son
# bouton "Annuler" et en ACTIVER un "Valider"/"OK" a la place, mais la fenetre reste ouverte
# tant que l'utilisateur n'a pas clique dessus. Comme cette fermeture n'intervient qu'une fois
# le lot entierement traite -- succes, erreurs deja affichees au fil de l'eau, ou annulation --
# il n'y a plus rien a confirmer : la fenetre doit simplement disparaitre.
zgu_batch_progress_close() {
  [[ -n "${ZGU_BATCH_FD}" ]] && exec {ZGU_BATCH_FD}>&- 2>/dev/null
  [[ -n "${ZGU_BATCH_PID}" ]] && kill "${ZGU_BATCH_PID}" 2>/dev/null
  ZGU_BATCH_FD=""
  ZGU_BATCH_PID=""
}
