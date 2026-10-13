# YunoBox

Tableau de bord local pour Raspberry Pi 5 + Waveshare UPS HAT (E) sous YunoHost.
Batterie et autonomie, réseaux WiFi, services YunoHost avec **yunomdns en tête**,
occupation des disques. Plus un hook qui relance `yunomdns` à chaque changement
de réseau, sans quoi les noms `.local` cessent de résoudre.

Sert aussi de **base pour l'écran tactile** : l'interface est dessinée pour du
800 × 480, la résolution des dalles 4,3" et 5", et s'étale sur desktop.

## Installation

```bash
scp -r yunobox root@rssi:/root/
ssh root@rssi 'cd /root/yunobox && ./install.sh'
```

Le script vérifie les prérequis, installe dans `/opt/yunobox`, génère un jeton,
pose le hook NetworkManager, active le service et lance un autotest. Il affiche
l'URL complète avec le jeton à la fin.

Pour installer sans le hook mDNS : `./install.sh --no-hook`.

## Ce qu'il faut savoir avant de l'exposer

**Le service tourne en root.** Il n'y a pas d'échappatoire : lire l'I2C du HAT,
piloter `nmcli`, redémarrer des services et interroger la CLI `yunohost`
demandent ces droits. L'accès est protégé par un **jeton** dans
`/etc/yunobox/token` (mode 0600), exigé sur toutes les routes `/api/*`.

Le jeton passe par l'en-tête `X-Auth-Token`, pas par un cookie — ce qui immunise
au passage contre le CSRF, puisqu'un site tiers ne peut pas le forger.

Cela reste un **outil de LAN**. Ne l'expose pas sur Internet, ni derrière le
reverse-proxy YunoHost, sans y ajouter une vraie authentification. Zéro
dépendance hors `python3-smbus` : rien n'est installé dans l'environnement
Python de YunoHost.

## Le hook de relance de yunomdns

C'est la partie qui répond au problème des `.local` qui tombent après un
changement de réseau. Deux morceaux :

**`/etc/NetworkManager/dispatcher.d/99-yunobox-mdns`** — appelé par
NetworkManager à chaque événement réseau. Il filtre sur `up`, `dhcp4-change`,
`dhcp6-change` et `connectivity-change`, ignore `lo`, **anti-rebondit** sur une
fenêtre de 15 s (NetworkManager émet plusieurs événements pour une seule
bascule), puis détache le travail réel. Ce détachement est indispensable :
NetworkManager tue les scripts dispatcher trop longs.

**`/usr/local/sbin/yunobox-mdns-refresh`** — attend que l'interface ait vraiment
une adresse IPv4, 30 s au maximum, laisse une seconde à la résolution pour se
stabiliser, puis relance `yunomdns`. Relancer avant l'adressage ne servirait à
rien : le service republierait sur une pile réseau incomplète.

Le résultat est journalisé et écrit dans `/var/lib/yunobox/mdns-last`, que
l'interface web affiche sous « Dernière relance auto ».

```bash
journalctl -t yunobox-mdns -f              # suivre les relances
/usr/local/sbin/yunobox-mdns-refresh wlan0 manuel   # forcer
```

Sous `systemd-networkd` au lieu de NetworkManager, le dispatcher ne sera pas
installé — il faudrait passer par `networkd-dispatcher`. Le worker, lui, reste
appelable à la main.

## API

Toutes les routes exigent l'en-tête `X-Auth-Token`.

| Route | Méthode | Rôle |
|---|---|---|
| `/api/etat` | GET | batterie, autonomie, cellules, température CPU, charge, bridage |
| `/api/disques` | GET | volumes, occupation, températures NVMe |
| `/api/wifi` | GET | connexion active, interfaces, profils, dernier scan |
| `/api/wifi/scan` | GET | force un nouveau scan |
| `/api/wifi/connect` | POST | `{ssid, password, interface}` |
| `/api/services` | GET | services YunoHost + bloc `mdns` détaillé |
| `/api/services/restart` | POST | `{nom}` |
| `/api/mdns` | GET | état yunomdns, domaines `.local`, état du hook |
| `/api/mdns/restart` | POST | relance yunomdns |

Les lectures sont mises en cache : 2 s pour la batterie, 3 s pour le système,
8 s pour les services, 20 s pour les disques, 30 s pour le scan WiFi. Cela évite
de marteler l'I2C et de relancer un scan à chaque rafraîchissement.

## Deux pièges du UPS HAT (E) encodés dans le code

Ils m'ont coûté une longue séance de diagnostic, autant que le programme les
connaisse :

1. **Le bit IP2368 du registre `0x03` tombe à 0 quand aucun chargeur n'est
   branché** — la puce est côté Type-C, elle dort sans entrée. C'est normal.
   L'interface ne signale une erreur que si VBUS est présent, sinon elle affiche
   « endormie (normal sans entrée USB-C) ».
2. **Les lectures octet par octet peuvent renvoyer un NACK** (`OSError 121`)
   quand le pin 5 V débite à côté des lignes SDA/SCL. D'où les relances, et une
   **lecture en bloc unique** pour les quatre tensions de cellule.

Le registre `0x02` ne remonte rien d'utile quand VBUS est absent : les zéros
sont alors des valeurs correctes, pas une panne.

## Autotest

```bash
python3 /opt/yunobox/yunobox.py --selftest
```

Vérifie chaque source de données et dit laquelle échoue. C'est le premier
réflexe si l'interface affiche des tirets.

## État de la vérification

Ce que j'ai testé, sur macOS, sans le matériel :

- syntaxe validée : `yunobox.py`, les deux scripts shell, `install.sh`
- serveur démarré, page servie, aucune erreur console
- authentification : 401 sans jeton, 200 avec
- `/api/etat`, `/api/wifi`, `/api/services` renvoient du JSON valide
- dégradation propre quand l'I2C, `nmcli` et la CLI `yunohost` sont absents :
  messages d'erreur structurés, aucun plantage
- interface rendue en 800 × 480

Ce que je **n'ai pas pu** tester, faute d'accès au Pi : la lecture réelle des
registres, `nmcli`, la CLI `yunohost`, et le déclenchement du hook par
NetworkManager. Lance `--selftest` juste après l'installation, c'est fait pour
ça.

## Idées pour la suite

- **Watchdog matériel** du HAT (`0x40` bit 1, délai dans `0x42`) : le MCU
  redémarre le Pi si le noyau se fige. Non exploité pour l'instant, mais c'est
  la fonction la plus utile qui reste dans le jeu de registres.
- Le HAT **n'expose aucune température de cellule** : angle mort à garder en
  tête dans un boîtier fermé.
- Historisation des mesures pour tracer des courbes de décharge, utile pour
  valider le budget de 4 h avec l'écran.
