#!/bin/bash

# --- lpm lsfg [slug...] [on|off] ---
#
# Active/désactive lsfg-vk (génération de frames "Lossless Scaling") pour un ou plusieurs
# jeux Wine/Proton de Lutris. Conception validée en amont (voir échange) :
#
#   1. Détection lsfg-vk (Flatpak : extension VulkanLayer installée ; natif : manifeste
#      Vulkan implicit_layer.d présent). AUCUNE commande de vérification de version n'est
#      documentée par le projet lsfg-vk -- cette détection est donc une présence, pas une
#      confirmation du schéma 2.0+. Si un utilisateur a une très vieille install 1.0
#      qui traîne (schéma LSFG_LEGACY, disparu), l'activation semblera réussir côté lpm mais
#      n'aura aucun effet en jeu -- pas de moyen fiable de le détecter autrement, documenté ici
#      plutôt que deviné.
#   2. Install absente :
#        - Flatpak : lpm installe lui-même l'extension VulkanLayer.lsfgvk (avec accord),
#          sans sudo (--user), pour la MÊME version de runtime que le Lutris Flatpak détecté.
#          Contrairement à l'hypothèse de départ, AUCUN "flatpak override" n'est nécessaire :
#          une extension VulkanLayer freedesktop est exposée automatiquement à toute
#          application utilisant ce runtime (même mécanisme que l'extension MangoHud, très
#          répandue) -- l'exemple d'override de la doc officielle lsfg-vk (LSFGVK_CONFIG) ne
#          concerne qu'un chemin de config HORS du wineprefix, jamais utilisé ici (lpm passe
#          tout par les variables d'env system.env du YAML Lutris, déjà pleinement accessibles
#          au sandbox Lutris Flatpak puisqu'elles pointent dans le wineprefix du jeu lui-même).
#        - Natif : pas d'install auto (pas de paquet universel) -- lien AUR si Arch détecté
#          (pacman présent), sinon lien générique de la doc officielle (couvre déjà toutes les
#          distros non-Arch sur une seule page). Ouverture auto du lien (xdg-open), confirmation
#          Valider/Annuler, re-vérification après Valider.
#   3. DLL de référence : DOIT être le fichier "lsfg-vk.dll" tel quel (nom vérifié, pas
#      renommé par l'utilisateur), provenant de la branche bêta Steam "lsfg-vk" de Lossless
#      Scaling (Propriétés du jeu > Bêtas > lsfg-vk). Le "Lossless.dll" de la branche
#      publique normale N'EST PAS ACCEPTÉ : il manque le shader "mipmaps" nécessaire au
#      schéma lsfg-vk 2.0 (vérifié en conditions réelles -- erreur "Unable to find base
#      shader 'mipmaps' in DLL" au lancement, reproductible avec Lossless.dll ET avec une
#      copie renommée de ce même fichier, corrigée uniquement en repointant vers le vrai
#      lsfg-vk.dll de la branche bêta). Copiée telle quelle en
#      ~/.config/lpm/lsfg-vk/lsfg-vk.dll.
#   4. Écran Activer/Désactiver, qui ne liste QUE les jeux concernés (activer -> jeux sans
#      LSFGVK_ENV=1 dans leur YAML, désactiver -> jeux qui l'ont) -- détection en relisant
#      directement le YAML de chaque jeu à chaque lancement, jamais de fichier de suivi séparé
#      (source de vérité unique, jamais de désynchronisation possible si l'utilisateur édite le
#      YAML à la main depuis Lutris).
#   5. Jeux Wine/Proton uniquement (runner='wine' dans pga.db -- Lutris ne distingue pas
#      Wine/Proton autrement, un jeu natif Linux a un autre runner et n'apparaît jamais ici).
#      Préfixes partagés (Epic/EA/Ubisoft/Battle.net) INCLUS : opération non destructive,
#      même principe que "lpm tools".
#   6. Activation : copie (écrase sans confirmation, c'est la copie de référence qui fait foi)
#      lsfg-vk.dll à la racine du préfixe, puis fusionne dans system.env du YAML :
#      LSFGVK_ENV=1, LSFGVK_DLL_PATH=<chemin>, et LSFGVK_MULTIPLIER=2 UNIQUEMENT si cette clé
#      n'existe pas déjà (ne jamais écraser un réglage déjà personnalisé par l'utilisateur
#      depuis les réglages Lutris). Aucune autre clé de system.env n'est touchée.
#      Désactivation : retire uniquement ces 3 clés (jamais DISABLE_LSFGVK, séparé et inutile
#      ici), ne supprime jamais le fichier lsfg-vk.dll déjà copié dans le préfixe.

cli_args=("$@")

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-checklist-utils.sh
source "${script_dir}/zgu-checklist-utils.sh"
# shellcheck source=./zgu-log-utils.sh
source "${script_dir}/zgu-log-utils.sh"
# shellcheck source=./zgu-lsfg-utils.sh
source "${script_dir}/zgu-lsfg-utils.sh"

# --- 0. Mode CLI vs GUI, et validation de la syntaxe CLI ---
will_use_zenity=true
cli_action=""
cli_slugs=()

if [[ ${#cli_args[@]} -gt 0 ]]; then
  will_use_zenity=false
  last_arg="${cli_args[-1]}"
  if [[ "${last_arg}" = "on" ]] || [[ "${last_arg}" = "off" ]]; then
    cli_action="${last_arg}"
    cli_slugs=("${cli_args[@]:0:$(( ${#cli_args[@]} - 1 ))}")
  fi
  if [[ -z "${cli_action}" ]] || [[ ${#cli_slugs[@]} -eq 0 ]]; then
    zgu_cli_error "$(t lsfg.cli_usage)"
    exit 1
  fi
fi

display_mode="gui"
[[ "${will_use_zenity}" = false ]] && display_mode="cli"

zgp_lsfg_report_error_early() {
  local msg="$1"
  if [[ "${will_use_zenity}" = true ]] && command -v zenity >/dev/null 2>&1; then
    zenity --error --text="${msg}" 2>/dev/null
  fi
  echo "${msg}" >&2
}

if [[ "${will_use_zenity}" = true ]] && ! command -v zenity >/dev/null 2>&1; then
  zgu_cli_error "$(t lsfg.zenity_missing)"
  exit 1
fi

for cmd in python3 sqlite3; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    zgp_lsfg_report_error_early "$(t lsfg.cmd_missing "${cmd}")"
    exit 1
  fi
done
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  if [[ "${will_use_zenity}" = true ]]; then
    zenity --error --text="$(t lsfg.pyyaml_missing_gui)" 2>/dev/null
  fi
  zgu_cli_error "$(t lsfg.pyyaml_missing_cli)"
  exit 1
fi

# --- 1. Détection Flatpak vs Paquet natif + résolution des chemins Lutris ---
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"
lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"
lutris_flatpak_system_file="${HOME}/.var/app/net.lutris.Lutris/data/lutris/system.yml"
lutris_package_system_file="${HOME}/.config/lutris/system.yml"
games_dir="${HOME}/Games"

version=$(zgu_resolve_lutris_version "${display_mode}" "${lutris_package_db}" "")
if [[ -z "${version}" ]]; then
  zgp_lsfg_report_error_early "$(t lsfg.lutris_missing)"
  exit 1
fi

lutris_is_flatpak=false
if [[ "${version}" = "flatpak" ]]; then
  lutris_is_flatpak=true
  lutris_db="${lutris_flatpak_db}"
  lutris_config_dir="${lutris_flatpak_config_dir}"
  lutris_system_file="${lutris_flatpak_system_file}"
else
  lutris_db="${lutris_package_db}"
  lutris_config_dir="${lutris_package_config_dir}"
  lutris_system_file="${lutris_package_system_file}"
fi

if [[ -f "${lutris_system_file}" ]]; then
  extracted_path=$(awk -F': ' '/^[[:space:]]*game_path:/ {print $2}' "${lutris_system_file}")
  [[ -n "${extracted_path}" ]] && games_dir="${extracted_path}"
fi

if [[ ! -f "${lutris_db}" ]]; then
  zgp_lsfg_report_error_early "$(t lsfg.db_missing "${lutris_db}")"
  exit 1
fi

# --- 2. Détection de lsfg-vk installé (présence uniquement, voir avertissement en tête
# de fichier sur la limite de cette vérification). Fonctions partagées avec "lpm check",
# voir zgu-lsfg-utils.sh (sourcé plus haut). ---
zgp_lsfg_vk_present() {
  zgu_lsfg_vk_present "${lutris_is_flatpak}"
}

# --- 3. Installation de lsfg-vk si absente ---
zgp_lsfg_install_flatpak() {
  local runtime_version
  runtime_version=$(zgu_lsfg_resolve_freedesktop_runtime_version)

  if [[ -z "${runtime_version}" ]]; then
    zgp_lsfg_report_error_early "$(t lsfg.flatpak_runtime_unknown)"
    return 1
  fi

  if [[ "${will_use_zenity}" = true ]]; then
    if ! zenity --question --title="$(t lsfg.install_title)" \
      --text="$(t lsfg.install_flatpak_confirm "${runtime_version}")" \
      --ok-label="$(t lsfg.btn_validate)" --cancel-label="$(t lsfg.btn_cancel)" \
      --width=480 2>/dev/null; then
      return 1
    fi
  else
    t lsfg.install_flatpak_confirm_cli "${runtime_version}"
    local response
    read -r -p "$(t lsfg.confirm_prompt_cli)" response
    [[ "${response}" =~ ^[oOyY] ]] || return 1
  fi

  local install_err
  install_err=$(zgu_lsfg_install_flatpak_do "${runtime_version}")
  if [[ $? -ne 0 ]]; then
    zgp_lsfg_report_error_early "$(t lsfg.flatpak_install_failed "${install_err}")"
    return 1
  fi
  return 0
}

zgp_lsfg_install_native() {
  local link label
  if command -v pacman >/dev/null 2>&1; then
    link="https://aur.archlinux.org/packages/lsfg-vk"
    label="$(t lsfg.install_native_arch_label)"
  else
    link="https://lsfg-vk.dev/docs/installation/"
    label="$(t lsfg.install_native_generic_label)"
  fi

  command -v xdg-open >/dev/null 2>&1 && xdg-open "${link}" >/dev/null 2>&1 &

  if [[ "${will_use_zenity}" = true ]]; then
    if ! zenity --question --title="$(t lsfg.install_title)" \
      --text="$(t lsfg.install_native_confirm_gui "${label}" "${link}")" \
      --ok-label="$(t lsfg.btn_validate)" --cancel-label="$(t lsfg.btn_cancel)" \
      --width=520 2>/dev/null; then
      return 1
    fi
  else
    t lsfg.install_native_confirm_cli "${label}" "${link}"
    local response
    read -r -p "$(t lsfg.confirm_prompt_cli)" response
    [[ "${response}" =~ ^[oOyY] ]] || return 1
  fi

  if ! zgp_lsfg_vk_present; then
    zgp_lsfg_report_error_early "$(t lsfg.native_still_missing)"
    return 1
  fi
  return 0
}

lsfg_dll_master="${XDG_CONFIG_HOME:-${HOME}/.config}/lpm/lsfg-vk/lsfg-vk.dll"

zgp_lsfg_ensure_dll() {
  [[ -f "${lsfg_dll_master}" ]] && return 0

  local candidate candidate_basename
  if [[ "${will_use_zenity}" = true ]]; then
    candidate=$(zenity --file-selection --title="$(t lsfg.dll_select_title)" 2>/dev/null)
  else
    t lsfg.dll_select_text_cli
    read -r -p "$(t lsfg.dll_select_prompt_cli)" candidate
  fi

  [[ -z "${candidate}" ]] && return 1
  [[ -f "${candidate}" ]] || { zgp_lsfg_report_error_early "$(t lsfg.dll_not_found "${candidate}")"; return 1; }

  # Le nom du fichier fait foi (pas de choix laissé à l'utilisateur, voir en-tête de
  # fichier) : seul un vrai "lsfg-vk.dll" de la branche bêta Steam "lsfg-vk" est accepté --
  # un "Lossless.dll" (branche publique) n'a pas le shader "mipmaps" requis par lsfg-vk 2.0
  # et provoque une erreur au lancement du jeu, vérifiée en conditions réelles.
  candidate_basename="$(basename -- "${candidate}")"
  if [[ "${candidate_basename,,}" != "lsfg-vk.dll" ]]; then
    zgp_lsfg_report_error_early "$(t lsfg.dll_wrong_name "${candidate_basename}")"
    return 1
  fi

  mkdir -p "$(dirname "${lsfg_dll_master}")"
  if ! cp -f -- "${candidate}" "${lsfg_dll_master}"; then
    zgp_lsfg_report_error_early "$(t lsfg.dll_copy_failed)"
    return 1
  fi
  return 0
}

if ! zgp_lsfg_vk_present; then
  if [[ "${lutris_is_flatpak}" = true ]]; then
    zgp_lsfg_install_flatpak || exit 0
  else
    zgp_lsfg_install_native || exit 0
  fi
fi

# --- 4. Choix activer/désactiver ---
if [[ -n "${cli_action}" ]]; then
  action="${cli_action}"
else
  choice=$(zenity --list --radiolist \
    --title="$(t lsfg.action_title)" \
    --text="$(t lsfg.action_text)" \
    --column="" --column="$(t lsfg.action_col)" \
    TRUE "$(t lsfg.action_activate)" \
    FALSE "$(t lsfg.action_deactivate)" \
    --width=420 --height=250 2>/dev/null)
  if [[ "${choice}" = "$(t lsfg.action_activate)" ]]; then
    action="on"
  elif [[ "${choice}" = "$(t lsfg.action_deactivate)" ]]; then
    action="off"
  else
    exit 0
  fi
fi

if [[ "${action}" = "on" ]]; then
  zgp_lsfg_ensure_dll || exit 0
fi

# --- 5. Liste des jeux Wine/Proton, filtrée par état actuel dans le YAML ---
games_list=$(sqlite3 "${lutris_db}" "SELECT COALESCE(id,'') || char(31) || COALESCE(name,'') || char(31) || COALESCE(slug,'') || char(31) || COALESCE(directory,'') || char(31) || COALESCE(configpath,'') FROM games WHERE runner='wine' ORDER BY name COLLATE NOCASE ASC;" 2>/dev/null)

if [[ -z "${games_list}" ]]; then
  zgp_lsfg_report_error_early "$(t lsfg.none_found)"
  exit 0
fi

declare -A name_by_slug dir_by_slug configpath_by_slug
sorted_slugs=()

while IFS=$'\x1f' read -r _g_id g_name g_slug g_dir g_configpath; do
  [[ -z "${g_slug}" ]] && continue
  [[ -z "${g_dir}" ]] && g_dir="${games_dir}/${g_slug}"
  name_by_slug["${g_slug}"]="${g_name}"
  dir_by_slug["${g_slug}"]="${g_dir}"
  configpath_by_slug["${g_slug}"]="${g_configpath}"
  sorted_slugs+=("${g_slug}")
done <<< "${games_list}"

# Retourne 0 (vrai) si LSFGVK_ENV=1 est déjà présent dans system.env du YAML de ce jeu.
zgp_lsfg_is_active() {
  local configpath="$1" yml_file
  [[ -z "${configpath}" ]] && return 1
  yml_file="${lutris_config_dir}/${configpath}.yml"
  [[ -f "${yml_file}" ]] || return 1
  YML_PATH="${yml_file}" python3 -c '
import os, sys, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f) or {}
    env = (data.get("system") or {}).get("env") or {}
    sys.exit(0 if str(env.get("LSFGVK_ENV", "")) == "1" else 1)
except Exception:
    sys.exit(1)
' 2>/dev/null
}

declare -A active_by_slug
for g_slug in "${sorted_slugs[@]}"; do
  if zgp_lsfg_is_active "${configpath_by_slug[${g_slug}]}"; then
    active_by_slug["${g_slug}"]=1
  fi
done

eligible_slugs=()
for g_slug in "${sorted_slugs[@]}"; do
  if [[ "${action}" = "on" ]]; then
    [[ -z "${active_by_slug[${g_slug}]:-}" ]] && eligible_slugs+=("${g_slug}")
  else
    [[ -n "${active_by_slug[${g_slug}]:-}" ]] && eligible_slugs+=("${g_slug}")
  fi
done

targets=()

if [[ "${will_use_zenity}" = false ]]; then
  # --- MODE CLI ---
  declare -A eligible_lookup
  for g_slug in "${eligible_slugs[@]}"; do
    eligible_lookup["${g_slug}"]=1
  done

  for target_slug in "${cli_slugs[@]}"; do
    if [[ -z "${name_by_slug[${target_slug}]:-}" ]]; then
      zgu_cli_error "$(t lsfg.slug_not_found "${target_slug}")"
      exit 1
    fi
    if [[ -z "${eligible_lookup[${target_slug}]:-}" ]]; then
      if [[ "${action}" = "on" ]]; then
        zgu_cli_error "$(t lsfg.already_active "${target_slug}")"
      else
        zgu_cli_error "$(t lsfg.already_inactive "${target_slug}")"
      fi
      exit 1
    fi
    targets+=("${target_slug}")
  done
else
  # --- MODE GUI ---
  if [[ ${#eligible_slugs[@]} -eq 0 ]]; then
    if [[ "${action}" = "on" ]]; then
      zenity --info --text="$(t lsfg.nothing_to_activate)" 2>/dev/null
    else
      zenity --info --text="$(t lsfg.nothing_to_deactivate)" 2>/dev/null
    fi
    exit 0
  fi

  # "zenity --list --checklist" sans "--print-column=ALL" n'imprime QUE la première colonne
  # de valeur (le nom), jamais les colonnes suivantes (le slug) -- vérifié en conditions
  # réelles (voir le bug rapporté : la sélection GUI ne faisait rien du tout, silencieusement,
  # "targets" restant vide car le code lisait à tort une paire nom+slug entrelacée qui n'était
  # jamais renvoyée). Même convention que zgp-game-uninstaller.sh/zgp-game-shortcutter.sh :
  # on ne récupère QUE le nom depuis Zenity, puis on retrouve le slug via une table dédiée.
  declare -A slug_by_name_eligible=()
  checklist_values=()
  for g_slug in "${eligible_slugs[@]}"; do
    checklist_values+=("${name_by_slug[${g_slug}]}" "${g_slug}")
    slug_by_name_eligible["${name_by_slug[${g_slug}]}"]="${g_slug}"
  done

  select_title="$(t lsfg.select_title_activate)"
  [[ "${action}" = "off" ]] && select_title="$(t lsfg.select_title_deactivate)"

  selected=$(zgu_gui_checklist_toggle_all "FALSE" 2 \
    "${select_title}" \
    "$(t lsfg.select_text)" \
    650 450 \
    "$(t lsfg.select_col_check)" "$(t lsfg.select_col_game)" "$(t lsfg.select_col_slug)" \
    -- \
    "${checklist_values[@]}")

  [[ -z "${selected}" ]] && exit 0

  IFS=$'\x1f' read -r -a selected_names <<< "${selected}"
  for g_name in "${selected_names[@]}"; do
    [[ -n "${slug_by_name_eligible[${g_name}]:-}" ]] && targets+=("${slug_by_name_eligible[${g_name}]}")
  done

  [[ ${#targets[@]} -eq 0 ]] && exit 0
fi

# --- 6. Application : copie du DLL + fusion/retrait des variables d'env ---
#
# MESA_VK_DEVICE_SELECT (détection multi-GPU) a été retiré : confirmé inutile en conditions
# réelles une fois le vrai lsfg-vk.dll (branche bêta) utilisé -- l'écran noir initialement
# attribué à une mauvaise sélection de GPU était en fait dû au mauvais fichier DLL (voir
# point 3 en en-tête de fichier), pas à une ambiguïté multi-devices Vulkan.
zgp_lsfg_apply_one() {
  local slug="$1" prefix_dir="$2" configpath="$3" mode="$4"
  local yml_file="${lutris_config_dir}/${configpath}.yml"

  if [[ ! -f "${yml_file}" ]]; then
    zgp_lsfg_report_error_early "$(t lsfg.yml_missing "${slug}")"
    zgu_log "lsfg" "ERREUR" "slug=${slug} raison=yaml_introuvable"
    return 1
  fi

  if [[ "${mode}" = "on" ]]; then
    mkdir -p "${prefix_dir}/lsfg-vk"
    if ! cp -f -- "${lsfg_dll_master}" "${prefix_dir}/lsfg-vk/lsfg-vk.dll"; then
      zgp_lsfg_report_error_early "$(t lsfg.dll_copy_failed_for "${slug}")"
      zgu_log "lsfg" "ERREUR" "slug=${slug} raison=copie_dll_echouee"
      return 1
    fi
  fi

  YML_PATH="${yml_file}" DLL_PATH="${prefix_dir}/lsfg-vk/lsfg-vk.dll" LSFG_MODE="${mode}" python3 -c '
import os, yaml

yml_path = os.environ["YML_PATH"]
dll_path = os.environ["DLL_PATH"]
mode = os.environ["LSFG_MODE"]

try:
    with open(yml_path, "r") as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict):
        raise ValueError("YAML racine invalide")

    if "system" not in data or not isinstance(data.get("system"), dict):
        data["system"] = {}
    if "env" not in data["system"] or not isinstance(data["system"].get("env"), dict):
        data["system"]["env"] = {}

    env = data["system"]["env"]

    if mode == "on":
        env["LSFGVK_ENV"] = "1"
        env["LSFGVK_DLL_PATH"] = dll_path
        if "LSFGVK_MULTIPLIER" not in env:
            env["LSFGVK_MULTIPLIER"] = "2"
    else:
        env.pop("LSFGVK_ENV", None)
        env.pop("LSFGVK_DLL_PATH", None)
        env.pop("LSFGVK_MULTIPLIER", None)

    with open(yml_path, "w") as f:
        yaml.dump(data, f, sort_keys=False)
except Exception as e:
    print(str(e))
    raise SystemExit(1)
' 2>/dev/null
  local py_status=$?
  if [[ "${py_status}" -ne 0 ]]; then
    zgp_lsfg_report_error_early "$(t lsfg.yaml_patch_failed "${slug}")"
    zgu_log "lsfg" "ERREUR" "slug=${slug} raison=patch_yaml_echoue"
    return 1
  fi

  zgu_log "lsfg" "OK" "slug=${slug} action=${mode}"
  return 0
}

exit_code=0
n_ok=0
for target_slug in "${targets[@]}"; do
  if zgp_lsfg_apply_one "${target_slug}" "${dir_by_slug[${target_slug}]}" "${configpath_by_slug[${target_slug}]}" "${action}"; then
    n_ok=$(( n_ok + 1 ))
    [[ "${will_use_zenity}" = false ]] && zgu_cli_ok "$(t lsfg.done_one_cli "${name_by_slug[${target_slug}]}")"
  else
    exit_code=1
  fi
done

if [[ "${will_use_zenity}" = true ]]; then
  if [[ "${n_ok}" -gt 0 ]]; then
    zenity --info --text="$(t lsfg.done_gui "${n_ok}")" 2>/dev/null
  elif [[ "${exit_code}" -eq 0 ]]; then
    exit 0
  fi
fi

exit "${exit_code}"
