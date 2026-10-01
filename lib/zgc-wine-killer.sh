#!/bin/bash

# --- lpm killwine : tue immédiatement tout process Wine/Winetricks/umu-run/Proton en
# cours, quel que soit le jeu ou le prefixe concerné (bouton "panique" pour un process
# bloqué/planté) ---
#
# Contrairement à "lpm tools <jeu> <action>" (qui cible UN jeu précis avec le bon
# binaire wine résolu depuis SA config), cette commande est volontairement large :
# tout process wine/wine64/wine-preloader/wine64-preloader/wineserver/winetricks/
# umu-run est tué, peu importe d'où il vient.
#
# EXCEPTION : Proton. "proton" est un mot trop générique pour matcher en aveugle sur la
# ligne de commande (ça tuerait aussi ProtonVPN, ProtonMail Bridge, Proton Pass...) --
# confirmé volontairement écarté par l'utilisateur, pour ne pas piéger d'autres
# utilisateurs de lpm qui utiliseraient ces applis. Donc "proton" n'est tué QUE si son
# chemin d'exécution vit sous le dossier des runners Lutris (Wine ET Proton y sont
# installés au même endroit par Lutris) -- ça attrape tout Proton lancé par/pour
# Lutris (via umu-run), sans jamais toucher à un Proton d'un autre éditeur.
#
# Implémentation par lecture directe de /proc/<pid>/cmdline (plutôt que "pkill -x" tout
# court) pour deux raisons vérifiées empiriquement :
#   1. "pkill -x" compare au nom "comm" du noyau, TRONQUÉ à 15 caractères -- "wine64-
#      preloader" fait 16 caractères et ne matcherait donc JAMAIS avec -x (testé).
#   2. Sécurité : chaque PID trouvé est explicitly comparé à $$ (ce script) et $PPID
#      (son parent, ex: le bash de bin/lpm) avant d'être tué, en plus de l'ancrage
#      du motif sur "/" et un séparateur -- degré de prudence supplémentaire pour une
#      action destructive et irréversible (-9, pas de confirmation possible après coup).

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./zgl-lang-loader.sh
source "${script_dir}/zgl-lang-loader.sh"
# shellcheck source=./zgu-cli-utils.sh
source "${script_dir}/zgu-cli-utils.sh"

# $1 = mode (toujours "cli" : bin/lpm n'a plus aucun point d'entrée interactif -- conservé
#      en position pour rester cohérent avec les autres scripts de lib/, mais sa valeur
#      n'est plus lue ici)
shift || true
confirm_flag="${1:-}"

if ! command -v pgrep >/dev/null 2>&1; then
  zgu_cli_error "$(t wine_killer.pgrep_missing)"
  exit 1
fi

# --- Confirmation (action destructive et irréversible : coupe tout jeu Wine en cours,
# progression non sauvegardée perdue) ---
if [[ "${confirm_flag}" != "yes" ]]; then
  t wine_killer.confirm_cli_header
  read -r -p "$(t wine_killer.confirm_cli_prompt)" response
  case "${response}" in
    [oOyY]) : ;;
    *)
      t wine_killer.cancelled_cli
      exit 0
      ;;
  esac
fi

# --- Chemins des runners Lutris (Flatpak ET paquet natif vérifiés systématiquement,
# indépendamment de la version "active" -- un process laissé par l'autre méthode
# d'installation doit quand même être détecté). ---
lutris_flatpak_runner_dir="${HOME}/.var/app/net.lutris.Lutris/data/lutris/runners/wine"
lutris_package_runner_dir="${HOME}/.local/share/lutris/runners/wine"

self_pid="$$"
parent_pid="${PPID}"

# zgc_kill_matching <motif_regex_etendu>
# Tue (-9) chaque process dont la ligne de commande complète (/proc/<pid>/cmdline)
# matche le motif donné, sauf ce script lui-même et son parent direct. Affiche sur
# stdout le nombre de process effectivement tués.
zgc_kill_matching() {
  local pattern="$1"
  local pid killed=0
  while IFS= read -r pid; do
    [[ -z "${pid}" ]] && continue
    [[ "${pid}" = "${self_pid}" ]] && continue
    [[ "${pid}" = "${parent_pid}" ]] && continue
    if kill -9 "${pid}" 2>/dev/null; then
      killed=$((killed + 1))
    fi
  done < <(pgrep -f -- "${pattern}" 2>/dev/null)
  echo "${killed}"
}

total_killed=0

# wine/wine64/wine-preloader/wine64-preloader/wineserver/winetricks/umu-run : motif
# ancré sur "/" (ou début de chaîne) avant, et un espace/fin de chaîne après -- exclut
# par construction un nom de fichier comme "zgc-wine-killer.sh" (le "wine" n'y est
# précédé ni de "/" ni suivi d'un espace), donc aucun risque de s'auto-tuer même sans
# la protection $$/$PPID ci-dessus.
for name in wine wine64 wine-preloader wine64-preloader wineserver winetricks umu-run; do
  count=$(zgc_kill_matching "(^|/)${name}([[:space:]]|\$)")
  [[ -n "${count}" ]] || count=0
  total_killed=$((total_killed + count))
done

# Fenêtre GUI de winetricks -- CORRIGÉ après retour terrain de l'utilisateur (le premier
# motif "zenity.*--title=winetricks" ne matchait RIEN en usage réel). Diagnostic obtenu
# via une commande lancée en direct sur la machine de l'utilisateur a montré le vrai
# mécanisme, différent de ce que laissait supposer la lecture statique du code source de
# winetricks :
#   sh   97886  /tmp/winetricks.f76WGtoc/w.harry.6289/zenity.sh
#   zenity 97888 (enfant du sh ci-dessus) --title "Winetricks - Choisir un préfixe" ...
# winetricks génère un dossier temporaire "winetricks.<aléatoire>/w.<user>.<pid>/", y
# écrit un script "zenity.sh", et le lance via "sh <chemin>/zenity.sh" -- ce script lance
# à son tour "zenity" comme process ENFANT séparé. Le titre affiché est localisé (donc
# variable selon la langue du système, ex: "Winetricks - Choisir un préfixe" en français)
# -- inutilisable comme motif de correspondance fiable. En revanche, le nom du dossier
# temporaire "winetricks.XXXXXXXX/w." est généré systématiquement par winetricks
# lui-même (via mktemp), quelle que soit la langue -- motif stable à utiliser.
#
# Le process "zenity" enfant, lui, n'a AUCUNE trace dans sa propre ligne de commande qui
# le relie à winetricks (juste "zenity --title <titre localisé> --text ... --list...") :
# le tuer directement par motif est donc impossible de façon fiable. Il faut donc :
#   1. Trouver le(s) process "sh .../winetricks.<alea>/w.<user>.<pid>/zenity.sh" via le
#      motif stable sur le dossier temporaire.
#   2. Tuer ce process "sh" lui-même.
#   3. ET tuer ses enfants directs (pgrep -P <pid>) -- c'est là que vit la fenêtre
#      "zenity" réellement affichée à l'écran, orpheline sinon (elle resterait ouverte
#      même après la mort de son parent "sh").
winetricks_wrapper_pattern="winetricks\.[A-Za-z0-9]+/w\.[^/]+\.[0-9]+/zenity\.sh"
while IFS= read -r wpid; do
  [[ -z "${wpid}" ]] && continue
  [[ "${wpid}" = "${self_pid}" ]] && continue
  [[ "${wpid}" = "${parent_pid}" ]] && continue

  # Enfants directs D'ABORD (avant de tuer le parent -- une fois le "sh" mort, on perd
  # la possibilité de retrouver ses enfants via pgrep -P, la fenêtre zenity deviendrait
  # orpheline sous PID 1 et indétectable par ce lien de parenté).
  while IFS= read -r cpid; do
    [[ -z "${cpid}" ]] && continue
    [[ "${cpid}" = "${self_pid}" ]] && continue
    [[ "${cpid}" = "${parent_pid}" ]] && continue
    if kill -9 "${cpid}" 2>/dev/null; then
      total_killed=$((total_killed + 1))
    fi
  done < <(pgrep -P "${wpid}" 2>/dev/null)

  if kill -9 "${wpid}" 2>/dev/null; then
    total_killed=$((total_killed + 1))
  fi
done < <(pgrep -f -- "${winetricks_wrapper_pattern}" 2>/dev/null)

# proton : scope obligatoire au dossier des runners Lutris (voir explication en tête de
# fichier -- "proton" seul est trop générique, collision possible avec ProtonVPN/
# ProtonMail/Proton Pass d'autres utilisateurs de lpm).
proton_killed=0
while IFS= read -r pid; do
  [[ -z "${pid}" ]] && continue
  [[ "${pid}" = "${self_pid}" ]] && continue
  [[ "${pid}" = "${parent_pid}" ]] && continue
  cmdline=$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null)
  [[ -z "${cmdline}" ]] && continue
  if [[ "${cmdline}" == *"${lutris_flatpak_runner_dir}"* ]] || [[ "${cmdline}" == *"${lutris_package_runner_dir}"* ]]; then
    if kill -9 "${pid}" 2>/dev/null; then
      proton_killed=$((proton_killed + 1))
    fi
  fi
done < <(pgrep -f -- "proton" 2>/dev/null)
total_killed=$((total_killed + proton_killed))

if [[ "${total_killed}" -gt 0 ]]; then
  zgu_cli_ok "$(t wine_killer.done_cli "${total_killed}")"
  notify-send "$(t wine_killer.notify_title)" "$(t wine_killer.done_gui "${total_killed}")" 2>/dev/null
else
  zgu_cli_ok "$(t wine_killer.nothing_running_cli)"
fi

exit 0
