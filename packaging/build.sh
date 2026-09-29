#!/bin/bash
set -euo pipefail

# --- build.sh : construit les paquets lpm (.deb / .rpm / Arch) chacun dans un conteneur
# Docker dédié à sa distribution cible -- reproductible, rien à installer sur l'hôte à part
# Docker lui-même. Les paquets finis atterrissent dans packaging/dist/.
#
# Usage : ./build.sh [deb|rpm|arch|all]   (défaut : all)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"

mkdir -p "${DIST_DIR}"
chmod 777 "${DIST_DIR}"   # écrit par root (deb/rpm) ET par l'utilisateur non-root du conteneur Arch

VERSION="$(grep -oP 'LPM_VERSION="v\K[^"]+' "${PROJECT_ROOT}/bin/lpm")"
echo "Version détectée : ${VERSION}"

build_deb() {
  echo "=== Build .deb (Debian 13) ==="
  echo "--- Préparation de l'image (téléchargement + outils, peut prendre plusieurs minutes la 1ère fois) ---"
  docker build -t lpm-builder-debian -f "${SCRIPT_DIR}/docker/Dockerfile.debian" "${SCRIPT_DIR}/docker"
  echo "--- Construction du paquet ---"
  docker run --rm -v "${PROJECT_ROOT}:/src:ro" -v "${DIST_DIR}:/dist" -e VERSION="${VERSION}" lpm-builder-debian \
    bash -c '
      set -e
      rm -rf /build && mkdir -p /build && cp -a /src/. /build/
      cd /build
      cp -a packaging/debian debian
      # Numéro de version injecté depuis bin/lpm (source unique) -- le "-1" (révision du
      # paquetage, distincte de la version du logiciel) reste géré à la main dans le
      # changelog d'\''origine.
      sed -i "s/^lpm (\([^)]*\))/lpm (${VERSION}-1)/" debian/changelog
      dpkg-buildpackage -us -uc -b
      cp ../lpm_*.deb /dist/
    '
  echo "[OK] .deb -> ${DIST_DIR}"
}

build_rpm() {
  echo "=== Build .rpm (Fedora) ==="
  echo "--- Préparation de l'image (téléchargement + outils, peut prendre plusieurs minutes la 1ère fois) ---"
  docker build -t lpm-builder-fedora -f "${SCRIPT_DIR}/docker/Dockerfile.fedora" "${SCRIPT_DIR}/docker"
  echo "--- Construction du paquet ---"
  docker run --rm -v "${PROJECT_ROOT}:/src:ro" -v "${DIST_DIR}:/dist" -e VERSION="${VERSION}" lpm-builder-fedora \
    bash -c '
      set -e
      rpmdev-setuptree
      tar --transform "s,^,lpm-${VERSION}/," -czf ~/rpmbuild/SOURCES/lpm-${VERSION}.tar.gz -C /src .
      # Numéro de version injecté depuis bin/lpm (source unique), à la place du "Version:"
      # écrit en dur dans le .spec d'\''origine.
      sed "s/^Version:.*/Version:        ${VERSION}/" /src/packaging/rpm/lpm.spec > ~/rpmbuild/SPECS/lpm.spec
      rpmbuild -bb ~/rpmbuild/SPECS/lpm.spec
      cp ~/rpmbuild/RPMS/noarch/*.rpm /dist/
    '
  echo "[OK] .rpm -> ${DIST_DIR}"
}

build_arch() {
  echo "=== Build paquet Arch (PKGBUILD) ==="
  echo "--- Préparation de l'image (téléchargement + outils, peut prendre plusieurs minutes la 1ère fois) ---"
  docker build -t lpm-builder-arch -f "${SCRIPT_DIR}/docker/Dockerfile.arch" "${SCRIPT_DIR}/docker"
  echo "--- Construction du paquet ---"
  # makepkg refuse de tourner en root (exigence d'Arch) -- mais alors rien ne peut
  # installer les dépendances manquantes avec pacman. On tourne donc en root par défaut
  # (installation des dépendances, lues directement dans le PKGBUILD -- source unique de
  # vérité, jamais dupliquées ici), puis on bascule sur l'utilisateur non privilégié
  # "builder" seulement pour la compilation elle-même.
  docker run --rm -v "${PROJECT_ROOT}:/src:ro" -v "${DIST_DIR}:/dist" -e VERSION="${VERSION}" lpm-builder-arch \
    bash -c '
      set -e
      source /src/packaging/arch/PKGBUILD
      pacman -Sy --noconfirm --needed "${depends[@]}"

      mkdir -p /build/pkg && cd /build/pkg
      tar --transform "s,^,lpm-${VERSION}/," -czf "lpm-${VERSION}.tar.gz" -C /src .
      # Numéro de version injecté depuis bin/lpm (source unique), à la place du "pkgver="
      # écrit en dur dans le PKGBUILD d'\''origine.
      sed "s/^pkgver=.*/pkgver=${VERSION}/" /src/packaging/arch/PKGBUILD > PKGBUILD
      chown -R builder:builder /build

      su - builder -c "cd /build/pkg && makepkg --noconfirm --skipinteg"
      cp ./*.pkg.tar.zst /dist/
    '
  echo "[OK] paquet Arch -> ${DIST_DIR}"
}

case "${1:-all}" in
  deb)  build_deb ;;
  rpm)  build_rpm ;;
  arch) build_arch ;;
  all)  build_deb; build_rpm; build_arch ;;
  *) echo "Usage: $0 [deb|rpm|arch|all]"; exit 1 ;;
esac

echo "========================================"
echo " Paquets disponibles dans : ${DIST_DIR}"
ls -la "${DIST_DIR}"
echo "========================================"
