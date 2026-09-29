# Ludis Package Manager

**Ludis Package Manager** vous permet de sauvegarder vos jeux Wine pour Lutris au format `.zgp` et vos runners au format `.zgr`. Il centralise l'exportation, la gestion et la suppression de vos archives, tandis que l'importation se charge de tout configurer pour que votre jeu soit immédiatement prêt à être lancé.

## Commandes

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

### Jeux

- `lpm install [-y] <fichiers.zgp...>` — Installe un ou plusieurs jeux depuis des paquets `.zgp` (local ou chemin).
- `lpm uninstall [-y] <slugs...>` — Désinstalle un ou plusieurs jeux (supprime le préfixe, l'entrée Lutris et les raccourcis).
- `lpm pack [-niveau] <dossiers...>` — Empaquette un ou plusieurs préfixes de jeux en `.zgp` (niveau de compression zstd optionnel, 0 à 22).
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

Pour des exemples de commande complets, voir `docs/Tests.md`.

</div></details>

## Dépendances

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

L'application est minimaliste mais requiert plusieurs dépendances :

- Tar
- Zstd
- bsdtar (utilitaire `bsdtar` de la bibliothèque libarchive — utilisé pour l'extraction sécurisée des `.zgp`/`.zgr`, distincte du `tar` GNU classique)
- Curl
- Wget
- Python 3 (avec le module PyYAML)
- Sqlite3
- Lutris
- pv
- grep
- awk
- zenity (interface graphique : menu principal, sélection de fichiers, barres de progression — requis dès qu'une commande n'est pas lancée en mode CLI strict avec cible explicite)

### Ubuntu

Sur une Debian / Ubuntu (et dérivées comme Linux Mint)

```bash
sudo apt install -y tar zstd curl wget python3 python3-yaml sqlite3 pv libarchive-tools zenity
flatpak install -y flathub net.lutris.Lutris
```

Sur cinnamon il faut activer les nouvelles fenêtres lancée d'un terminal

`Paramètres du système > Fenêtres > Comportement > **Cibler les nouvelles fenêtres lancées d'un terminal** (à activer).`

### Arch Linux

Sur une Arch Linux (et dérivées comme Manjaro)

```bash
sudo pacman -S --needed tar zstd curl wget python python-yaml sqlite pv bsdtar zenity
flatpak install -y flathub net.lutris.Lutris
```

### Fedora

Sur une Fedora (et dérivées comme RHEL)

```bash
sudo dnf install -y tar zstd curl wget python3 python3-pyyaml sqlite pv bsdtar zenity
flatpak install -y flathub net.lutris.Lutris
```

### OpenSUSE

Sur une OpenSUSE (et dérivées comme Leap)

```bash
sudo zypper install -y tar zstd curl wget python3 python3-PyYAML sqlite3 pv bsdtar zenity
flatpak install -y flathub net.lutris.Lutris
```

> ⚠️ Le paquet `bsdtar` n'est pas officiellement disponible sur certaines versions d'openSUSE Leap (ex. 15.6) au moment de la rédaction. S'il est introuvable via `zypper`, vérifiez sur [software.opensuse.org/package/bsdtar](https://software.opensuse.org/package/bsdtar) la disponibilité pour votre version, ou passez par le dépôt communautaire indiqué sur cette page.

</div></details>

## Installation

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

Pour l'installer il suffit de lancer le script d'installation.

On le rend executable

```bash
chmod +x ./install.sh
```

Puis on l'installe

```bash
sudo ./install.sh
```

Ça installe aussi les icônes propres à lpm (thème `hicolor`) : une pour l'application dans le menu, et une pour chacun des types de fichiers `.zgp`/`.zgr` dans votre gestionnaire de fichiers.

</div></details>

## Information

<details><summary class="button">🔍 Spoiler</summary><div class="spoiler">

Pour avoir une icone au lanceur, il suffit de créer un répertoire `icon` à la racine du préfixe, et y déplacer votre fichier image.

Pour tout autre fichier annexe (config manette Antimicro `.amgp`, scripts personnels...) : il suffit qu'il soit présent quelque part dans le préfixe **avant l'empaquetage** (`lpm pack`) pour être inclus dans l'archive `.zgp` et se retrouver au même endroit après réinstallation. Pour une config manette, il vous suffit ensuite de la référencer normalement dans la configuration Lutris du jeu (YAML) : le préfixe étant réécrit vers `$GAMEDIR` à l'installation, un chemin qui pointe dedans continue de fonctionner sur la machine de destination.

</div></details>

## Auteur

[<img src="https://github.com/RogerBytes.png" width="40" height="40" style="border-radius:50%;" alt="RogerBytes' avatar">](https://github.com/RogerBytes)
[**RogerBytes (Harry Richmond)**](https://github.com/RogerBytes)

<span hidden>
<details><summary></summary>
<style>.spoiler{border-left:4px solid #1abc9c;border-bottom-left-radius:3px;padding-left:10px;padding-top:15px;margin-top:-10px;margin-bottom:15px}.button{cursor:pointer;padding:5px 10px;background-color:#3498db;color:white;border-radius:3px;margin-bottom:5px;display:inline-block;transition:background-color 0.2s}.button:hover{background-color:#217dbb}details[open] .button{background-color:#1abc9c}</style>
</details></span>

<p align="right"><a href="#">🔝 Retour en haut</a></p>
