# Installation

## Prérequis

**Les deux machines** tournent sous Debian avec YunoHost, et la machine de
secours a besoin d'une **horloge matérielle (RTC)** capable d'armer un réveil :
c'est elle qui rallume la machine chaque nuit.

| | production | arche (réplica) |
|---|---|---|
| YunoHost | ✔ | ✔ |
| `rsync`, `flock`, `python3` | ✔ | ✔ |
| Docker + greffon `compose` | si des piles Docker sont à répliquer | ✔ |
| `/sys/class/rtc/rtc0/wakealarm` | | ✔ |
| Espace disque | — | plusieurs fois la taille d'une archive |

Sur un Raspberry Pi, vérifier que le micrologiciel coupe réellement
l'alimentation à l'extinction, sans quoi le réveil par l'horloge ne peut pas
fonctionner :

```bash
rpi-eeprom-config | grep POWER_OFF_ON_HALT   # doit valoir 1
```

Ce réglage vit dans la carte, **pas sur le disque** : il est à refaire si l'on
change de carte en gardant le même disque.

## Accès de l'arche à la production

L'arche se connecte à la production ; **jamais l'inverse**. Créer sur la
production un compte dédié, lui donner accès en lecture au répertoire des
sauvegardes, et déposer la clé publique de `root` de l'arche :

```bash
# sur la production
sudo adduser --disabled-password --gecos "réplication PRA" pra
sudo install -d -m 700 -o pra -g pra /var/lib/pra/recus-arche
```

Le second répertoire reçoit les **reçus** que l'arche dépose après chaque
restauration. Il doit être inscriptible par ce compte, et par lui seul.

> Ne donnez pas à ce compte de droits `sudo` sur la production. L'arche n'en a
> pas besoin : elle lit des fichiers et dépose un reçu.

## Installation

```bash
git clone <ce dépôt> arche && cd arche
sudo ARCHE_ROLE=production ./scripts/install.sh    # sur la production
sudo ARCHE_ROLE=arche      ./scripts/install.sh    # sur le réplica
```

L'installation est idempotente : on la relance à chaque mise à jour. Elle
conserve la configuration existante, ne réactive pas une minuterie que vous
avez délibérément arrêtée, et **refuse le rôle « production »** sur une machine
portant les marques d'un réplica — le script de nuit éteint la machine.

Le dépôt est à garder dans un **répertoire permanent** : `/tmp` est vidé au
démarrage, et une mise à jour suivie d'un redémarrage laisserait l'installateur
introuvable.

## Configuration

Tout vit dans `/etc/pra/pra.conf` (root, 600). Le fichier emploie
`: "${VAR:=valeur}"`, donc une variable passée sur la ligne de commande reste
prioritaire. L'interface web est un éditeur de ce fichier ; on peut aussi
l'écrire à la main.

### Le minimum pour que la nuit se déroule

```sh
: "${PRA_SERVER1:=192.0.2.10}"        # adresse de la production, par IP
: "${PRA_PROD_USER:=pra}"             # compte SSH sur la production
: "${PRA_WITNESSES:=192.0.2.10 192.0.2.11}"   # machines témoins
: "${PRA_QUORUM_MIN:=2}"              # en dessous : incident large, on s'abstient
```

**Par adresse IP, jamais par nom.** Les domaines de la production sont restaurés
sur l'arche comme domaines YunoHost : son résolveur local les renvoie alors vers
elle-même, et l'arche se parlerait à elle-même en croyant joindre la production.

### Ce qui est restauré

```sh
: "${PRA_RESTORE_APPS:=}"             # vide = toutes les applications de l'archive
: "${PRA_DOCKER_STACKS:=}"            # vide = toutes les piles de l'instantané
: "${PRA_DOCKER_PORTS:=}"             # pile:port — liaison sur 127.0.0.1
: "${PRA_DOMAINE_PRINCIPAL:=}"        # nom principal du réplica
: "${PRA_DOMAINES_LOCAUX:=}"          # ses autres noms, pour la ligne « hosts »
: "${PRA_PERMS_VISITEURS:=}"          # permissions à rouvrir aux visiteurs
```

Les listes acceptent espaces et virgules.

### Où les applications doivent répondre

Quatre fichiers de liste complètent la configuration. Ils sont facultatifs —
absents, le mécanisme correspondant se tait et le journal le dit — mais le
premier décide de **l'accessibilité du réplica le jour où il sert** :

| Fichier | Contenu |
|---|---|
| `/etc/pra/applications.list` | `app\|domaine\|chemin` : où chaque application doit répondre sur le réplica |
| `/etc/pra/applications-exclues.list` | `app: raison` : ce qu'on ne restaure pas, et pourquoi |
| `/etc/pra/piles.list` | les piles Docker à prendre en instantané, côté production |
| `/etc/pra/dependances.list` | `app\|unité` : ce dont une application a besoin au démarrage |

Des exemples commentés sont dans [`exemples/`](../exemples). Pour une machine
qui sert déjà, `sudo PRA_LISTER=1 pra_restore_replica.sh` sort une première
table au bon format, à relire et corriger. Détails et pièges :
[extension.md](extension.md).

Voir [extension.md](extension.md) pour les piles qui demandent un traitement
particulier.

### Rétention

```sh
: "${PRA_GFS_JOURS:=4}"               # jours distincts conservés
: "${PRA_GFS_LUNDIS:=2}"
: "${PRA_GFS_MOIS:=3}"                # premiers du mois
: "${PRA_KEEP_MIN:=5}"                # plancher, quel que soit l'âge
: "${PRA_PURGE_APPLIQUER:=1}"         # 0 = compte rendu sans supprimer
```

Garder quelques jalons anciens porte la profondeur à plusieurs mois : c'est ce
qui protège d'un chiffrement passé inaperçu plus longtemps que la profondeur
quotidienne. Attention au mode « compte rendu seul » : laissé en place, il
remplit le disque et la restauration s'arrêtera un jour faute de place.

### Alertes

```sh
: "${NC_TALK_URL:=https://nextcloud.exemple.org}"
: "${NC_TALK_ROOM:=jeton_de_la_conversation}"
: "${NC_TALK_SECRET:=secret_du_bot}"
: "${NC_TALK_IP:=192.0.2.10}"
```

Sans ces valeurs, **aucun échec ne sera signalé**. Le destinataire vit sur la
production : en cas de sinistre majeur, le message n'arrivera pas — le journal
local fait foi.

## Mise en route

```bash
# 1. répliquer sans rien restaurer, pour voir arriver les fichiers
sudo PRA_DRY_RUN=1 pra_nightly.sh

# 2. une restauration en validation : contrôles complets, rien de destructif
sudo PRA_DRY_RUN=1 pra_restore_replica.sh

# 3. la vraie, une fois les contrôles passés
sudo pra_restore_replica.sh
```

Puis éprouver le cycle complet, qui est le cœur du dispositif :

```bash
# arme un réveil à deux minutes, puis éteint
sudo sh -c 'date -d "+2 minutes" +%s > /sys/class/rtc/rtc0/wakealarm; halt'
```

Si la machine se rallume seule, l'essentiel fonctionne.

## Exposer l'interface

L'interface écoute sur `127.0.0.1:8770`. L'exposer derrière le mandataire de
YunoHost, restreinte au groupe des administrateurs, et laisser
`ARCHE_AUTH_MODE=proxy`.

Prévoir **aussi** un accès de secours par mot de passe : l'authentification
unique repose sur une application restaurée, donc susceptible d'être cassée
précisément le jour où l'on a besoin de l'interface.

```bash
ARCHE_AUTH_MODE=password
ARCHE_ADMIN_PASSWORD_HASH=$(/opt/arche/.venv/bin/python -c \
  "from app.security import hash_password; print(hash_password('mot-de-passe'))")
```

## Après l'installation

- Déployer les **canaris** sur la production (`pra_canaries.sh deployer`), puis
  enregistrer leurs empreintes depuis l'arche (`pra_canaries.sh rebaser`).
- Vérifier que la minuterie est **activée**, et pas seulement active : une
  minuterie active mais désactivée ne survivra pas au redémarrage.
- Déposer `/etc/pra/applications.list` **avant la première restauration
  réelle** : sans elle, les applications restent sur les domaines de production,
  donc inaccessibles depuis le réplica.
- Déposer les pages de crise propres à l'organisation — guide, mode opératoire,
  annuaire imprimable — dans `/var/www/arche-secours` : elles sont servies par
  les deux portes, à condition que leurs liens soient **relatifs**.
- Lire [exploitation.md](exploitation.md) pour les journaux et les incidents
  courants.
