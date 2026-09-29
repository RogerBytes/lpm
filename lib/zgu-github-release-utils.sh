#!/bin/bash

# --- Utilitaires partagés pour les interactions avec la release GitHub des runners ---
#
# Regroupe la logique commune à zgc-dependency-checker.sh, zgr-runner-installer.sh et
# zgr-runner-remote-lister.sh : construction de l'URL d'API GitHub à partir de l'URL de
# la page de release, récupération silencieuse d'une URL (curl si dispo, sinon wget), et
# vérification d'un digest SHA256 au format "sha256:<hash>" tel que renvoyé par l'API GitHub.
#
# Ce fichier ne fait AUCUN affichage (pas de zenity, pas d'echo/say_err) : chaque appelant
# reste responsable de son propre message d'erreur et de son propre nettoyage en cas
# d'échec (le mode CLI et le mode GUI n'affichent pas les échecs de la même façon), seule
# la logique de calcul, identique partout, est partagée ici.

# URL de la page de release GitHub contenant les paquets de runners (.zgr) précompilés.
# Point d'entrée UNIQUE : c'est la seule ligne à modifier pour pointer lpm vers un autre
# dépôt/une autre release de runners. zgc-dependency-checker.sh, zgr-runner-installer.sh
# et zgr-runner-remote-lister.sh sourcent ce fichier et réutilisent cette même constante.
# shellcheck disable=SC2034 # lue par les scripts qui sourcent ce fichier (ex: zgc-dependency-checker.sh)
readonly GITHUB_RELEASE_URL="https://github.com/RogerBytes/Mintage/releases/tag/zgr-pkg"

# Convertit l'URL d'une page de release GitHub (.../releases/tag/<tag>) en URL d'API
# (https://api.github.com/repos/<owner>/<repo>/releases/tags/<tag>).
zgu_github_api_url() {
  local release_url="$1"
  echo "${release_url}" | sed -E 's|https?://github\.com/([^/]+)/([^/]+)/releases/tag/([^/]+)|https://api.github.com/repos/\1/\2/releases/tags/\3|'
}

# Récupère le contenu d'une URL sur stdout, silencieusement, via curl si disponible sinon wget.
# Retourne 1 si aucun des deux outils n'est disponible (l'appelant a normalement déjà vérifié
# leur présence plus tôt, ceci est un filet de sécurité).
zgu_fetch_url() {
  local url="$1"
  if command -v curl >/dev/null 2>&1; then
    # -f : en cas d'erreur HTTP (ex: rate-limit ou 404 de l'API GitHub), curl échoue
    # silencieusement (sortie vide, code de retour non nul) au lieu de renvoyer le corps
    # JSON de l'erreur comme s'il s'agissait d'une réponse valide. Sans ce flag, un tel
    # corps ("assets" absent) pourrait être confondu par les appelants avec une vraie
    # réponse "aucun runner disponible", masquant le vrai problème réseau/API.
    curl -sf "${url}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "${url}"
  else
    return 1
  fi
}

# Compare le SHA256 d'un fichier local à un digest attendu au format "sha256:<hash>" (tel que
# renvoyé par le champ "digest" des assets de l'API GitHub). Un digest vide signifie que GitHub
# n'en a fourni aucun pour cet asset : dans ce cas, il n'y a rien à vérifier et la fonction
# retourne 0 (succès).
# Retourne 0 si les hashs correspondent (ou si expected_digest est vide), 1 sinon.
zgu_sha256_matches() {
  local archive_path="$1"
  local expected_digest="$2"

  [[ -z "${expected_digest}" ]] && return 0

  local expected_sha="${expected_digest#sha256:}"
  local actual_sha
  actual_sha=$(sha256sum "${archive_path}" 2>/dev/null | awk '{print $1}')

  [[ "${actual_sha}" = "${expected_sha}" ]]
}
