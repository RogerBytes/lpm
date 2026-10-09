#!/bin/bash
set -euo pipefail

# --- build.sh: builds the lpm packages (.deb / .rpm / Arch), each in a Docker container
# dedicated to its target distribution -- reproducible, only Docker needed on the host.
# Finished packages land in packaging/dist/.
#
# Usage: ./build.sh [deb|rpm|arch|all]   (default: all)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DIST_DIR="${SCRIPT_DIR}/dist"

mkdir -p "${DIST_DIR}"
chmod 777 "${DIST_DIR}"   # written by root (deb/rpm) AND by the non-root user of the Arch container

# Host user's UID/GID: packages are built as root in the containers (needed by
# dpkg-buildpackage/rpmbuild and for pacman dependencies on Arch), so without a chown the
# files copied to /dist would be root:root on the host (not modifiable without sudo). The
# chown runs FROM the container, right after each cp, where root may change ownership.
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"

VERSION="$(grep -oP 'LPM_VERSION="v\K[^"]+' "${PROJECT_ROOT}/bin/lpm")"
echo "Version détectée : ${VERSION}"

build_deb() {
  echo "=== Build .deb (Debian 13) ==="
  echo "--- Préparation de l'image (téléchargement + outils, peut prendre plusieurs minutes la 1ère fois) ---"
  docker build -t lpm-builder-debian -f "${SCRIPT_DIR}/docker/Dockerfile.debian" "${SCRIPT_DIR}/docker"
  echo "--- Construction du paquet ---"
  docker run --rm -v "${PROJECT_ROOT}:/src:ro" -v "${DIST_DIR}:/dist" \
    -e VERSION="${VERSION}" -e HOST_UID="${HOST_UID}" -e HOST_GID="${HOST_GID}" lpm-builder-debian \
    bash -c '
      set -e
      rm -rf /build && mkdir -p /build && cp -a /src/. /build/
      cd /build
      cp -a packaging/debian debian
      # Version injected from bin/lpm (single source); the "-1" package revision is
      # maintained by hand in the original changelog.
      sed -i "s/^lpm (\([^)]*\))/lpm (${VERSION}-1)/" debian/changelog
      dpkg-buildpackage -us -uc -b
      cp ../lpm_*.deb /dist/
      chown "${HOST_UID}:${HOST_GID}" /dist/lpm_*.deb
    '
  echo "[OK] .deb -> ${DIST_DIR}"
}

build_rpm() {
  echo "=== Build .rpm (Fedora) ==="
  echo "--- Préparation de l'image (téléchargement + outils, peut prendre plusieurs minutes la 1ère fois) ---"
  docker build -t lpm-builder-fedora -f "${SCRIPT_DIR}/docker/Dockerfile.fedora" "${SCRIPT_DIR}/docker"
  echo "--- Construction du paquet ---"
  docker run --rm -v "${PROJECT_ROOT}:/src:ro" -v "${DIST_DIR}:/dist" \
    -e VERSION="${VERSION}" -e HOST_UID="${HOST_UID}" -e HOST_GID="${HOST_GID}" lpm-builder-fedora \
    bash -c '
      set -e
      rpmdev-setuptree
      tar --transform "s,^,lpm-${VERSION}/," -czf ~/rpmbuild/SOURCES/lpm-${VERSION}.tar.gz -C /src .
      # Version injected from bin/lpm (single source), replacing the hardcoded "Version:"
      # in the original .spec.
      sed "s/^Version:.*/Version:        ${VERSION}/" /src/packaging/rpm/lpm.spec > ~/rpmbuild/SPECS/lpm.spec
      rpmbuild -bb ~/rpmbuild/SPECS/lpm.spec
      cp ~/rpmbuild/RPMS/noarch/*.rpm /dist/
      chown "${HOST_UID}:${HOST_GID}" /dist/*.rpm
    '
  echo "[OK] .rpm -> ${DIST_DIR}"
}

build_arch() {
  echo "=== Build paquet Arch (PKGBUILD) ==="
  echo "--- Préparation de l'image (téléchargement + outils, peut prendre plusieurs minutes la 1ère fois) ---"
  docker build -t lpm-builder-arch -f "${SCRIPT_DIR}/docker/Dockerfile.arch" "${SCRIPT_DIR}/docker"
  echo "--- Construction du paquet ---"
  # makepkg refuses to run as root (Arch requirement), but then nothing could install missing
  # dependencies with pacman. So run as root by default (installing dependencies read straight
  # from the PKGBUILD, the single source of truth), then switch to the unprivileged "builder"
  # user only for the build itself.
  docker run --rm -v "${PROJECT_ROOT}:/src:ro" -v "${DIST_DIR}:/dist" \
    -e VERSION="${VERSION}" -e HOST_UID="${HOST_UID}" -e HOST_GID="${HOST_GID}" lpm-builder-arch \
    bash -c '
      set -e
      source /src/packaging/arch/PKGBUILD
      pacman -Sy --noconfirm --needed "${depends[@]}"

      mkdir -p /build/pkg && cd /build/pkg
      tar --transform "s,^,lpm-${VERSION}/," -czf "lpm-${VERSION}.tar.gz" -C /src .
      # Version injected from bin/lpm (single source), replacing the hardcoded "pkgver="
      # in the original PKGBUILD.
      sed "s/^pkgver=.*/pkgver=${VERSION}/" /src/packaging/arch/PKGBUILD > PKGBUILD
      chown -R builder:builder /build

      su - builder -c "cd /build/pkg && makepkg --noconfirm --skipinteg"
      cp ./*.pkg.tar.zst /dist/
      chown "${HOST_UID}:${HOST_GID}" /dist/*.pkg.tar.zst
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
