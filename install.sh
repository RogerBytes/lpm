#!/bin/bash

# Ensure the script runs with root privileges (sudo)
if [[ "${EUID}" -ne 0 ]]; then
  echo "Error: please run this install script with administrator privileges (sudo ./install.sh)."
  exit 1
fi

# Run from the script's own directory (not the caller's cwd) so that
# "sudo /path/to/install.sh" works from anywhere.
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# Destination paths on the system.
# Overridable via LPM_INSTALL_BIN_DIR (tests, packaging); defaults to /usr/local/bin.
INSTALL_BIN_DIR="${LPM_INSTALL_BIN_DIR:-/usr/local/bin}"
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

# 0. Another program may already be named "lpm" (e.g. Lite XL's plugin manager). Never
# overwrite it: if "lpm" exists there and is not our script (identified by its LPM_VERSION=
# line), abort before copying anything.
if [[ -e "${INSTALL_BIN_DIR}/lpm" ]] && ! grep -aq 'LPM_VERSION=' "${INSTALL_BIN_DIR}/lpm" 2>/dev/null; then
  echo "Error: ${INSTALL_BIN_DIR}/lpm already exists and is not Ludis Prefix Manager (another program named \"lpm\"?)."
  echo "Nothing was installed or modified. Move or delete that file if you want to install lpm, then run this script again."
  exit 1
fi

# 1. Create destination directories
mkdir -p "${INSTALL_LIB_DIR}"
mkdir -p "${APP_DESKTOP_DIR}"
mkdir -p "${MIME_DIR}"
mkdir -p "${ICON_APPS_DIR}"
mkdir -p "${ICON_MIMETYPES_DIR}"

# 2. Copy library scripts (lib/)
if [[ -d "lib" ]]; then
  cp -r lib/* "${INSTALL_LIB_DIR}/"
  chmod +x "${INSTALL_LIB_DIR}"/*.sh
  chmod +x "${INSTALL_LIB_DIR}"/*.py 2>/dev/null || true
  echo "[OK] Libraries copied to ${INSTALL_LIB_DIR}"
else
  echo "Error: the 'lib' folder was not found."
  exit 1
fi

# 2bis. Copy language files (lang/)
if [[ -d "lang" ]]; then
  mkdir -p "${INSTALL_LIB_DIR}/lang"
  cp -r lang/* "${INSTALL_LIB_DIR}/lang/"
  echo "[OK] Language files copied to ${INSTALL_LIB_DIR}/lang"
else
  echo "Error: the 'lang' folder was not found."
  exit 1
fi

# 3. Copy and link the main binary (bin/lpm)
if [[ -f "bin/lpm" ]]; then
  cp bin/lpm "${INSTALL_BIN_DIR}/lpm"
  chmod +x "${INSTALL_BIN_DIR}/lpm"
  echo "[OK] lpm binary installed in ${INSTALL_BIN_DIR}/lpm"
else
  echo "Error: the 'bin/lpm' file was not found."
  exit 1
fi

# 3bis. Copy the GTK4/Libadwaita GUI (gui/) and its launcher (bin/lpm-gui)
# -- optional: missing PyGObject/GTK4/Libadwaita must not fail the install; the CLI works
# without them (bin/lpm-gui checks these dependencies itself at runtime).
if [[ -d "gui" ]] && [[ -f "bin/lpm-gui" ]]; then
  mkdir -p "${INSTALL_LIB_DIR}/gui"
  cp -r gui/* "${INSTALL_LIB_DIR}/gui/"
  chmod +x "${INSTALL_LIB_DIR}/gui"/*.py 2>/dev/null || true
  cp bin/lpm-gui "${INSTALL_BIN_DIR}/lpm-gui"
  chmod +x "${INSTALL_BIN_DIR}/lpm-gui"
  echo "[OK] GUI installed in ${INSTALL_LIB_DIR}/gui (run with: lpm-gui)"
else
  echo "[INFO] GUI not present in this source package, skipped."
fi

# 3bis. Copy lpm's own SVG icons (hicolor theme: app icon, fallback game-shortcut icon,
# .zgp/.zgr MIME type icons). assets/icons/lutris-bg-template.svg and
# assets/icons/box-bg-template.svg are intentionally not copied: they are reserves for
# future icons, not runtime assets.
if [[ -f "assets/icons/lpm.svg" ]] && [[ -f "assets/icons/lpm-game-generic.svg" ]] && [[ -f "assets/icons/application-x-zgp-game.svg" ]] && [[ -f "assets/icons/application-x-zgr-runner.svg" ]]; then
  cp assets/icons/lpm.svg "${ICON_APPS_DIR}/lpm.svg"
  cp assets/icons/lpm-game-generic.svg "${ICON_APPS_DIR}/lpm-game-generic.svg"
  cp assets/icons/application-x-zgp-game.svg "${ICON_MIMETYPES_DIR}/application-x-zgp-game.svg"
  cp assets/icons/application-x-zgr-runner.svg "${ICON_MIMETYPES_DIR}/application-x-zgr-runner.svg"
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "${ICON_THEME_DIR}" 2>/dev/null || true
  elif [[ -f "${ICON_THEME_DIR}/icon-theme.cache" ]]; then
    # Without gtk-update-icon-cache, an existing binary cache would be stale (unaware of our
    # new icons) and hide them; remove it to force a direct directory scan.
    rm -f "${ICON_THEME_DIR}/icon-theme.cache"
  fi
  echo "[OK] lpm icons installed in ${ICON_THEME_DIR}"
else
  echo "Error: the 'assets/icons' folder is incomplete or was not found."
  exit 1
fi

# 4. Register the MIME types (.zgp and .zgr). No <icon> tag: it does not exist in the
# shared-mime-info spec. Declare <generic-icon> pointing to our own icon instead; this is
# required for Nemo/Cinnamon: otherwise the default fallback name "application-x-generic"
# stays among the candidates, and a known Nemo bug (linuxmint/nemo issue #3062) makes it
# match that generic name in a parent theme (e.g. Adwaita) before reaching hicolor, where
# our specific icon lives. Pointing <generic-icon> at our icon removes that candidate.
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
echo "[OK] MIME types registered with the lpm icons."

# 5. Generate the launcher in the Applications menu
DESKTOP_FILE="${APP_DESKTOP_DIR}/lpm.desktop"

cat << EOF > "${DESKTOP_FILE}"
[Desktop Entry]
Type=Application
Name=lpm
Comment=Prefix manager for Lutris games and runners
Comment[fr]=Gestionnaire de préfixes et runners pour Lutris
Exec=lpm-gui %f
Icon=lpm
Categories=Game;Utility;
Terminal=false
StartupNotify=true
MimeType=application/x-zgp-game;application/x-zgr-runner;
EOF

chmod +x "${DESKTOP_FILE}"
update-desktop-database "${APP_DESKTOP_DIR}" 2>/dev/null || true
echo "[OK] Launcher and file associations created."

# 6. zsh completion (optional: a missing zsh or completion directory does not abort the
# install)
if [[ -f "completions/_lpm" ]]; then
  mkdir -p "${ZSH_COMPLETION_DIR}"
  cp completions/_lpm "${ZSH_COMPLETION_DIR}/_lpm"
  echo "[OK] zsh completion installed in ${ZSH_COMPLETION_DIR}"
  echo "     (if it does not show up: check that this folder is in your \$fpath,"
  echo "     then run 'rm -f ~/.zcompdump && compinit' in a new terminal)"
fi

# 7. bash completion (optional, same logic as zsh completion above)
if [[ -f "completions/lpm.bash" ]]; then
  mkdir -p "${BASH_COMPLETION_DIR}"
  cp completions/lpm.bash "${BASH_COMPLETION_DIR}/lpm"
  echo "[OK] bash completion installed in ${BASH_COMPLETION_DIR}"
  echo "     (if it does not show up: open a new terminal, or check that the"
  echo "     'bash-completion' package is installed on this system)"
fi

# 8. Man page, multi-language (English default + French variant in the standard "fr/man1/"
# locale directory, picked by "man" from $LANG/$LC_MESSAGES). Optional: a missing "mandb"
# does not abort the install (same best-effort logic as update-desktop-database/
# update-mime-database above); "lpm --help" works regardless via its built-in fallback,
# see bin/lpm)
if [[ -f "man/man1/lpm.1" ]]; then
  mkdir -p "${MAN_DIR}/man1"
  cp man/man1/lpm.1 "${MAN_DIR}/man1/lpm.1"
  if [[ -f "man/fr/man1/lpm.1" ]]; then
    mkdir -p "${MAN_DIR}/fr/man1"
    cp man/fr/man1/lpm.1 "${MAN_DIR}/fr/man1/lpm.1"
  fi
  mandb 2>/dev/null || true
  echo "[OK] Man page (EN + FR) installed in ${MAN_DIR} ('lpm --help' will use it from now on)"
fi

echo "========================================"
echo " Installation completed successfully!"
echo " You can now run 'lpm' or open your .zgp / .zgr files directly!"
echo "========================================"
