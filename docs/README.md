# Ludis Package Manager

*Read this in [English](README.en.md).*

Sauvegardez, transférez et réinstallez vos jeux Wine/Lutris en un clic.

<p align="center">
  <img src="../assets/icons/lpm.svg" width="128" height="128" alt="Icône Ludis Package Manager">
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

**Ludis Package Manager** vous permet de sauvegarder vos jeux Wine pour Lutris au format `.zgp` et vos runners au format `.zgr`. Il centralise l'exportation, la gestion et la suppression de vos archives, tandis que l'importation se charge de tout configurer pour que votre jeu soit immédiatement prêt à être lancé.

## Fonctionnalités

- Sauvegarde et restauration de vos jeux et runners Wine/Lutris sous forme d'archives portables (`.zgp` / `.zgr`), installables sur n'importe quelle machine.
- Lanceurs (raccourcis desktop) unifiés et fiables, cohérents quel que soit votre environnement de bureau.
- Icônes fonctionnelles pour vos jeux et runners, correctement affichées dans le menu et le gestionnaire de fichiers.
- Utilisable en ligne de commande, ou en mode guidé (dialogues graphiques) si vous préférez ne rien taper.
- Interface disponible en français et en anglais.
- Complétion bash/zsh et page de manuel (`man lpm`) incluses.
- Paquets natifs `.deb`, `.rpm` et Arch, ou installation manuelle universelle sur n'importe quelle distribution.

## Démarrage rapide

```bash
lpm pack mariovania papers-please
lpm install -y Mariovania.zgp "Papers, Please.zgp"
```

Même principe pour un runner : `lpm pack-runner <nom>` puis `lpm install-runner <fichier>.zgr`.

## Commandes

Chaque commande ci-dessous fonctionne en ligne de commande explicite (avec ses arguments), ou en mode guidé (menus et dialogues graphiques) si vous la lancez sans argument.

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

### Jeux

- `lpm install [-y] <fichiers.zgp...>` — Installe un ou plusieurs jeux depuis des paquets `.zgp` (local ou chemin).
- `lpm uninstall [-y] <slugs...>` — Désinstalle un ou plusieurs jeux (supprime le préfixe, l'entrée Lutris et les raccourcis).
- `lpm pack [-niveau] <slugs...>` — Empaquette un ou plusieurs jeux (par slug) en `.zgp` (niveau de compression zstd optionnel, 0 à 22).
- `lpm list` — Liste les jeux Wine installés (slug puis nom).

### Runners

- `lpm install-runner [-y] <fichiers.zgr|noms...>` — Installe un ou plusieurs runners, depuis un fichier `.zgr` local ou par nom depuis la release GitHub de lpm.
- `lpm uninstall-runner [-y] <noms...>` — Désinstalle un ou plusieurs runners.
- `lpm pack-runner [-niveau] <noms...>` — Empaquette un ou plusieurs runners installés en `.zgr`.
- `lpm list-runner` — Liste les runners actuellement installés.
- `lpm list-remote-runners` — Liste les runners disponibles sur le dépôt GitHub distant (signale ceux déjà installés).

### Dépendances

- `lpm check` — Analyse les fichiers YAML de tous les jeux installés, compare avec les runners réellement présents, et pour chaque runner manquant tente de le récupérer automatiquement depuis la release GitHub de lpm (avec vérification SHA256). Les runners manquants introuvables sur le dépôt sont listés en fin d'exécution avec leurs jeux dépendants ; il faut alors les installer manuellement via un fichier `.zgr` (`lpm install-runner <fichier>.zgr`) ou via ProtonUp-Qt.
- `lpm lutris-version [flatpak|native|reset]` — Affiche les versions de Lutris détectées (Flatpak et/ou paquet natif), avec leur numéro et un statut à jour/dépassé. Si les deux sont installées en même temps, lpm demande une seule fois laquelle utiliser (sinon Flatpak est prioritaire par défaut) et retient ce choix ; `flatpak`/`native` force ce choix, `reset` l'efface.

Pour la liste complète et toujours à jour de toutes les commandes (raccourcis, icônes, isolation de préfixe, outils, lsfg, logs, etc.), voir `lpm --help` ou `man lpm`.

</div></details>

## Installation

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
sudo apt install -y tar zstd curl wget python3 python3-yaml sqlite3 pv libarchive-tools zenity
flatpak install -y flathub net.lutris.Lutris
```

#### Arch Linux

```bash
sudo pacman -S --needed tar zstd curl wget python python-yaml sqlite pv bsdtar zenity
flatpak install -y flathub net.lutris.Lutris
```

#### Fedora

```bash
sudo dnf install -y tar zstd curl wget python3 python3-pyyaml sqlite pv bsdtar zenity
flatpak install -y flathub net.lutris.Lutris
```

#### openSUSE

```bash
sudo zypper install -y tar zstd curl wget python3 python3-PyYAML sqlite3 pv bsdtar zenity
flatpak install -y flathub net.lutris.Lutris
```

> [!WARNING]
> Le paquet `bsdtar` n'est pas officiellement disponible sur certaines versions d'openSUSE Leap (ex. 15.6) au moment de la rédaction. S'il est introuvable via `zypper`, vérifiez sur [software.opensuse.org/package/bsdtar](https://software.opensuse.org/package/bsdtar) la disponibilité pour votre version, ou passez par le dépôt communautaire indiqué sur cette page.

Puis lancez le script d'installation :

```bash
chmod +x ./install.sh
sudo ./install.sh
```

Ça installe aussi les icônes propres à lpm (thème `hicolor`) : une pour l'application dans le menu, et une pour chacun des types de fichiers `.zgp`/`.zgr` dans votre gestionnaire de fichiers.

</div></details>

## Information

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

Pour avoir une icone au lanceur, il suffit de créer un répertoire `icon` à la racine du préfixe, et y déplacer votre fichier image.

Pour tout autre fichier annexe (config manette Antimicro `.amgp`, scripts personnels...) : il suffit qu'il soit présent quelque part dans le préfixe **avant l'empaquetage** (`lpm pack`) pour être inclus dans l'archive `.zgp` et se retrouver au même endroit après réinstallation. Pour une config manette, il vous suffit ensuite de la référencer normalement dans la configuration Lutris du jeu (YAML) : le préfixe étant réécrit vers `$GAMEDIR` à l'installation, un chemin qui pointe dedans continue de fonctionner sur la machine de destination.

</div></details>

## Licence et contribution

Ce projet est sous licence MIT (voir [`LICENSE`](../LICENSE)), à l'exception de trois fichiers d'icônes sous GPLv3. Le nom "Ludis Package Manager"/"lpm" et le logo du projet ne sont pas couverts par cette licence.

Pour contribuer, signaler un bug ou proposer une fonctionnalité, voir [`CONTRIBUTING.md`](../CONTRIBUTING.md).

## Auteur

[<img src="https://github.com/RogerBytes.png" width="40" height="40" style="border-radius:50%;" alt="RogerBytes' avatar">](https://github.com/RogerBytes)
[**RogerBytes (Harry Richmond)**](https://github.com/RogerBytes)

<span hidden>
<details><summary></summary>
<style>.spoiler{border-left:4px solid #1abc9c;border-bottom-left-radius:3px;padding-left:10px;padding-top:15px;margin-top:-10px;margin-bottom:15px}.button{cursor:pointer;padding:5px 10px;background-color:#3498db;color:white;border-radius:3px;margin-bottom:5px;display:inline-block;transition:background-color 0.2s}.button:hover{background-color:#217dbb}details[open] .button{background-color:#1abc9c}</style>
</details></span>

<p align="right"><a href="#">🔝 Retour en haut</a></p>
