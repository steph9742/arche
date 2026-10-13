# Architecture

## Le principe

Une machine de secours — « l'arche » — passe ses journées éteinte. Chaque nuit,
son horloge matérielle la réveille. Elle vérifie que la production est joignable
et saine, tire les sauvegardes, **s'en restaure réellement**, contrôle que les
services répondent, dépose un reçu chez la production, puis s'éteint.

```
                  réveil RTC 02:00
                         │
                  ┌──────▼───────┐   témoins, quorum, canaris
                  │  contrôles   │───────────────────────────► abstention
                  └──────┬───────┘        (dans le doute, rien)
                         │
   production ──rsync──► magasin (écriture unique)
                         │
                  ┌──────▼───────┐
                  │ restauration │  applications YunoHost, puis piles Docker
                  └──────┬───────┘
                         │
                  sonde des services ──► alerte si régression
                         │
                  reçu chez la production
                         │
                  extinction + réveil armé
```

Le point important n'est pas la sauvegarde : c'est que **la restauration a lieu
chaque nuit**. Un dispositif de reprise qu'on n'exerce pas est une hypothèse.

## Les deux rôles

Un seul code, deux installations. `ARCHE_ROLE` décide ce qui est installé :

| | production | arche (réplica) |
|---|---|---|
| Sauvegarde quotidienne YunoHost | ✔ | |
| Instantané des piles Docker | ✔ | |
| Canaris (création) | ✔ | |
| Contrôle des reçus, état publié | ✔ | |
| Réplication, restauration | | ✔ |
| Réveil et extinction automatiques | | ✔ |
| Dépôt de secours hors ligne | | ✔ |

Le script de nuit **éteint la machine** : le rôle « production » ne l'installe
donc jamais, et l'installation refuse ce rôle sur une machine portant les
marques d'un réplica.

## Le chemin des données

**1. La production se sauvegarde.** `yunohost_backup_daily.sh` produit une
archive `AAAAMMJJ-HHMMSS.tar` et son empreinte, puis `pra_docker_snapshot.sh`
produit un instantané `AAAAMMJJ-HHMMSS-docker.tar` contenant les compositions,
les variables d'environnement, les dumps de bases et les données montées.

**2. L'arche tire.** `rsync --ignore-existing` : le magasin est en écriture
unique. L'empreinte est vérifiée à l'arrivée ; un fichier qui ne correspond pas
est mis en quarantaine, pas supprimé.

**3. L'arche restaure.** `pra_restore_replica.sh` traite les applications
YunoHost — en relevant les domaines avant toute opération, car restaurer
l'annuaire LDAP ferait oublier au système les domaines propres au réplica — puis
enchaîne `pra_docker_restore.sh` pour les piles Docker.

**4. L'arche se juge.** Un verdict par volet dans `/var/lib/pra/*.json`, une
sonde d'accessibilité réelle des services, une comparaison à la veille.

**5. L'arche parle, puis se tait.** Reçu déposé chez la production, alarme
réarmée, extinction.

## Les deux volets de restauration

**Les applications YunoHost** savent se restaurer : l'outil les désinstalle puis
les restaure depuis l'archive, et corrige ensuite ce que la restauration ne sait
pas faire — URL transposées vers les domaines du réplica, certificats, URI de
retour du fournisseur d'identité, binaires compilés pour une autre architecture.

**Les piles Docker** n'ont aucune convention commune. L'outil fait le générique
— composition, environnement, images reconstruites localement, bases rechargées,
démarrage — et délègue le particulier à des adaptateurs de pile. Voir
[extension.md](extension.md).

Deux pièges structurent ce volet :

- `docker compose -f fichier.yml` **n'assemble pas** `docker-compose.override.yml`.
  La fusion n'a lieu que par découverte automatique, en se plaçant dans le
  répertoire. Or c'est l'override qui porte la liaison des ports sur la boucle
  locale et le montage de l'autorité interne.
- Une base PostgreSQL doit être **effacée avant d'être rechargée**. Sinon les
  `CREATE` échouent sur des tables déjà présentes, les erreurs passent pour
  bénignes, et le dump n'est jamais chargé. L'outil compte les tables obtenues :
  `psql` sort en 0 même quand tout a échoué.

## État et journaux

| Fichier | Contenu |
|---|---|
| `/var/lib/pra/status.json` | verdict du volet YunoHost, application par application |
| `/var/lib/pra/docker-status.json` | verdict du volet Docker, pile par pile |
| `/var/lib/pra/sante.json` | dernière sonde d'accessibilité, pour comparaison |
| `/var/lib/pra/recu-etat.json` | côté production : état des reçus de l'arche |
| `/var/log/pra_nightly.log` | déroulé de la nuit, un seul fichier à lire au réveil |

Les verdicts mesurent le **travail accompli**, pas le code de sortie : un script
qui s'arrête proprement au milieu sortirait en 0 et se déclarerait en succès.
Le nombre de piles attendues est donc comparé au nombre de piles traitées.

## L'interface web

FastAPI + Jinja, écoute sur `127.0.0.1`. Elle n'est **qu'un éditeur de
configuration** : arrêtée, la réplication continue à l'identique. Elle ne touche
jamais au système directement — un composant privilégié unique, appelé par
`sudo`, détient ce droit, revalide tout ce qu'elle envoie et journalise qui a
fait quoi dans un fichier qu'elle ne peut pas écrire elle-même.

## Le tableau de bord machine

Un service séparé, sans dépendance à l'interface web, affiche l'état physique :
batterie et autonomie, Wi-Fi, services, disques, température, et l'adresse à
laquelle joindre la page de secours — avec son QR code, parce que l'adresse
change quand la machine change de réseau.

## Ce qui ne dépend de rien

Le jour où tout est tombé, trois choses doivent fonctionner sans le reste :

- la **page de secours**, servie en HTTP simple sur un port dédié, sans
  authentification, qui dit où l'on est et quoi faire ;
- le **dépôt hors ligne** d'ISO et de manuels, qui ne dépend d'aucune
  restauration ;
- l'**accès de secours** à l'interface par mot de passe, car l'authentification
  unique repose sur une application restaurée, donc faillible.
