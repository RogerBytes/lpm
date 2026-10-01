#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-desktop-utils.sh
source "${script_dir}/zgu-desktop-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"
# shellcheck source=./zgu-hash-utils.sh
source "${script_dir}/zgu-hash-utils.sh"

# --- Analyse des arguments transmis par bin/lpm ---
# $1 = mode (toujours "cli" désormais : bin/lpm n'a plus aucun point d'entrée interactif --
#      conservé en position pour rester cohérent avec les autres scripts de lib/, mais sa
#      valeur n'est plus lue ici)
# $2 = confirm_flag ("yes" si -y)
# $3 = allow_scripts_flag ("yes" si --allow-scripts)
# $4 = ignore_hash_flag ("yes" si --ignore-hash)
# $5, $6... = cibles (fichiers .zgp)
shift || true
confirm_flag="${1:-}"
shift || true
allow_scripts_flag="${1:-}"
shift || true
ignore_hash_flag="${1:-}"
shift || true
cli_targets=("$@")

# Configuration des chemins
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"

# Dossier des builds Wine/Proton installés : nécessaire pour zgu_write_game_shortcut, qui y
# vérifie la présence de "toolmanifest.vdf" (même test que umu-run) afin de distinguer un
# runner Proton d'un Wine classique -- voir le commentaire détaillé dans zgu-desktop-utils.sh.
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

games_dir="${HOME}/Games"

# 1. Vérification des dépendances
# sqlite3, pv et bsdtar sont toujours nécessaires (CLI comme interactif). bsdtar (paquet
# "libarchive-tools" sur Debian/Ubuntu) remplace le tar GNU pour l'extraction : il refuse
# par défaut (ARCHIVE_EXTRACT_SECURE_NODOTDOT / ARCHIVE_EXTRACT_SECURE_SYMLINKS) tout membre
# d'archive tentant de sortir de son dossier de destination via "../" ou un lien symbolique
# piégé -- un .zgp est un paquet potentiellement partagé par un tiers, donc non fiable (voir
# la vérification de slug plus bas), et cette protection doit s'appliquer dès l'extraction,
# pas seulement après coup sur le nom du dossier de premier niveau. bsdtar lit le zstd
# nativement (libzstd liée en dur), donc zstd n'est plus une dépendance externe requise ici.
for cmd in sqlite3 pv bsdtar; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    t install_game.cmd_missing "${cmd}"
    exit 1
  fi
done

# python3 lui-même est requis, distinctement de PyYAML ci-dessous : sans cette vérification
# séparée, une machine sans python3 du tout recevait le même message "PyYAML manquant" qu'une
# machine avec python3 mais sans le module, ce qui égarait l'utilisateur sur la vraie cause.
if ! command -v python3 >/dev/null 2>&1; then
  t install_game.cmd_missing "python3"
  exit 1
fi

# PyYAML est utilisé pour lire/écrire le YAML embarqué (zgp-game-config.yml) : sans lui,
# l'installation se poursuivait avant en silence avec un exécutable Lutris vide.
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  zgu_cli_error "$(t install_game.pyyaml_missing_cli)"
  exit 1
fi

# 2. Fermeture préalable de Lutris pour libérer la BDD
if flatpak list 2>/dev/null | grep -q lutris; then
  flatpak kill net.lutris.Lutris 2>/dev/null
fi
pkill -9 -x lutris 2>/dev/null
pkill -9 -f "/usr/bin/lutris" 2>/dev/null

# 3. Détection Flatpak vs Paquet natif (fonction fournie par zgu-lutris-utils.sh -- résout
# aussi le cas des deux installées en même temps)
version=$(zgu_resolve_lutris_version "cli" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  t install_game.lutris_missing_cli
  exit 1
fi
[[ "${version}" = "native" ]] && version="package"

case "${version}" in
  flatpak)
    lutris_config_dir="${lutris_flatpak_config_dir}"
    lutris_db="${lutris_flatpak_db}"
    lutris_system_file="${lutris_flatpak_system_file}"
    runner_dir="${lutris_flatpak_runner_dir}"
    ;;
  package)
    lutris_config_dir="${lutris_package_config_dir}"
    lutris_db="${lutris_package_db}"
    lutris_system_file="${lutris_package_system_file}"
    runner_dir="${lutris_package_runner_dir}"
    ;;
  *)
    # Ne devrait jamais arriver : $version n'est affecté qu'à "flatpak" ou "package"
    # ci-dessus (sinon exit 1). Garde-fou si cette invariant venait à changer.
    echo "Erreur interne : version Lutris inattendue '${version}'." >&2
    exit 1
    ;;
esac

# Chemin Games personnalisé (si défini dans Lutris) : cette préférence globale ("appliquée à
# tous les jeux", donc côté système et non côté runner Wine) vit dans system.yml, sous la clé
# "system: game_path:" -- PAS dans runners/wine.yml (qui ne contient que des options propres
# au runner Wine, comme system_winetricks/version). L'awk ne dépend pas de l'indentation ou
# de la clé parente : il matche n'importe quelle ligne "game_path:" (avec espaces de tête),
# donc il fonctionne tel quel une fois pointé vers le bon fichier.
if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  if [[ -n "${extracted_path}" ]]; then
    games_dir="${extracted_path}"
  fi
fi

mkdir -p "${lutris_config_dir}"
mkdir -p "$(dirname "${lutris_db}")"
mkdir -p "${games_dir}"

# ---------------------------------------------------------------------------------------------

games_to_install=()
declare -A filepath_by_name
create_menu=false
create_desktop=false
# Écran de chargement (voir lib/zgl-launcher-orchestrator.sh) : actif par défaut pour tout
# raccourci créé par lpm, quel que soit le mode (CLI ou interactif/double-clic) -- aucun
# flag CLI dédié pour l'instant, même convention que create_menu/create_desktop en mode CLI
# (toujours "true", sans équivalent --no-menu/--no-desktop).
loadingscreen_enabled=true

# Mode CLI strict uniquement (depuis le terminal avec ou sans -y) : bin/lpm n'a plus aucun
# point d'entrée interactif, donc l'ancien menu Zenity/sélecteur de fichier/case à cocher
# (mode menu ou double-clic) a été retiré ici.
for target in "${cli_targets[@]}"; do
  if [[ -f "${target}" ]]; then
    filename=$(basename "${target}" .zgp)
    games_to_install+=("${filename}")
    filepath_by_name["${filename}"]="${target}"
  else
    zgu_cli_error "$(t install_game.file_not_found "${target}")"
    exit 1
  fi
done

# Gestion de la confirmation interactive si le flag -y n'est pas présent
if [[ "${confirm_flag}" != "yes" ]]; then
  t install_game.confirm_cli_header
  for name in "${games_to_install[@]}"; do
    t install_game.confirm_cli_item "${name}" "${filepath_by_name[${name}]}"
  done
  read -r -p "$(t install_game.confirm_cli_prompt)" response
  case "${response}" in
    [nN])
      t install_game.cancelled_cli
      exit 0
      ;;
    *)
      ;;
  esac
fi

create_menu=true
create_desktop=true

# --- Vérification d'intégrité (sha256) de tout le lot, avant toute extraction ---
#
# Faite ici, après que games_to_install soit définitivement établi par les deux branches
# ci-dessus (CLI stricte et interactive/double-clic), pour ne vérifier qu'une seule fois par
# lot plutôt que de mélanger la vérif dans chaque branche séparément. Tout se joue AVANT le
# début de la boucle d'extraction plus bas : aucun fichier n'est touché tant que ce bloc n'a
# pas fini de décider quels jeux restent dans games_to_install.
if [[ "${ignore_hash_flag}" != "yes" ]]; then
  hash_mismatch_names=()
  for name in "${games_to_install[@]}"; do
    filepath="${filepath_by_name[${name}]}"
    if hash_file=$(zgu_find_hash_sidecar "${filepath}"); then
      zgu_verify_archive_hash "${filepath}" "${hash_file}" || hash_mismatch_names+=("${name}")
    fi
  done

  if [[ ${#hash_mismatch_names[@]} -gt 0 ]]; then
    zgu_cli_error "$(t install_game.hash_mismatch_cli_header)"
    for name in "${hash_mismatch_names[@]}"; do
      zgu_cli_error "$(t install_game.hash_mismatch_cli_item "${name}")"
    done
    read -r -p "$(t install_game.hash_mismatch_cli_prompt)" hash_response
    case "${hash_response}" in
      [yY])
        : # installer quand même, games_to_install reste tel quel
        ;;
      *)
        declare -A hash_excluded
        for name in "${hash_mismatch_names[@]}"; do
          hash_excluded["${name}"]=1
        done
        hash_filtered_games=()
        for name in "${games_to_install[@]}"; do
          [[ -n "${hash_excluded[${name}]:-}" ]] || hash_filtered_games+=("${name}")
        done
        games_to_install=("${hash_filtered_games[@]}")
        ;;
    esac
  fi
fi

if [[ ${#games_to_install[@]} -eq 0 ]]; then
  exit 0
fi

# ---------------------------------------------------------------------------------------------

install_idx=0
# Compteur de réussites réelles, utilisé pour que le notify-send final reflète ce qui a VRAIMENT
# été installé plutôt que d'annoncer systématiquement un succès total (bug réel rencontré par
# l'utilisateur : 103 jeux cochés, 0 installés, message final disant pourtant "103 installés").
# Un simple fichier plutôt qu'une variable de shell, par prudence si run_post_install venait à
# être appelée depuis un sous-shell -- toute variable qu'elle modifierait y resterait invisible
# une fois le sous-shell terminé, alors qu'une écriture dans un fichier par chemin traverse cette
# frontière.
install_success_file=$(mktemp)
# Traitement de chaque jeu sélectionné
for name in "${games_to_install[@]}"; do
  install_idx=$((install_idx + 1))
  filepath="${filepath_by_name[${name}]}"

  # 1. Extraction dans un dossier temporaire DIRECTEMENT dans $games_dir (renommage instantané garanti)
  temp_extract_dir=$(mktemp -d "${games_dir}/.zgp-extract-XXXXXX")
  file_size=$(stat -c %s "${filepath}" 2>/dev/null || stat -f %z "${filepath}" 2>/dev/null)

  t install_game.importing_cli "${name}"
  # bsdtar (et non tar -I zstd) : voir le commentaire sur la vérification des dépendances
  # plus haut dans ce fichier pour le détail des protections SECURE_NODOTDOT/SECURE_SYMLINKS.
  # umask 022 le temps de l'extraction : bsdtar préserve par défaut les bits de permission
  # d'origine de l'archive, sans "--no-same-permissions". Sans ce garde-fou, un .zgp
  # forgé par un tiers pouvait planter un fichier monde-inscriptible (777) dans le
  # dossier de jeux -- exploitable par un autre utilisateur local sur une machine
  # partagée -- ou un fichier illisible (000) pour saboter silencieusement l'installation.
  _lpm_old_umask=$(umask)
  umask 022
  pv -s "${file_size:-0}" "${filepath}" | bsdtar -xf - -C "${temp_extract_dir}"
  tar_exit="${PIPESTATUS[1]}"
  umask "${_lpm_old_umask}"

  # 1bis. Vérification de l'intégrité de l'extraction : si tar a échoué (archive corrompue,
  # tronquée ou invalide), on abandonne proprement ce jeu sans toucher à Lutris ni créer de raccourcis
  if [[ "${tar_exit}" -ne 0 ]]; then
    err_msg="$(t install_game.corrupt_archive "${name}" "${tar_exit}")"
    echo "${err_msg}" >&2
    zgu_log "install" "ERREUR" "fichier=${name} raison=archive_corrompue code=${tar_exit}"
    rm -rf "${temp_extract_dir}"
    continue
  fi

  # 2. Découverte du véritable slug à partir de ce qui a été réellement extrait
  # find + head plutôt que "ls -1 | head -n 1" (SC2012) : comportement identique dans le
  # cas normal (un seul dossier top-level attendu), la protection réelle contre un nom de
  # fichier pathologique reste de toute façon assurée par les vérifications qui suivent
  # (-d, anti-symlink, realpath) plutôt que par ce choix de commande.
  slug=$(basename "$(find "${temp_extract_dir}" -mindepth 1 -maxdepth 1 | head -n 1)")
  if [[ -z "${slug}" ]] || [[ ! -d "${temp_extract_dir}/${slug}" ]]; then
    zgu_cli_error "$(t install_game.slug_detect_failed "${name}")"
    zgu_log "install" "ERREUR" "fichier=${name} raison=slug_introuvable"
    rm -rf "${temp_extract_dir}"
    continue
  fi

  # 2bis. Durcissement anti-traversée : un .zgp est un paquet potentiellement partagé
  # par un tiers, donc non fiable. Un lien symbolique nommé comme entrée de premier
  # niveau dans l'archive (ex: pointant vers /etc ou $HOME) ferait passer le test
  # "-d" ci-dessus tout en pointant hors de $temp_extract_dir : on refuse tout lien
  # symbolique ici, et on vérifie en plus que le chemin réel résolu reste bien un
  # enfant direct de $temp_extract_dir avant de continuer.
  if [[ -L "${temp_extract_dir}/${slug}" ]]; then
    zgu_cli_error "$(t install_game.slug_detect_failed "${name}")"
    zgu_log "install" "ERREUR" "fichier=${name} raison=slug_lien_symbolique"
    rm -rf "${temp_extract_dir}"
    continue
  fi
  # shellcheck disable=SC2249 # filtre de rejet, pas un dispatch : un slug qui ne matche
  # pas ces motifs dangereux continue normalement le traitement ci-dessous, c'est voulu.
  case "${slug}" in
    */*|.|..)
      zgu_cli_error "$(t install_game.slug_detect_failed "${name}")"
      zgu_log "install" "ERREUR" "fichier=${name} raison=slug_traversee_chemin"
      rm -rf "${temp_extract_dir}"
      continue
      ;;
  esac

  # Rejet de tout caractère de contrôle (saut de ligne, retour chariot...) dans le slug :
  # un nom de dossier Linux peut légalement en contenir, et slug sert de repli pour
  # icon_path, lui-même injecté tel quel dans le fichier .desktop généré plus bas
  # ("Icon=${icon_path}"). Sans ce filtre, un \n dans le slug d'un .zgp forgé par un tiers
  # pouvait ajouter une ligne "Exec=" arbitraire dans le .desktop -- qui, marqué
  # "metadata::trusted true" à la création, s'exécute sans avertissement au double-clic.
  # Même risque déjà mitigé pour game_real_name plus bas ; slug suit exactement le même
  # chemin et doit être filtré de façon identique, ici en amont, par rejet plutôt que
  # nettoyage a posteriori.
  case "${slug}" in
    *[$'\n\r\t']*)
      zgu_cli_error "$(t install_game.slug_detect_failed "${name}")"
      zgu_log "install" "ERREUR" "fichier=${name} raison=slug_caractere_controle"
      rm -rf "${temp_extract_dir}"
      continue
      ;;
  esac
  real_slug_dir=$(realpath -e "${temp_extract_dir}/${slug}" 2>/dev/null)
  real_temp_dir=$(realpath -e "${temp_extract_dir}" 2>/dev/null)
  if [[ -z "${real_slug_dir}" ]] || [[ -z "${real_temp_dir}" ]] || [[ "${real_slug_dir%/*}" != "${real_temp_dir}" ]]; then
    zgu_cli_error "$(t install_game.slug_detect_failed "${name}")"
    zgu_log "install" "ERREUR" "fichier=${name} raison=slug_chemin_reel_invalide"
    rm -rf "${temp_extract_dir}"
    continue
  fi

  prefix_dir="${games_dir}/${slug}"

  # 3. Vérification stricte : si le préfixe existe déjà, on refuse catégoriquement l'installation
  if [[ -d "${prefix_dir}" ]]; then
    err_msg="$(t install_game.already_installed "${slug}")"
    echo "${err_msg}" >&2
    zgu_log "install" "ERREUR" "fichier=${name} slug=${slug} raison=deja_installe"
    rm -rf "${temp_extract_dir}"
    continue
  fi

  # 4. Déplacement définitif instantané (0 seconde)
  if ! mv "${temp_extract_dir}/${slug}" "${games_dir}/"; then
    err_msg="$(t install_game.move_failed "${name}")"
    echo "${err_msg}" >&2
    zgu_log "install" "ERREUR" "fichier=${name} slug=${slug} raison=deplacement_echoue"
    rm -rf "${temp_extract_dir}"
    continue
  fi
  rm -rf "${temp_extract_dir}"

  run_post_install() {
    t install_game.analyzing "${name}"

    timestamp=$(date +%s%N)
    config_id="${slug}-${timestamp}"

    # Le nom affiche du jeu (raccourci .desktop, messages, etc.) vient directement du champ
    # "name" du zgp-game-config.yml embarque -- c'est deja la copie du YAML Lutris d'origine,
    # ou ce champ est present nativement (confirme par inspection d'un vrai fichier Lutris :
    # "game:", "game_slug:", "name:", "system:", "wine:" en cles racine). Il n'y a donc plus
    # besoin d'un zgp-meta.json separe portant la meme information en double : un seul fichier
    # a lire au lieu de deux, sans rien perdre (l'ancien zgp-meta.json n'etait ecrit par le
    # packer que pour transporter ce meme nom).
    bundled_yml="${prefix_dir}/zgp-game-config.yml"
    game_real_name=""

    if [[ -f "${bundled_yml}" ]]; then
      # Pas de test "command -v python3" ici : python3 est déjà vérifié comme dépendance
      # obligatoire en tête de script (le script quitte sinon), donc toujours présent à ce stade.
      # $bundled_yml dérive de $slug, potentiellement forgé par quiconque a créé le
      # paquet .zgp partagé (voir la même remarque plus bas concernant l'échappement
      # SQL) : passé via l'environnement plutôt qu'interpolé dans le code Python, pour
      # qu'une apostrophe ou tout autre caractère spécial dans le chemin extrait
      # ne puisse plus casser la chaîne littérale et injecter du code Python arbitraire.
      game_real_name=$(BUN_YML="${bundled_yml}" python3 -c '
import yaml, os
try:
    with open(os.environ["BUN_YML"]) as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        print(data.get("name", "") or "")
except Exception:
    pass
' 2>/dev/null)
    fi

    # game_real_name vient d'un zgp-game-config.yml potentiellement forgé par quiconque a créé
    # le paquet .zgp partagé (voir remarque plus haut sur l'échappement SQL/Python). Cette
    # valeur est ensuite réutilisée telle quelle dans le fichier .desktop généré plus bas
    # ("Name=${game_real_name}") et dans bonus_dir_name : un saut de ligne injecté ici
    # pourrait ajouter une clé "Exec=" arbitraire dans le .desktop (exécution de commande
    # au clic sur le raccourci), et un "/" ou "../" pourrait faire sortir le rm -rf de
    # bonus_dir_name de desktop_dir. On retire donc tout caractère de contrôle (CR/LF en
    # tête) et tout séparateur de chemin avant toute autre utilisation de cette variable.
    game_real_name="${game_real_name//[$'\n\r']/ }"
    game_real_name="${game_real_name//\//-}"

    [[ -z "${game_real_name}" ]] && game_real_name="${name}"

    t install_game.processing_registry
    for reg in "system.reg" "user.reg" "userdef.reg" "lutris.json"; do
      if [[ -f "${prefix_dir}/${reg}" ]]; then
        sed -i "s|anonuser|${USER}|g" "${prefix_dir}/${reg}"
      fi
    done

    # find + head -n 1 plutôt qu'un glob passé tel quel à basename : si "Games/" contient
    # plusieurs sous-dossiers, basename recevait plusieurs arguments et interprétait le
    # second comme un suffixe à retirer du premier (voire échouait avec "extra operand"
    # sur 3+ dossiers), ce qui pouvait faire sauter silencieusement ce patch goglog.ini.
    # Même mécanisme que dans zgp-game-packer.sh pour rester cohérent.
    gamefolder=$(basename "$(find "${prefix_dir}/drive_c/Games" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n 1)")
    if [[ -n "${gamefolder}" ]]; then
      ini_parent_dir="${prefix_dir}/drive_c/Games/${gamefolder}"
      goglog="${ini_parent_dir}/goglog.ini"
      if [[ -f "${goglog}" ]]; then
        sed -i "s|anonuser|${USER}|g" "${goglog}"
      fi
    fi

    mkdir -p "${prefix_dir}/dosdevices"
    ln -sf "../drive_c" "${prefix_dir}/dosdevices/c:"
    if [[ ! -e "${prefix_dir}/pfx" ]]; then
      ln -sf "." "${prefix_dir}/pfx"
    fi

    # Filet de sécurité pour une archive plus ancienne encore packagée avant ce nettoyage
    # (voir zgp-game-packer.sh) : "Local Settings" peut contenir un résidu de migration
    # Proton ("Application Data BACKUP" non vide) qui ferait échouer la migration automatique
    # au premier lancement avec "Directory not empty". Supprimé sans condition, comme au pack.
    if [[ -e "${prefix_dir}/drive_c/users/steamuser/Local Settings" || -L "${prefix_dir}/drive_c/users/steamuser/Local Settings" ]]; then
      rm -rf -- "${prefix_dir}/drive_c/users/steamuser/Local Settings"
    fi

    t install_game.registering_lutris
    safe_name="${game_real_name//\'/\'\'}"
    # slug et config_id dérivent du nom du dossier extrait de l'archive .zgp (voir plus haut :
    # slug=$(ls -1 "$temp_extract_dir" | head -n 1)), donc potentiellement forgés par quiconque a
    # créé le paquet .zgp partagé, pas seulement par l'utilisateur local. Sans échappement, un nom
    # de dossier contenant une apostrophe permettait une injection SQL dans les requêtes ci-dessous.
    safe_slug="${slug//\'/\'\'}"
    safe_config_id="${config_id//\'/\'\'}"

    # bundled_yml a déjà été résolu plus haut (lecture du nom réel du jeu) ; on réutilise la
    # même variable ici plutôt que de la redéclarer.
    yml_config_file="${lutris_config_dir}/${config_id}.yml"

    executable_path=""

    if [[ -f "${bundled_yml}" ]]; then
      # --- Détection des hooks d'exécution automatique (prelaunch_command, etc.) ---
      # Lecture seule, rien n'est modifié ici : on liste juste, à l'avance, les clés que le
      # nettoyage ci-dessous retirerait silencieusement (voir le commentaire détaillé sur
      # strip_exec_hooks un peu plus bas). Un .zgp peut aussi bien venir d'un tiers non
      # fiable que d'un paquet que l'utilisateur a créé lui-même avec "lpm pack" -- lpm ne
      # peut pas savoir lequel c'est, donc plutôt que de retirer ces hooks sans jamais le
      # dire, on informe explicitement et on laisse le choix (voir la confirmation plus bas).
      detected_hooks=$(BUN_YML="${bundled_yml}" python3 -c '
import os, yaml

def find_hooks(obj, path=""):
    found = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            kl = k.lower() if isinstance(k, str) else ""
            cur_path = f"{path}.{k}" if path else str(k)
            if kl.endswith("_command") or kl.endswith("_script") or kl.endswith("_wait") or "exec" in kl:
                found.append((cur_path, v))
                continue
            found.extend(find_hooks(v, cur_path))
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            found.extend(find_hooks(item, f"{path}[{i}]"))
    return found

try:
    with open(os.environ["BUN_YML"], "r") as f:
        data = yaml.safe_load(f)
    for hook_path, hook_value in find_hooks(data):
        print(f"{hook_path}\x1f{hook_value}")
except Exception:
    pass
' 2>/dev/null)

      # Par défaut, on strip (comportement historique, sûr) : keep_hooks ne passe à "yes"
      # que si confirmé explicitement ci-dessous -- soit par une réponse interactive, soit
      # par le flag --allow-scripts (voir bin/lpm), fourni explicitement et séparément de
      # -y : -y saute la confirmation d'installation générale, pas l'autorisation
      # d'exécution automatique d'un script à chaque lancement du jeu -- ce sont deux
      # risques différents, --allow-scripts doit être demandé pour lui-même.
      keep_hooks="no"
      if [[ -n "${detected_hooks}" ]]; then
        if [[ "${allow_scripts_flag}" = "yes" ]]; then
          keep_hooks="yes"
          # Notification affichée quelle que soit la voie (CLI-strict ecrit dans le terminal,
          # GUI/double-clic ecrit dans le flux qui alimente la barre de progression -- meme
          # convention que les autres "t install_game.*" appeles depuis run_post_install,
          # ex. "install_game.finalizing" plus bas).
          t install_game.hooks_auto_allowed_cli "${game_real_name}"
        else
          t install_game.hooks_confirm_header_cli "${game_real_name}"
          while IFS=$'\x1f' read -r hook_path hook_value; do
            [[ -z "${hook_path}" ]] && continue
            t install_game.hooks_list_item_cli "${hook_path}" "${hook_value}"
          done <<< "${detected_hooks}"
          read -r -p "$(t install_game.hooks_confirm_prompt_cli)" hooks_response
          case "${hooks_response}" in
            [oOyY]) keep_hooks="yes" ;;
            *) keep_hooks="no" ;;
          esac
        fi
      fi

      BUN_YML="${bundled_yml}" YML_OUT="${yml_config_file}" PFX_DIR="${prefix_dir}" USER_HOME="${HOME}" ERR_YAML_LABEL="$(t install_game.yaml_processing_error)" KEEP_HOOKS="${keep_hooks}" python3 -c '
import os, yaml, re
try:
    with open(os.environ["BUN_YML"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        data.pop("script", None)
        data.pop("version", None)
        
        def update_paths(obj):
            if isinstance(obj, dict):
                return {k: update_paths(v) for k, v in obj.items()}
            elif isinstance(obj, list):
                return [update_paths(v) for v in obj]
            elif isinstance(obj, str):
                res = re.sub(r"/home/[^/]+", os.environ["USER_HOME"], obj)
                res = res.replace("$GAMEDIR", os.environ["PFX_DIR"])
                return res
            return obj
            
        data = update_paths(data)

        # zgp-game-config.yml vient du paquet .zgp partage, potentiellement forge par
        # quiconque l a cree (meme remarque que pour game_real_name/safe_slug plus haut) --
        # voire edite a la main pour y glisser un hook. Lutris execute automatiquement
        # tout ce qui ressemble a une commande/script au lancement ou a la fermeture du
        # jeu (prelaunch_script/postexit_script sous "game", prelaunch_command/
        # postexit_command sous "system"), sans aucune confirmation demandee a
        # l utilisateur. Plutot qu une liste figee de noms de cles connus (qui ne
        # couvrirait pas un futur hook Lutris ni une cle ajoutee a la main sous une
        # autre section), on retire recursivement, dans TOUT le YAML, toute cle dont le
        # nom se termine par "_command"/"_script"/"_wait" ou contient "exec". Ce filtre
        # ne touche pas system.env (LD_PRELOAD, WINEDLLOVERRIDES, etc.) : ces variables
        # sont un usage legitime tres courant (gamemode, mangohud, overrides DXVK...)
        # qu on ne peut pas distinguer d une valeur malveillante sans whitelist de
        # valeurs, donc on les laisse volontairement intactes.
        # keep_hooks : passe a True uniquement si confirmation explicite de la personne qui
        # installe (voir la detection + confirmation juste avant cet appel Python, cote
        # bash) -- sinon comportement historique inchange (strip silencieux).
        keep_hooks = os.environ.get("KEEP_HOOKS", "no") == "yes"

        def strip_exec_hooks(obj):
            if isinstance(obj, dict):
                cleaned = {}
                for k, v in obj.items():
                    kl = k.lower() if isinstance(k, str) else ""
                    if not keep_hooks and (kl.endswith("_command") or kl.endswith("_script") or kl.endswith("_wait") or "exec" in kl):
                        continue
                    cleaned[k] = strip_exec_hooks(v)
                return cleaned
            elif isinstance(obj, list):
                return [strip_exec_hooks(v) for v in obj]
            return obj

        data = strip_exec_hooks(data)

        if "game" not in data:
            data["game"] = {}
        data["game"]["prefix"] = os.environ["PFX_DIR"]

        with open(os.environ["YML_OUT"], "w") as f:
            yaml.dump(data, f, sort_keys=False)
except Exception as e:
    err_label = os.environ.get("ERR_YAML_LABEL", "YAML processing error")
    print(f"{err_label}: {e}")
' 2>/dev/null
      rm -f "${bundled_yml}"

      # Chemin de l'exécutable relu depuis le YAML DÉJÀ PATCHÉ (game.prefix, "$GAMEDIR"
      # et "/home/<user>" déjà résolus vers cette machine ci-dessus), et non depuis le YAML
      # brut embarqué dans le paquet : sinon le "$GAMEDIR" littéral (ou le "anonuser" du
      # paquetage) se retrouverait tel quel dans la base Lutris, pointant vers un chemin
      # inexistant dès qu'on installe sur une autre machine ou un dossier de jeux différent
      # de celui de la machine ayant créé le paquet.
      if [[ -f "${yml_config_file}" ]]; then
        executable_path=$(YML_OUT="${yml_config_file}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_OUT"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        print(data.get("game", {}).get("exe", ""))
except Exception:
    pass
' 2>/dev/null)
      fi
    fi

    if [[ ! -f "${yml_config_file}" ]]; then
      t install_game.yml_missing
    fi

    if [[ "${executable_path}" != /* ]]; then
      executable_path="${prefix_dir}/${executable_path}"
    fi

    safe_prefix_dir="${prefix_dir//\'/\'\'}"
    safe_executable_path="${executable_path//\'/\'\'}"

    sqlite3 "${lutris_db}" "DELETE FROM games WHERE slug='${safe_slug}';"
    sqlite3 "${lutris_db}" <<EOF
INSERT INTO games (name, slug, installer_slug, parent_slug, runner, executable, directory, configpath, updated, installed, installed_at)
VALUES (
  '${safe_name}',
  '${safe_slug}',
  '${safe_slug}',
  '',
  'wine',
  '${safe_executable_path}',
  '${safe_prefix_dir}',
  '${safe_config_id}',
  strftime('%s','now'),
  1,
  strftime('%s','now')
);
EOF

    t install_game.creating_shortcuts
    game_id=$(sqlite3 "${lutris_db}" "SELECT id FROM games WHERE slug='${safe_slug}';")

    zgu_write_game_shortcut "${game_real_name}" "${slug}" "${prefix_dir}" "${game_id}" "${version}" "${create_menu}" "${create_desktop}" "${executable_path}" "${config_id}" "${lutris_config_dir}" "${runner_dir}"

    # Marqueur d'écran de chargement (voir lib/zgl-launcher-orchestrator.sh) : idempotent,
    # même logique que zgp-game-shortcutter.sh -- créé si décoché, absent (donc écran actif)
    # sinon, ce qui est déjà l'état par défaut d'un dossier de jeu fraîchement extrait.
    if [[ "${loadingscreen_enabled}" = false ]]; then
      : > "${prefix_dir}/.lpm-no-loadingscreen" 2>/dev/null
    fi

    zgu_log "install" "OK" "slug=${slug} nom=${game_real_name}"
    echo 1 >> "${install_success_file}"

    t install_game.finalizing
  }

  run_post_install
done

# Notification finale reflétant le résultat RÉEL (voir le commentaire sur install_success_file
# plus haut) : succès total, échec total, ou partiel -- plutôt que d'annoncer un succès total
# sans condition, ce qui a produit un message trompeur lors du bug du lot de 103 jeux.
install_success_count=$(wc -l < "${install_success_file}" 2>/dev/null)
rm -f "${install_success_file}"
[[ -z "${install_success_count}" ]] && install_success_count=0
install_total_count=${#games_to_install[@]}

if [[ "${install_success_count}" -eq "${install_total_count}" ]] && [[ "${install_total_count}" -gt 0 ]]; then
  notify-send "$(t install_game.notify_title)" "$(t install_game.notify_body)" 2>/dev/null
elif [[ "${install_success_count}" -eq 0 ]]; then
  notify-send "$(t install_game.notify_title_none)" "$(t install_game.notify_body_none)" 2>/dev/null
else
  notify-send "$(t install_game.notify_title_partial)" "$(t install_game.notify_body_partial "${install_success_count}" "${install_total_count}")" 2>/dev/null
fi
exit 0
