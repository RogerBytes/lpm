#!/bin/bash

# --- Utilitaire partagé : détection du dossier "Bureau" de l'utilisateur ---
#
# Utilise le mécanisme standard XDG (commande xdg-user-dir, adossée à
# ~/.config/user-dirs.dirs) : c'est la seule source fiable, car c'est elle que les
# environnements de bureau eux-mêmes utilisent pour savoir où poser une icône,
# quelle que soit la langue du système ET même si l'utilisateur a renommé ou
# déplacé son dossier Bureau depuis les paramètres de son environnement.
#
# Une détection codée en dur ("Desktop" / "Bureau" uniquement) échouerait sur un
# système installé dans une autre langue (allemand "Schreibtisch", espagnol
# "Escritorio"...) : le chemin "$HOME/Desktop" serait inexistant, sans le moindre
# message d'erreur (le raccourci ne serait simplement jamais créé/supprimé,
# silencieusement).
#
# Repli sur l'heuristique Desktop/Bureau si xdg-user-dir est absent ou ne renvoie
# rien d'exploitable (environnement minimal sans le paquet xdg-user-dirs).
zgu_get_desktop_dir() {
  if command -v xdg-user-dir >/dev/null 2>&1; then
    local xdg_desktop
    xdg_desktop=$(xdg-user-dir DESKTOP 2>/dev/null)
    # xdg-user-dir renvoie $HOME tel quel quand XDG_DESKTOP_DIR n'est pas configuré :
    # dans ce cas précis, ce n'est pas une vraie réponse, on continue vers le fallback.
    if [[ -n "${xdg_desktop}" ]] && [[ "${xdg_desktop}" != "${HOME}" ]]; then
      echo "${xdg_desktop}"
      return 0
    fi
  fi

  if [[ -d "${HOME}/Bureau" ]]; then
    echo "${HOME}/Bureau"
  else
    echo "${HOME}/Desktop"
  fi
}

# --- Utilitaire partagé : génère le(s) raccourci(s) .desktop d'un jeu lpm ---
#
# zgu_write_game_shortcut <nom_affiche> <slug> <prefix_dir> <game_id> <version> <create_menu> <create_desktop> [<executable_path>] [<configpath>] [<lutris_config_dir>] [<runner_dir>]
#
# Utilisée à la fois par zgp-game-installer.sh (juste après l'installation d'un .zgp) et
# zgp-game-shortcutter.sh (a posteriori, sur un jeu déjà installé) -- une seule et même
# logique, pour qu'un futur correctif ou une amélioration s'applique aux deux sans
# duplication. Suppose que "t" (zgl-lang-loader.sh) est déjà chargée par l'appelant.
#
# Résolution de l'icône : cherche une image dans <prefix_dir>/icon (déposée à la main par
# l'utilisateur, ou packagée dans le .zgp). À défaut, retombe sur "lpm-game-generic", notre
# propre icône de secours (assets/icons/lpm-game-generic.svg, installée dans le thème
# hicolor par install.sh) -- une reproduction du fond de l'icône système générique
# "applications-games" avec un glyphe manette, volontairement DIFFÉRENTE du glyphe "paquet"
# (.zgp) et du glyphe "verre" (.zgr, voir install.sh) : les réutiliser aurait créé une
# confusion visuelle entre un fichier .zgp, le lanceur lpm lui-même et un simple raccourci de
# jeu. Avant ce choix, un jeu sans icône se voyait affublé de "Icon=lutris_${slug}" -- un nom
# de thème d'icône inventé ne correspondant à rien sur le système (Lutris, lui, télécharge
# réellement une icône sous ce nom via son propre système de jaquettes ; lpm ne le fait pas),
# d'où l'aspect "cassé" du raccourci ; puis "applications-games" (icône système générique),
# remplacée à son tour par notre propre icône pour rester cohérent avec le reste de la
# famille lpm et ne plus dépendre du thème d'icônes installé sur la machine de l'utilisateur.
#
# StartupWMClass : sans ça, la fenêtre du jeu une fois lancée n'affiche PAS l'icône du
# raccourci dans le panneau des tâches, mais celle que Wine annonce lui-même pour la
# fenêtre (l'icône embarquée dans l'exécutable, ou rien) -- parce que le panneau essaie de
# faire correspondre la fenêtre en cours au .desktop via la propriété X11 WM_CLASS, et Wine
# y met le nom de l'exécutable tel quel (ex: "Notepad.exe"), qui ne correspond à rien dans
# un .desktop généré sans ce champ. Confirmé via un message d'un développeur Wine sur la
# liste wine-devel (avril 2017) décrivant exactement ce bug et cette correction, et via la
# spec freedesktop Desktop Entry qui définit StartupWMClass précisément pour ce cas.
#
# CAS PARTICULIER PROTON/UMU (runner Proton, ex: GE-Proton) : le comportement ci-dessus ne
# s'applique QU'AU wine classique. Confirmé par test réel (xprop) : une fenêtre lancée via
# umu-run a pour WM_CLASS "steam_app_<id>", jamais le nom de l'exécutable -- et <id> ne
# dépend PAS du contenu réel de GAMEID tel quel, mais d'un motif précis vérifié dans le
# code source d'umu-run (umu/umu_run.py) : GAMEID n'est reconnu que sous la forme
# "umu-<id>", auquel cas <id> devient STEAM_COMPAT_APP_ID/SteamAppId, d'où le WM_CLASS
# "steam_app_<id>". Sans GAMEID réglé du tout, umu-run retombe sur un WM_CLASS générique
# ("steam_app_default" ou "steam_app_0") IDENTIQUE pour tous les jeux Proton de la machine
# -- donc sans correctif, deux jeux Proton différents se retrouveraient fusionnés à tort
# dans le panneau, ou le raccourci épinglé ne correspondrait jamais à aucun d'eux.
#
# Impossible de régler GAMEID depuis le .desktop lui-même : le raccourci ne fait que
# demander à Lutris de lancer le jeu ("lutris:rungameid/<id>"), c'est Lutris qui invoque
# umu-run ensuite -- et au lancement réel d'un jeu, Lutris construit l'environnement
# UNIQUEMENT à partir de sa propre config (get_env(os_env=False) dans wine.py, confirmé
# dans le code source de Lutris), pas de l'environnement du .desktop. Le seul levier est
# donc la config Lutris du jeu elle-même (system: env: GAMEID), d'où l'appel Python
# ci-dessous qui y ajoute GAMEID="umu-<game_id>" -- réutilisant l'id Lutris du jeu, déjà
# unique par jeu -- SEULEMENT si ce jeu utilise bien un runner Proton (présence de
# toolmanifest.vdf dans son dossier de build, exactement la vérification faite par
# umu-run lui-même pour valider un PROTONPATH) et SEULEMENT si GAMEID n'est pas déjà
# réglé à la main par l'utilisateur (jamais écrasé). Une sauvegarde (.lpm-bak) du YAML est
# conservée avant toute écriture. Si python3/PyYAML est absent, ou si le jeu n'utilise pas
# Proton, ou si un GAMEID personnalisé incompatible est déjà présent : repli silencieux sur
# le comportement wine classique (nom de l'exécutable) ci-dessus, rien ne casse.
zgu_write_game_shortcut() {
  local game_real_name="$1"
  local slug="$2"
  local prefix_dir="$3"
  local game_id="$4"
  local version="$5"
  local create_menu="$6"
  local create_desktop="$7"
  local executable_path="${8:-}"
  local configpath="${9:-}"
  local lutris_config_dir="${10:-}"
  local runner_dir="${11:-}"

  local icon_path="lpm-game-generic"
  if [[ -d "${prefix_dir}/icon" ]]; then
    local icon_file
    icon_file=$(find "${prefix_dir}/icon" -maxdepth 1 -type f \( -name "*.png" -o -name "*.ico" -o -name "*.svg" -o -name "*.xpm" \) -print -quit 2>/dev/null)
    # icon_file est un nom de fichier réel potentiellement forgé par un tiers (paquet .zgp
    # partagé) et injecté tel quel dans "Icon=${icon_path}" du .desktop généré plus bas : un
    # \n dans ce nom de fichier pourrait ajouter une ligne "Exec=" arbitraire (exécution
    # silencieuse au double-clic, le .desktop étant marqué "metadata::trusted true"). Même
    # filtre que pour slug/game_real_name ailleurs dans le projet.
    icon_file="${icon_file//[$'\n\r\t']/}"
    [[ -n "${icon_file}" ]] && icon_path="${icon_file}"
  fi

  # Tous les raccourcis .desktop créés par lpm passent désormais par l'orchestrateur
  # (lib/zgl-launcher-orchestrator.sh), point d'entrée unique -- voir son en-tête pour la
  # conception complète (écran de chargement, homogénéité voulue de tous les Exec=). Seuls
  # "game_id" (entier) et "version" (mot fixe "flatpak"/"package") transitent par Exec= :
  # tous deux toujours sûrs sans échappement particulier, contrairement à "slug"/"game_dir"
  # (chemins potentiellement porteurs d'espaces) qu'un Exec= au format Desktop Entry devrait
  # alors échapper selon des règles propres à ce format, distinctes de celles d'un shell --
  # l'orchestrateur re-interroge lui-même la base Lutris pour le reste (voir ce fichier).
  # shellcheck disable=SC2154 # script_dir : assigné par l'appelant avant de sourcer ce
  # fichier (zgp-game-shortcutter.sh / zgp-game-installer.sh), même convention que partout
  # ailleurs dans le projet -- portée dynamique bash, pas une variable non définie.
  local exec_cmd="${script_dir}/zgl-launcher-orchestrator.sh ${game_id} ${version}"

  # WM_CLASS Wine = nom de fichier de l'exécutable tel quel (casse et extension conservées,
  # ex: "Notepad.exe"), jamais le chemin complet. executable_path vient de la base Lutris
  # (colonne "executable"), donc potentiellement forgée par un tiers (paquet .zgp partagé) :
  # même filtre anti-injection que pour icon_file/slug/game_real_name ci-dessus/ailleurs,
  # avant d'atterrir dans "StartupWMClass=${wm_class}" du .desktop généré plus bas.
  local wm_class=""
  if [[ -n "${executable_path}" ]]; then
    wm_class=$(basename -- "${executable_path}")
    wm_class="${wm_class//[$'\n\r\t']/}"
  fi

  # Repli Proton/umu (voir commentaire détaillé plus haut) : ne tente rien si un des
  # ingrédients nécessaires manque (configpath/lutris_config_dir/runner_dir non fournis,
  # fichier YAML introuvable, ou python3/PyYAML absent) -- le comportement wine classique
  # ci-dessus reste alors inchangé.
  if [[ -n "${configpath}" ]] && [[ -n "${lutris_config_dir}" ]] && [[ -n "${runner_dir}" ]] \
     && command -v python3 >/dev/null 2>&1 && python3 -c "import yaml" >/dev/null 2>&1; then

    local yml_path="${lutris_config_dir}/${configpath}.yml"
    if [[ -f "${yml_path}" ]]; then
      local proton_wm_class
      proton_wm_class=$(YML_PATH="${yml_path}" RUNNER_DIR="${runner_dir}" GAME_ID="${game_id}" python3 -c '
import os, re, shutil, sys, yaml

yml_path = os.environ["YML_PATH"]
runner_dir = os.environ["RUNNER_DIR"]
game_id = os.environ["GAME_ID"]

try:
    with open(yml_path, "r") as f:
        data = yaml.safe_load(f)
except Exception:
    sys.exit(0)

if not isinstance(data, dict):
    sys.exit(0)

wine_version = data.get("wine", {}).get("version", "") if isinstance(data.get("wine"), dict) else ""
if not wine_version:
    sys.exit(0)

# Meme verification que celle faite par umu-run lui-meme pour valider un PROTONPATH :
# un dossier de build wine classique ne contient jamais ce fichier.
if not os.path.isfile(os.path.join(runner_dir, wine_version, "toolmanifest.vdf")):
    sys.exit(0)

system_cfg = data.get("system")
if not isinstance(system_cfg, dict):
    system_cfg = {}
    data["system"] = system_cfg

env_cfg = system_cfg.get("env")
if not isinstance(env_cfg, dict):
    env_cfg = {}
    system_cfg["env"] = env_cfg

existing = env_cfg.get("GAMEID")
if existing:
    # Ne jamais ecraser un GAMEID deja regle a la main : on en deduit le WM_CLASS
    # attendu seulement s il suit le motif reconnu par umu-run (voir umu_run.py),
    # sinon on ne sait pas ce que ca donne et on abandonne proprement.
    m = re.match(r"^umu-([\d\w]+)$", str(existing))
    if m:
        print(f"steam_app_{m.group(1)}")
    sys.exit(0)

env_cfg["GAMEID"] = f"umu-{game_id}"

try:
    shutil.copy2(yml_path, yml_path + ".lpm-bak")
    with open(yml_path, "w") as f:
        yaml.dump(data, f, sort_keys=False)
except Exception:
    sys.exit(0)

print(f"steam_app_{game_id}")
' 2>/dev/null)

      [[ -n "${proton_wm_class}" ]] && wm_class="${proton_wm_class}"
    fi
  fi

  local shortcut_content="[Desktop Entry]
Type=Application
Name=${game_real_name}
Icon=${icon_path}
Exec=${exec_cmd}
Categories=Game"

  [[ -n "${wm_class}" ]] && shortcut_content="${shortcut_content}
StartupWMClass=${wm_class}"

  if [[ "${create_menu}" = true ]]; then
    mkdir -p "${HOME}/.local/share/applications"
    echo "${shortcut_content}" > "${HOME}/.local/share/applications/net.lutris.${slug}.desktop"
    update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  fi

  if [[ "${create_desktop}" = true ]]; then
    local desktop_dir
    desktop_dir=$(zgu_get_desktop_dir)
    if [[ -d "${desktop_dir}" ]]; then
      echo "${shortcut_content}" > "${desktop_dir}/${slug}.desktop"
      chmod +x "${desktop_dir}/${slug}.desktop"
      gio set "${desktop_dir}/${slug}.desktop" metadata::trusted true 2>/dev/null || true

      if [[ -d "${prefix_dir}/extras" ]]; then
        local bonus_dir_name="${game_real_name} $(t install_game.bonus_folder_suffix)"
        rm -rf "${desktop_dir}/${bonus_dir_name:?}"
        ln -s "${prefix_dir}/extras" "${desktop_dir}/${bonus_dir_name}"
      fi
    fi
  fi
}
