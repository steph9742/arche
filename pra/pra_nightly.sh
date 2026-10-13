#!/bin/bash
###############################################################################
# PRA Nightly — orchestrateur du réplica                             version 2
#
# Vérifie le réseau, programme le réveil RTC, lance la restauration, éteint.
#
# Différences majeures avec la v1, et pourquoi :
#
#  1. LE RÉVEIL EST GARANTI. Écrire l'alarme RTC en début de script sans la
#     remettre à zéro d'abord ne suffit pas : une alarme déjà armée fait échouer
#     l'écriture (EBUSY), et sous « set -e » le script avorte AVANT d'avoir
#     programmé quoi que ce soit ni éteint — machine allumée toute la nuit sur
#     batterie, et aucun réveil le lendemain. Ici l'alarme est armée dans un
#     trap, donc même en cas d'échec, de coupure réseau ou d'erreur de
#     restauration.
#
#  2. L'EXTINCTION EST GARANTIE elle aussi, par le même trap. Sur une machine
#     sur batterie, un script qui meurt sans éteindre vide le pack.
#
#  3. VALIDATION D'ABORD. La restauration ne détruit le réplica que si
#     l'archive est vérifiée. Voir pra_restore_replica.sh.
#
#  4. Plus de rsync en double : la récupération est faite une seule fois, par
#     le script de restauration.
#
# Usage :
#   pra_nightly.sh                    exécution normale (éteint à la fin)
#   PRA_NO_HALT=1 pra_nightly.sh      pour tester sans éteindre la machine
#   PRA_DRY_RUN=1 pra_nightly.sh      valide l'archive sans rien restaurer
###############################################################################
set -uo pipefail

# ─── Configuration commune ───────────────────────────────────────────────────
# Éditée par la webapp Arche, lue par les scripts. La webapp n'est qu'un éditeur :
# si elle est absente ou cassée, la réplication continue exactement pareil.
# Le fichier emploie « : "${VAR:=valeur}" », qui n'affecte QUE les variables non
# définies : une variable passée à la main sur la ligne de commande reste donc
# prioritaire (PRA_DRY_RUN=1, PRA_ONLY=…).
# shellcheck source=/dev/null
[ -r "${PRA_CONF:-/etc/pra/pra.conf}" ] && . "${PRA_CONF:-/etc/pra/pra.conf}"


LOG="/var/log/pra_nightly.log"
STATE_DIR="/var/lib/pra"
LOCK="/run/pra_nightly.lock"
# Un SEUL emplacement d'installation : /usr/local/sbin, celui de install.sh.
# Deux copies qui coexistent — un répertoire historique et celui-ci — et l'unité
# systemd qui lance l'ancienne suffisent à ce que les contrôles
# anti-rançongiciel soient installés mais NE TOURNENT PAS. Un script à jour au
# mauvais endroit ne protège de rien.
SBIN="${PRA_SBIN:-/usr/local/sbin}"
RESTORE="${PRA_RESTORE_BIN:-$SBIN/pra_restore_replica.sh}"
DOCKER_RESTORE="${PRA_DOCKER_RESTORE_BIN:-$SBIN/pra_docker_restore.sh}"
GITLAB_EXTRACT="${PRA_GITLAB_EXTRACT_BIN:-$SBIN/pra_gitlab_extract.sh}"
FORGEJO_SYNC="${PRA_FORGEJO_SYNC_BIN:-$SBIN/pra_forgejo_sync.sh}"
RECU="${PRA_RECU_BIN:-$SBIN/pra_recu.sh}"

# Production (source des sauvegardes) et second témoin, à déclarer dans pra.conf.
# Viser la production PAR IP : ses domaines sont restaurés ici et le résolveur
# local les renverrait vers le réplica lui-même.
SERVER1="${PRA_SERVER1:-}"
SERVER2="${PRA_SERVER2:-}"
PING_TIMEOUT=5

# Témoins interrogés avant toute réplication. Par défaut les deux serveurs
# connus ; en ajouter d'autres rend le quorum plus significatif (un commutateur,
# une baie, un hyperviseur…). PRA_WITNESSES accepte une liste séparée d'espaces.
read -r -a WITNESSES <<< "${PRA_WITNESSES:-$SERVER1 $SERVER2}"
# Minimum de témoins devant répondre. Par défaut la majorité stricte.
QUORUM_MIN="${PRA_QUORUM_MIN:-$(( ${#WITNESSES[@]} / 2 + 1 ))}"

# Canaris : manifeste d'empreintes généré par « pra_canaries.sh rebaser ».
CANARIES_BIN="${PRA_CANARIES_BIN:-/usr/local/sbin/pra_canaries.sh}"
CANARY_MANIFEST="${PRA_CANARY_MANIFEST:-/etc/pra/canaries.list}"

NOTIFY="${PRA_NOTIFY_BIN:-/usr/local/sbin/pra_notify.sh}"
# Best effort et jamais bloquant : une alerte qui ne part pas ne doit pas
# empêcher une réplication qui, elle, fonctionne.
notifier() { [ -x "$NOTIFY" ] && "$NOTIFY" "$@" >/dev/null 2>&1 || true; }
WAKE_AT="${PRA_WAKE_AT:-02:00 tomorrow}"
NO_HALT="${PRA_NO_HALT:-0}"

# Fenêtre horaire d'exécution automatique, en heures pleines.
#
# L'unité systemd est WantedBy=multi-user.target : elle se déclenche donc à
# CHAQUE démarrage. Sans garde-fou, allumer la machine pour une intervention
# lançait une restauration puis une extinction — ce qui explique très
# probablement pourquoi le service avait fini par être désactivé, laissant le
# PRA sans aucune exécution automatique.
#
# Hors de cette fenêtre, le script ne fait rien et n'éteint pas : un démarrage
# de maintenance est donc sans effet. PRA_FORCE=1 passe outre.
WINDOW_START="${PRA_WINDOW_START:-1}"
WINDOW_END="${PRA_WINDOW_END:-5}"
FORCE="${PRA_FORCE:-0}"

mkdir -p "$STATE_DIR"
exec >> "$LOG" 2>&1

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

# Sans adresse de production, il n'y a rien à tirer : on s'abstient plutôt
# que de lancer des transferts vers un hôte vide, qui échoueraient un à un
# en donnant l'apparence d'une panne réseau.
if [ -z "$SERVER1" ]; then
  log "PRA_SERVER1 non défini dans ${PRA_CONF:-/etc/pra/pra.conf} — nocturne abandonné"
  exit 1
fi

### ─── VERROU ───────────────────────────────────────────────────────────────
exec 9>"$LOCK"
if ! flock -n 9; then
  log "Une autre exécution est déjà en cours — abandon."
  exit 0
fi

### ─── FENÊTRE HORAIRE ──────────────────────────────────────────────────────
# Contrôlée AVANT d'installer le trap : hors fenêtre on sort sans armer le
# réveil ni éteindre, pour ne pas interférer avec une intervention manuelle.
HOUR="$(date +%-H)"
if [ "$FORCE" != 1 ] && { [ "$HOUR" -lt "$WINDOW_START" ] || [ "$HOUR" -ge "$WINDOW_END" ]; }; then
  log "Démarrage à ${HOUR}h, hors de la fenêtre ${WINDOW_START}h-${WINDOW_END}h."
  log "Rien n'est fait : ce démarrage est considéré comme une intervention."
  log "Pour forcer malgré tout : PRA_FORCE=1 $0"
  exit 0
fi

### ─── RÉVEIL ET EXTINCTION GARANTIS ────────────────────────────────────────
arm_wakealarm() {
  local target
  target="$(date -d "$WAKE_AT" +%s)" || { log "date invalide : $WAKE_AT"; return 1; }
  # UNE ALARME DANS LE PASSÉ NE SONNE JAMAIS, ET RIEN NE LE SIGNALE.
  #
  # « 02:00 tomorrow » est toujours à venir, donc la question ne se posait pas.
  # Elle se pose dès qu'on vise une heure du jour même — « 09:00 » pour un
  # réveil de mise au point : si la restauration déborde au-delà de cette heure,
  # on armerait une alarme déjà passée et la machine ne se rallumerait plus jamais
  # seule. On décale alors au lendemain, et on le dit.
  local maintenant; maintenant="$(date +%s)"
  if [ "$target" -le "$maintenant" ]; then
    while [ "$target" -le "$maintenant" ]; do target=$((target + 86400)); done
    log "« $WAKE_AT » est déjà passé — réveil reporté au $(date -d "@$target" '+%F %T')"
  fi
  # Remise à zéro obligatoire : écrire par-dessus une alarme armée échoue.
  echo 0 > /sys/class/rtc/rtc0/wakealarm 2>/dev/null || true
  if echo "$target" > /sys/class/rtc/rtc0/wakealarm 2>/dev/null; then
    log "Réveil RTC armé pour $(date -d "@$target" '+%F %T')"
    printf '%s\n' "$target" > "$STATE_DIR/next-wake"
    return 0
  fi
  log "ÉCHEC de l'armement du réveil RTC — la machine ne se rallumera pas seule."
  return 1
}

on_exit() {
  local code=$?
  log "Sortie (code $code) — armement du réveil puis extinction"
  arm_wakealarm || true
  printf '%s\n' "$code" > "$STATE_DIR/last-nightly-code"
  # LE REÇU PART AVANT L'EXTINCTION, QUEL QUE SOIT LE VERDICT.
  #
  # « J'ai échoué » vaut autant que « j'ai réussi » : dans les deux cas la
  # production apprend que l'arche s'est réveillée et a travaillé. C'est
  # l'ABSENCE de reçu qui devient le signal, et elle couvre les deux pannes que
  # rien ne distinguait jusqu'ici — pas réveillée, ou réveillée sans succès.
  #
  # Au meilleur effort : jamais bloquant, jamais fatal. L'armement du réveil
  # passe avant, il est plus important ; et une production injoignable est
  # précisément le jour où l'arche sert, pas un motif d'alarme ici.
  if [ -x "$RECU" ]; then
    "$RECU" nocturne "$code" >/dev/null 2>&1 || true
  fi
  if [ "$NO_HALT" = 1 ]; then
    log "PRA_NO_HALT=1 : la machine reste allumée."
  else
    log "===== PRA NIGHTLY END $(date) ====="
    sync
    systemctl halt
  fi
}
trap on_exit EXIT

log "===== PRA NIGHTLY START $(date) ====="

# UN RÉGLAGE TEMPORAIRE QUI NE SE RAPPELLE PAS À NOUS DEVIENT PERMANENT.
# On le dit à chaque exécution, dans le journal que l'interface affiche.
if [ "$WAKE_AT" != "02:00 tomorrow" ]; then
  log "RÉVEIL NON STANDARD : « $WAKE_AT » au lieu de « 02:00 tomorrow »"
  log "  réglage de mise au point — à retirer de /etc/pra/pra.conf une fois fini"
fi

### ─── ABSTENTION SI QUELQU'UN TRAVAILLE DÉJÀ ────────────────────────────────
# UN NOCTURNE NE DOIT JAMAIS ÉTEINDRE UNE MACHINE EN COURS D'OPÉRATION.
#
# Une restauration lancée à la main quelques minutes avant l'heure du nocturne
# est tuée net : le nocturne démarre, sa propre restauration échoue proprement
# sur le verrou, puis le trap de sortie éteint la machine. L'échec sur le verrou
# est correct ; l'extinction ensuite est une faute.
#
# Le mécanisme de pause existait déjà, mais il faut le DEMANDER — et personne ne
# pense à demander une pause avant de lancer une restauration à la main. Un
# garde-fou qu'il faut penser à armer n'est pas un garde-fou.
#
# On détecte donc le verrou de restauration et l'on s'abstient, machine allumée.
# La réplication de cette nuit est perdue : c'est le bon choix, puisque quelqu'un
# est en train de restaurer une archive de son choix — l'écraser serait pire.
# EN CAS DE DOUTE, ON CONTINUE — même raison que pour la pause : une réplication
# qui ne se fait plus en silence est bien pire qu'un risque d'interruption. On ne
# s'abstient donc QUE si flock affirme le verrou tenu (code 1), jamais parce que
# le test lui-même a échoué.
RESTORE_LOCK="${PRA_RESTORE_LOCK:-/run/pra_restore.lock}"
if ! command -v flock >/dev/null 2>&1; then
  log "ATTENTION  flock introuvable — impossible de savoir si une restauration tourne."
  log "  On CONTINUE : mieux vaut ce risque qu'un dispositif silencieusement à l'arrêt."
elif [ -e "$RESTORE_LOCK" ]; then
  ( exec 8>>"$RESTORE_LOCK" && flock -n 8 ) 2>/dev/null
  _rc=$?
  if [ "$_rc" -eq 1 ]; then
    NO_HALT=1
    log "UNE RESTAURATION EST DÉJÀ EN COURS — le nocturne s'abstient."
    log "  La machine reste ALLUMÉE : l'éteindre maintenant détruirait cette"
    log "  opération. Aucune réplication cette nuit."
    notifier alerte "Réplication reportée" \
      "Une restauration était en cours à l'heure du nocturne. L'arche s'est abstenue et reste allumée pour ne pas l'interrompre. Aucune réplication cette nuit."
    exit 0
  elif [ "$_rc" -ne 0 ]; then
    log "ATTENTION  état du verrou indéterminé (code $_rc) — on continue par défaut."
  fi
fi

### ─── PAUSE TEMPORAIRE ─────────────────────────────────────────────────────
# Permet de travailler la nuit sans que l'arche restaure par-dessus ni s'éteigne
# sous les pieds de celui qui s'en sert. Jusqu'ici la seule voie était de
# désactiver le minuteur — ce qui est DÉFINITIF sans le dire : on désactive un
# soir de crise, et des mois plus tard personne ne se souvient que le dispositif
# ne tourne plus.
#
# D'où trois garde-fous, qui sont tout l'intérêt du mécanisme :
#
#  1. L'ÉCHÉANCE EST OBLIGATOIRE. Passée la date, la réplication reprend seule.
#  2. Elle est PLAFONNÉE (PRA_PAUSE_MAX_JOURS, 7 par défaut). Une pause fixée à
#     2099 serait un PRA éteint qui se croit actif.
#  3. Une date ILLISIBLE n'active PAS la pause. En cas de faute de frappe, mieux
#     vaut une machine qui s'éteint sous les pieds qu'un dispositif silencieux.
#
# Chaque nuit de pause envoie une alerte : une pause qu'on oublie est pire que
# pas de pause du tout.
PAUSE_JUSQUA="${PRA_PAUSE_JUSQUA:-}"
PAUSE_MAX_JOURS="${PRA_PAUSE_MAX_JOURS:-7}"
if [ -n "$PAUSE_JUSQUA" ]; then
  if fin="$(date -d "$PAUSE_JUSQUA" +%s 2>/dev/null)" && [ -n "$fin" ]; then
    maintenant="$(date +%s)"
    plafond=$(( maintenant + PAUSE_MAX_JOURS * 86400 ))
    if [ "$fin" -gt "$plafond" ]; then
      log "ATTENTION  pause demandée au-delà de $PAUSE_MAX_JOURS jours — ramenée au plafond."
      fin="$plafond"
    fi
    if [ "$maintenant" -lt "$fin" ]; then
      NO_HALT=1          # la machine reste allumée : c'est le but
      log "PAUSE ACTIVE jusqu'au $(date -d "@$fin" '+%F %H:%M') — aucune réplication,"
      log "  et la machine ne s'éteindra pas. Elle reprendra seule à l'échéance."
      notifier alerte "Réplication en pause" \
        "L'arche ne réplique pas et reste allumée jusqu'au $(date -d "@$fin" '+%F à %H:%M'). Reprise automatique ensuite. Pour reprendre tout de suite, vider PRA_PAUSE_JUSQUA."
      exit 0
    fi
    log "Pause expirée le $(date -d "@$fin" '+%F %H:%M') — reprise normale."
  else
    log "ATTENTION  PRA_PAUSE_JUSQUA illisible (« $PAUSE_JUSQUA ») — pause IGNORÉE."
    log "  Format attendu : AAAA-MM-JJ ou « AAAA-MM-JJ HH:MM »."
  fi
fi

# POWER_OFF_ON_HALT doit valoir 1 dans l'EEPROM, sinon « halt » laisse la carte
# sous tension et le réveil RTC ne peut pas fonctionner.
if command -v rpi-eeprom-config >/dev/null 2>&1; then
  rpi-eeprom-config | grep -q 'POWER_OFF_ON_HALT=1' \
    || log "ATTENTION : POWER_OFF_ON_HALT n'est pas à 1 — extinction et réveil RTC compromis"
fi

### ─── ÉTAPE 1 : RÉSEAU, QUORUM ET CANARI ──────────────────────────────────
check_host() { ping -c 2 -W "$PING_TIMEOUT" "$1" >/dev/null 2>&1; }

log "Vérification de la connectivité"
unreachable=()
reachable=0
for h in "${WITNESSES[@]}"; do
  if check_host "$h"; then
    log "  $h joignable"; reachable=$((reachable + 1))
  else
    log "  $h INJOIGNABLE"; unreachable+=("$h")
  fi
done

# Seul SERVER1 porte les sauvegardes : lui seul est bloquant. La v1 éteignait
# aussi quand SERVER2 était absent, ce qui faisait perdre une nuit entière de
# réplication pour un serveur qui n'intervient pas dans la chaîne.
if printf '%s\n' "${unreachable[@]:-}" | grep -qx "$SERVER1"; then
  log "Source des sauvegardes injoignable — pas de réplication cette nuit."
  notifier echec "Source des sauvegardes injoignable" \
    "$SERVER1 ne répond pas. Aucune réplication cette nuit ; l'arche conserve son état."
  exit 1
fi

# QUORUM DE TÉMOINS. Une machine qui tombe, c'est une panne. Plusieurs la même
# nuit, c'est un incident large — et répliquer depuis un parc en train de tomber
# est exactement la façon dont une sauvegarde devient un vecteur de propagation.
# Dans le doute, l'arche ne fait RIEN : elle garde son dernier état bon.
if [ "$reachable" -lt "$QUORUM_MIN" ]; then
  log "QUORUM NON ATTEINT : $reachable témoin(s) sur ${#WITNESSES[@]}, minimum $QUORUM_MIN"
  log "Incident large suspecté — ni réplication ni restauration cette nuit."
  notifier echec "Quorum de témoins non atteint" \
    "Seuls $reachable témoin(s) sur ${#WITNESSES[@]} répondent (minimum $QUORUM_MIN). Injoignables : ${unreachable[*]}. Incident large suspecté, l'arche s'abstient et conserve son état. À lever à la main si c'est une maintenance planifiée."
  exit 1
fi
[ ${#unreachable[@]} -gt 0 ] && log "Poursuite malgré : ${unreachable[*]}"

# CANARIS. Plusieurs fichiers témoins posés à différents endroits de la
# production, dont l'arche vérifie les empreintes. S'ils changent ou deviennent
# illisibles, la production est chiffrée : c'est le signal le plus difficile à
# contourner, un rançongiciel ne pouvant pas deviner quels fichiers sont
# surveillés. Voir pra_canaries.sh pour le déploiement et le choix des
# emplacements (ce sont des APPÂTS : noms de documents, extensions courantes).
#
# Désactivé tant que le manifeste n'existe pas : un canari mal configuré qui
# bloquerait chaque nuit serait pire que pas de canari du tout.
if [ -x "$CANARIES_BIN" ] && [ -r "$CANARY_MANIFEST" ]; then
  log "Vérification des canaris sur la production"
  sortie="$("$CANARIES_BIN" verifier 2>&1)"; code=$?
  while IFS= read -r l; do log "  $l"; done <<< "$sortie"

  case "$code" in
    0) : ;;
    2)
      # Absence ISOLÉE : on alerte sans bloquer. Perdre une nuit de réplication
      # pour un fichier rangé par quelqu'un d'autre coûte plus qu'il ne protège.
      log "Canari absent, tolérance appliquée — la réplication se poursuit."
      notifier alerte "Canari absent sur la production" \
        "$(printf '%s' "$sortie" | tr '\n' ' ') — La réplication se poursuit. Vérifier si l'absence est légitime, puis « pra_canaries.sh rebaser » ou choisir un autre emplacement."
      ;;
    *)
      log "CANARIS EN DÉFAUT — chiffrement suspecté, aucune réplication cette nuit."
      notifier echec "Canaris en défaut sur la production" \
        "$(printf '%s' "$sortie" | tr '\n' ' ') — L'arche s'abstient et conserve son état. Si la modification est légitime, re-générer le manifeste : pra_canaries.sh rebaser"
      exit 1
      ;;
  esac
else
  log "Canaris : manifeste absent, contrôle désactivé (pra_canaries.sh rebaser)"
fi

### ─── ÉTAPE 2 : DONNÉES HORS ARCHIVE YUNOHOST ─────────────────────────────
# L'archive YunoHost est rapatriée par pra_restore_replica.sh. Restent deux
# jeux qu'elle ne contient pas.
PROD_USER="${PRA_PROD_USER:-}"
if [ -z "$PROD_USER" ]; then
  log "PRA_PROD_USER non défini — données hors archive non répliquées"
else
  BACKUP_DIR="${PRA_BACKUP_DIR:-/transferts/backups}"
  TODAY="$(date +%Y%m%d)"
  # Répertoire de journaux répliqué en plus de l'archive : vide, donc inactif,
  # tant qu'il n'est pas déclaré.
  LOG_SRC="${PRA_LOG_SRC:-}"
  LOG_KEEP_DAYS="${PRA_LOG_KEEP_DAYS:-90}"
  LOG_PURGE="${PRA_LOG_PURGE:-0}"

  # L'instantané Docker : petit, transféré intégralement.
  #
  # Deux protections contre la propagation d'un rançongiciel :
  #
  #   ${TODAY}  — on ne récupère QUE les instantanés du jour. Le motif accepte
  #               les deux nommages : « AAAAMMJJ-docker.tar » et
  #               « AAAAMMJJ-HHMMSS-docker.tar », l'heure distinguant
  #               l'instantané périodique d'un instantané manuel — sans elle, le
  #               manuel porte le même nom et --ignore-existing le laisse sur
  #               place. Un motif plus large, '*-docker.tar*',
  #               resynchroniserait TOUS les instantanés
  #               chaque nuit : un fichier chiffré sur la production écrasait la
  #               bonne copie de l'arche. L'archive YunoHost était déjà protégée
  #               par ce filtre, pas celui-ci.
  #
  #   --ignore-existing — une archive déjà présente sur l'arche n'est PLUS JAMAIS
  #               réécrite, quoi qu'il arrive côté production. Le magasin devient
  #               effectivement en écriture unique : c'est la protection la plus
  #               efficace du dispositif, et elle coûte un argument.
  # LE JOUR ET LA VEILLE. Un instantané manuel pris hier soir — après le passage
  # du nocturne d'hier — n'a jamais été transféré : le motif d'hier ne tournera
  # plus jamais. Sans la veille, ce fichier manquait définitivement au miroir,
  # et si la production mourait à 01h30, l'arche n'aurait pas l'état d'hier soir
  # qu'elle aurait pu avoir. --ignore-existing rend l'élargissement sans risque :
  # ce qui est déjà là n'est jamais réécrit.
  log "Récupération des instantanés Docker (jour et veille)"
  VEILLE="$(date -d yesterday +%Y%m%d)"
  for _jour_snap in "$TODAY" "$VEILLE"; do
    rsync -a --timeout=900 --partial-dir=.rsync-partial --chmod=F600 \
          --ignore-existing \
          "$PROD_USER@$SERVER1:$BACKUP_DIR/${_jour_snap}"'*-docker.tar*' "$BACKUP_DIR/" \
      2>&1 | tail -2 || log "  aucun instantané du $_jour_snap disponible"
  done

  # Journaux volumineux hors archive (PRA_LOG_SRC) : plusieurs dizaines de
  # gigaoctets par mois, donc incrémental et SANS --delete. Le réplica les
  # conserve plus longtemps que la production, qui les purge vite — c'est ce qui
  # lui donne sa valeur en investigation post-incident.
  if [ -z "$LOG_SRC" ]; then
    log "Journaux volumineux : aucun répertoire déclaré (PRA_LOG_SRC) — ignoré"
  else
    log "Réplication incrémentale des journaux volumineux"
    mkdir -p "$LOG_SRC"
    if rsync -a --timeout=3600 --partial-dir=.rsync-partial \
             "$PROD_USER@$SERVER1:$LOG_SRC/" "$LOG_SRC/" 2>&1 | tail -3; then
      log "  logs à jour ($(du -sh "$LOG_SRC" 2>/dev/null | cut -f1))"
    else
      log "  ATTENTION : réplication des logs incomplète"
    fi

    # Purge en COMPTE RENDU par défaut : une suppression mal ciblée sur des logs
    # d'investigation est irréversible. Passer PRA_LOG_PURGE=1 après avoir vérifié
    # la liste ci-dessous.
    COUNT="$(find "$LOG_SRC" -type f -mtime "+$LOG_KEEP_DAYS" 2>/dev/null | wc -l)"
    if [ "$COUNT" -gt 0 ]; then
      if [ "$LOG_PURGE" = 1 ]; then
        find "$LOG_SRC" -type f -mtime "+$LOG_KEEP_DAYS" -delete
        log "  purge : $COUNT fichier(s) de plus de $LOG_KEEP_DAYS jours"
      else
        log "  $COUNT fichier(s) dépassent $LOG_KEEP_DAYS jours — NON supprimés"
        log "  (activer avec PRA_LOG_PURGE=1 après contrôle de la liste)"
        find "$LOG_SRC" -type f -mtime "+$LOG_KEEP_DAYS" 2>/dev/null | head -3 \
          | while read -r f; do log "    exemple : $f"; done
      fi
    fi
  fi
fi

### ─── ÉTAPE 3 : RESTAURATION ───────────────────────────────────────────────
[ -x "$RESTORE" ] || { log "$RESTORE absent ou non exécutable"; exit 1; }

log "Lancement de la restauration"
# UN SEUL REÇU PAR NUIT. La restauration en dépose un quand on la lance à la
# main ; ici c'est le nocturne qui le fera, à l'extinction, avec le verdict
# complet — volet Docker et sonde compris. On le lui dit, sinon la production
# recevrait deux reçus dont l'un se déclarerait « manuel ».
if PRA_RECU_DIFFERE=1 bash "$RESTORE"; then
  log "Restauration YunoHost terminée sans erreur bloquante"
else
  log "La restauration YunoHost a retourné une erreur — voir /var/log/pra_restore.log"
fi

### ─── DÉPÔTS GIT ───────────────────────────────────────────────────────────
# Déplie les dépôts GitLab de l'archive en dépôts nus consultables. Trois
# secondes, 4 Mo. Le code de la cellule était DÉJÀ sauvegardé — le paquet
# YunoHost embarque la sauvegarde native de GitLab — mais il fallait dérouler
# 12 Go pour l'atteindre. Ici on paie ce prix une fois par nuit, pendant que la
# machine est de toute façon allumée.
#
# Non bloquant : c'est un service de commodité, pas un maillon de la chaîne de
# sauvegarde. Son échec ne doit pas empêcher le volet Docker de tourner.
if [ -x "$GITLAB_EXTRACT" ]; then
  log "Extraction des dépôts git"
  if bash "$GITLAB_EXTRACT" >/dev/null 2>&1; then
    log "  dépôts disponibles dans ${PRA_GIT_DEST:-/srv/git}"
    # Publication dans la forge locale, si elle est installée. Elle n'est que la
    # vitrine : /srv/git reste le chemin garanti, qui ne dépend d'aucun service.
    if [ -x "$FORGEJO_SYNC" ]; then
      if bash "$FORGEJO_SYNC" >/dev/null 2>&1; then
        log "  dépôts publiés dans la forge"
      else
        log "  publication dans la forge en échec — voir /var/log/pra_forgejo.log"
      fi
    fi
  else
    log "  extraction des dépôts en échec — voir /var/log/pra_gitlab.log"
    notifier alerte "Extraction des dépôts git en échec" \
      "Les dépôts ne sont pas consultables sur l'arche. La sauvegarde, elle, reste intacte dans l'archive : c'est l'accès qui manque, pas les données."
  fi
fi

### ─── VOLET DOCKER ─────────────────────────────────────────────────────────
# Lancé APRÈS le volet YunoHost, et sans condition sur son résultat : les
# reverse proxies YunoHost pointent vers ces conteneurs, mais l'inverse n'est
# pas vrai. Une pile Docker qui démarre reste utile même si une application
# YunoHost a échoué — et refuser de la démarrer ne réparerait rien.
#
# Volontairement non bloquant pour la nuit : le verdict détaillé part dans
# docker-status.json, que la webapp affiche, et tout échec déclenche une alerte.
if [ -x "$DOCKER_RESTORE" ]; then
  log "Restauration du volet Docker"
  if bash "$DOCKER_RESTORE"; then
    log "Volet Docker terminé"
  else
    log "Le volet Docker a retourné une erreur — voir /var/log/pra_docker_restore.log"
    notifier alerte "Volet Docker en échec" \
      "La restauration des piles Docker a échoué. Le volet YunoHost, lui, a été traité. Voir /var/log/pra_docker_restore.log."
  fi
else
  log "$DOCKER_RESTORE absent — volet Docker ignoré"
fi

# Report du verdict détaillé dans le journal de la nuit, pour n'avoir qu'un
# seul fichier à lire au réveil.
if [ -r "$STATE_DIR/status.json" ]; then
  log "État final :"
  python3 - "$STATE_DIR/status.json" <<'PY' 2>/dev/null || cat "$STATE_DIR/status.json"
import json,sys
d=json.load(open(sys.argv[1]))
print("   verdict : %s (%s, %s s)" % (d.get("verdict"), d.get("mode"), d.get("duree_s")))
print("   archive : %s" % d.get("archive"))
for k,v in sorted(d.get("applications",{}).items()):
    print("   - %-22s %s" % (k, v))
PY
fi

### ─── SONDE DE SANTÉ, ET COMPARAISON À LA VEILLE ──────────────────────────
# UNE RÉGRESSION PARLE, UN ÉTAT ABSOLU NON.
#
# Les verdicts disent si la restauration s'est bien passée. Aucun ne dit si les
# services RÉPONDENT, et l'un ne présume pas de l'autre : un conteneur
# « running » peut rendre 502 pendant des heures derrière un volet Docker
# déclaré en succès.
#
# On sonde donc les adresses en fin de nuit, et l'on compare à la veille. « 24
# applications joignables » ne dit rien ; « hier 29, ce matin 24, voici
# lesquelles » désigne le problème. C'est le seul signal qu'aucun verdict ne sait
# produire.
#
# Non bloquant, et volontairement APRÈS le report du verdict : une sonde qui
# échoue ne doit pas masquer le résultat de la restauration, qui compte plus.
HELPER="${ARCHE_HELPER:-/opt/arche/helper/arche-helper}"
if [ -x "$HELPER" ]; then
  log "Sonde de santé des services"
  # « --patienter » : on redemande à ce qui ne répond pas encore, jusqu'à trois
  # minutes. Certaines applications mettent plusieurs dizaines de secondes à
  # servir et leur mandataire rend 502 en attendant : sans cela, presque chaque
  # nuit annonce « ne répond plus » pour un service debout deux minutes après. Une
  # alerte qui se trompe régulièrement cesse d'être lue.
  if sonde="$("$HELPER" sante --patienter 2>/dev/null)"; then
    printf '%s' "$sonde" | python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
av, ap = d.get("ok_avant"), d.get("ok_apres")
if av is None:
    print("%s service(s) joignable(s) — première mesure, rien à comparer" % ap)
else:
    print("%s service(s) joignable(s) (hier : %s)" % (ap, av))
for r in d.get("regressions", []):
    print("RÉGRESSION : %s répondait hier et ne répond plus" % r)
# Ce qui a fini par répondre, mais tard. Ce n\x27est plus une alerte — c\x27est
# un symptôme, et le taire reviendrait à remplacer une fausse alerte par un
# silence : un service qui met une minute et demie à servir finira par
# dépasser la patience de la sonde.
for e in d.get("applications", []) + d.get("piles", []):
    if e.get("apparu_apres_s"):
        print("lent au démarrage : %s a répondu après %s s d\x27attente"
              % (e.get("id") or e.get("nom"), e["apparu_apres_s"]))
' 2>/dev/null | while IFS= read -r l; do log "  $l"; done
    # L'alerte ne part QUE sur une régression. Notifier chaque nuit un état
    # inchangé ferait cesser de lire les notifications — c'est le défaut qu'on
    # corrige partout ailleurs dans ce dispositif.
    regs="$(printf '%s' "$sonde" | python3 -c '
import json,sys
try: print(" ".join(json.load(sys.stdin).get("regressions", [])))
except Exception: pass' 2>/dev/null || true)"
    if [ -n "${regs// /}" ]; then
      notifier alerte "Services devenus injoignables" \
        "Ces services répondaient hier et ne répondent plus :$regs. L'arche est restaurée mais tout ne fonctionne pas — voir la page Santé de l'interface."
    fi
  else
    log "  sonde indisponible (helper en échec) — sans conséquence sur la nuit"
  fi
fi

exit 0
