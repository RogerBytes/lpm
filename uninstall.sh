#!/bin/bash

# Ensure the script runs with root privileges (sudo)
if [[ "${EUID}" -ne 0 ]]; then
  echo "Error: please run this uninstall script with administrator privileges (sudo ./uninstall.sh)."
  exit 1
fi

# Destination paths used at install time
INSTALL_BIN_DIR="${LUDIS_INSTALL_BIN_DIR:-/usr/local/bin}"
INSTALL_LIB_DIR="/usr/local/lib/ludis"
APP_DESKTOP_DIR="/usr/share/applications"
DESKTOP_FILE="${APP_DESKTOP_DIR}/ludis.desktop"
MIME_FILE="/usr/share/mime/packages/ludis.xml"
ZSH_COMPLETION_FILE="/usr/local/share/zsh/site-functions/_ludis"
BASH_COMPLETION_FILE="/usr/local/share/bash-completion/completions/ludis"
MAN_FILE="/usr/local/share/man/man1/ludis.1"
ICON_THEME_DIR="/usr/share/icons/hicolor"
ICON_APP_FILE="${ICON_THEME_DIR}/scalable/apps/ludis.svg"
ICON_ZGP_FILE="${ICON_THEME_DIR}/scalable/mimetypes/application-x-zgp-game.svg"
ICON_ZGR_FILE="${ICON_THEME_DIR}/scalable/mimetypes/application-x-zgr-runner.svg"
ICON_ZGS_FILE="${ICON_THEME_DIR}/scalable/mimetypes/application-x-zgs-saves.svg"

echo "=== Uninstalling ludis ==="

# 1. Remove the main binary -- only if it is our script (LUDIS_VERSION= line); another
# program named "ludis" installed at the same place must never be removed.
if [[ -f "${INSTALL_BIN_DIR}/ludis" ]] && ! grep -aq 'LUDIS_VERSION=' "${INSTALL_BIN_DIR}/ludis" 2>/dev/null; then
  echo "[Info] ${INSTALL_BIN_DIR}/ludis is not Ludis (another program named \"ludis\"?): it is kept."
elif [[ -f "${INSTALL_BIN_DIR}/ludis" ]]; then
  rm -f "${INSTALL_BIN_DIR}/ludis"
  echo "[OK] ludis binary removed from ${INSTALL_BIN_DIR}"
else
  echo "[Info] The ludis binary was not present in ${INSTALL_BIN_DIR}"
fi

# 2. Remove the library directory
if [[ -d "${INSTALL_LIB_DIR}" ]]; then
  rm -rf "${INSTALL_LIB_DIR}"
  echo "[OK] Libraries folder removed from ${INSTALL_LIB_DIR}"
else
  echo "[Info] The libraries folder did not exist at ${INSTALL_LIB_DIR}"
fi

# 2bis. Remove the compatibility links of the former name "lpm" (only if they are links to ludis)
[[ -L "$(dirname "${INSTALL_LIB_DIR}")/lpm" ]] && rm -f "$(dirname "${INSTALL_LIB_DIR}")/lpm"
[[ -L "${INSTALL_BIN_DIR}/lpm" ]] && rm -f "${INSTALL_BIN_DIR}/lpm"

# 3. Remove the MIME types (.zgp, .zgr and .zgs) and update the database
if [[ -f "${MIME_FILE}" ]]; then
  rm -f "${MIME_FILE}"
  update-mime-database /usr/share/mime 2>/dev/null || true
  echo "[OK] MIME types (.zgp, .zgr and .zgs) removed from the system."
else
  echo "[Info] No associated MIME type found."
fi

# 4. Remove the launcher from the Applications menu
if [[ -f "${DESKTOP_FILE}" ]]; then
  rm -f "${DESKTOP_FILE}"
  update-desktop-database "${APP_DESKTOP_DIR}" 2>/dev/null || true
  echo "[OK] Application menu launcher removed."
else
  echo "[Info] No launcher found in ${APP_DESKTOP_DIR}"
fi

# 5. Remove ludis icons (hicolor theme)
ICONS_REMOVED=false
for icon_file in "${ICON_APP_FILE}" "${ICON_ZGP_FILE}" "${ICON_ZGR_FILE}" "${ICON_ZGS_FILE}"; do
  if [[ -f "${icon_file}" ]]; then
    rm -f "${icon_file}"
    ICONS_REMOVED=true
  fi
done
if [[ "${ICONS_REMOVED}" = true ]]; then
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "${ICON_THEME_DIR}" 2>/dev/null || true
  elif [[ -f "${ICON_THEME_DIR}/icon-theme.cache" ]]; then
    # Same logic as at install: without the tool to regenerate it, a cache still referencing
    # our removed icons is worse than a direct directory scan.
    rm -f "${ICON_THEME_DIR}/icon-theme.cache"
  fi
  echo "[OK] ludis icons removed from ${ICON_THEME_DIR}"
else
  echo "[Info] No ludis icon found in ${ICON_THEME_DIR}"
fi

# 6. Remove zsh completion
if [[ -f "${ZSH_COMPLETION_FILE}" ]]; then
  rm -f "${ZSH_COMPLETION_FILE}"
  echo "[OK] zsh completion removed from ${ZSH_COMPLETION_FILE}"
else
  echo "[Info] No zsh completion found at ${ZSH_COMPLETION_FILE}"
fi

# 7. Remove bash completion
if [[ -f "${BASH_COMPLETION_FILE}" ]]; then
  rm -f "${BASH_COMPLETION_FILE}"
  echo "[OK] bash completion removed from ${BASH_COMPLETION_FILE}"
else
  echo "[Info] No bash completion found at ${BASH_COMPLETION_FILE}"
fi

# 8. Remove the man page
if [[ -f "${MAN_FILE}" ]]; then
  rm -f "${MAN_FILE}"
  mandb 2>/dev/null || true
  echo "[OK] Man page removed from ${MAN_FILE}"
else
  echo "[Info] No man page found at ${MAN_FILE}"
fi

echo "========================================"
echo " Uninstall completed successfully!"
echo " ludis has been completely removed from your system."
echo "========================================"
