Name:           lpm
Version:        0.9.3
Release:        1%{?dist}
Summary:        Package manager for Lutris

License:        MIT AND GPL-3.0-or-later
URL:            https://rogerbytes.com
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

Requires:       bash
Requires:       python3
Requires:       python3-pyyaml
Requires:       python3-gobject
Requires:       python3-evdev
Requires:       SDL2
Requires:       sqlite
Requires:       zstd
Requires:       bsdtar
Requires:       desktop-file-utils
Requires:       shared-mime-info
Requires:       hicolor-icon-theme
Requires:       gtk4 >= 4.10
Requires:       libadwaita >= 1.4
Recommends:     lutris
Recommends:     wine
Recommends:     winetricks
Recommends:     ImageMagick
Recommends:     curl
Recommends:     xdotool
Recommends:     ydotool
Recommends:     bash-completion

%description
lpm (Ludis Package Manager) packages, installs and manages Wine/Proton
games and runners for Lutris as .zgp/.zgr archives, with support for
lsfg-vk (frame generation), shared-prefix isolation, and desktop
integration (icons, MIME types, shortcuts).

%prep
%setup -q

%build
# Rien à compiler : projet bash pur.

%install
rm -rf %{buildroot}

install -Dm755 bin/lpm %{buildroot}/usr/bin/lpm

# Interface graphique GTK4/Libadwaita (gui/) + son lanceur (bin/lpm-gui) : gtk4 et
# libadwaita sont des dépendances obligatoires (voir Requires ci-dessus), donc bin/lpm et
# bin/lpm-gui n'ont plus besoin de vérifier leur présence à l'exécution.
install -Dm755 bin/lpm-gui %{buildroot}/usr/bin/lpm-gui
install -d %{buildroot}/usr/lib/lpm/gui
for f in gui/*.py; do
  install -Dm755 "${f}" "%{buildroot}/usr/lib/lpm/gui/$(basename "${f}")"
done

install -d %{buildroot}/usr/lib/lpm
for f in lib/*.sh; do
  install -Dm755 "${f}" "%{buildroot}/usr/lib/lpm/$(basename "${f}")"
done
for f in lib/*.py; do
  install -Dm755 "${f}" "%{buildroot}/usr/lib/lpm/$(basename "${f}")"
done

install -d %{buildroot}/usr/lib/lpm/data
for f in lib/data/*; do
  install -Dm644 "${f}" "%{buildroot}/usr/lib/lpm/data/$(basename "${f}")"
done

install -d %{buildroot}/usr/lib/lpm/lang
for f in lang/*.lang; do
  install -Dm644 "${f}" "%{buildroot}/usr/lib/lpm/lang/$(basename "${f}")"
done

install -Dm644 completions/lpm.bash %{buildroot}/usr/share/bash-completion/completions/lpm
install -Dm644 completions/_lpm %{buildroot}/usr/share/zsh/site-functions/_lpm
install -Dm644 man/man1/lpm.1 %{buildroot}/usr/share/man/man1/lpm.1
install -Dm644 man/fr/man1/lpm.1 %{buildroot}/usr/share/man/fr/man1/lpm.1

install -Dm644 assets/icons/lpm.svg %{buildroot}/usr/share/icons/hicolor/scalable/apps/lpm.svg
install -Dm644 assets/icons/lpm-game-generic.svg %{buildroot}/usr/share/icons/hicolor/scalable/apps/lpm-game-generic.svg
install -Dm644 assets/icons/application-x-zgp-game.svg %{buildroot}/usr/share/icons/hicolor/scalable/mimetypes/application-x-zgp-game.svg
install -Dm644 assets/icons/application-x-zgr-runner.svg %{buildroot}/usr/share/icons/hicolor/scalable/mimetypes/application-x-zgr-runner.svg

install -Dm644 packaging/common/lpm.desktop %{buildroot}/usr/share/applications/lpm.desktop
install -Dm644 packaging/common/lpm.xml %{buildroot}/usr/share/mime/packages/lpm.xml

%files
%license LICENSE
/usr/bin/lpm
/usr/bin/lpm-gui
/usr/lib/lpm/
/usr/lib/lpm/data/
/usr/lib/lpm/gui/
/usr/share/bash-completion/completions/lpm
/usr/share/zsh/site-functions/_lpm
/usr/share/man/man1/lpm.1*
/usr/share/man/fr/man1/lpm.1*
/usr/share/icons/hicolor/scalable/apps/lpm.svg
/usr/share/icons/hicolor/scalable/apps/lpm-game-generic.svg
/usr/share/icons/hicolor/scalable/mimetypes/application-x-zgp-game.svg
/usr/share/icons/hicolor/scalable/mimetypes/application-x-zgr-runner.svg
/usr/share/applications/lpm.desktop
/usr/share/mime/packages/lpm.xml

%changelog
* Thu Oct 01 2026 Harry <harry.richmond@rogerbytes.com> - 0.9.3-1
- Remove all remaining Zenity code; lpm-gui (GTK4/Libadwaita) is now the sole GUI.
- gtk4 and libadwaita become mandatory Requires (>= 4.10 / >= 1.4) instead of Recommends;
  the GTK4/Libadwaita runtime check at launch is removed accordingly.

* Tue Sep 29 2026 Harry <harry.richmond@rogerbytes.com> - 0.9.2-1
- Initial RPM package release.
