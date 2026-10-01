#!/bin/bash

# --- Utilitaires partagés pour la détection de l'installation Lutris (Flatpak vs paquet natif) ---
#
# check_flatpak_lutris_installed() est utilisée par les 9 fichiers de lib/ qui ont besoin
# de savoir si Lutris est installé (zgc-dependency-checker.sh, zgp-game-installer.sh,
# zgp-game-lister.sh, zgp-game-uninstaller.sh, zgr-runner-installer.sh, zgr-runner-lister.sh,
# zgr-runner-packer.sh, zgr-runner-remote-lister.sh, zgr-runner-uninstaller.sh). Une seule
# définition, sourcée par tous les appelants, garantit qu'une correction de la détection
# s'applique partout à la fois : une détection basée sur la simple existence de fichiers
# résiduels (pga.db, dossier games/) plutôt que sur l'application réellement installée
# risquerait de lire la mauvaise base de données si un ancien profil Flatpak ou natif traîne
# encore sur le disque après un changement de méthode d'installation.
#
# Ce fichier ne fait AUCUN affichage (pas de zenity, pas d'echo) : c'est une pure fonction de
# détection, chaque appelant reste responsable de la résolution des chemins qui en dépendent.

# Retourne 0 (vrai) si Lutris est installé via Flatpak, 1 (faux) sinon (paquet natif ou absent).
check_flatpak_lutris_installed() {
  flatpak list 2>/dev/null | grep -q lutris
}

# Retourne 0 (vrai) si Lutris semble installé en paquet natif (par opposition à Flatpak),
# 1 (faux) sinon.
#
# ANCIENNE VERSION (bug corrigé) : combinait "command -v lutris" avec l'existence de pga.db
# et du dossier des runners Wine natifs -- l'idée étant qu'un signal seul (le PATH) laisserait
# passer une installation non standard. Problème réel, remonté par un utilisateur : désinstaller
# le paquet natif (apt/dnf/pacman) ne touche JAMAIS à "~/.local/share/lutris/" -- c'est un
# dossier de données UTILISATEUR, jamais géré par un gestionnaire de paquets, sur aucune
# distro. pga.db et runners/wine y restent donc orphelins indéfiniment après désinstallation,
# et les deux signaux "fichiers résiduels" restaient vrais pour toujours -- lpm continuait de
# croire Lutris natif installé alors qu'il avait été retiré, avec Flatpak comme seule version
# restante (confirmé réel : un utilisateur a désinstallé le paquet natif, gardé Flatpak, et
# lpm continuait de lui proposer le choix "les deux versions sont installées").
#
# Nouvelle détection : uniquement l'EXÉCUTABLE réel, présent sur le disque -- dans le PATH
# (cas normal), ou à un des emplacements standards des paquets Lutris (Debian/RPM/Arch)
# même si le PATH ne le contient pas (installation non standard). Jamais de fichier de
# données : seule la présence du binaire lui-même signale une installation encore active.
check_native_lutris_installed() {
  command -v lutris >/dev/null 2>&1 && return 0

  local candidate
  for candidate in /usr/bin/lutris /usr/local/bin/lutris /usr/games/lutris /opt/lutris/bin/lutris; do
    [[ -x "${candidate}" ]] && return 0
  done

  return 1
}

# Retourne (sur stdout) le runner Wine/Proton par défaut configuré globalement dans
# Lutris (clé "version:" de runners/wine.yml, quel que soit l'emplacement Flatpak ou
# paquet natif), ou "proton-cachyos-x86_64" si aucun fichier n'est trouvé ou lisible.
#
# Utilisée par zgp-game-installer.sh et zgp-game-packer.sh : une seule définition garantit
# que le runner de repli par défaut reste identique partout si jamais il doit être changé.
zgu_get_default_runner() {
  local runners_path found=""
  for runners_path in \
    "${HOME}/.local/share/lutris/runners/wine.yml" \
    "${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine.yml" \
    "${HOME}/.config/lutris/runners/wine.yml"; do
    if [[ -f "${runners_path}" ]]; then
      found=$(awk -F': ' '/^[[:space:]]*version:/ {print $2; exit}' "${runners_path}" | tr -d '"'\''[:space:]')
      [[ -n "${found}" ]] && break
    fi
  done
  [[ -z "${found}" ]] && found="proton-cachyos-x86_64"
  echo "${found}"
}

# --- Détection des jeux vivant dans un préfixe de store partagé (Epic Games Store,
# EA App, Ubisoft Connect...) ---
#
# lpm applique le principe un-jeu-un-préfixe, mais Lutris ne crée pas systématiquement
# un wineprefix par jeu : certains launchers tiers (client installé + jeux dedans) créent
# UN SEUL wineprefix partagé par plusieurs jeux ("directory" identique pour plusieurs
# lignes de la table games). Ces jeux-là ne doivent apparaître nulle part dans lpm (ni
# listés, ni empaquetables, ni désinstallables), sous peine de casser le préfixe partagé
# pour les autres jeux qui y vivent encore.
#
# GOG, itch.io et ZOOM Platform ont été vérifiés comme respectant déjà un-jeu-un-préfixe
# (chaque jeu a son propre "directory" en base, même si rangé dans un sous-dossier comme
# gog/<jeu>/) : ils ne sont donc PAS dans cette liste.
ZGU_STORE_KEYWORDS=("Epic Games Store" "EA App" "EA Desktop" "Ubisoft Connect" "Battle.net" "Steam")

# Retourne (sur stdout, un slug par ligne) l'ensemble des slugs de jeux runner='wine' à
# exclure de lpm : ceux dont le "directory" est partagé par au moins une autre entrée de
# la table games (signal principal, détecte automatiquement tout store à préfixe partagé
# dès qu'un jeu y est installé, sans connaître son nom à l'avance), complété par un filet
# de sécurité par mots-clés (ZGU_STORE_KEYWORDS) pour bloquer aussi un store fraîchement
# installé mais encore vide (donc sans "directory" dupliqué détectable pour l'instant).
#
# Ne fait aucun affichage, ne modifie rien : pure fonction de lecture, à appeler par
# chaque script (lister/packer/uninstaller) pour filtrer sa propre liste de jeux.
zgu_get_blacklisted_slugs() {
  local lutris_db="$1"
  [[ -f "${lutris_db}" ]] || return 0

  local rows
  rows=$(sqlite3 "${lutris_db}" "SELECT slug || char(31) || name || char(31) || directory FROM games WHERE runner='wine';" 2>/dev/null)
  [[ -z "${rows}" ]] && return 0

  local -A dir_count
  local slug name dir
  while IFS=$'\x1f' read -r slug name dir; do
    [[ -z "${dir}" ]] && continue
    dir_count["${dir}"]=$(( ${dir_count["${dir}"]:-0} + 1 ))
  done <<< "${rows}"

  local kw is_blacklisted
  while IFS=$'\x1f' read -r slug name dir; do
    [[ -z "${slug}" ]] && continue
    is_blacklisted=0

    if [[ -n "${dir}" ]] && [[ "${dir_count[${dir}]:-0}" -gt 1 ]]; then
      is_blacklisted=1
    fi

    if [[ "${is_blacklisted}" -eq 0 ]]; then
      for kw in "${ZGU_STORE_KEYWORDS[@]}"; do
        if [[ "${name}" == *"${kw}"* ]]; then
          is_blacklisted=1
          break
        fi
      done
    fi

    [[ "${is_blacklisted}" -eq 1 ]] && echo "${slug}"
  done <<< "${rows}"
}

# --- Détection du store (Epic/EA/Ubisoft/Battle.net) pour un giga-préfixe donné ---
#
# Partagée par zgp-game-isolator.sh ("lpm isolate") et zgp-isolable-lister.sh
# ("lpm list-isolable") : une seule définition garantit que la liste affichée par
# list-isolable et le store effectivement ciblé par isolate ne divergent jamais.
#
# Distinct de ZGU_STORE_KEYWORDS ci-dessus, qui inclut aussi "Steam" pour le filet de
# sécurité de la blacklist générale : Steam est explicitement hors sujet ici (les jeux
# Steam ne sont pas gérés par lpm). Seuls les 4 stores documentés sont reconnus ; un
# préfixe partagé qui n'en fait pas partie (store inconnu, ou blacklisté uniquement par
# détection générique de "directory" dupliqué) retourne 1, sans rien afficher : ni isolate
# ni list-isolable ne doivent deviner un store qu'ils ne savent pas traiter.
zgu_detect_isolation_store() {
  local lutris_db="$1" giga_dir="$2" safe_dir rows name
  safe_dir="${giga_dir//\'/\'\'}"
  rows=$(sqlite3 "${lutris_db}" "SELECT name FROM games WHERE runner='wine' AND directory='${safe_dir}';" 2>/dev/null)
  while IFS= read -r name; do
    case "${name}" in
      *"Epic Games Store"*) echo "egs"; return 0 ;;
      *"EA App"*|*"EA Desktop"*) echo "ea"; return 0 ;;
      *"Ubisoft Connect"*) echo "ubisoft"; return 0 ;;
      *"Battle.net"*) echo "battlenet"; return 0 ;;
    esac
  done <<< "${rows}"
  return 1
}

# Convertit un code de store interne (retourné par zgu_detect_isolation_store) en son nom
# d'affichage complet, pour l'humain (list-isolable, messages isolate).
zgu_store_display_name() {
  case "$1" in
    egs) echo "Epic Games Store" ;;
    ea) echo "EA App / EA Desktop" ;;
    ubisoft) echo "Ubisoft Connect" ;;
    battlenet) echo "Battle.net" ;;
    *) echo "$1" ;;
  esac
}

# Le launcher lui-même (Epic Games Launcher, EA App/Desktop, Ubisoft Connect, Battle.net)
# vit dans le même giga-préfixe partagé que les jeux, et se retrouve donc lui aussi comme
# une entrée "runner=wine" dans pga.db avec un "directory" partagé -- exactement le même
# signal que pour un vrai jeu (voir zgu_get_blacklisted_slugs ci-dessus). Ce n'est pourtant
# jamais un jeu à isoler individuellement : il est déjà dupliqué en entier (le "socle")
# dans le nouveau préfixe de CHAQUE jeu isolé (voir "1. Copie du socle" dans
# zgp-game-isolator.sh), donc "isoler le launcher" à part n'a pas de sens et échoue
# systématiquement (aucun "dossier de jeu" propre à lui à isoler).
#
# Noms exacts sous lesquels Lutris/lpm connaît ces entrées (voir ZGU_STORE_KEYWORDS
# ci-dessus, dont ceux-ci sont un sous-ensemble) -- partagé par "lpm isolate" (qui ne doit
# jamais tenter de l'isoler) et "lpm list-isolable" (qui ne doit jamais le lister), pour que
# les deux commandes s'accordent toujours.
zgu_is_store_launcher_name() {
  local store="$1" name="$2"
  case "${store}" in
    egs) [[ "${name}" = "Epic Games Store" ]] ;;
    ea) [[ "${name}" = "EA App" ]] || [[ "${name}" = "EA Desktop" ]] ;;
    ubisoft) [[ "${name}" = "Ubisoft Connect" ]] ;;
    battlenet) [[ "${name}" = "Battle.net" ]] ;;
    *) return 1 ;;
  esac
}

# --- Résolution de la version Lutris à utiliser (Flatpak vs paquet natif) quand les deux
# sont installées en même temps ---
#
# Avant cette fonction, chaque appelant faisait "if check_flatpak_lutris_installed; then ...
# elif check_native_lutris_installed; then ..." : si les deux étaient présentes, Flatpak
# gagnait systématiquement, silencieusement, sans qu'aucun message n'indique à l'utilisateur
# que sa bibliothèque native (jeux/runners) était ignorée. Statistiquement, une machine avec
# les deux installées (test Flatpak jamais désinstallé, dépendance d'une autre appli, etc.)
# n'est pas un cas si rare -- voir l'échange qui a mené à cette fonction.
#
# Fichier de config persistant pour le choix forcé par l'utilisateur, même dossier que la
# clé SteamGridDB (~/.config/lpm/) : mêmes conventions de persistance dans tout le projet.
ZGU_LUTRIS_VERSION_CONFIG="${HOME}/.config/lpm/lutris-version"

# Résout la version à utiliser pour CETTE exécution de lpm, dans cet ordre :
#   1. Variable d'environnement LPM_LUTRIS_VERSION ("flatpak" ou "native") -- override
#      ponctuel, jamais écrit sur disque, pour un test rapide sans toucher au choix sauvegardé.
#   2. Fichier de config sauvegardé (ZGU_LUTRIS_VERSION_CONFIG), SEULEMENT s'il désigne une
#      version encore installée -- sinon il est supprimé ici (silencieusement) plutôt que
#      laissé en place : un choix "zombie" ne doit jamais ressurgir plus tard si l'autre
#      version est réinstallée dans un contexte différent, sans que l'utilisateur s'en souvienne.
#   3. Une seule version installée -> utilisée directement, rien d'affiché, rien de sauvegardé
#      (c'est le cas de l'immense majorité des utilisateurs : ils ne voient jamais ce mécanisme).
#   4. Les deux installées, rien de sauvegardé -> avertissement + choix interactif immédiat,
#      sauvegardé ensuite pour ne plus jamais redemander tant que les deux restent installées.
#      Un choix annulé (Zenity fermé, ou réponse vide en CLI en dehors du raccourci "2") retombe
#      sur Flatpak pour CETTE exécution uniquement, sans rien sauvegarder -- pour redemander
#      normalement au prochain lancement plutôt que de figer un choix jamais confirmé.
#
# $1 = mode d'affichage ("cli" ou "gui", même convention que les appelants).
# $2 = chemin de la pga.db du paquet natif (chaîne vide si l'appelant ne l'a pas sous la main).
# $3 = dossier des runners Wine natifs, ou chaîne vide (voir check_native_lutris_installed).
#
# Écrit "flatpak" ou "native" sur stdout. Retourne 1 si aucune des deux n'est installée --
# ce n'est pas le rôle de cette fonction d'afficher l'erreur "Lutris introuvable", chaque
# appelant garde son propre message pour ça, inchangé.
zgu_resolve_lutris_version() {
  local display_mode="$1" package_db="$2" package_runner_dir="$3"

  local has_flatpak=false has_native=false
  check_flatpak_lutris_installed && has_flatpak=true
  check_native_lutris_installed "${package_db}" "${package_runner_dir}" && has_native=true

  if [[ "${has_flatpak}" = false ]] && [[ "${has_native}" = false ]]; then
    return 1
  fi

  case "${LPM_LUTRIS_VERSION:-}" in
    flatpak) [[ "${has_flatpak}" = true ]] && { echo "flatpak"; return 0; } ;;
    native) [[ "${has_native}" = true ]] && { echo "native"; return 0; } ;;
  esac

  if [[ -f "${ZGU_LUTRIS_VERSION_CONFIG}" ]]; then
    local saved
    saved=$(<"${ZGU_LUTRIS_VERSION_CONFIG}")
    saved="${saved//[$'\t\r\n ']/}"
    if [[ "${saved}" = "flatpak" ]] && [[ "${has_flatpak}" = true ]]; then
      echo "flatpak"; return 0
    elif [[ "${saved}" = "native" ]] && [[ "${has_native}" = true ]]; then
      echo "native"; return 0
    else
      rm -f "${ZGU_LUTRIS_VERSION_CONFIG}"
    fi
  fi

  if [[ "${has_flatpak}" = true ]] && [[ "${has_native}" = false ]]; then
    echo "flatpak"; return 0
  fi
  if [[ "${has_native}" = true ]] && [[ "${has_flatpak}" = false ]]; then
    echo "native"; return 0
  fi

  # Les deux sont installées et rien n'est sauvegardé : avertissement + choix immédiat.
  # "display_mode" est systématiquement "cli" désormais (bin/lpm n'a plus aucun point
  # d'entrée interactif -- menu et double-clic délèguent tous les deux à lpm-gui, qui
  # appelle toujours ce script avec des cibles explicites) : plus de branche zenity ici.
  local choice="" confirmed=true
  t common.dual_lutris_warning_cli >&2
  local response
  read -r -p "$(t common.dual_lutris_prompt_cli)" response
  case "${response}" in
    2) choice="native" ;;
    1|"") choice="flatpak" ;;
    *) choice="flatpak"; confirmed=false ;;
  esac

  if [[ "${confirmed}" = true ]]; then
    mkdir -p "$(dirname "${ZGU_LUTRIS_VERSION_CONFIG}")"
    echo "${choice}" > "${ZGU_LUTRIS_VERSION_CONFIG}"
  fi
  echo "${choice}"
  return 0
}

# zgu_get_wine_binary <runner_dir> <version>
# Résout le chemin du binaire wine pour la version de runner donnée. DEUX structures de
# dossier possibles, vérifiées dans le code source de Lutris (lutris/runners/wine.py :
# get_executable() appelle proton.get_proton_wine_path(version) pour une version Proton,
# vs get_path_for_version() -- donc "bin/wine" -- pour un vrai build Wine ; confirmé aussi
# par un mainteneur du projet Proton-GE sur github.com/lutris/lutris/issues/6673, qui
# décrit explicitement la structure "files/bin/wine" des runners Proton) :
#   - Un vrai build Wine (ex: "lutris-ge-8.7-x86_64", "wine-11.14-amd64") :
#     <runner_dir>/<version>/bin/wine
#   - Un runner Proton (ex: "GE-Proton11-3", "proton-cachyos-..."), qui embarque une
#     structure héritée de Steam Play (compatibilitytools.d) :
#     <runner_dir>/<version>/files/bin/wine
# Plutôt que deviner lequel des deux s'applique en inspectant le NOM de la version (motif
# fragile : rien ne garantit qu'un nom de runner Proton contienne littéralement le mot
# "proton", et l'inverse non plus), on sonde directement le disque : les deux emplacements
# sont testés dans l'ordre, et le premier binaire réellement exécutable trouvé est utilisé
# -- reproduit le même résultat que Lutris sans dépendre d'une convention de nommage.
# Sortie : chemin sur stdout, rien si introuvable/non exécutable (code de retour 1).
zgu_get_wine_binary() {
  local runner_dir="$1" version="$2" candidate
  [[ -z "${version}" ]] && return 1
  for candidate in \
    "${runner_dir}/${version}/bin/wine" \
    "${runner_dir}/${version}/files/bin/wine"; do
    if [[ -x "${candidate}" ]]; then
      echo "${candidate}"
      return 0
    fi
  done
  return 1
}
