# Feature : `lpm isolate`

**Nom affiché** : "🧩 Isolate games from a shared store" / "🧩 Isoler les jeux d'un store partagé"

## Contexte

Lutris gère chaque jeu Wine via une ligne dans la table `games` de sa base SQLite (`pga.db`), avec entre autres les colonnes `directory` (chemin du wineprefix) et `executable` (chemin de l'exécutable du jeu).

Le principe de base de lpm est **un jeu = un wineprefix indépendant**. Ce principe est respecté par la plupart des stores (GOG, itch.io, ZOOM Platform, installation manuelle) : chaque jeu a son propre `directory` en base.

**Exception** : certains stores (Epic Games Store, EA App, Ubisoft Connect, potentiellement Battle.net) ne respectent pas ce principe. Lutris crée un **seul wineprefix partagé** par tous les jeux installés via le launcher de ce store — on appelle ça un **"giga-préfixe"** dans ce document. Dans ce cas, plusieurs lignes de la table `games` partagent la même valeur de `directory`.

**Steam est hors sujet** : les jeux Steam ne sont pas gérés par lpm du tout, ils vivent dans les fichiers propres à Steam, pas dans un wineprefix Lutris classique.

## État existant (déjà implémenté, à ne pas refaire)

La fonction `zgu_get_blacklisted_slugs()` (dans `lib/zgu-lutris-utils.sh`) détecte déjà les jeux vivant dans un giga-préfixe partagé (via `directory` dupliqué en base + une liste de mots-clés de secours) et les exclut des commandes `list`, `pack`, `uninstall` de lpm.

## Objectif de la feature

Pour un giga-préfixe donné contenant N jeux, produire **N wineprefix indépendants**, un par jeu, tels que :

1. Chaque nouveau préfixe contient une copie complète et fonctionnelle du launcher (Epic/EA/Ubisoft/etc.), avec ses credentials et sa session de connexion préservés — l'utilisateur ne doit pas avoir à se reconnecter.
2. Chaque nouveau préfixe ne contient **que le dossier du jeu concerné**, pas les dossiers des autres jeux du giga-préfixe d'origine.
3. Chaque nouveau préfixe est enregistré comme une **nouvelle ligne indépendante** dans la table `games` de Lutris, avec son propre `directory` (pointant vers ce nouveau préfixe, plus dupliqué).
4. Une fois cette nouvelle ligne créée, le jeu sort automatiquement de la détection `zgu_get_blacklisted_slugs()` (puisque son `directory` n'est plus dupliqué) et redevient visible/gérable par `list`, `pack`, `uninstall`.

## Contrainte technique identifiée : espace disque

Une copie naïve du wineprefix entier pour chaque jeu copierait aussi, à chaque instance, tous les dossiers des **autres** jeux du giga-préfixe. Pour N jeux, ça représenterait N× l'espace disque total du giga-préfixe avant tout nettoyage — inacceptable pour un giga-préfixe volumineux.

**Piste à explorer** : séparer conceptuellement deux parties du giga-préfixe :
- Le **"socle"** : tout ce qui appartient au launcher lui-même (binaires, config, credentials, session) — identique et à copier pour chaque instance.
- Le **"dossier de jeu"** : le sous-dossier propre à un jeu précis — à inclure uniquement dans l'instance correspondant à ce jeu, exclu de toutes les autres copies.

La stratégie exacte de séparation socle/jeu (exclusion à la copie, copie sélective, autre) reste à définir.

## Question ouverte, non résolue dans ce document

Comment identifier, pour un giga-préfixe donné, quel sous-dossier appartient à quel jeu (afin de l'exclure des copies des autres instances) ? La structure interne diffère probablement d'un launcher à l'autre (Epic ≠ EA ≠ Ubisoft ≠ Battle.net).
