#!/bin/bash

# --- Shared detection/installation of lsfg-vk ---
#
# Used by both "lpm lsfg" (zgl-lsfg-manager.sh) and "lpm check" (zgc-dependency-checker.sh).
# Centralized so only one version of this logic exists: two copies could disagree ("present" vs
# "absent") unnoticed.
#
# This file makes no assumption about the display mode (CLI/GUI) or translations (t()): each caller
# is responsible for its own messages/confirmations. These functions only detect and run the install.

# Presence of the lsfg-vk Vulkan layer (presence only, not a confirmation of the 2.0+ schema -- see
# the warning at the top of zgl-lsfg-manager.sh for this limit).
# $1 = "true" if Lutris is Flatpak, "false" otherwise.
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

# The VulkanLayer.lsfgvk layer is published ONLY for versions of "org.freedesktop.Platform"
# (23.08/24.08/25.08). But Lutris (like many GNOME apps) runs on
# "org.gnome.Platform/x86_64/<GNOME version, e.g. 49>", not directly on org.freedesktop.Platform --
# and that GNOME runtime exposes NO "Runtime:" line in "flatpak info" to recover the underlying
# freedesktop version (that field only exists for apps, not runtimes). There is no reliable,
# documented GNOME-to-freedesktop mapping either (it changes every release cycle).
#
# Chosen solution: reuse the freedesktop version of a VulkanLayer extension ALREADY installed on the
# machine (e.g. org.freedesktop.Platform.VulkanLayer.MangoHud, very common) -- the most reliable proof
# that a freedesktop layer of that version already works with this GNOME/KDE runtime. Otherwise fall
# back to the newest org.freedesktop.Platform actually installed (system or user): a base already
# present on the machine, never a random version.
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

# Resolves the native install link of lsfg-vk (AUR if Arch/pacman detected, otherwise the generic link
# from the official docs) -- shared by zgl-lsfg-manager.sh (CLI confirmation of "lpm lsfg <slug...> on"
# AND the non-interactive GUI command "lsfg install-info") so the detection exists in one place. Prints
# "<link>\t<label key>" on stdout -- the label KEY, not translated text: each caller does its own
# "t <key>" with its own zgl-lang-loader.sh (bash) or t() function (GUI Python).
zgu_lsfg_native_link_info() {
  if command -v pacman >/dev/null 2>&1; then
    printf '%s\t%s\n' "https://aur.archlinux.org/packages/lsfg-vk" "lsfg.install_native_arch_label"
  else
    printf '%s\t%s\n' "https://lsfg-vk.dev/docs/installation/" "lsfg.install_native_generic_label"
  fi
}

# Actually installs the lsfg-vk Flatpak extension for the given runtime version. No confirmation here:
# the caller must ask for consent before calling (each has its own CLI/GUI confirmation text). On
# failure, prints the raw "flatpak install" error message on stdout (never stderr, so the caller can
# capture it via "$(...)") and returns non-zero.
# $1 = freedesktop runtime version (e.g. "24.08").
zgu_lsfg_install_flatpak_do() {
  local runtime_version="$1"

  # "flatpak install --user" fails silently with "No remote refs found" if no --user remote (Flathub) is
  # configured -- common when Flathub was only added system-wide (--system) when Lutris was installed:
  # the two remotes are independent in Flatpak. So ensure the --user Flathub remote exists (idempotent,
  # "--if-not-exists" does nothing if already there) before installing.
  flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1

  local install_err
  install_err=$(flatpak install --user -y flathub "org.freedesktop.Platform.VulkanLayer.lsfgvk//${runtime_version}" 2>&1 >/dev/null)
  if [[ $? -ne 0 ]]; then
    echo "${install_err}"
    return 1
  fi
  return 0
}
