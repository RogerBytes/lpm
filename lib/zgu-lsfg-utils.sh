#!/bin/bash

# --- Détection/installation partagées de lsfg-vk ---
#
# Utilisé à la fois par "lpm lsfg" (zgl-lsfg-manager.sh) et "lpm check"
# (zgc-dependency-checker.sh). Centralisé ici pour qu'une seule version de cette logique
# existe : une divergence entre deux copies aurait pu rester invisible jusqu'à ce qu'un
# utilisateur tombe sur un cas où l'une dit "présent" et l'autre "absent".
#
# Ce fichier ne fait aucune hypothèse sur le mode d'affichage (CLI/GUI) ni sur les traductions
# (t()) : chaque appelant reste responsable de ses propres messages/confirmations. Ces
# fonctions ne font que détecter et exécuter l'installation elle-même.

# Présence du layer Vulkan lsfg-vk (présence uniquement, pas une confirmation du schéma
# 2.0+ -- voir l'avertissement en tête de zgl-lsfg-manager.sh pour le détail de cette limite).
# $1 = "true" si Lutris est en Flatpak, "false" sinon.
zgu_lsfg_vk_present() {
  local lutris_is_flatpak="$1"

  if [[ "${lutris_is_flatpak}" = true ]]; then
    flatpak list --runtime --columns=application 2>/dev/null | grep -qx "org.freedesktop.Platform.VulkanLayer.lsfgvk"
    return $?
  fi

  local dir f
  for dir in \
    "${HOME}/.local/share/vulkan/implicit_layer.d" \
    "/usr/share/vulkan/implicit_layer.d" \
    "/usr/local/share/vulkan/implicit_layer.d" \
    "/etc/vulkan/implicit_layer.d"; do
    [[ -d "${dir}" ]] || continue
    f=$(find "${dir}" -maxdepth 1 -type f -iname "*lsfg*" -print -quit 2>/dev/null)
    [[ -n "${f}" ]] && return 0
  done
  return 1
}

# Le layer VulkanLayer.lsfgvk n'est publié QUE pour des versions de "org.freedesktop.Platform"
# (23.08/24.08/25.08). Mais Lutris (comme beaucoup d'applis GNOME) tourne sur
# "org.gnome.Platform/x86_64/<version GNOME, ex: 49>", pas directement sur
# org.freedesktop.Platform -- et CE runtime GNOME n'expose, via "flatpak info", AUCUNE ligne
# "Runtime:" permettant de retrouver la version freedesktop sous-jacente (vérifié en
# conditions réelles : ce champ n'existe tout simplement pas pour un runtime, seulement pour
# une appli). Pas de mapping GNOME-vers-freedesktop fiable et documenté non plus (change à
# chaque cycle de sortie) -- deviner serait aussi fragile que le premier essai raté.
#
# Solution retenue, vérifiée en conditions réelles : réutiliser la version freedesktop d'une
# extension VulkanLayer DÉJÀ installée sur la machine (ex: org.freedesktop.Platform.
# VulkanLayer.MangoHud, très répandue) -- la preuve la plus fiable qui soit qu'un layer
# freedesktop de cette version fonctionne déjà avec ce runtime GNOME/KDE précis, sur cette
# machine précise, sans avoir à deviner de correspondance théorique. À défaut, repli sur la
# version la plus récente de org.freedesktop.Platform réellement installée (system ou user) :
# une base déjà présente sur la machine, jamais une version choisie au hasard.
zgu_lsfg_resolve_freedesktop_runtime_version() {
  local existing latest
  existing=$(flatpak list --runtime --columns=application,branch 2>/dev/null | awk -F'\t' '$1 ~ /^org\.freedesktop\.Platform\.VulkanLayer\./ {print $2; exit}')
  if [[ -n "${existing}" ]]; then
    echo "${existing}"
    return 0
  fi

  latest=$(flatpak list --runtime --columns=application,branch 2>/dev/null | awk -F'\t' '$1 == "org.freedesktop.Platform" {print $2}' | sort -V | tail -n1)
  if [[ -n "${latest}" ]]; then
    echo "${latest}"
    return 0
  fi

  return 1
}

# Installe réellement l'extension Flatpak lsfg-vk pour la version de runtime donnée. Aucune
# confirmation ici : à l'appelant de demander l'accord avant d'appeler cette fonction (chaque
# appelant a son propre texte de confirmation CLI/GUI). En cas d'échec, imprime le message
# d'erreur brut de "flatpak install" sur stdout (jamais stderr, pour rester capturable par
# l'appelant via "$(...)") et retourne un code non nul.
# $1 = version de runtime freedesktop (ex: "24.08").
zgu_lsfg_install_flatpak_do() {
  local runtime_version="$1"

  # "flatpak install --user" échoue silencieusement en "No remote refs found" si aucun
  # dépôt --user (Flathub) n'est configuré à ce niveau -- cas fréquent sur une machine où
  # Flathub n'a été ajouté qu'en système (--system) au moment de l'install de Lutris, pas
  # en --user : les deux dépôts sont indépendants dans Flatpak. On s'assure donc que le
  # dépôt Flathub --user existe (idempotent, "--if-not-exists" ne fait rien s'il est déjà
  # là) avant de tenter l'install, plutôt que de deviner et d'échouer sans piste.
  flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1

  local install_err
  install_err=$(flatpak install --user -y flathub "org.freedesktop.Platform.VulkanLayer.lsfgvk//${runtime_version}" 2>&1 >/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "${install_err}"
    return 1
  fi
  return 0
}
