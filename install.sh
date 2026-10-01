#!/bin/bash

# S'assurer que le script est exécuté avec les privilèges root (sudo)
if [[ "${EUID}" -ne 0 ]]; then
  echo "Erreur : Veuillez exécuter ce script d'installation avec les privilèges administrateur (sudo ./install.sh)."
  exit 1
fi

# Se placer dans le dossier du script (et non le répertoire courant de l'appelant) : permet
# de lancer "sudo /chemin/vers/install.sh" depuis n'importe où, comme bin/lpm le fait déjà
# pour se localiser lui-même, plutôt que d'exiger d'être dans la racine du projet.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# Définition des chemins de destination sur le système
INSTALL_BIN_DIR="/usr/local/bin"
INSTALL_LIB_DIR="/usr/local/lib/lpm"
APP_DESKTOP_DIR="/usr/share/applications"
MIME_DIR="/usr/share/mime/packages"
ZSH_COMPLETION_DIR="/usr/local/share/zsh/site-functions"
BASH_COMPLETION_DIR="/usr/local/share/bash-completion/completions"
MAN_DIR="/usr/local/share/man"
ICON_THEME_DIR="/usr/share/icons/hicolor"
ICON_APPS_DIR="${ICON_THEME_DIR}/scalable/apps"
ICON_MIMETYPES_DIR="${ICON_THEME_DIR}/scalable/mimetypes"

echo "=== Installation de lpm ==="

# 1. Création des dossiers de destination
mkdir -p "${INSTALL_LIB_DIR}"
mkdir -p "${APP_DESKTOP_DIR}"
mkdir -p "${MIME_DIR}"
mkdir -p "${ICON_APPS_DIR}"
mkdir -p "${ICON_MIMETYPES_DIR}"

# 2. Copie des scripts de la bibliothèque (lib/)
if [[ -d "lib" ]]; then
  cp -r lib/* "${INSTALL_LIB_DIR}/"
  chmod +x "${INSTALL_LIB_DIR}"/*.sh
  chmod +x "${INSTALL_LIB_DIR}"/*.py 2>/dev/null || true
  echo "[OK] Bibliothèques copiées dans ${INSTALL_LIB_DIR}"
else
  echo "Erreur : Le dossier 'lib' est introuvable."
  exit 1
fi

# 2bis. Copie des fichiers de langue (lang/)
if [[ -d "lang" ]]; then
  mkdir -p "${INSTALL_LIB_DIR}/lang"
  cp -r lang/* "${INSTALL_LIB_DIR}/lang/"
  echo "[OK] Fichiers de langue copiés dans ${INSTALL_LIB_DIR}/lang"
else
  echo "Erreur : Le dossier 'lang' est introuvable."
  exit 1
fi

# 3. Copie et liaison du binaire principal (bin/lpm)
if [[ -f "bin/lpm" ]]; then
  cp bin/lpm "${INSTALL_BIN_DIR}/lpm"
  chmod +x "${INSTALL_BIN_DIR}/lpm"
  echo "[OK] Binaire du manager installé dans ${INSTALL_BIN_DIR}/lpm"
else
  echo "Erreur : Le fichier 'bin/lpm' est introuvable."
  exit 1
fi

# 3bis. Copie de l'interface graphique GTK4/Libadwaita (gui/) + son lanceur (bin/lpm-gui)
# -- facultative : l'absence de PyGObject/GTK4/Libadwaita sur la machine ne doit jamais
# faire échouer l'installation du reste de lpm (CLI toujours pleinement fonctionnelle
# sans elle, voir bin/lpm-gui qui vérifie lui-même ces dépendances à l'exécution).
if [[ -d "gui" ]] && [[ -f "bin/lpm-gui" ]]; then
  mkdir -p "${INSTALL_LIB_DIR}/gui"
  cp -r gui/* "${INSTALL_LIB_DIR}/gui/"
  chmod +x "${INSTALL_LIB_DIR}/gui"/*.py 2>/dev/null || true
  cp bin/lpm-gui "${INSTALL_BIN_DIR}/lpm-gui"
  chmod +x "${INSTALL_BIN_DIR}/lpm-gui"
  echo "[OK] Interface graphique installée dans ${INSTALL_LIB_DIR}/gui (lancer avec : lpm-gui)"
else
  echo "[INFO] Interface graphique absente de ce paquet source, ignorée."
fi

# 3bis. Copie des icônes SVG propres à lpm (thème hicolor -- icône de l'appli, icône de
# secours des raccourcis de jeux, et icônes des types MIME .zgp/.zgr). Les gabarits de fond
# assets/icons/lutris-bg-template.svg (carré, style "appli") et assets/icons/box-bg-template.svg
# (carton, style "fichier") ne sont volontairement pas copiés ici : ce sont des réserves pour
# de futures icônes de la famille lpm (un pour chaque style, appli et fichier), pas des
# assets utilisés au runtime.
if [[ -f "assets/icons/lpm.svg" ]] && [[ -f "assets/icons/lpm-game-generic.svg" ]] && [[ -f "assets/icons/application-x-zgp-game.svg" ]] && [[ -f "assets/icons/application-x-zgr-runner.svg" ]]; then
  cp assets/icons/lpm.svg "${ICON_APPS_DIR}/lpm.svg"
  cp assets/icons/lpm-game-generic.svg "${ICON_APPS_DIR}/lpm-game-generic.svg"
  cp assets/icons/application-x-zgp-game.svg "${ICON_MIMETYPES_DIR}/application-x-zgp-game.svg"
  cp assets/icons/application-x-zgr-runner.svg "${ICON_MIMETYPES_DIR}/application-x-zgr-runner.svg"
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "${ICON_THEME_DIR}" 2>/dev/null || true
  elif [[ -f "${ICON_THEME_DIR}/icon-theme.cache" ]]; then
    # gtk-update-icon-cache est absent : un cache binaire existant deviendrait obsolète
    # (il ne connaîtrait pas nos nouvelles icônes) et empêcherait leur affichage tant qu'il
    # n'est pas régénéré -- on le supprime pour forcer un scan direct du dossier à la place.
    rm -f "${ICON_THEME_DIR}/icon-theme.cache"
  fi
  echo "[OK] Icônes lpm installées dans ${ICON_THEME_DIR}"
else
  echo "Erreur : Le dossier 'assets/icons' est incomplet ou introuvable."
  exit 1
fi

# 4. Enregistrement des types MIME (.zgp et .zgr). Pas de balise <icon> ici : elle n'existe
# pas dans la spec shared-mime-info. On déclare en revanche <generic-icon> vers notre propre
# icône -- indispensable avec Nemo/Cinnamon : sans ça, le nom de repli calculé par défaut
# ("application-x-generic") reste dans la liste de noms candidats, et un bug connu de Nemo
# (cf. github.com/linuxmint/nemo issue #3062) fait qu'il matche ce nom générique dans un
# thème parent (ex. Adwaita, en tête de la chaîne d'héritage du thème actif) AVANT même
# d'atteindre hicolor où vit notre icône spécifique -- Nemo teste chaque thème en entier
# avec tous les noms candidats plutôt que de tester le nom spécifique dans tous les thèmes
# d'abord. En pointant <generic-icon> vers notre propre icône, "application-x-generic"
# disparaît de la liste de candidats et ce court-circuit ne peut plus se produire.
MIME_FILE="${MIME_DIR}/lpm.xml"

cat << EOF > "${MIME_FILE}"
<?xml-stylesheet type="text/xsl" href="libxslt:shared-mime-info"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-zgp-game">
    <comment>lpm game</comment>
    <comment xml:lang="fr">Jeu lpm</comment>
    <glob pattern="*.zgp"/>
    <generic-icon name="application-x-zgp-game"/>
  </mime-type>
  <mime-type type="application/x-zgr-runner">
    <comment>lpm runner</comment>
    <comment xml:lang="fr">Runner lpm</comment>
    <glob pattern="*.zgr"/>
    <generic-icon name="application-x-zgr-runner"/>
  </mime-type>
</mime-info>
EOF

update-mime-database /usr/share/mime 2>/dev/null || true
echo "[OK] Types MIME enregistrés avec les icônes lpm."

# 5. Génération du lanceur dans le Menu des applications
DESKTOP_FILE="${APP_DESKTOP_DIR}/lpm.desktop"

cat << EOF > "${DESKTOP_FILE}"
[Desktop Entry]
Type=Application
Name=lpm
Comment=Package manager for games and runners
Comment[fr]=Gestionnaire de paquets et runners pour jeux
Exec=lpm %f
Icon=lpm
Categories=Game;Utility;
Terminal=false
StartupNotify=true
MimeType=application/x-zgp-game;application/x-zgr-runner;
EOF

chmod +x "${DESKTOP_FILE}"
update-desktop-database "${APP_DESKTOP_DIR}" 2>/dev/null || true
echo "[OK] Lanceur et association de fichiers créés."

# 6. Complétion zsh (optionnelle : absence de zsh ou du dossier de complétion n'interrompt
# pas l'installation, lpm reste utilisable sans)
if [[ -f "completions/_lpm" ]]; then
  mkdir -p "${ZSH_COMPLETION_DIR}"
  cp completions/_lpm "${ZSH_COMPLETION_DIR}/_lpm"
  echo "[OK] Complétion zsh installée dans ${ZSH_COMPLETION_DIR}"
  echo "     (si elle n'apparaît pas : vérifier que ce dossier est dans votre \$fpath,"
  echo "     puis 'rm -f ~/.zcompdump && compinit' dans un nouveau terminal)"
fi

# 7. Complétion bash (optionnelle : absence du dossier n'interrompt pas l'installation,
# lpm reste utilisable sans -- même logique que la complétion zsh ci-dessus)
if [[ -f "completions/lpm.bash" ]]; then
  mkdir -p "${BASH_COMPLETION_DIR}"
  cp completions/lpm.bash "${BASH_COMPLETION_DIR}/lpm"
  echo "[OK] Complétion bash installée dans ${BASH_COMPLETION_DIR}"
  echo "     (si elle n'apparaît pas : ouvrir un nouveau terminal, ou vérifier que le"
  echo "     paquet 'bash-completion' est installé sur ce système)"
fi

# 8. Page man, multi-langue (anglais par défaut + variante française dans le sous-dossier
# de locale standard "fr/man1/", sélectionnée automatiquement par "man" selon $LANG/
# $LC_MESSAGES). Optionnelle : absence de "mandb" n'interrompt pas l'installation -- même
# logique best-effort que update-desktop-database/update-mime-database ci-dessus ; "lpm
# --help" reste fonctionnel dans tous les cas via son repli intégré, voir bin/lpm)
if [[ -f "man/man1/lpm.1" ]]; then
  mkdir -p "${MAN_DIR}/man1"
  cp man/man1/lpm.1 "${MAN_DIR}/man1/lpm.1"
  if [[ -f "man/fr/man1/lpm.1" ]]; then
    mkdir -p "${MAN_DIR}/fr/man1"
    cp man/fr/man1/lpm.1 "${MAN_DIR}/fr/man1/lpm.1"
  fi
  mandb 2>/dev/null || true
  echo "[OK] Page man (EN + FR) installée dans ${MAN_DIR} ('lpm --help' l'utilisera désormais)"
fi

echo "========================================"
echo " Installation terminée avec succès !"
echo " Tu peux maintenant lancer 'lpm' ou ouvrir directement tes fichiers .zgp / .zgr !"
echo "========================================"
