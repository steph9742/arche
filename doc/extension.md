# Adapter l'outil à ses propres applications

L'arche restaure deux mondes : les applications **YunoHost**, qui savent se
restaurer elles-mêmes, et les **piles Docker**, qui n'ont aucune convention
commune. Pour ces dernières, l'outil fait le travail générique — composition,
variables d'environnement, images reconstruites, bases rechargées, démarrage —
et laisse à l'exploitant ce qui ne peut pas être devin : ce que chaque
application attend d'un réplica.

Rien de propre à une application n'est codé dans les scripts : tout passe par
`/etc/pra/pra.conf` et par quelques fichiers de liste, dont des exemples
commentés sont fournis dans [`exemples/`](../exemples).

## 0. Déclarer ses applications, ses piles et ses noms

Ces fichiers sont lus à chaque passage ; une ligne vide ou commençant par `#`
est ignorée. **Un fichier absent n'est pas une erreur** : le mécanisme
correspondant se tait, le journal le dit, et la nuit se déroule sans lui.

| Fichier | Contenu | Exemple fourni |
|---|---|---|
| `/etc/pra/applications.list` | `app\|domaine\|chemin` — où chaque application YunoHost doit répondre **sur le réplica** | [applications.list](../exemples/applications.list) |
| `/etc/pra/applications-exclues.list` | `app: raison` — applications présentes dans l'archive qu'on ne restaure pas, avec le motif | [applications-exclues.list](../exemples/applications-exclues.list) |
| `/etc/pra/piles.list` | une pile Docker par ligne, ses chemins et ses bases — c'est ce fichier qui dit à la production **quoi** mettre dans l'instantané | [piles.list](../exemples/piles.list) |
| `/etc/pra/dependances.list` | `app\|unité` — l'unité dont une application a besoin au démarrage, quand son paquet ne le déclare pas | [dependances.list](../exemples/dependances.list) |

### `applications.list` — la transposition des URL

C'est la pièce centrale de la restauration YunoHost. L'archive porte les
domaines de **production** ; le réplica, lui, sert sur ses propres noms. Après
restauration, l'outil replace chaque application à l'adresse déclarée ici :

```
nextcloud|replica.local|/nextcloud
wiki|wiki.local|/
coturn|replica.local|
```

Un **chemin vide** signifie « pas d'URL web » : l'application est restaurée,
mais aucune transposition n'est tentée. Sans ce fichier, les applications
restent sur les domaines de production — donc **inaccessibles depuis le réplica
le jour où elles servent**, puisque ces domaines pointent alors vers une machine
morte. L'outil l'avertit à chaque nuit plutôt que de le deviner, et refuse de
continuer si un domaine d'origine manque à l'annuaire.

> **Première installation.** Sur une machine qui sert déjà, la liste n'a pas à
> être écrite à la main : `sudo PRA_LISTER=1 pra_restore_replica.sh` sort une
> table au bon format — celle du fichier s'il existe, sinon celle que YunoHost
> déclare, application par application. Ce mode n'écrit rien et sort avant le
> premier accès réseau. Il reste à relire la sortie, à corriger les domaines
> pour ceux du réplica, puis à la déposer.

### Les noms du réplica

```sh
: "${PRA_DOMAINE_PRINCIPAL:=replica.local}"
: "${PRA_DOMAINES_LOCAUX:=wiki.local kiwix.local}"
```

Le premier sert de repli partout où un nom est nécessaire sans pouvoir être
déduit ; le second alimente la **ligne `hosts`** proposée par la page de secours,
pour qui veut joindre les applications par leur nom sans DNS. Les deux sont
facultatifs : non déclarés, la page affiche un gabarit à compléter plutôt qu'une
adresse fausse.

### Les portes de secours

Une application qui s'authentifie elle-même peut offrir une entrée par mot de
passe pour le jour où le fournisseur d'identité ne répond plus. Mais la
restauration rapporte la permission de la production, où elle est réservée aux
utilisateurs authentifiés : SSOwat intercepte alors la requête et renvoie au
portail — on n'atteint jamais la porte de secours, qui n'existe que pour le cas
où le portail est mort.

```sh
: "${PRA_PERMS_VISITEURS:=}"          # identifiants YunoHost, séparés par des espaces
```

Les permissions nommées ici sont rouvertes aux visiteurs **à chaque
restauration**. Vide par défaut : rien n'est ouvert sans déclaration explicite.
Ce n'est pas une ouverture au sens large — l'application demande ses propres
identifiants derrière — mais cela reste une décision de sécurité, donc explicite.

## 1. Lier les ports à la boucle locale

Les compositions venues de la production publient souvent leurs ports sur toutes
les interfaces. Sur un réplica joignable depuis le réseau, c'est une exposition
dont on ne veut pas.

```sh
PRA_DOCKER_PORTS="monapp:8077 wiki:3010"
```

L'outil écrit alors un `docker-compose.override.yml` qui republie le port sur
`127.0.0.1`. Le service visé est détecté : c'est celui qui publie déjà ce port.

> **Pourquoi un override et non une modification du compose ?** Le compose vient
> de la production et sera remplacé à la prochaine nuit. Un override est
> reconstruit à chaque restauration, donc jamais perdu.

## 2. Déclarer les données montées et les bases

Une pile peut garder ses données hors des volumes Docker, dans un répertoire
monté. L'instantané les apporte, mais la destination dépend de la composition :

```sh
PRA_DOCKER_DONNEES="monapp-data:/srv/monapp uptime:/docker/uptime"
```

Une archive sans destination déclarée est **signalée et non extraite** : déplier
une arborescence au hasard serait pire que de ne rien faire.

De même, le nom du conteneur PostgreSQL ne se déduit pas du nom du dump. L'outil
tente `<pile>-postgres-1`, la forme usuelle de Compose ; sinon on le déclare :

```sh
PRA_DOCKER_BASES="notes:notes_postgres"
```

## 3. Écrire un adaptateur de pile

Pour tout le reste — URL codées en dur dans la composition, autorité de
certification interne, URI de retour OIDC, droits d'un fichier de secret —
l'outil source `/etc/pra/adaptateurs/<pile>.sh` après avoir mis la composition
en place et avant de construire les images.

L'adaptateur dispose de :

| Variable / fonction | Contenu |
|---|---|
| `$name` | nom de la pile |
| `$dir` | son répertoire (composition, `.env`, `.secrets`) |
| `$WORK` | instantané déplié |
| `$ROOT` | racine des piles |
| `$CA_PUB` | copie lisible de l'autorité interne, si elle a été extraite |
| `log`, `warn` | journalisation |
| `run` | exécution respectant le mode « à blanc » |
| `override` | ajout au `docker-compose.override.yml` |
| `extraire_ca_yunohost` | extraction et vérification de l'autorité interne |

Il est **sourcé**, pas exécuté : il voit ces fonctions et peut modifier les
fichiers de la pile. Il tourne en root, comme le script appelant — n'y mettre
que du code dont on répond.

### Exemple : une application servie sous un sous-chemin

```sh
# /etc/pra/adaptateurs/monapp.sh
dom="$(yunohost app setting monapp domain 2>/dev/null || hostname)"

# L'URL publique change : l'application construit ses liens avec.
sed -i "s|^PUBLIC_URL=.*|PUBLIC_URL=https://$dom/monapp|" "$dir/.env"

# Le conteneur tourne sous un compte non privilégié et ne peut pas lire
# l'autorité interne de YunoHost : on lui en monte une copie lisible.
extraire_ca_yunohost "$dom"
override monapp 8080 "NODE_EXTRA_CA_CERTS: /ca/interne.pem"
```

### Deux pièges que l'adaptateur doit connaître

**Compose fusionne les listes.** Un `extra_hosts` ou un `ports` déclaré dans
l'override **s'ajoute** à celui du compose d'origine ; les entrées de production
survivent. Il faut `!override` pour les remplacer :

```yaml
services:
  app:
    extra_hosts: !override
      - "serveur.interne:host-gateway"
```

**Une adresse injoignable ne refuse pas, elle attend.** Si une composition code
en dur l'adresse d'un service de production, sur un réseau isolé les requêtes
n'échouent pas : elles expirent. Le rendu côté serveur gèle, les fichiers
statiques passent, et rien n'apparaît dans les journaux. C'est long à
diagnostiquer — autant réécrire ces adresses dès l'adaptateur.

## 4. Choisir ce qui est restauré

```sh
PRA_RESTORE_APPS="dex nextcloud monapp"   # vide = toutes celles de l'archive
PRA_DOCKER_STACKS="monapp notes"          # vide = toutes celles de l'instantané
```

Les deux listes acceptent les espaces comme les virgules. La sélection porte sur
l'inventaire de la **veille** : une pile choisie aujourd'hui et absente de
l'instantané du jour est ignorée avec une trace, sans faire échouer la nuit.

## Tâches ponctuelles et dépendances

Une pile qui déclare `depends_on: migrate: service_completed_successfully`
relance sa migration à chaque démarrage. Sur un réplica, la base porte déjà le
schéma restauré : la migration échoue, la condition n'est pas remplie, et les
services qui en dépendent ne démarrent pas du tout — la pile reste à terre pour
une tâche qui a pourtant fait son travail.

L'outil le détecte : il repart service par service, sans les dépendances, en
sautant précisément les tâches dont une condition d'achèvement dépend. Il n'y a
donc rien à faire, mais il faut le savoir pour ne pas s'étonner de voir une pile
démarrer « à 5 services sur 6 ».
