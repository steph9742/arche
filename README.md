# Arche — réplique hors ligne et plan de reprise pour YunoHost + Docker

Un serveur de secours qui se réveille seul chaque nuit, tire les sauvegardes
d'un serveur **YunoHost** de production, s'en restaure réellement — applications
YunoHost *et* piles Docker — puis s'éteint. S'il arrive quelque chose à la
production, la machine est déjà debout, à jour de la nuit, et sert les
applications.

> **Fait par la cellule cyber de l'UMLP, pour la cellule cyber de l'UMLP.**
> Conçu, développé et utilisé en production par la cellule cyber de l'Université Marie et
> Louis Pasteur (UMLP) pour ses propres besoins, puis publié sous licence MIT pour que
> d'autres équipes puissent le reprendre, l'adapter et le déployer chez elles.

> Restaurer une sauvegarde, personne ne sait vraiment le faire tant que personne
> ne l'a fait. Ici, la restauration a lieu **chaque nuit** : c'est le même geste
> qui sauvegarde et qui éprouve la sauvegarde.

## Ce que fait l'outil

- **Réplique** les archives de sauvegarde par `rsync` en **écriture unique**
  (`--ignore-existing`) : le magasin ne peut pas être réécrit depuis la
  production, donc pas chiffré à distance.
- **Restaure** les applications YunoHost et les piles Docker : compositions,
  variables d'environnement, images reconstruites pour l'architecture locale,
  rechargement des bases PostgreSQL, démarrage des piles.
- **Contrôle avant d'agir** : témoins et quorum, fichiers canaris, recherche de
  notes de rançon dans l'archive, taille comparée à la médiane, nombre
  d'applications, incompressibilité d'un échantillon. Au moindre doute, l'arche
  ne fait rien et conserve son dernier état bon.
- **Se réveille et s'éteint seule** par l'horloge matérielle (RTC), avec un
  filet qui garantit qu'une alarme future existe toujours.
- **Se surveille** : sonde l'accessibilité réelle des services après
  restauration, compare à la veille, alerte sur régression via Nextcloud Talk.
- **Donne signe de vie** : après chaque restauration, l'arche dépose un reçu
  chez la production, qui publie un état lisible sans authentification. C'est
  l'**absence** de reçu qui alerte.
- **Se pilote** par une interface web (FastAPI + Jinja) qui n'est qu'un éditeur
  de configuration : arrêtée, la réplication continue à l'identique.
- **Embarque un dépôt hors ligne** d'ISO et de manuels, pour travailler sans
  Internet le jour où il n'y a plus de réseau.
- **Affiche l'état de la machine** (batterie, Wi-Fi, services, disques,
  température) sur un tableau de bord local destiné à un petit écran.

## Principes de conception

Trois règles traversent tout le code et expliquent la plupart des choix :

1. **Le modèle est « pull ».** L'arche tire ; la production ne détient aucun
   identifiant vers l'arche et ne peut pas la joindre. C'est la protection de
   fond contre un rançongiciel. La seule chose qui sorte de l'arche est un reçu,
   sur un canal **en écriture seule**.
2. **Le magasin est en écriture unique.** Un fichier déjà présent n'est jamais
   réécrit. Un fichier douteux est mis en quarantaine, pas supprimé.
3. **Dans le doute, l'arche ne fait rien.** Un contrôle qui hésite s'abstient et
   le journalise. Un verdict qui alerte en permanence cesse d'être lu : les
   messages sont donc conçus pour ne parler que lorsqu'il y a lieu.

## Matériel de référence

Un Raspberry Pi 5 avec SSD NVMe, sur onduleur à batterie, dans une armoire, sur
un réseau isolé. Rien n'impose ce matériel : n'importe quelle machine Debian avec
une horloge RTC et YunoHost convient. Le tableau de bord de la machine sait en
plus lire un onduleur à jauge I²C.

## Installation

```bash
sudo ARCHE_ROLE=arche ./scripts/install.sh          # sur le réplica
sudo ARCHE_ROLE=production ./scripts/install.sh     # sur le serveur sauvegardé
```

L'installation est **idempotente** et refuse le rôle « production » sur une
machine qui porte les marques d'un réplica : le script de nuit éteint la
machine, l'installer sur un serveur en service serait une faute.

Voir [`doc/installation.md`](doc/installation.md) pour les prérequis, la
configuration et la mise en route pas à pas.

## Configuration

Tout vit dans `/etc/pra/pra.conf` (root, 600), lu par les scripts et édité par
l'interface web. Les réglages propres à une installation — adresses, comptes,
applications à restaurer, piles Docker, seuils — y sont déclarés ; rien n'est
codé en dur dans les scripts.

Quelques fichiers de liste et un point d'extension par pile permettent
d'accueillir des applications particulières sans modifier l'outil. Des exemples
commentés sont fournis dans [`exemples/`](exemples) :

| Mécanisme | Rôle |
|---|---|
| `/etc/pra/applications.list` | où chaque application YunoHost doit répondre **sur le réplica** |
| `/etc/pra/applications-exclues.list` | ce qu'on ne restaure pas, et pourquoi |
| `/etc/pra/piles.list` | les piles Docker à prendre en instantané |
| `/etc/pra/dependances.list` | l'unité dont une application a besoin au démarrage |
| `/etc/pra/adaptateurs/<pile>.sh` | ajustements propres à une pile Docker : réécriture d'URL, autorité interne, secrets |
| `PRA_DOCKER_PORTS` | liaison des ports publiés sur la boucle locale |
| `PRA_DOCKER_DONNEES`, `PRA_DOCKER_BASES` | destinations des données montées, conteneurs PostgreSQL |
| `PRA_PERMS_VISITEURS` | permissions rouvertes aux visiteurs, pour les portes de secours |

La **page de secours** est engendrée à partir de
[`gabarits/page-secours.html`](gabarits/page-secours.html). Les pages propres à
une organisation — guide, mode opératoire, annuaire imprimable — se déposent
dans `/var/www/arche-secours` : elles sont alors servies par les deux portes,
sans rien à déclarer. L'outil n'en fournit aucune.

## Documentation

| Document | Pour |
|---|---|
| [doc/architecture.md](doc/architecture.md) | comprendre le dispositif avant de le modifier |
| [doc/installation.md](doc/installation.md) | installer, configurer, mettre en route |
| [doc/exploitation.md](doc/exploitation.md) | exploiter au quotidien, lire les journaux, traiter un incident |
| [doc/securite.md](doc/securite.md) | modèle de menace, secrets, contrôles périodiques |
| [doc/extension.md](doc/extension.md) | adapter l'outil à ses propres applications |

## Tests

```bash
python3 -m venv .venv && .venv/bin/pip install -e . pytest
.venv/bin/pytest tests/ -q
```

La suite vérifie le code réel des scripts, pas une reconstitution : extraits de
fonctions shell exécutés, configuration nginx analysée, `shellcheck` sur tous les
scripts.

Plusieurs tests exigent des outils GNU (`find -printf`, `stat -c`, `date -d`,
`flock`) et sont **ignorés** ailleurs. Un test ignoré n'est pas un test passé :
sous macOS, les exécuter dans un conteneur Debian.

```bash
docker run --rm -v "$PWD:/depot:ro" python:3-slim bash -c \
  'cp -r /depot /w && cd /w && rm -rf .venv && pip install -q -e . pytest \
   && python -m pytest tests/ -q'
```

Quatre échecs y sont **normaux** et propres au conteneur, pas des défauts : il
tourne en root — le refus de tourner sans privilège ne peut donc pas se
produire —, son `python3` vit hors du PATH minimal que les tests imposent
exprès, et il n'a pas d'horloge RTC.

## Licence et provenance

[MIT](LICENSE) — © 2026 Université Marie et Louis Pasteur.

Un des outils de la **cellule cyber de l'UMLP**, écrits pour ses propres besoins et
publiés ensemble :

| Outil | Rôle |
|---|---|
| **Slowpoke** | gestion des incidents de cybersécurité |
| **Catalogue** | cartographie du SI et conformité cyber |
| **Assistants IA** | réponses sourcées sur le corpus de procédures, analyse de journaux |
| **Astreintes** | planning et heures d'astreinte de l'équipe |
| **Gestion de crise cyber** | conduite d'une crise d'origine cyber : main courante, décisions, communications, exercices |
| **Arche** (ce dépôt) | réplique hors ligne et plan de reprise YunoHost + Docker |
| **Bureautix Fleet** | parc de postes de travail NixOS durcis, multi-entités — *expérimental, en cours* |
