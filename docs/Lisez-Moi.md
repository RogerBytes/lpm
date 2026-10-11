# Ludis Prefix Manager

Sauvegardez, transférez et réinstallez vos jeux Wine/Lutris en un clic.

<p align="center">
  <img src="../assets/icons/lpm.svg" width="128" height="128" alt="Icône Ludis Prefix Manager">
</p>

<p align="center">
  <a href="https://github.com/RogerBytes/lpm/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/RogerBytes/lpm"></a>
  <img alt="License MIT" src="https://img.shields.io/badge/license-MIT-green">
</p>

<p align="center">
  <a href="https://github.com/RogerBytes/lpm/releases/latest">Dernière release</a> ·
  <a href="#installation">Installation</a> ·
  <a href="#commandes">Commandes</a> ·
  <a href="https://github.com/RogerBytes/lpm/issues">Issues</a>
</p>

**Ludis Prefix Manager** vous permet de sauvegarder vos jeux Wine pour Lutris au format `.zgp` et vos runners au format `.zgr`. Il centralise l'exportation, la gestion et la suppression de vos archives, tandis que l'importation se charge de tout configurer pour que votre jeu soit immédiatement prêt à être lancé.

> [!WARNING]
> **N'installez que des archives `.zgp` et `.zgr` que vous avez créées vous-même ou qui viennent de quelqu'un en qui vous avez confiance.** lpm sert à sauvegarder et à déplacer vos propres jeux et runners entre vos machines ; il n'est pas fait pour télécharger ou distribuer des jeux. Une archive peut contenir n'importe quel fichier : les scripts qu'elle embarque sont désactivés tant que vous ne les autorisez pas (`--allow-scripts`), mais vous l'installez malgré tout à vos propres risques. N'installez jamais une archive d'origine inconnue.

## Fonctionnalités

- Sauvegarde et restauration de vos jeux et runners Wine/Lutris sous forme d'archives portables (`.zgp` / `.zgr`), installables sur n'importe quelle machine.
- Lanceurs (raccourcis desktop) unifiés et fiables, cohérents quel que soit votre environnement de bureau.
- Icônes fonctionnelles pour vos jeux et runners, correctement affichées dans le menu et le gestionnaire de fichiers.
- Utilisable en ligne de commande, ou avec l'interface graphique (`lpm-gui`) si vous préférez ne rien taper.
- Réglages par jeu : outils Wine (winetricks, éditeur de registre, winecfg, console, variables d'environnement, changement de runner), désactivation forcée du VSync, génération de frames lsfg-vk, et un lanceur avec écran de chargement qui permet de choisir parmi plusieurs exécutables.
- Raccourcis manette pendant le jeu quand le lanceur est activé (Alt+Tab, F4, Alt+Entrée, F11), sous X11 et Wayland.
- Interface disponible en français et en anglais.
- Complétion bash/zsh et page de manuel (`man lpm`) incluses.
- Paquets natifs `.deb`, `.rpm` et Arch, ou installation manuelle universelle sur n'importe quelle distribution.

## Installation

lpm gère des jeux installés dans **Lutris** : Lutris doit donc être installé sur votre machine (paquet Flatpak ou natif, les deux sont pris en charge). Les paquets `.deb`, `.rpm` et Arch le recommandent seulement et ne l'installent pas à votre place.

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

### Debian, Ubuntu, Linux Mint (et dérivées)

Téléchargez le fichier `.deb` correspondant depuis la [page des releases](https://github.com/RogerBytes/lpm/releases), puis :

```bash
sudo apt install -y ./lpm_*.deb
```

Les dépendances sont résolues automatiquement.

### Fedora (et dérivées)

Téléchargez le fichier `.rpm` correspondant depuis la [page des releases](https://github.com/RogerBytes/lpm/releases), puis :

```bash
sudo dnf install -y ./lpm-*.rpm
```

### Arch Linux (et dérivées)

Téléchargez le fichier `.pkg.tar.zst` correspondant depuis la [page des releases](https://github.com/RogerBytes/lpm/releases), puis :

```bash
sudo pacman -U --noconfirm ./lpm-*.pkg.tar.zst
```

### Autres distributions (installation manuelle)

Si votre distribution n'est pas couverte ci-dessus (par exemple openSUSE), ou si vous préférez une installation manuelle, installez d'abord les dépendances :

#### Ubuntu / Debian / Linux Mint

```bash
sudo apt install -y tar zstd curl wget python3 python3-yaml python3-gi python3-evdev gir1.2-gtk-4.0 gir1.2-adw-1 libsdl2-2.0-0 sqlite3 pv libarchive-tools desktop-file-utils shared-mime-info hicolor-icon-theme
flatpak install -y flathub net.lutris.Lutris
```

#### Arch Linux

```bash
sudo pacman -S --needed tar zstd curl wget python python-yaml python-gobject python-evdev gtk4 libadwaita sdl2 sqlite pv bsdtar desktop-file-utils shared-mime-info hicolor-icon-theme
flatpak install -y flathub net.lutris.Lutris
```

#### Fedora

```bash
sudo dnf install -y tar zstd curl wget python3 python3-pyyaml python3-gobject python3-evdev gtk4 libadwaita SDL2 sqlite pv bsdtar desktop-file-utils shared-mime-info hicolor-icon-theme
flatpak install -y flathub net.lutris.Lutris
```

#### openSUSE

```bash
sudo zypper install -y tar zstd curl wget python3 python3-PyYAML python3-gobject python3-evdev typelib-1_0-Gtk-4_0 typelib-1_0-Adw-1 libSDL2-2_0-0 sqlite3 pv bsdtar desktop-file-utils shared-mime-info hicolor-icon-theme
flatpak install -y flathub net.lutris.Lutris
```

> [!WARNING]
> Le paquet `bsdtar` n'est pas officiellement disponible sur certaines versions d'openSUSE Leap (ex. 15.6) au moment de la rédaction. S'il est introuvable via `zypper`, vérifiez sur [software.opensuse.org/package/bsdtar](https://software.opensuse.org/package/bsdtar) la disponibilité pour votre version, ou passez par le dépôt communautaire indiqué sur cette page.

Téléchargez ensuite le projet et lancez le script d'installation depuis son dossier :

```bash
git clone https://github.com/RogerBytes/lpm.git
cd lpm
chmod +x ./install.sh
sudo ./install.sh
```

Ça installe aussi les icônes propres à lpm (thème `hicolor`) : une pour l'application dans le menu, et une pour chacun des types de fichiers `.zgp`/`.zgr` dans votre gestionnaire de fichiers.

Si un autre programme nommé `lpm` existe déjà dans `/usr/local/bin` (par exemple le gestionnaire de plugins de Lite XL), `install.sh` s'arrête avant de rien copier et vous le dit, et `uninstall.sh` ne supprime jamais un `/usr/local/bin/lpm` qui n'est pas Ludis Prefix Manager. Les paquets `.deb`, `.rpm` et Arch sont protégés par votre gestionnaire de paquets, qui refuse d'écraser un fichier appartenant à un autre paquet.

**Désinstallation :** avec un paquet, utilisez votre gestionnaire de paquets (`sudo apt remove lpm`, `sudo dnf remove lpm` ou `sudo pacman -R lpm`) ; après une installation manuelle, lancez `sudo ./uninstall.sh` depuis le dossier du projet. Désinstaller lpm ne retire que ses propres fichiers : vos jeux, vos préfixes et votre configuration Lutris ne sont pas touchés.

</div></details>

## Démarrage rapide

```bash
lpm pack mariovania papers-please
lpm install -y Mariovania.zgp "Papers, Please.zgp"
```

Même principe pour un runner : `lpm pack-runner <nom>` puis `lpm install-runner <fichier>.zgr`.

## Commandes

`lpm` est une commande de terminal, utilisable en script : elle n'ouvre jamais de fenêtre, et lancée sans argument elle affiche l'aide. L'interface graphique se lance avec `lpm-gui`. Chaque commande a sa page de référence détaillée (en anglais) : arguments, options, comportement, codes de sortie, notes pour les scripts et exemples. Voir aussi [les options globales](commands/options.md) (`-y`, `--hash`…) et [le format des archives](commands/archives.md) (`.zgp` / `.zgr`).

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

### Jeux

- [`lpm install`](commands/install.md) — Installe un ou plusieurs jeux depuis des archives `.zgp`.
- [`lpm uninstall`](commands/uninstall.md) — Désinstalle un ou plusieurs jeux (préfixe, entrée Lutris, raccourcis).
- [`lpm pack`](commands/pack.md) — Empaquette un ou plusieurs jeux en `.zgp`.
- [`lpm isolate`](commands/isolate.md) — Sépare un préfixe de store partagé (Epic, EA, Ubisoft, Battle.net) en un préfixe par jeu (bêta).
- [`lpm list`](commands/list.md) — Liste les jeux installés.
- [`lpm list-isolable`](commands/list-isolable.md) — Liste les jeux qui partagent un préfixe de store.
- [`lpm info`](commands/info.md) — Affiche les métadonnées d'un jeu installé.
- [`lpm create-prefix`](commands/create-prefix.md) — Crée des préfixes Wine vides enregistrés dans Lutris.
- [`lpm exe-install`](commands/exe-install.md) — Crée un préfixe et y lance un installeur Windows.
- [`lpm shortcut`](commands/shortcut.md) — (Re)crée les raccourcis menu/bureau.
- [`lpm icon`](commands/icon.md) — Récupère l'icône d'un jeu depuis SteamGridDB.
- [`lpm splash`](commands/splash.md) — Récupère la bannière de l'écran de chargement depuis SteamGridDB.
- [`lpm logo`](commands/logo.md) — Récupère le logo transparent d'un jeu.
- [`lpm sync-media`](commands/sync-media.md) — Télécharge les médias propres à Lutris pour les jeux qui n'en ont pas.
- [`lpm tools`](commands/tools.md) — Lance un outil Wine sur un jeu (winetricks, regedit, winecfg, console, exe, folder, favorite, env, runner, mangohud, gamepad).
- [`lpm vsync`](commands/vsync.md) — Force la désactivation du VSync d'un jeu via des variables d'environnement (Direct3D 9/11/12, OpenGL).
- [`lpm lsfg`](commands/lsfg.md) — Active/désactive la génération de frames lsfg-vk.
- [`lpm launcher`](commands/launcher.md) — Active/désactive le LPM Launcher (écran de chargement et sélecteur d'exécutable).
- [`lpm killwine`](commands/killwine.md) — Tue tous les processus Wine/Proton en cours.

### Runners

- [`lpm install-runner`](commands/install-runner.md) — Installe des runners depuis des fichiers `.zgr` locaux ou la release GitHub.
- [`lpm uninstall-runner`](commands/uninstall-runner.md) — Désinstalle des runners.
- [`lpm pack-runner`](commands/pack-runner.md) — Empaquette des runners en `.zgr`.
- [`lpm list-runner`](commands/list-runner.md) — Liste les runners installés.
- [`lpm list-remote-runners`](commands/list-remote-runners.md) — Liste les runners disponibles sur la release GitHub.

### Système

- [`lpm check`](commands/check.md) — Vérifie que les runners requis par les jeux installés sont présents et récupère ceux qui manquent.
- [`lpm lutris-version`](commands/lutris-version.md) — Affiche ou force l'installation de Lutris utilisée quand Flatpak et natif coexistent.
- [`lpm self-update`](commands/self-update.md) — Cherche une version plus récente de lpm et l'installe (installations par paquet uniquement).
- [`lpm log`](commands/log.md) — Affiche, filtre ou vide le journal des actions.

### Avancé

- [`lpm launcher-entries`](commands/launcher-entries.md) — Lit/remplace les entrées du sélecteur du launcher (JSON).
- [`lpm lsfg-dll`](commands/lsfg-dll.md) — Lit ou enregistre la DLL de référence `lsfg-vk.dll`.
- [`lpm sgdb-key`](commands/sgdb-key.md) — Lit, enregistre ou efface la clé d'API SteamGridDB.
- [`lpm sgdb-images`](commands/sgdb-images.md) — Liste les images candidates de SteamGridDB en JSON (utilisé par l'interface graphique).

</div></details>

## Information

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

Pour avoir une icone au lanceur, il suffit de créer un répertoire `icon` à la racine du préfixe, et y déplacer votre fichier image.

Pour tout autre fichier annexe (config manette Antimicro `.amgp`, scripts personnels...) : il suffit qu'il soit présent quelque part dans le préfixe **avant l'empaquetage** (`lpm pack`) pour être inclus dans l'archive `.zgp` et se retrouver au même endroit après réinstallation. Pour une config manette, il vous suffit ensuite de la référencer normalement dans la configuration Lutris du jeu (YAML) : le préfixe étant réécrit vers `$GAMEDIR` à l'installation, un chemin qui pointe dedans continue de fonctionner sur la machine de destination.

</div></details>

## Licence et contribution

Ce projet est sous licence MIT (voir [`LICENSE`](../LICENSE)), à l'exception de trois fichiers d'icônes sous GPLv3. Le nom "Ludis Prefix Manager"/"lpm" et le logo du projet ne sont pas couverts par cette licence.

Pour contribuer, signaler un bug ou proposer une fonctionnalité, voir [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## Auteur

[<img src="https://github.com/RogerBytes.png" width="40" height="40" style="border-radius:50%;" alt="RogerBytes' avatar">](https://github.com/RogerBytes)
[**RogerBytes (Harry Richmond)**](https://github.com/RogerBytes)

Ce projet a été développé avec l'aide d'une IA (Claude, d'Anthropic). L'auteur décide de ce qu'il fait, le teste et le maintient.

<span hidden>
<details><summary></summary>
<style>.spoiler{border-left:4px solid #1abc9c;border-bottom-left-radius:3px;padding-left:10px;padding-top:15px;margin-top:-10px;margin-bottom:15px}.button{cursor:pointer;padding:5px 10px;background-color:#3498db;color:white;border-radius:3px;margin-bottom:5px;display:inline-block;transition:background-color 0.2s}.button:hover{background-color:#217dbb}details[open] .button{background-color:#1abc9c}</style>
</details></span>

<p align="right"><a href="#ludis-prefix-manager">🔝 Retour en haut</a></p>
