#!/bin/bash

# --- Utilitaire partagé : vérification d'intégrité sha256 optionnelle des archives .zgp/.zgr ---
#
# Le hash de référence est un fichier "sidecar" séparé, JAMAIS embarqué dans l'archive
# elle-même : impossible par construction, puisque ajouter le hash dans l'archive après
# l'avoir calculé changerait ses octets et invaliderait le hash qu'on vient de calculer
# (voir zgp-game-packer.sh/zgr-runner-packer.sh pour la génération). Le sidecar contient
# uniquement le hash hexadécimal, une seule ligne, rien d'autre -- pas le format classique
# "sha256sum -c" qui inclut aussi le nom du fichier : un simple renommage de l'archive après
# téléchargement (très courant, ex: "MonJeu (1).zgp") ferait alors échouer la vérification
# à tort, alors que l'archive elle-même n'a pas bougé d'un octet.
#
# Deux emplacements possibles pour le sidecar d'une archive "<dossier>/<archive>" :
#   1. "<dossier>/hash/<archive>.sha256" -- prioritaire, pour garder un ensemble de paquets
#      organisé (plusieurs .zgp/.zgr partagés ensemble, tous leurs hash regroupés à part).
#   2. "<dossier>/<archive>.sha256" -- repli, pour un partage simple d'un seul fichier sans
#      dossier dédié.
# Si les deux existent pour la même archive, celui dans hash/ l'emporte sans détection
# particulière du désaccord entre les deux (cas limite jugé trop rare pour la complexité
# que ça ajouterait).

# zgu_find_hash_sidecar <archive_path>
# Affiche sur stdout le chemin du sidecar trouvé, rien si absent (code de retour 1 dans ce cas).
zgu_find_hash_sidecar() {
  local archive_path="$1"
  local dir base candidate
  dir="$(dirname -- "${archive_path}")"
  base="$(basename -- "${archive_path}")"

  candidate="${dir}/hash/${base}.sha256"
  if [[ -f "${candidate}" ]]; then
    echo "${candidate}"
    return 0
  fi

  candidate="${dir}/${base}.sha256"
  if [[ -f "${candidate}" ]]; then
    echo "${candidate}"
    return 0
  fi

  return 1
}

# zgu_verify_archive_hash <archive_path> <hash_file>
# Code de retour 0 si le hash correspond, 1 sinon. Un sidecar illisible, vide, tronqué ou ne
# contenant pas un hash sha256 valide (64 caractères hexadécimaux) est traité EXACTEMENT
# comme un vrai mismatch, sans distinction côté appelant : un sidecar cassé n'inspire pas
# plus confiance qu'un hash qui ne correspond pas, les deux doivent déclencher la même
# alerte plutôt qu'échouer silencieusement ou planter le script.
zgu_verify_archive_hash() {
  local archive_path="$1"
  local hash_file="$2"
  local expected actual

  expected=$(tr -d '[:space:]' < "${hash_file}" 2>/dev/null)
  if [[ ! "${expected}" =~ ^[0-9a-fA-F]{64}$ ]]; then
    return 1
  fi

  actual=$(sha256sum -- "${archive_path}" 2>/dev/null | cut -d' ' -f1)
  [[ -n "${actual}" ]] || return 1

  [[ "${actual,,}" = "${expected,,}" ]]
}

# zgu_write_hash_sidecar <archive_path> <output_dir>
# Calcule le sha256 de <archive_path> (déjà complètement écrite et figée sur le disque -- ne
# JAMAIS appeler avant que l'archive soit terminée, voir l'explication en tête de fichier) et
# écrit le sidecar dans "<output_dir>/hash/<basename archive_path>.sha256", en créant le
# dossier hash/ si besoin. Code de retour 1 si le calcul échoue (archive introuvable, sha256sum
# absent...), sans jamais faire échouer l'empaquetage lui-même côté appelant (l'archive reste
# valide même sans son sidecar).
zgu_write_hash_sidecar() {
  local archive_path="$1"
  local output_dir="$2"
  local base hash_dir hash_value

  [[ -f "${archive_path}" ]] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1

  base="$(basename -- "${archive_path}")"
  hash_dir="${output_dir}/hash"
  mkdir -p "${hash_dir}" || return 1

  hash_value=$(sha256sum -- "${archive_path}" 2>/dev/null | cut -d' ' -f1)
  [[ -n "${hash_value}" ]] || return 1

  echo "${hash_value}" > "${hash_dir}/${base}.sha256"
}
