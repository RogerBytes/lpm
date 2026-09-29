#!/bin/bash

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"
# shellcheck source=./zgu-github-release-utils.sh
source "${script_dir}/zgu-github-release-utils.sh"
# shellcheck source=./zgu-lutris-utils.sh
source "${script_dir}/zgu-lutris-utils.sh"
# shellcheck source=./zgu-progress-utils.sh
source "${script_dir}/zgu-progress-utils.sh"
# shellcheck source=./zgu-focus-utils.sh
source "${script_dir}/zgu-focus-utils.sh"
# shellcheck source=./zgu-lsfg-utils.sh
source "${script_dir}/zgu-lsfg-utils.sh"

# --- Récupération des arguments du routeur lpm ---
# $1 = mode ("cli" depuis le terminal, "gui" ou vide depuis le menu Zenity)
mode="${1:-gui}"

# Configuration des chemins Lutris
lutris_flatpak_db="${HOME}/.var/app/net.lutris.Lutris/data/lutris/pga.db"
lutris_package_db="${HOME}/.local/share/lutris/pga.db"

lutris_flatpak_config_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/games"
lutris_package_config_dir="${HOME}/.config/lutris/games"

lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

# GITHUB_RELEASE_URL est définie dans zgu-github-release-utils.sh (sourcé plus haut),
# seul endroit à modifier pour changer le dépôt/la release des runners.

say() {
  if [[ "${mode}" = "cli" ]]; then
    echo "$1"
  else
    zenity --info --text="$1" --width=450 2>/dev/null
  fi
}

say_err() {
  if [[ "${mode}" = "cli" ]]; then
    echo "$1" >&2
  else
    zenity --error --text="$1" --width=450 2>/dev/null
  fi
}

# Présence d'AntimicroX (fork maintenu du projet "antimicro", voir
# https://github.com/AntiMicroX/antimicrox) : binaire natif sous l'un ou l'autre nom (l'ancien
# "antimicro" original n'est plus maintenu mais reste installable sur certaines distros), ou
# application Flatpak "io.github.antimicrox.antimicrox" (id vérifié sur Flathub). Présence
# uniquement, comme zgu_lsfg_vk_present : aucune vérification de version.
zgu_antimicro_present() {
  command -v antimicrox >/dev/null 2>&1 && return 0
  command -v antimicro >/dev/null 2>&1 && return 0
  flatpak list --app --columns=application 2>/dev/null | grep -qx "io.github.antimicrox.antimicrox" && return 0
  return 1
}

# 1. Vérification des dépendances nécessaires
# bsdtar (paquet "libarchive-tools" sur Debian/Ubuntu) remplace tar -I zstd pour l'extraction
# des runners téléchargés : ses protections par défaut ARCHIVE_EXTRACT_SECURE_NODOTDOT /
# ARCHIVE_EXTRACT_SECURE_SYMLINKS refusent tout membre d'archive tentant de sortir de son
# dossier de destination via "../" ou un lien symbolique piégé. bsdtar lit le zstd nativement
# (libzstd liée en dur), donc zstd externe n'est plus nécessaire pour ce script.
for cmd in sqlite3 python3 bsdtar sha256sum; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    say_err "$(t check.cmd_missing "${cmd}")"
    exit 1
  fi
done

if [[ "${mode}" != "cli" ]] && ! command -v zenity >/dev/null 2>&1; then
  zgu_cli_error "$(t check.zenity_missing_gui)"
  exit 1
fi

if [[ "${mode}" != "cli" ]]; then
  zgu_start_focus_watcher
fi

# curl OU wget est requis pour interroger la release GitHub des runners (section 5 plus bas).
# Sans cette vérification explicite (alignée sur zgr-runner-remote-lister.sh et
# zgr-runner-installer.sh), l'absence des deux outils faisait échouer zgu_fetch_url en
# silence : release_json restait vide, et TOUS les runners manquants étaient alors listés
# comme "non résolus" en fin d'exécution, sans jamais indiquer que la vraie cause était
# l'absence d'outil réseau plutôt qu'une release GitHub introuvable.
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
  say_err "$(t check.network_tool_missing)"
  exit 1
fi

# pv n'est requis ici qu'en mode GUI : extract_gui() (plus bas) délègue à
# zgu_gui_extract_zstd (voir zgu-progress-utils.sh), qui appelle pv SANS repli possible en son
# absence (contrairement à extract_cli() juste en dessous, qui bascule proprement sur un appel
# bsdtar direct si pv est absent). Sans cette vérification, un pv manquant en mode GUI faisait
# échouer l'extraction avec un message générique "runner non résolu", sans jamais indiquer que
# la vraie cause était pv manquant.
if [[ "${mode}" != "cli" ]] && ! command -v pv >/dev/null 2>&1; then
  say_err "$(t check.cmd_missing "pv")"
  exit 1
fi

# Le module PyYAML est requis pour lire la clé wine.version des YAML des jeux installés.
# Sans lui, chaque jeu était silencieusement traité comme n'ayant aucun runner requis,
# ce qui rendait `lpm check` inutile sans jamais le signaler.
if ! python3 -c "import yaml" >/dev/null 2>&1; then
  say_err "$(t check.pyyaml_missing)"
  exit 1
fi

# 2. Détection Flatpak vs Paquet natif (fonction fournie par zgu-lutris-utils.sh -- résout
# aussi le cas des deux installées en même temps, voir zgu_resolve_lutris_version)
lutris_version=$(zgu_resolve_lutris_version "${mode}" "${lutris_package_db}" "${lutris_package_runner_dir}")
if [[ -z "${lutris_version}" ]]; then
  say_err "$(t check.lutris_missing)"
  exit 1
fi
case "${lutris_version}" in
  flatpak)
    lutris_db="${lutris_flatpak_db}"
    lutris_config_dir="${lutris_flatpak_config_dir}"
    runner_dir="${lutris_flatpak_runner_dir}"
    ;;
  native)
    lutris_db="${lutris_package_db}"
    lutris_config_dir="${lutris_package_config_dir}"
    runner_dir="${lutris_package_runner_dir}"
    ;;
esac

if [[ ! -f "${lutris_db}" ]]; then
  say_err "$(t check.db_missing "${lutris_db}")"
  exit 1
fi

mkdir -p "${runner_dir}"

# ---------------------------------------------------------------------------------------------
# 3. Détermination des runners requis par les jeux installés (clé wine.version des YAML)
# ---------------------------------------------------------------------------------------------

games_list=$(sqlite3 "${lutris_db}" "SELECT name || char(31) || slug || char(31) || configpath FROM games WHERE runner='wine';" 2>/dev/null)

declare -A games_needing_runner   # runner_name -> "jeu1, jeu2, ..."
required_runners=()

# Jeux référençant lsfg-vk (LSFGVK_ENV=1 dans system.env) et/ou AntimicroX (clé
# system.antimicro_config, gérée nativement par Lutris) -- alimentés dans la MÊME boucle que
# la lecture du runner requis ci-dessous, pour ne lire chaque YAML qu'une seule fois (un
# python3 par jeu, pas trois).
lsfg_games=()
antimicro_games=()

while IFS=$'\x1f' read -r game_name game_slug configpath; do
  [[ -z "${game_slug}" ]] && continue
  [[ -z "${configpath}" ]] && continue

  yml_path="${lutris_config_dir}/${configpath}.yml"
  [[ -f "${yml_path}" ]] || continue

  yml_fields=$(YML_PATH="${yml_path}" python3 -c '
import os, yaml
try:
    with open(os.environ["YML_PATH"], "r") as f:
        data = yaml.safe_load(f)
    if isinstance(data, dict):
        wine_version = data.get("wine", {}).get("version", "")
        system = data.get("system") or {}
        env = system.get("env") or {}
        lsfg_on = "1" if str(env.get("LSFGVK_ENV", "")) == "1" else ""
        antimicro_on = "1" if system.get("antimicro_config") else ""
        print(f"{wine_version}\x1f{lsfg_on}\x1f{antimicro_on}")
except Exception:
    pass
' 2>/dev/null)

  IFS=$'\x1f' read -r required_runner lsfg_on antimicro_on <<< "${yml_fields}"

  [[ -n "${lsfg_on}" ]] && lsfg_games+=("${game_name}")
  [[ -n "${antimicro_on}" ]] && antimicro_games+=("${game_name}")

  [[ -z "${required_runner}" ]] && continue

  # Durcissement par cohérence avec le filtrage déjà appliqué à "slug" dans
  # zgp-game-installer.sh : required_runner (clé wine.version) vient du YAML Lutris du jeu,
  # potentiellement issu d'un .zgp partagé par un tiers et non validé à l'installation sur
  # ce champ précis. required_runner sert plus bas à construire des chemins sous runner_dir
  # (test d'existence, et rm -rf en cas d'échec/annulation d'extraction) : sans ce filtre,
  # une valeur comme "../../..." resterait théoriquement possible ici, même si elle est déjà
  # neutralisée en pratique par ailleurs (le téléchargement n'a lieu que si cette valeur
  # correspond exactement au nom d'un asset publié sur la release GitHub officielle).
  case "${required_runner}" in
    */*|.|..)
      continue
      ;;
  esac

  if [[ -z "${games_needing_runner[${required_runner}]}" ]]; then
    games_needing_runner["${required_runner}"]="${game_name}"
    required_runners+=("${required_runner}")
  else
    games_needing_runner["${required_runner}"]="${games_needing_runner[${required_runner}]}, ${game_name}"
  fi
done <<< "${games_list}"

# ---------------------------------------------------------------------------------------------
# 3bis. Vérification lsfg-vk et AntimicroX -- placée AVANT les "exit 0" anticipés de la
# section runners ci-dessous : ces deux dépendances sont indépendantes des runners (un jeu
# peut avoir son runner présent et lsfg-vk/AntimicroX absent, ou l'inverse), donc ce bloc ne
# doit jamais être court-circuité par un "aucun runner requis"/"tous les runners présents".
# Chacune des deux n'est vérifiée que si au moins un jeu installé la référence réellement
# (LSFGVK_ENV=1 pour lsfg-vk, system.antimicro_config pour AntimicroX) : comme pour les
# runners, on ne signale jamais une dépendance que l'utilisateur n'utilise pas.
# ---------------------------------------------------------------------------------------------

if [[ ${#lsfg_games[@]} -gt 0 ]]; then
  lutris_is_flatpak_bool=false
  [[ "${lutris_version}" = "flatpak" ]] && lutris_is_flatpak_bool=true

  if ! zgu_lsfg_vk_present "${lutris_is_flatpak_bool}"; then
    lsfg_game_list=$(IFS=', '; echo "${lsfg_games[*]}")

    if [[ "${mode}" = "cli" ]]; then
      t check.lsfg_missing_cli "${lsfg_game_list}"
    else
      say "$(t check.lsfg_missing_gui "${lsfg_game_list}")"
    fi

    if [[ "${lutris_is_flatpak_bool}" = true ]]; then
      lsfg_runtime_version=$(zgu_lsfg_resolve_freedesktop_runtime_version)
      if [[ -z "${lsfg_runtime_version}" ]]; then
        say_err "$(t lsfg.flatpak_runtime_unknown)"
      else
        lsfg_do_install=false
        if [[ "${mode}" = "cli" ]]; then
          t lsfg.install_flatpak_confirm_cli "${lsfg_runtime_version}"
          read -r -p "$(t lsfg.confirm_prompt_cli)" lsfg_response
          [[ "${lsfg_response}" =~ ^[oOyY] ]] && lsfg_do_install=true
        else
          if zenity --question --title="$(t lsfg.install_title)" \
            --text="$(t lsfg.install_flatpak_confirm "${lsfg_runtime_version}")" \
            --ok-label="$(t lsfg.btn_validate)" --cancel-label="$(t lsfg.btn_cancel)" \
            --width=480 2>/dev/null; then
            lsfg_do_install=true
          fi
        fi

        if [[ "${lsfg_do_install}" = true ]]; then
          lsfg_install_err=$(zgu_lsfg_install_flatpak_do "${lsfg_runtime_version}")
          if [[ $? -eq 0 ]]; then
            say "$(t check.lsfg_installed_success)"
          else
            say_err "$(t lsfg.flatpak_install_failed "${lsfg_install_err}")"
          fi
        fi
      fi
    else
      # Natif : pas d'install auto possible (pas de paquet universel lsfg-vk), même limite
      # que "lpm lsfg" -- on se contente d'indiquer où trouver les instructions.
      say "$(t check.lsfg_native_hint)"
    fi
  fi
fi

if [[ ${#antimicro_games[@]} -gt 0 ]]; then
  if ! zgu_antimicro_present; then
    antimicro_game_list=$(IFS=', '; echo "${antimicro_games[*]}")

    if [[ "${mode}" = "cli" ]]; then
      t check.antimicro_missing_cli "${antimicro_game_list}"
    else
      say "$(t check.antimicro_missing_gui "${antimicro_game_list}")"
    fi

    if command -v flatpak >/dev/null 2>&1; then
      antimicro_do_install=false
      if [[ "${mode}" = "cli" ]]; then
        t check.antimicro_install_offer_cli
        read -r -p "$(t lsfg.confirm_prompt_cli)" antimicro_response
        [[ "${antimicro_response}" =~ ^[oOyY] ]] && antimicro_do_install=true
      else
        if zenity --question --title="$(t check.antimicro_install_title)" \
          --text="$(t check.antimicro_install_offer_gui)" \
          --ok-label="$(t lsfg.btn_validate)" --cancel-label="$(t lsfg.btn_cancel)" \
          --width=480 2>/dev/null; then
          antimicro_do_install=true
        fi
      fi

      if [[ "${antimicro_do_install}" = true ]]; then
        flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1
        antimicro_install_err=$(flatpak install --user -y flathub io.github.antimicrox.antimicrox 2>&1 >/dev/null)
        if [[ $? -eq 0 ]]; then
          say "$(t check.antimicro_installed_success)"
        else
          say_err "$(t check.antimicro_install_failed "${antimicro_install_err}")"
        fi
      fi
    else
      say "$(t check.antimicro_no_flatpak_hint)"
    fi
  fi
fi

if [[ ${#required_runners[@]} -eq 0 ]]; then
  say "$(t check.no_games_reference_runner)"
  exit 0
fi

# ---------------------------------------------------------------------------------------------
# 4. Comparaison avec les runners réellement installés
# ---------------------------------------------------------------------------------------------

missing_runners=()
for runner_name in "${required_runners[@]}"; do
  if [[ ! -d "${runner_dir}/${runner_name}" ]]; then
    missing_runners+=("${runner_name}")
  fi
done

if [[ ${#missing_runners[@]} -eq 0 ]]; then
  say "$(t check.all_runners_present)"
  exit 0
fi

if [[ "${mode}" = "cli" ]]; then
  t check.missing_detected_header
  for r in "${missing_runners[@]}"; do
    t check.missing_detected_item "${r}" "${games_needing_runner[${r}]}"
  done
  echo ""
fi

# ---------------------------------------------------------------------------------------------
# 5. Récupération unique de la liste des assets de la release GitHub (avec taille et digest SHA256)
# ---------------------------------------------------------------------------------------------

declare -A release_asset_url     # runner_name (sans .zgr) -> url de téléchargement
declare -A release_asset_size    # runner_name (sans .zgr) -> taille en octets
declare -A release_asset_digest  # runner_name (sans .zgr) -> "sha256:<hash>" (vide si non fourni par GitHub)

api_url=$(zgu_github_api_url "${GITHUB_RELEASE_URL}")
release_json=$(zgu_fetch_url "${api_url}")

if [[ -n "${release_json}" ]]; then
  parsed_assets=$(python3 -c '
import sys, json
try:
    data = json.loads(sys.argv[1])
    for asset in data.get("assets", []):
        name = asset.get("name", "")
        url = asset.get("browser_download_url", "")
        size = asset.get("size", 0)
        digest = asset.get("digest") or ""
        if name.endswith(".zgr"):
            print(f"{name}\x1f{url}\x1f{size}\x1f{digest}")
except Exception:
    pass
' "${release_json}" 2>/dev/null)

  while IFS=$'\x1f' read -r asset_name download_url asset_size asset_digest; do
    [[ -z "${asset_name}" ]] && continue
    release_asset_url["${asset_name%.zgr}"]="${download_url}"
    release_asset_size["${asset_name%.zgr}"]="${asset_size}"
    release_asset_digest["${asset_name%.zgr}"]="${asset_digest}"
  done <<< "${parsed_assets}"
fi

# ---------------------------------------------------------------------------------------------
# 6. Fonctions de téléchargement et d'extraction avec barres de progression réelles
# ---------------------------------------------------------------------------------------------

download_cli() {
  local url="$1" runner_name="$2"
  local dest
  # Pas de "-u" : "-u" se contente de choisir un nom sans créer le fichier, laissant une
  # fenêtre entre le choix du nom et l'écriture par wget/curl pendant laquelle un autre
  # utilisateur du même systeme peut y placer un lien symbolique dans /tmp (partagé, world-
  # writable) et rediriger l'écriture vers un chemin arbitraire (TOCTOU classique). Sans
  # "-u", mktemp crée réellement le fichier tout de suite, de façon atomique et sous nos
  # seuls droits, avant tout téléchargement dedans.
  dest=$(mktemp "/tmp/${runner_name}-XXXXXX.zgr")

  zgu_cli_error "$(t check.download_cli_start "${runner_name}")"
  if command -v wget >/dev/null 2>&1; then
    wget --show-progress -O "${dest}" "${url}"
  else
    curl -Lf -# -o "${dest}" "${url}"
  fi

  if [[ ! -f "${dest}" ]] || [[ ! -s "${dest}" ]]; then
    rm -f "${dest}"
    return 1
  fi
  echo "${dest}"
}

# Mince wrapper autour de zgu_gui_download (voir zgu-progress-utils.sh) : téléchargement
# piloté par pv, pourcentage réel quand la taille de l'asset est connue, sans aucun
# balayage disque périodique. Imprime le chemin du fichier téléchargé sur stdout en cas
# de succès uniquement.
download_gui() {
  local url="$1" runner_name="$2" expected_size="${3:-0}"
  # Texte optionnel (compteur "N/Total : nom -- etape") utilise en mode lot -- voir
  # ZGU_BATCH_FD plus bas dans ce fichier. Vide hors lot : comportement inchange.
  local batch_text="${4:-}"
  local zen_text="${batch_text:-$(t check.download_gui_text)}"
  local dest
  # Voir le commentaire dans download_cli() ci-dessus : pas de "-u", même raison.
  dest=$(mktemp "/tmp/${runner_name}-XXXXXX.zgr")

  zgu_gui_download "${url}" "${dest}" "${expected_size}" \
    "$(t check.download_gui_title "${runner_name}")" \
    "${zen_text}"
  local status=$?

  [[ "${status}" -eq 0 ]] && echo "${dest}"
  return "${status}"
}

# Vérifie le SHA256 d'une archive téléchargée par rapport au digest de la release GitHub
# (calcul factorisé dans zgu_sha256_matches, voir lib/zgu-github-release-utils.sh).
# Retourne 0 si la vérification passe (ou si aucun digest n'est disponible pour cet asset),
# 1 si le digest est présent mais ne correspond pas.
verify_checksum() {
  local archive_path="$1" runner_name="$2"
  local expected_digest="${release_asset_digest[${runner_name}]}"

  if [[ -z "${expected_digest}" ]]; then
    # Avertissement non bloquant (l'extraction se poursuit normalement juste après) :
    # say() plutôt que say_err(), pour ne pas afficher une popup "erreur" zenity trompeuse
    # alors qu'aucune vérification n'a en réalité échoué -- GitHub n'a simplement fourni
    # aucun digest pour cet asset précis.
    say "$(t check.checksum_missing "${runner_name}")"
  fi

  if ! zgu_sha256_matches "${archive_path}" "${expected_digest}"; then
    say_err "$(t check.checksum_invalid "${runner_name}")"
    return 1
  fi
  return 0
}

extract_cli() {
  local archive_path="$1" runner_name="$2"
  t check.extract_cli_start "${runner_name}"
  local archive_size
  archive_size=$(stat -c%s "${archive_path}" 2>/dev/null || stat -f%z "${archive_path}" 2>/dev/null)
  # umask 022 le temps de l'extraction : même garde-fou que zgp-game-installer.sh/
  # zgr-runner-installer.sh contre un .zgr forgé plantant un fichier trop permissif.
  local _lpm_old_umask
  _lpm_old_umask=$(umask)
  umask 022
  if command -v pv >/dev/null 2>&1; then
    pv -s "${archive_size:-0}" "${archive_path}" | bsdtar -xf - -C "${runner_dir}"
    local tar_exit="${PIPESTATUS[1]}"
  else
    bsdtar -xf "${archive_path}" -C "${runner_dir}"
    local tar_exit=$?
  fi
  umask "${_lpm_old_umask}"
  [[ "${tar_exit}" -eq 0 ]] && [[ -d "${runner_dir}/${runner_name}" ]]
}

# Mince wrapper autour de zgu_gui_extract_zstd (voir zgu-progress-utils.sh) : pourcentage
# réel piloté par pv sur le flux compressé d'entrée, sans balayage périodique du dossier
# de sortie (un "du -sb" répété serait coûteux sur un runner volumineux). Sur annulation
# ou échec, nettoie la cible avant de retourner.
extract_gui() {
  local archive_path="$1" runner_name="$2"
  # Texte optionnel (compteur "N/Total : nom -- etape") utilise en mode lot -- voir
  # ZGU_BATCH_FD plus bas dans ce fichier. Vide hors lot : comportement inchange.
  local batch_text="${3:-}"
  local zen_text="${batch_text:-$(t check.extract_gui_text)}"
  local target_dir="${runner_dir}/${runner_name}"

  zgu_gui_extract_zstd "${archive_path}" "${runner_dir}" \
    "$(t check.extract_gui_title "${runner_name}")" \
    "${zen_text}"
  local status=$?

  if [[ "${status}" -ne 0 ]]; then
    rm -rf "${target_dir}"
    return 1
  fi

  [[ -d "${target_dir}" ]]
}

# ---------------------------------------------------------------------------------------------
# 7. Traitement de chaque runner manquant : recherche distante uniquement, pas de question locale
# ---------------------------------------------------------------------------------------------

resolved_runners=()
unresolved_runners=()

# Fenêtre de progression PARTAGÉE (voir zgu_batch_progress_open dans zgu-progress-utils.sh),
# même principe que zgp-game-installer.sh : sans ça, plusieurs runners manquants résolus en
# une passe ouvraient et refermaient DEUX fenêtres chacun (téléchargement puis extraction).
check_using_batch=false
if [[ "${mode}" != "cli" ]] && [[ ${#missing_runners[@]} -gt 1 ]]; then
  check_using_batch=true
  zgu_batch_progress_open "$(t check.batch_progress_title "${#missing_runners[@]}")"
fi
check_idx=0

for runner_name in "${missing_runners[@]}"; do
  check_idx=$((check_idx + 1))
  install_ok=false

  if [[ -n "${release_asset_url[${runner_name}]}" ]]; then
    if [[ "${mode}" = "cli" ]]; then
      archive_path=$(download_cli "${release_asset_url[${runner_name}]}" "${runner_name}")
    else
      dl_text=""
      if [[ "${check_using_batch}" = true ]]; then
        dl_text="$(t check.batch_progress_item "${check_idx}" "${#missing_runners[@]}" "${runner_name}" "$(t check.download_gui_text)")"
      fi
      archive_path=$(download_gui "${release_asset_url[${runner_name}]}" "${runner_name}" "${release_asset_size[${runner_name}]}" "${dl_text}")
    fi

    if [[ -n "${archive_path}" ]]; then
      if verify_checksum "${archive_path}" "${runner_name}"; then
        if [[ "${mode}" = "cli" ]]; then
          extract_cli "${archive_path}" "${runner_name}" && install_ok=true
        else
          ex_text=""
          if [[ "${check_using_batch}" = true ]]; then
            ex_text="$(t check.batch_progress_item "${check_idx}" "${#missing_runners[@]}" "${runner_name}" "$(t check.extract_gui_text)")"
          fi
          extract_gui "${archive_path}" "${runner_name}" "${ex_text}" && install_ok=true
        fi
      fi
      rm -f "${archive_path}"
    fi
  fi

  if [[ "${install_ok}" = true ]]; then
    resolved_runners+=("${runner_name}")
    [[ "${mode}" = "cli" ]] && t check.runner_installed_success "${runner_name}"
  else
    unresolved_runners+=("${runner_name}")
  fi
done

[[ "${check_using_batch}" = true ]] && zgu_batch_progress_close

# ---------------------------------------------------------------------------------------------
# 8. Récapitulatif final
# ---------------------------------------------------------------------------------------------

if [[ ${#unresolved_runners[@]} -eq 0 ]]; then
  say "$(t check.all_resolved "${resolved_runners[*]}")"
  exit 0
fi

# Bloc de noms bruts, un par ligne, pour copier-coller facilement
recap_names=""
for r in "${unresolved_runners[@]}"; do
  recap_names+="${r}
"
done

recap_details=""
for r in "${unresolved_runners[@]}"; do
  recap_details+="$(t check.unresolved_detail_item "${r}" "${games_needing_runner[${r}]}")
"
done

if [[ "${mode}" = "cli" ]]; then
  echo ""
  echo "=== $(t check.unresolved_header_cli) ==="
  echo "${recap_names}"
  t check.detail_label
  echo "${recap_details}"
  t check.manual_install_hint
else
  full_text="$(t check.unresolved_header_gui)

${recap_names}
$(t check.detail_label)
${recap_details}
$(t check.manual_install_hint)"

  echo "${full_text}" | zenity --text-info --title="$(t check.unresolved_gui_title)" --width=550 --height=400 2>/dev/null
fi

exit 0
