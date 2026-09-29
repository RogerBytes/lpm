#!/bin/bash

# --- Chargeur de langue pour lpm ---
#
# Remplit le tableau associatif STRINGS[] :
#   1. Charge lang/en.lang en base (obligatoire, doit contenir toutes les clés).
#   2. Détecte la langue système ($LC_ALL > $LC_MESSAGES > $LANG).
#   3. Si un fichier lang/<code>.lang existe pour cette langue, le charge
#      par-dessus : seules les clés qu'il définit sont écrasées, les clés
#      absentes gardent leur valeur anglaise (repli automatique clé par clé).
#
# Pour ajouter une traduction : déposer un fichier "<code>.lang" dans ce même
# dossier "lang/", format "cle=Texte traduit" (une clé par ligne, %s / %d pour
# les valeurs dynamiques). Rien d'autre à modifier : si la langue système de
# l'utilisateur correspond, le fichier est pris en compte automatiquement.
#
# Les fichiers de langue sont volontairement de simples fichiers texte
# "clé=valeur" LUS ligne par ligne, jamais "source"/exécutés : une traduction
# contribuée par la communauté ne peut donc jamais faire exécuter de code.

# Même logique de détection que bin/lpm (voir son commentaire "Détection automatique de
# l'emplacement des libs") -- doit rester synchronisée avec elle : install.sh vs paquet
# .deb/.rpm/Arch vs mode dev.
_lpm_lang_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${_lpm_lang_script_dir}" in
    /usr/local/lib/lpm) LANG_DIR="/usr/local/lib/lpm/lang" ;;
    /usr/lib/lpm)       LANG_DIR="/usr/lib/lpm/lang" ;;
    *)                  LANG_DIR="${_lpm_lang_script_dir}/../lang" ;;
esac

declare -gA STRINGS=()

# Charge un fichier "cle=valeur" dans STRINGS (écrase les clés déjà présentes)
_lpm_load_lang_file() {
  local file="$1"
  [[ -f "${file}" ]] || return 1

  local line key value
  while IFS= read -r line || [[ -n "${line}" ]]; do
    [[ -z "${line}" ]] && continue
    # shellcheck disable=SC2249 # filtre, pas un dispatch : toute ligne qui ne matche pas
    # "#*" continue normalement vers le parsing clé=valeur ci-dessous, c'est voulu.
    case "${line}" in
      \#*) continue ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"
    [[ -z "${key}" ]] && continue

    STRINGS["${key}"]="${value}"
  done < "${file}"

  return 0
}

# 1. Base anglaise obligatoire
if ! _lpm_load_lang_file "${LANG_DIR}/en.lang"; then
  echo "Erreur critique : fichier de langue de base introuvable : ${LANG_DIR}/en.lang" >&2
  exit 1
fi

# 2. Détection de la langue système, code à 2 lettres en minuscule
_lpm_detected_locale="${LC_ALL:-${LC_MESSAGES:-${LANG:-en}}}"
_lpm_detected_code="${_lpm_detected_locale%%[._]*}"
_lpm_detected_code="${_lpm_detected_code,,}"
[[ -z "${_lpm_detected_code}" ]] && _lpm_detected_code="en"

# 3. Surcharge avec la langue détectée si elle existe (repli clé par clé implicite)
if [[ "${_lpm_detected_code}" != "en" ]]; then
  _lpm_load_lang_file "${LANG_DIR}/${_lpm_detected_code}.lang"
fi

# Fonction d'accès aux textes traduits : t <clé> [arguments pour %s / %d...]
# Ajoute elle-même le saut de ligne final (comme le ferait un "echo") : un appel s'utilise
# directement, "t ma.cle "$arg"", sans l'envelopper dans "echo "$(...)"". Un appel dont le
# résultat est capturé via "$(...)" (concaténation dans une variable, --text= de zenity...)
# n'est pas affecté : la substitution de commande retire de toute façon ce saut de ligne final.
# Exemple : t list_games.db_missing "$lutris_db"
t() {
  local key="$1"
  shift
  local template="${STRINGS[${key}]:-${key}}"
  # Protège d'abord les vrais specifiers %s/%d -- les seuls utilisés par ce projet (voir
  # commentaire au-dessus) -- via des sentinelles (octets de contrôle improbables dans une
  # traduction), AVANT tout échappement des '%' isolés restants (ex: un pourcentage
  # littéral "50%" dans une traduction communautaire, qui sans ça casserait silencieusement
  # l'affichage -- voire l'appel entier -- une fois utilisé comme format printf).
  # Protéger AVANT d'échapper (plutôt que l'inverse, doubler-puis-restaurer) évite qu'un
  # "%s"/"%d" non voulu comme specifier, une fois doublé en "%%s"/"%%d", soit malgré tout
  # restauré comme un vrai specifier au passage suivant : ici, seul un %s/%d présent tel
  # quel dans la traduction SOURCE (donc un vrai specifier voulu par le traducteur) est
  # jamais transformé en argument attendu.
  template="${template//%s/$'\x01'}"
  template="${template//%d/$'\x02'}"
  template="${template//%/%%}"
  template="${template//$'\x01'/%s}"
  template="${template//$'\x02'/%d}"
  # shellcheck disable=SC2059
  printf -- "${template}\n" "$@"
}
