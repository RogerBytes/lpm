#!/bin/bash

# S'assurer que le script est exécuté avec les privilèges root (sudo)
if [[ "${EUID}" -ne 0 ]]; then
  echo "Erreur : Veuillez exécuter ce script de désinstallation avec les privilèges administrateur (sudo ./uninstall.sh)."
  exit 1
fi

# Définition des chemins de destination utilisés lors de l'installation
INSTALL_BIN_DIR="/usr/local/bin"
INSTALL_LIB_DIR="/usr/local/lib/lpm"
APP_DESKTOP_DIR="/usr/share/applications"
DESKTOP_FILE="${APP_DESKTOP_DIR}/lpm.desktop"
MIME_FILE="/usr/share/mime/packages/lpm.xml"
ZSH_COMPLETION_FILE="/usr/local/share/zsh/site-functions/_lpm"
BASH_COMPLETION_FILE="/usr/local/share/bash-completion/completions/lpm"
MAN_FILE="/usr/local/share/man/man1/lpm.1"
ICON_THEME_DIR="/usr/share/icons/hicolor"
ICON_APP_FILE="${ICON_THEME_DIR}/scalable/apps/lpm.svg"
ICON_ZGP_FILE="${ICON_THEME_DIR}/scalable/mimetypes/application-x-zgp-game.svg"
ICON_ZGR_FILE="${ICON_THEME_DIR}/scalable/mimetypes/application-x-zgr-runner.svg"

echo "=== Désinstallation de lpm ==="

# 1. Suppression du binaire principal
if [[ -f "${INSTALL_BIN_DIR}/lpm" ]]; then
  rm -f "${INSTALL_BIN_DIR}/lpm"
  echo "[OK] Binaire lpm supprimé de ${INSTALL_BIN_DIR}"
else
  echo "[Info] Le binaire lpm n'était pas présent dans ${INSTALL_BIN_DIR}"
fi

# 2. Suppression du dossier des bibliothèques
if [[ -d "${INSTALL_LIB_DIR}" ]]; then
  rm -rf "${INSTALL_LIB_DIR}"
  echo "[OK] Dossier des bibliothèques supprimé de ${INSTALL_LIB_DIR}"
else
  echo "[Info] Le dossier des bibliothèques n'existait pas à ${INSTALL_LIB_DIR}"
fi

# 3. Suppression des types MIME (.zgp et .zgr) et mise à jour de la base
if [[ -f "${MIME_FILE}" ]]; then
  rm -f "${MIME_FILE}"
  update-mime-database /usr/share/mime 2>/dev/null || true
  echo "[OK] Types MIME (.zgp et .zgr) supprimés du système."
else
  echo "[Info] Aucun type MIME associé trouvé."
fi

# 4. Suppression du lanceur dans le Menu des applications
if [[ -f "${DESKTOP_FILE}" ]]; then
  rm -f "${DESKTOP_FILE}"
  update-desktop-database "${APP_DESKTOP_DIR}" 2>/dev/null || true
  echo "[OK] Lanceur du menu des applications supprimé."
else
  echo "[Info] Aucun lanceur trouvé dans ${APP_DESKTOP_DIR}"
fi

# 5. Suppression des icônes lpm (thème hicolor)
ICONS_REMOVED=false
for icon_file in "${ICON_APP_FILE}" "${ICON_ZGP_FILE}" "${ICON_ZGR_FILE}"; do
  if [[ -f "${icon_file}" ]]; then
    rm -f "${icon_file}"
    ICONS_REMOVED=true
  fi
done
if [[ "${ICONS_REMOVED}" = true ]]; then
  if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "${ICON_THEME_DIR}" 2>/dev/null || true
  elif [[ -f "${ICON_THEME_DIR}/icon-theme.cache" ]]; then
    # Même logique qu'à l'installation : sans l'outil pour le régénérer, un cache qui
    # référence encore nos icônes supprimées vaut moins qu'un scan direct du dossier.
    rm -f "${ICON_THEME_DIR}/icon-theme.cache"
  fi
  echo "[OK] Icônes lpm supprimées de ${ICON_THEME_DIR}"
else
  echo "[Info] Aucune icône lpm trouvée dans ${ICON_THEME_DIR}"
fi

# 6. Suppression de la complétion zsh
if [[ -f "${ZSH_COMPLETION_FILE}" ]]; then
  rm -f "${ZSH_COMPLETION_FILE}"
  echo "[OK] Complétion zsh supprimée de ${ZSH_COMPLETION_FILE}"
else
  echo "[Info] Aucune complétion zsh trouvée à ${ZSH_COMPLETION_FILE}"
fi

# 7. Suppression de la complétion bash
if [[ -f "${BASH_COMPLETION_FILE}" ]]; then
  rm -f "${BASH_COMPLETION_FILE}"
  echo "[OK] Complétion bash supprimée de ${BASH_COMPLETION_FILE}"
else
  echo "[Info] Aucune complétion bash trouvée à ${BASH_COMPLETION_FILE}"
fi

# 8. Suppression de la page man
if [[ -f "${MAN_FILE}" ]]; then
  rm -f "${MAN_FILE}"
  mandb 2>/dev/null || true
  echo "[OK] Page man supprimée de ${MAN_FILE}"
else
  echo "[Info] Aucune page man trouvée à ${MAN_FILE}"
fi

echo "========================================"
echo " Désinstallation terminée avec succès !"
echo " lpm a été complètement retiré de votre système."
echo "========================================"
