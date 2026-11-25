# Démarrer avec ludis

Une page, trois choses que vous ferez sûrement avec ludis. Chaque commande a sa propre page de référence dans [`commands/`](commands/) ; celle-ci ne montre que les chemins courants. Vous préférez une fenêtre au terminal ? Lancez `ludis-gui` : chaque action ci-dessous y existe aussi, sous le même nom.

Avant tout, Lutris doit être installé (Flatpak ou paquet natif) et vos jeux doivent y être enregistrés. `ludis list` affiche vos jeux installés avec leur **slug** (le nom court utilisé par toutes les commandes).

## 1. Déplacer un jeu vers une autre machine

Sur la machine qui possède le jeu :

```bash
ludis list                      # trouver le slug
ludis pack mariovania           # écrit « <Nom du jeu>.zgp » dans votre dossier personnel
```

Copiez le fichier `.zgp` sur l'autre machine (clé USB, partage réseau...), puis :

```bash
ludis install Mariovania.zgp
```

Le jeu est enregistré dans Lutris, ses raccourcis sont créés, il est prêt à être lancé. Plusieurs jeux d'un coup : `ludis pack slug1 slug2 ...` puis `ludis install a.zgp b.zgp`. Ajoutez `-y` juste après `install` pour ne pas avoir de confirmation.

- Un jeu existant n'est **jamais écrasé** : désinstallez-le d'abord avec `ludis uninstall <slug>`.
- Une archive peut contenir des données privées (registre, clés de licence) : gardez-les pour vous, et n'installez que des archives que vous avez faites ou qui viennent de quelqu'un en qui vous avez confiance.
- Les runners fonctionnent pareil : `ludis pack-runner <nom>`, puis `ludis install-runner <fichier>.zgr`. Sur la nouvelle machine, `ludis check` récupère les runners dont vos jeux installés ont besoin.

Voir [`pack`](commands/pack.md), [`install`](commands/install.md) et le [format des archives](commands/archives.md).

## 2. Ajouter un jeu depuis un installateur Windows

```bash
ludis exe-install "Setup.exe|Mon Jeu"
```

ludis crée un préfixe Wine vierge, y lance l'installateur, puis ajoute le jeu à Lutris. Choisissez le runner avec `-r <runner>` (et `-a win32` pour un préfixe 32 bits). Vous voulez juste un préfixe vide pour le préparer à la main ? Utilisez [`ludis create-prefix`](commands/create-prefix.md).

Voir [`exe-install`](commands/exe-install.md).

## 3. Régler un jeu

Tout se fait jeu par jeu, avec le slug :

```bash
ludis tools mongame winetricks  # ou : regedit, winecfg, console, env set CLÉ VALEUR ...
ludis vsync mongame off         # forcer la VSync à off
ludis lsfg mongame on           # génération d'images lsfg-vk
ludis launcher mongame on       # écran de chargement + sélecteur d'exécutable, utilisable à la manette
```

Chacune a une forme `status` pour voir l'état actuel. Les visuels du menu et de l'écran de chargement viennent de SteamGridDB (`ludis sgdb-key` pour enregistrer votre clé d'API, puis `ludis icon`, `ludis splash`, `ludis logo`), ou de Lutris lui-même avec `ludis sync-media`.

Voir [`tools`](commands/tools.md), [`vsync`](commands/vsync.md), [`lsfg`](commands/lsfg.md) et [`launcher`](commands/launcher.md).

## En cas de problème

- `ludis log` montre ce que ludis a fait et où ça a échoué.
- Lutris Flatpak et natif installés ensemble ? `ludis lutris-version` affiche ou force celui que ludis utilise.
- Jeu bloqué après un plantage : `ludis killwine` tue tous les processus Wine/Proton en cours.
- Bug ou question : ouvrez une [issue](https://github.com/RogerBytes/ludis/issues).
