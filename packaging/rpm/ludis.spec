Name:           ludis
Version:        0.9.3
Release:        1%{?dist}
Summary:        Prefix manager for Lutris

License:        MIT AND GPL-3.0-or-later
URL:            https://rogerbytes.com
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

Obsoletes:      lpm
Provides:       lpm = %{version}
Requires:       bash
Requires:       python3
Requires:       python3-pyyaml
Requires:       python3-gobject
Requires:       python3-evdev
Requires:       SDL2
Requires:       sqlite
Requires:       zstd
Requires:       pv
Requires:       bsdtar
Requires:       desktop-file-utils
Requires:       shared-mime-info
Requires:       hicolor-icon-theme
Requires:       gtk4 >= 4.10
Requires:       libadwaita >= 1.5
Recommends:     lutris
Recommends:     wine
Recommends:     winetricks
Recommends:     ImageMagick
Recommends:     curl
Recommends:     xdotool
Recommends:     ydotool
Recommends:     bash-completion

%description
ludis (Ludis) packages, installs and manages Wine/Proton
games and runners for Lutris as .zgp/.zgr archives, with support for
lsfg-vk (frame generation), shared-prefix isolation, and desktop
integration (icons, MIME types, shortcuts).

%prep
%setup -q

%build
# Rien à compiler : projet bash pur.

%install
rm -rf %{buildroot}

install -Dm755 bin/ludis %{buildroot}/usr/bin/ludis
/usr/bin/lpm
/usr/lib/lpm

# Interface graphique GTK4/Libadwaita (gui/) + son lanceur (bin/ludis-gui) : gtk4 et
# libadwaita sont des dépendances obligatoires (voir Requires ci-dessus), donc bin/ludis et
# bin/ludis-gui n'ont plus besoin de vérifier leur présence à l'exécution.
install -Dm755 bin/ludis-gui %{buildroot}/usr/bin/ludis-gui
install -d %{buildroot}/usr/lib/ludis/gui
for f in gui/*.py; do
  install -Dm755 "${f}" "%{buildroot}/usr/lib/ludis/gui/$(basename "${f}")"
done

install -d %{buildroot}/usr/lib/ludis
for f in lib/*.sh; do
  install -Dm755 "${f}" "%{buildroot}/usr/lib/ludis/$(basename "${f}")"
done
for f in lib/*.py; do
  install -Dm755 "${f}" "%{buildroot}/usr/lib/ludis/$(basename "${f}")"
done

install -d %{buildroot}/usr/lib/ludis/data
for f in lib/data/*; do
  install -Dm644 "${f}" "%{buildroot}/usr/lib/ludis/data/$(basename "${f}")"
done

install -d %{buildroot}/usr/lib/ludis/lang
for f in lang/*.lang; do
  install -Dm644 "${f}" "%{buildroot}/usr/lib/ludis/lang/$(basename "${f}")"
done

install -Dm644 completions/ludis.bash %{buildroot}/usr/share/bash-completion/completions/ludis
install -Dm644 completions/_ludis %{buildroot}/usr/share/zsh/site-functions/_ludis
install -Dm644 man/man1/ludis.1 %{buildroot}/usr/share/man/man1/ludis.1
install -Dm644 man/fr/man1/ludis.1 %{buildroot}/usr/share/man/fr/man1/ludis.1

install -Dm644 assets/icons/ludis.svg %{buildroot}/usr/share/icons/hicolor/scalable/apps/ludis.svg
install -Dm644 assets/icons/ludis-game-generic.svg %{buildroot}/usr/share/icons/hicolor/scalable/apps/ludis-game-generic.svg
install -Dm644 assets/icons/application-x-zgp-game.svg %{buildroot}/usr/share/icons/hicolor/scalable/mimetypes/application-x-zgp-game.svg
install -Dm644 assets/icons/application-x-zgr-runner.svg %{buildroot}/usr/share/icons/hicolor/scalable/mimetypes/application-x-zgr-runner.svg

install -Dm644 packaging/common/ludis.desktop %{buildroot}/usr/share/applications/ludis.desktop
install -Dm644 packaging/common/ludis.xml %{buildroot}/usr/share/mime/packages/ludis.xml

# Compatibility with the former name "lpm": existing shortcuts point to /usr/lib/lpm.
ln -s ludis %{buildroot}/usr/lib/lpm
ln -s ludis %{buildroot}/usr/bin/lpm

%files
%license LICENSE
/usr/bin/ludis
/usr/bin/ludis-gui
/usr/lib/ludis/
/usr/lib/ludis/data/
/usr/lib/ludis/gui/
/usr/share/bash-completion/completions/ludis
/usr/share/zsh/site-functions/_ludis
/usr/share/man/man1/ludis.1*
/usr/share/man/fr/man1/ludis.1*
/usr/share/icons/hicolor/scalable/apps/ludis.svg
/usr/share/icons/hicolor/scalable/apps/ludis-game-generic.svg
/usr/share/icons/hicolor/scalable/mimetypes/application-x-zgp-game.svg
/usr/share/icons/hicolor/scalable/mimetypes/application-x-zgr-runner.svg
/usr/share/applications/ludis.desktop
/usr/share/mime/packages/ludis.xml

%changelog
* Thu Oct 01 2026 Harry <harry.richmond@rogerbytes.com> - 0.9.3-1
- Remove all remaining Zenity code; ludis-gui (GTK4/Libadwaita) is now the sole GUI.
- gtk4 and libadwaita become mandatory Requires (>= 4.10 / >= 1.4) instead of Recommends;
  the GTK4/Libadwaita runtime check at launch is removed accordingly.

* Tue Sep 29 2026 Harry <harry.richmond@rogerbytes.com> - 0.9.2-1
- Initial RPM package release.
