#!/bin/bash
###############################################################################
# PRA Restore — à exécuter sur le RÉPLICA.
#
# Restaure une sauvegarde YunoHost de la production sur le réplica.
#
# Différences majeures avec la v1, et pourquoi :
#
#  1. VALIDATION AVANT DESTRUCTION. Restaurer, c'est désinstaller puis
#     réinstaller : une interruption entre les deux laisse le réplica creux —
#     une application déclarée installée, sans utilisateur de base ni vhost.
#     On valide donc l'archive intégralement avant de toucher à quoi que ce soit.
#
#  2. AUTO-RÉPARATION. Le script détecte un état incohérent — application
#     déclarée installée mais sans vhost ou sans utilisateur de base — et force
#     sa reconstruction. Une coupure de courant redevient rattrapable à
#     l'exécution suivante au lieu de laisser le réplica muet.
#
#  3. FICHIER D'ÉTAT MACHINE. /var/lib/pra/status.json, lu par l'interface de
#     pilotage. Un plan de reprise qui échoue en silence ne sert à rien.
#
#  4. MODE VALIDATION SEULE. PRA_DRY_RUN=1 vérifie l'archive sans rien
#     modifier. Permet de tester la chaîne toutes les nuits sans risque.
#
#  5. Le script ne coupe JAMAIS la machine de lui-même : c'est pra_nightly.sh
#     qui décide, ou PRA_HALT_APRES pour une restauration lancée à la main.
#
# Usage :
#   pra_restore_replica.sh                 restauration normale
#   PRA_DRY_RUN=1 pra_restore_replica.sh   validation seule
#   PRA_FORCE_ALL=1 …                      ignore les tests de santé
###############################################################################
set -euo pipefail

# ─── Configuration commune ───────────────────────────────────────────────────
# Éditée par la webapp Arche, lue par les scripts. La webapp n'est qu'un éditeur :
# si elle est absente ou cassée, la réplication continue exactement pareil.
# Le fichier emploie « : "${VAR:=valeur}" », qui n'affecte QUE les variables non
# définies : une variable passée à la main sur la ligne de commande reste donc
# prioritaire (PRA_DRY_RUN=1, PRA_ONLY=…).
# shellcheck source=/dev/null
[ -r "${PRA_CONF:-/etc/pra/pra.conf}" ] && . "${PRA_CONF:-/etc/pra/pra.conf}"


### ─── CONFIGURATION ────────────────────────────────────────────────────────
# Adresse de la production, PAR IP : ses domaines sont restaurés ici comme
# domaines YunoHost, et le résolveur local les renverrait vers le réplica
# lui-même. Sans ces deux valeurs, le transfert ne peut pas avoir lieu.
PROD_HOST="${PRA_PROD_HOST:-${PRA_SERVER1:-}}"
PROD_USER="${PRA_PROD_USER:-}"
PROD_DIR="/transferts/backups"

BACKUP_SRC="/transferts/backups"
ARCHIVE_DST="/home/yunohost.backup/archives"
STATE_DIR="/var/lib/pra"
STATUS="$STATE_DIR/status.json"
LOG="/var/log/pra_restore.log"
LOCK="/run/pra_restore.lock"

# Répertoire de travail sur LE MÊME système de fichiers que la destination :
# le déplacement final devient instantané au lieu de recopier 12 Go.
WORKDIR="$ARCHIVE_DST/.pra_work"

# Rétention : on garde TOUJOURS les KEEP_MIN archives les plus récentes, quel
# que soit leur âge. Une purge uniquement basée sur la date est dangereuse pour
# un PRA — si la réplication échoue une semaine, elle vide l'arche entièrement
# et il ne reste plus rien à restaurer. L'âge ne s'applique qu'au-delà du
# minimum garanti.
# Rétention grand-père/père/fils. PRA_PURGE_APPLIQUER=1 pour supprimer
# réellement ; par défaut le script se contente d'un compte rendu.
RETENTION_LIB="${PRA_RETENTION_LIB:-/usr/local/sbin/pra_retention.sh}"
RECU_BIN="${PRA_RECU_BIN:-/usr/local/sbin/pra_recu.sh}"
# Le défaut est l'application RÉELLE de la purge. Le mode « compte rendu seul »
# laissé en place remplit le disque de copies préparées jamais reprises, et la
# restauration finit par s'arrêter faute de place — APRÈS la désinstallation des
# applications, donc au pire moment. Le constat sans suppression reste
# disponible avec PRA_PURGE_APPLIQUER=0.
PURGE_APPLIQUER="${PRA_PURGE_APPLIQUER:-1}"
# shellcheck source=/dev/null
[ -r "$RETENTION_LIB" ] && . "$RETENTION_LIB"

KEEP_MIN="${PRA_KEEP_MIN:-5}"
# Parties système à restaurer, séparées par des espaces.
#
# « conf_ldap » est restauré par défaut : l'archive ne porte aucun attribut
# d'URL, donc restaurer les permissions ne défait pas la transposition des URL
# de la section 7. Sans elle, l'annuaire du réplica dérive en silence — un mot
# de passe changé sur la production ne fonctionne pas ici, et on ne le découvre
# qu'en crise.
#
# Ce qu'elle emporte en revanche, ce sont les DOMAINES de courrier : ceux
# propres au réplica n'y figurent pas et disparaissent du LDAP. Sans conséquence
# pour nginx, qui n'en dépend pas, mais l'état devient incohérent — la
# section 7 quater les recrée.
# « ${VAR-défaut} » et NON « ${VAR:-défaut} » : sans les deux-points, le défaut ne
# s'applique que si la variable est absente. Avec, une valeur VIDE retombait sur
# le défaut — il était donc impossible de désactiver conf_ldap.
# Sans cette nuance, « PRA_SYSTEM_PARTS= » restaurerait quand même conf_ldap :
# il serait impossible de le désactiver.
SYSTEM_PARTS="${PRA_SYSTEM_PARTS-conf_ldap}"
# Répare automatiquement les binaires d'une autre architecture ramenés par la
# sauvegarde. Sans cela, les applications qui embarquent un binaire précompilé
# sont hors service à chaque nuit — voir la section 8 bis.
REPARER_BINAIRES="${PRA_REPARER_BINAIRES:-1}"

# Applications retenues pour la restauration. VIDE = toutes celles de APP_TABLE,
# ce qui reste le comportement par défaut.
#
# La sélection est faite depuis la webapp à partir de l'inventaire de la
# DERNIÈRE exécution — donc de la veille. Une application choisie hier peut
# avoir disparu de l'archive du jour : le contrôle « absent de l'archive » de la
# section 4 l'écarte alors avec une trace, sans faire échouer la nuit. C'est ce
# décalage de 24 h qui rend ce garde-fou nécessaire.
RESTORE_APPS="${PRA_RESTORE_APPS:-}"

app_selectionnee() {
  # Coupe à l'espace ET à la virgule : la configuration écrit à l'espace, et
  # figer l'autre séparateur ferait silencieusement correspondre zéro
  # application. On accepte les deux, partout.
  [ -z "${RESTORE_APPS//[ ,]/}" ] && return 0
  printf '%s\n' "$RESTORE_APPS" | tr ' ,' '\n\n' | grep -qx "$1"
}
RETENTION_DAYS="${PRA_RETENTION_DAYS:-7}"
DRY_RUN="${PRA_DRY_RUN:-0}"
FORCE_ALL="${PRA_FORCE_ALL:-0}"
# Éteindre la machine à la fin. Utile pour une restauration manuelle qu'on lance
# avant de partir : elle dure une trentaine de minutes, et l'arche ne doit pas
# rester allumée toute la nuit pour rien — une machine allumée est attaquable.
#
# L'extinction a lieu QUEL QUE SOIT LE VERDICT, comme dans la chaîne nocturne :
# l'alerte est envoyée avant, et laisser la machine allumée sur un échec ne la
# répare pas. Celui qui veut examiner les dégâts la rallume.
HALT_APRES="${PRA_HALT_APRES:-0}"
# Enchaîner le volet Docker. La chaîne nocturne l'appelle elle-même après ce
# script ; ce drapeau sert aux restaurations lancées À LA MAIN, qui autrement
# ne restaureraient QUE les applications YunoHost.
#
# Sans ce drapeau, « Restaurer maintenant » rend un réplica dont les
# applications YunoHost sont à jour mais dont les piles Docker datent de la
# veille, sans que rien ne le signale.
AVEC_DOCKER="${PRA_AVEC_DOCKER:-0}"
DOCKER_RESTORE_BIN="${PRA_DOCKER_RESTORE_BIN:-/usr/local/sbin/pra_docker_restore.sh}"
# Ne contacte pas la production : valide l'archive déjà présente localement.
# Permet de contrôler la chaîne sans transfert ni charge sur le serveur de prod.
SKIP_FETCH="${PRA_SKIP_FETCH:-0}"

# Applications à restaurer, dans l'ordre, et URL à leur donner SUR LE RÉPLICA.
#
# Format « id|domaine|chemin », une par ligne, dans
# /etc/pra/applications.list (voir exemples/applications.list).
#
#   - un CHEMIN VIDE signifie « ne pas toucher à l'URL » : indispensable pour
#     les applications sans interface web, ou servies à la racine d'un domaine ;
#   - les instances multiples d'un même paquet ont besoin de chemins DISTINCTS,
#     sinon YunoHost refuse la collision ;
#   - une application servie à la racine d'un domaine dédié en production ne se
#     replie pas sur un sous-chemin sans casser les URL qu'elle génère : lui
#     donner son propre domaine local.
#
# Si le fichier est absent, la table est déduite de l'archive à la lecture du
# manifeste : toutes les applications sont restaurées et AUCUNE URL n'est
# transposée — elles resteront donc sur les domaines de la production.
APP_TABLE=()
APP_TABLE_FICHIER="${PRA_APP_TABLE:-/etc/pra/applications.list}"
if [ -r "$APP_TABLE_FICHIER" ]; then
  while IFS= read -r _ligne; do
    case "$_ligne" in ''|\#*) continue ;; esac
    APP_TABLE+=("$_ligne")
  done < "$APP_TABLE_FICHIER"
fi

# ─── MODE LISTAGE ───────────────────────────────────────────────────────────
# Affiche la table et sort, SANS RIEN TOUCHER. Placé ici, immédiatement après la
# table et avant tout accès réseau ou disque, ce qui n'était pas le cas
# auparavant : le bloc se trouvait après la récupération de l'archive, si bien
# que l'interface attendait un rsync vers la production pour afficher une liste
# statique. La page Réglages mettait soixante secondes à s'ouvrir — la durée du
# délai d'attente du helper — et le navigateur abandonnait avant.
#
# La règle vaut d'être retenue : un mode « lister » doit sortir avant la
# première entrée-sortie, sinon ce n'est pas un mode lister.
# Table vide — premier contact avec une machine — : on la PROPOSE d'après ce que
# YunoHost déclare, au lieu de n'afficher rien. C'est le cas où ce mode sert le
# plus : la sortie se relit, se corrige, puis se dépose en applications.list.
if [ "${PRA_LISTER:-0}" = 1 ]; then
if [ "${#APP_TABLE[@]}" -gt 0 ]; then
for row in "${APP_TABLE[@]}"; do printf '%s\n' "$row"; done
elif command -v yunohost >/dev/null 2>&1; then
while read -r _a; do
[ -n "$_a" ] || continue
printf '%s|%s|%s\n' "$_a" \
"$(yunohost app setting "$_a" domain 2>/dev/null)" \
"$(yunohost app setting "$_a" path 2>/dev/null)"
done < <(yunohost app list --output-as plain 2>/dev/null \
| grep -v '^#' | grep -vE '^\s*$')
fi
exit 0
fi

# Applications présentes en production mais volontairement écartées, avec la
# raison. Format « id: raison », une par ligne, dans
# /etc/pra/applications-exclues.list (voir exemples/).
#
# Déclarer une exclusion vaut mieux que l'oublier : sans elle, le contrôle de
# couverture signale chaque nuit une application « non couverte », et un
# avertissement permanent cesse d'être lu.
declare -A EXCLUDED=()
EXCLUES_FICHIER="${PRA_APP_EXCLUES:-/etc/pra/applications-exclues.list}"
if [ -r "$EXCLUES_FICHIER" ]; then
  while IFS= read -r _ligne; do
    case "$_ligne" in ''|\#*) continue ;; esac
    _id="${_ligne%%:*}"; _raison="${_ligne#*:}"
    [ -n "$_id" ] && EXCLUDED["$(printf '%s' "$_id" | tr -d ' ')"]="${_raison# }"
  done < "$EXCLUES_FICHIER"
fi

# Nextcloud n'utilise pas forcément la même version de PHP que le reste du
# système, et une version figée dans le script finit toujours par être la
# mauvaise. On la déduit de la tâche cron posée par le paquet, avec repli sur
# les versions installées.
# « || true » : sans ce fichier — Nextcloud pas encore restauré, arche neuve —
# grep rend 1, « pipefail » fait échouer l'affectation et « set -e » abat le
# script AU DÉMARRAGE, avant la moindre ligne de journal. Le repli sur les
# versions installées, juste dessous, ne serait jamais atteint.
PHP_BIN="${PRA_PHP_BIN:-$(
  p="$(grep -ohE 'php[0-9]+\.[0-9]+' /etc/cron.d/nextcloud 2>/dev/null | head -1 || true)"
  if [ -n "$p" ]; then printf '%s' "$p"
  else for c in php8.4 php8.3 php8.2 php; do
         # « if » et non « && » : en dernière itération, un « && » qui échoue rend 1
         # et « set -e » abat le script. Or « aucun PHP installé » doit produire un
         # avertissement, pas une mort au démarrage.
         if command -v "$c" >/dev/null 2>&1; then printf '%s' "$c"; break; fi
       done
  fi
  true)}"
NEXTCLOUD_OCC="/var/www/nextcloud/occ"
OCC_USER="nextcloud"

### ─── ÉTAT ─────────────────────────────────────────────────────────────────
declare -a RESULTS=()
STEP="démarrage"
VERDICT="en cours"
ARCHIVE_NAME=""
ARCHIVE_FILE=""
START_TS=$(date +%s)

# TEE, SAUF QUAND LA SORTIE STANDARD EST DÉJÀ CE JOURNAL.
#
# Le helper lance ce script en redirigeant sa sortie standard vers
# /var/log/pra_restore.log — le fichier même où « tee -a » écrit. Chaque ligne y
# arrivait donc DEUX fois : une par tee, une par la redirection. Invisible depuis
# cron, dont la sortie va ailleurs ; flagrant depuis l'interface.
#
# On ne supprime pas le tee pour autant : c'est lui qui fait remonter ces lignes
# dans le journal de l'appelant — le journal nocturne, notamment, où l'on veut
# voir le détail sans ouvrir un second fichier. On compare donc la destination
# réelle de la sortie standard au journal, et on ne dédouble que si ce sont le
# même fichier.
# « -ef » compare le périphérique et l'inode : c'est la seule façon fiable de
# savoir que deux chemins désignent le MÊME fichier. Une comparaison de chaînes
# ne suffit pas — et si elle échoue des deux côtés, deux résultats vides se
# valent, ce qui supprimerait la sortie au lieu de la dédoubler.
# Si /dev/stdout est indisponible, le test est faux et l'on double : l'ancien
# comportement, jamais une perte silencieuse.
if [ /dev/stdout -ef "$LOG" ]; then
  ECHO_STDOUT=0        # la redirection s'en charge déjà
else
  ECHO_STDOUT=1        # terminal, ou journal d'un appelant : on double
fi
log() {
  local l; l="$(printf '[%s] %s' "$(date '+%F %T')" "$*")"
  printf '%s\n' "$l" >> "$LOG"
  [ "$ECHO_STDOUT" = 1 ] && printf '%s\n' "$l" || true
}
warn() { log "ATTENTION  $*"; }
NOTIFY="${PRA_NOTIFY_BIN:-/usr/local/sbin/pra_notify.sh}"
# Best effort et jamais bloquant : une alerte qui ne part pas ne doit pas
# masquer ni aggraver l'échec qu'elle signale.
notifier() { [ -x "$NOTIFY" ] && "$NOTIFY" "$@" >/dev/null 2>&1 || true; }

# Toute sortie fatale prévient la production : c'est le seul moyen de trancher
# entre une vraie attaque et un faux positif sans attendre le lendemain.
die()  {
  VERDICT="échec"; log "ÉCHEC  $*"
  notifier echec "Restauration interrompue (étape : ${STEP:-?})" "$*"
  exit 1
}

json_escape() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'; }

write_status() {
  mkdir -p "$STATE_DIR"
  {
    printf '{\n'
    printf '  "horodatage": "%s",\n' "$(date -Is)"
    printf '  "duree_s": %d,\n' "$(( $(date +%s) - START_TS ))"
    printf '  "verdict": "%s",\n' "$VERDICT"
    printf '  "etape": %s,\n' "$(printf '%s' "$STEP" | json_escape)"
    printf '  "mode": "%s",\n' "$([ "$DRY_RUN" = 1 ] && echo validation || echo restauration)"
    printf '  "archive": "%s",\n' "$ARCHIVE_NAME"
    printf '  "applications": {\n'
    local first=1 r
    for r in "${RESULTS[@]:-}"; do
      [ -z "$r" ] && continue
      [ $first -eq 0 ] && printf ',\n'
      printf '    "%s": "%s"' "${r%%=*}" "${r#*=}"
      first=0
    done
    printf '\n  }\n}\n'
  } > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"
  chmod 644 "$STATUS"
}

record() { RESULTS+=("$1=$2"); }

on_exit() {
  local code=$?
  [ $code -eq 0 ] && [ "$VERDICT" = "en cours" ] && VERDICT="succès"
  [ $code -ne 0 ] && VERDICT="échec"
  rm -rf "$WORKDIR" 2>/dev/null || true
  write_status
  log "==== FIN — verdict : $VERDICT (étape : $STEP) ===="

  # Extinction demandée. Elle est ICI, dans le piège de sortie, et non à la fin
  # du déroulé : le verdict « partiel » sort par un « exit 0 » anticipé, et une
  # extinction placée plus bas serait esquivée précisément dans le cas où l'on a
  # le plus besoin qu'elle ait lieu — celui où l'on est parti en la croyant
  # programmée.
  #
  # Elle a lieu quel que soit le verdict, comme dans la chaîne nocturne :
  # l'alerte est déjà partie, et laisser la machine allumée sur un échec ne le
  # répare pas.
  # Volet Docker, s'il a été demandé. Placé ici pour deux raisons : il doit
  # tourner même quand le verdict est « partiel » — une pile qui démarre reste
  # utile si une application YunoHost a échoué — et il doit précéder
  # l'extinction, sans quoi la machine s'arrêterait avant de l'avoir fait.
  if [ "${AVEC_DOCKER:-0}" = 1 ] && [ "$DRY_RUN" != 1 ]; then
    if [ -x "$DOCKER_RESTORE_BIN" ]; then
      log "Enchaînement du volet Docker"
      # ON TRANSMET LE JOUR DE L'ARCHIVE RESTAURÉE.
      #
      # Sans cela le volet Docker prenait toujours l'instantané le plus récent :
      # choisir une archive YunoHost antérieure pour échapper à un chiffrement
      # laissait les piles Docker ramener celui du jour. Le sélecteur d'archive
      # ne protégeait alors que la moitié du dispositif.
      #
      # « ARCHIVE_NAME » vaut « AAAAMMJJ-HHMMSS » : on en extrait le jour, que
      # pra_docker_restore.sh apparie à « AAAAMMJJ-docker.tar ».
      _jour="${ARCHIVE_NAME%%-*}"
      # L'heure aussi, depuis que les instantanés la portent dans leur nom :
      # elle départage l'instantané du cron d'un instantané manuel du même jour.
      _heure="${ARCHIVE_NAME#*-}"
      case "$_jour" in
        [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
        *) _jour=""; _heure="" ;;   # nommage inattendu : comportement d'avant
      esac
      case "$_heure" in
        [0-9][0-9][0-9][0-9][0-9][0-9]) : ;;
        *) _heure="" ;;
      esac
      PRA_JOUR="$_jour" PRA_HEURE="$_heure" bash "$DOCKER_RESTORE_BIN" \
        && log "Volet Docker terminé" \
        || log "Volet Docker en échec — voir /var/log/pra_docker_restore.log"
    else
      log "$DOCKER_RESTORE_BIN absent — volet Docker ignoré"
    fi
  fi

  # REÇU POUR LA PRODUCTION, quand cette restauration a été lancée à la main.
  #
  # Le nocturne, lui, pose PRA_RECU_DIFFERE=1 : il déposera le sien à
  # l'extinction, avec le verdict complet — volet Docker et sonde compris. Sans
  # cette distinction la production recevrait deux reçus par nuit, dont l'un se
  # déclarerait « manuel ».
  #
  # Ce canal est en ÉCRITURE SEULE : on dépose, on ne relit rien. Voir
  # pra_recu.sh — c'est la règle qui empêche le modèle de s'inverser.
  if [ "${PRA_RECU_DIFFERE:-0}" != 1 ] && [ -x "$RECU_BIN" ]; then
    "$RECU_BIN" manuel "$code" >/dev/null 2>&1 || true
  fi

  if [ "${HALT_APRES:-0}" = 1 ]; then
    log "Extinction demandée à la fin de cette restauration"
    sync
    systemctl halt
  fi
}
trap on_exit EXIT

### ─── PRÉREQUIS ────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || { echo "À exécuter en root." >&2; exit 1; }

exec 9>"$LOCK"
flock -n 9 || { echo "Une autre exécution est en cours." >&2; exit 1; }

for cmd in yunohost tar rsync systemctl python3 flock; do
  command -v "$cmd" >/dev/null 2>&1 || die "commande manquante : $cmd"
done

# MYSQL À PART : ON LE RÉPARE AU LIEU D'ABANDONNER.
#
# Le réplica peut se retrouver dans un état dont il ne sort pas seul : la
# désinstallation des applications fait purger mariadb-server par l'autoremove
# d'apt, puis ce contrôle refuse de démarrer parce que « mysql » a disparu avec
# le paquet. Une machine de reprise qui
# se bloque elle-même ne remplit pas son office — et le jour où elle sert, il n'y
# a personne pour taper la commande.
#
# On tente donc la réinstallation. Si elle échoue — pas de réseau, ce qui est le
# cas normal en crise — on le dit franchement et on s'arrête : mieux vaut un
# refus explicite qu'une restauration qui perdrait les bases en silence.
if ! command -v mysql >/dev/null 2>&1; then
  warn "« mysql » absent — MariaDB a probablement été purgée par un autoremove"
  log  "  tentative de réinstallation de mariadb-server"
  if DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       mariadb-server >/dev/null 2>&1 && command -v mysql >/dev/null 2>&1; then
    log "  mariadb-server réinstallé"
    systemctl start mariadb 2>/dev/null || warn "  mariadb installée mais non démarrée"
  else
    die "mysql absent et réinstallation impossible (réseau ?) — installer mariadb-server puis relancer"
  fi
fi
command -v "$PHP_BIN" >/dev/null 2>&1 || warn "$PHP_BIN absent, étapes Nextcloud ignorées"

mkdir -p "$STATE_DIR" "$BACKUP_SRC" "$ARCHIVE_DST"
log "==== DÉBUT PRA RESTORE v2 — mode $([ "$DRY_RUN" = 1 ] && echo validation || echo restauration) ===="

### ─── 1. RÉCUPÉRATION DE L'ARCHIVE ─────────────────────────────────────────
# --partial-dir permet de reprendre un transfert coupé. La v1 utilisait
# --ignore-existing, qui gardait indéfiniment une archive tronquée : un fichier
# incomplet n'était jamais retéléchargé.
STEP="récupération de l'archive"
TODAY="$(date +%Y%m%d)"

# PRA_ARCHIVE : restaurer une archive PRÉCISE au lieu de celle du jour.
#
# Sans cela, le script ne savait restaurer que l'archive du jour — or c'est
# exactement l'inverse de ce qu'exige un rançongiciel : la plus récente est
# justement celle dont on se méfie, et il faut pouvoir remonter à une nuit
# antérieure.
#
# Une archive désignée à la main n'est jamais retéléchargée : elle est déjà là,
# et aller la rechercher sur une production compromise n'aurait aucun sens.
ARCHIVE_CHOISIE="${PRA_ARCHIVE:-}"
if [ -n "$ARCHIVE_CHOISIE" ]; then
  [ -f "$ARCHIVE_CHOISIE" ] || die "PRA_ARCHIVE : fichier introuvable — $ARCHIVE_CHOISIE"
  case "$(basename "$ARCHIVE_CHOISIE")" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9].tar) : ;;
    *) die "PRA_ARCHIVE : nommage inattendu (AAAAMMJJ-HHMMSS.tar attendu) — $ARCHIVE_CHOISIE" ;;
  esac
  SKIP_FETCH=1
  log "PRA_ARCHIVE : restauration d'une archive désignée, $(basename "$ARCHIVE_CHOISIE")"
fi

if [ "$SKIP_FETCH" = 1 ]; then
  log "PRA_SKIP_FETCH=1 : pas de contact avec la production"
else
  log "Transfert depuis $PROD_USER@$PROD_HOST"

  # UNE SEULE ARCHIVE, LA PLUS RÉCENTE — et non le glob du jour.
  #
  # « ${TODAY}*.tar » ramène TOUTES les archives du jour : une sauvegarde
  # automatique et deux manuelles qui cohabitent font tirer trois fois le volume
  # utile sur le réseau, pour n'en restaurer qu'une. Or la sélection qui
  # suit ne retient de toute façon que la plus récente, et trois archives du
  # MÊME JOUR n'apportent presque rien en reprise — ce qui compte, ce sont des
  # jours différents, et ceux-là sont déjà là.
  #
  # On demande donc d'abord à la production laquelle est la plus récente, puis on
  # ne tire que celle-là. Cela reste du tirage : l'arche décide, la production ne
  # pousse rien.
  DISTANTES="$(ssh -o BatchMode=yes -o ConnectTimeout=15 \
                 "$PROD_USER@$PROD_HOST" \
                 "ls -1 $PROD_DIR/${TODAY}-[0-9][0-9][0-9][0-9][0-9][0-9].tar 2>/dev/null" \
               2>/dev/null | sort || true)"
  NB_DISTANTES="$(printf '%s' "$DISTANTES" | grep -c . || true)"

  if [ "${NB_DISTANTES:-0}" -eq 0 ]; then
    warn "aucune archive du jour côté production — on se rabattra sur ce qui est déjà là"
  else
    A_TIRER="$(printf '%s\n' "$DISTANTES" | tail -n1)"
    # Le volume annoncé AVANT de commencer : sans lui, le journal se tait pendant
    # une heure et l'on cherche une panne là où il n'y a qu'un gros fichier.
    VOL="$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$PROD_USER@$PROD_HOST" \
             "du -h '$A_TIRER' 2>/dev/null | cut -f1" 2>/dev/null || true)"
    if [ "$NB_DISTANTES" -gt 1 ]; then
      log "  $NB_DISTANTES archives du jour côté production — on ne tire que la plus récente"
      printf '%s\n' "$DISTANTES" | while read -r f; do
        [ -n "$f" ] && log "    $([ "$f" = "$A_TIRER" ] && echo 'RETENUE ' || echo 'ignorée ')$(basename "$f")"
      done
    fi
    log "  transfert de $(basename "$A_TIRER")${VOL:+ ($VOL)} — le journal reste muet jusqu'à la fin"

    # --ignore-existing : une archive déjà présente sur l'arche n'est PLUS JAMAIS
    # réécrite. Si la production est chiffrée après coup, sa copie ne peut pas
    # écraser la bonne. Le magasin devient en écriture unique.
    rsync -a --timeout=1800 --partial-dir=.rsync-partial \
          --chmod=F600 --ignore-existing \
          "$PROD_USER@$PROD_HOST:$A_TIRER" "$BACKUP_SRC/" \
      && log "  transfert terminé" \
      || warn "transfert incomplet — on se rabattra sur ce qui est déjà là"
  fi

  # LES INSTANTANÉS DOCKER DU JOUR, EUX AUSSI.
  #
  # Ce transfert ne vivait que dans le nocturne : une restauration MANUELLE
  # tirait bien l'archive YunoHost fraîche, mais appariait ensuite son volet
  # Docker dans un magasin qui ne contenait que l'instantané de la nuit : une
  # sauvegarde manuelle de l'après-midi s'appariait alors « au plus près » parmi
  # un seul candidat, celui du matin. L'appariement à l'heure ne sert à rien si le
  # bon fichier n'est jamais arrivé.
  #
  # Mêmes protections que la nuit : le motif ne prend que le jour courant, et
  # --ignore-existing garde le magasin en écriture unique.
  # LES LOGOS DU PORTAIL. « yunohost backup » n'inclut PAS
  # /usr/share/yunohost/applogos/ : les logos téléversés à la main n'existent que
  # sur la production. Les réglages restaurés les référencent par leur empreinte,
  # et le portail du réplica affiche alors « ? » à leur place : la référence
  # voyage dans l'archive, le fichier jamais.
  #
  # Quelques mégaoctets, incrémental, et cosmétique — mais c'est la première
  # chose qu'un utilisateur voit, et des « ? » font douter de tout le reste.
  # PAS de --ignore-existing ici : un logo est un fichier public remplaçable,
  # pas une sauvegarde à protéger d'une réécriture — et un logo changé sur la
  # production doit suivre.
  rsync -a --timeout=300 \
        "$PROD_USER@$PROD_HOST:/usr/share/yunohost/applogos/" \
        /usr/share/yunohost/applogos/ 2>/dev/null \
    || log "  logos du portail non synchronisés (sans gravité)"

  # Jour ET veille : une restauration lancée juste après minuit doit encore
  # trouver l'instantané de la sauvegarde d'hier soir — même raison que dans le
  # nocturne, même écriture unique qui rend l'élargissement sans risque.
  log "  instantanés Docker (jour et veille)"
  for _jour_snap in "$(date +%Y%m%d)" "$(date -d yesterday +%Y%m%d)"; do
    rsync -a --timeout=900 --partial-dir=.rsync-partial --chmod=F600 \
          --ignore-existing \
          "$PROD_USER@$PROD_HOST:$BACKUP_SRC/${_jour_snap}"'*-docker.tar*' "$BACKUP_SRC/" \
      2>&1 | tail -2 || log "  aucun instantané du $_jour_snap côté production"
  done
fi

### ─── 2. SÉLECTION ET VALIDATION ───────────────────────────────────────────
STEP="validation de l'archive"
# On cible EXACTEMENT le nommage YunoHost : 8 chiffres, tiret, 6 chiffres.
#
# Un simple « $TODAY-*.tar » capture aussi « AAAAMMJJ-docker.tar », et comme le
# tri se fait par date décroissante, un instantané Docker de l'après-midi passe
# devant l'archive YunoHost de minuit : le script irait chercher un manifeste
# YunoHost dans un tar Docker. La validation refuse alors de continuer, avant
# toute désinstallation — mais autant ne pas s'y fier.

if [ -n "$ARCHIVE_CHOISIE" ]; then
  ARCHIVE_FILE="$ARCHIVE_CHOISIE"
else
  ARCHIVE_FILE="$(find "$BACKUP_SRC" -maxdepth 1 -type f \
    -regextype posix-extended -regex ".*/${TODAY}-[0-9]{6}\.tar" \
    -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1 | cut -d' ' -f2- || true)"
  [[ -n "$ARCHIVE_FILE" ]] || die "aucune archive YunoHost (AAAAMMJJ-HHMMSS.tar) pour $TODAY"
fi

ARCHIVE_NAME="$(basename "$ARCHIVE_FILE" .tar)"
SIZE_H="$(du -h "$ARCHIVE_FILE" | cut -f1)"
log "Archive retenue : $ARCHIVE_NAME ($SIZE_H)"

# Empreinte comparée à la production : détecte une corruption de transfert que
# la taille seule ne verrait pas.
if [ "$SKIP_FETCH" = 1 ]; then
  REMOTE_SUM=""
  if [ -n "$ARCHIVE_CHOISIE" ]; then
    warn "empreinte production non vérifiée (archive désignée par PRA_ARCHIVE)"
    warn "  attendu : une archive ancienne n'existe plus forcément côté production,"
    warn "  et cette production est peut-être celle dont on se méfie justement."
  else
    warn "empreinte production non vérifiée (PRA_SKIP_FETCH)"
  fi
elif REMOTE_SUM="$(ssh -o BatchMode=yes -o ConnectTimeout=15 \
      "$PROD_USER@$PROD_HOST" "sha256sum $PROD_DIR/$(basename "$ARCHIVE_FILE") 2>/dev/null | cut -d' ' -f1" 2>/dev/null)" \
   && [ -n "$REMOTE_SUM" ]; then
  log "Vérification de l'empreinte…"
  LOCAL_SUM="$(sha256sum "$ARCHIVE_FILE" | cut -d' ' -f1)"
  if [ "$LOCAL_SUM" != "$REMOTE_SUM" ]; then
    rm -f "$ARCHIVE_FILE"
    die "empreinte différente de la production — archive supprimée, elle sera retéléchargée au prochain run"
  fi
  log "Empreinte conforme"
else
  warn "empreinte production indisponible, validation par lecture seule"
fi

# Le manifeste doit être lisible et lister les applications attendues.
STEP="lecture du manifeste"
INFO_JSON=""
for p in info.json ./info.json; do
  if INFO_JSON="$(tar --occurrence=1 -xOf "$ARCHIVE_FILE" "$p" 2>/dev/null)" && [ -n "$INFO_JSON" ]; then
    break
  fi
done
[[ -n "$INFO_JSON" ]] || die "info.json illisible — archive corrompue ou tronquée"

mapfile -t ARCHIVE_APPS < <(printf '%s' "$INFO_JSON" | python3 -c \
  'import json,sys; print("\n".join(sorted(json.load(sys.stdin).get("apps",{}))))')
[[ ${#ARCHIVE_APPS[@]} -gt 0 ]] || die "le manifeste ne contient aucune application"
log "Manifeste : ${#ARCHIVE_APPS[@]} applications"

# Table absente : on restaure tout ce que porte l'archive, sans transposer les
# URL. Mieux vaut des applications restaurées sur les domaines de la production
# — et le dire — que ne rien restaurer du tout.
if [ "${#APP_TABLE[@]}" -eq 0 ]; then
  for _a in "${ARCHIVE_APPS[@]}"; do APP_TABLE+=("$_a||"); done
  warn "aucune table d'applications ($APP_TABLE_FICHIER) :"
  warn "  les ${#APP_TABLE[@]} applications de l'archive seront restaurées telles quelles,"
  warn "  leurs URL resteront celles de la production — voir exemples/applications.list"
fi

archive_has() {
  local a
  for a in "${ARCHIVE_APPS[@]}"; do [ "$a" = "$1" ] && return 0; done
  return 1
}

# Signale ce qui est apparu en production et n'est ni restauré ni écarté :
# une nouvelle application sur la prod ne doit pas passer inaperçue.
STEP="contrôle de couverture"
for a in "${ARCHIVE_APPS[@]}"; do
  in_table=0
  for row in "${APP_TABLE[@]}"; do [ "${row%%|*}" = "$a" ] && in_table=1; done
  if [ $in_table -eq 0 ] && [ -z "${EXCLUDED[$a]:-}" ]; then
    warn "application NON COUVERTE dans l'archive : $a — à arbitrer"
    record "$a" "non couverte"
  fi
done

### ─── 2 bis. DOMAINES REQUIS ───────────────────────────────────────────────
# Un domaine absent ne se manifeste qu'au moment du change-url, très tard dans
# la séquence et après avoir déjà désinstallé l'application. On vérifie donc
# maintenant, et on le signale tant qu'aucun dégât n'est fait.
STEP="contrôle des domaines"
mapfile -t YNH_DOMAINS < <(yunohost domain list --output-as json 2>/dev/null | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print("\n".join(d.get("domains",d) if isinstance(d,(list,dict)) else []))')

MISSING_DOMAINS=()
for row in "${APP_TABLE[@]}"; do
  IFS='|' read -r app dom path <<<"$row"
  [ -z "$dom" ] && continue
  printf '%s\n' "${YNH_DOMAINS[@]:-}" | grep -qx "$dom" && continue
  printf '%s\n' "${MISSING_DOMAINS[@]:-}" | grep -qx "$dom" && continue
  MISSING_DOMAINS+=("$dom")
done

if [ ${#MISSING_DOMAINS[@]} -gt 0 ]; then
  warn "domaines absents du réplica : ${MISSING_DOMAINS[*]}"
  for d in "${MISSING_DOMAINS[@]}"; do
    warn "  à créer :  yunohost domain add $d"
  done
  warn "les applications concernées seront restaurées mais leur URL échouera"
fi

### ─── 3. ÉTAT DE SANTÉ DU RÉPLICA ──────────────────────────────────────────
# Une application peut être déclarée installée tout en étant inutilisable :
# c'est l'état dans lequel la v1 laissait le réplica après une interruption.
STEP="diagnostic du réplica"
mapfile -t INSTALLED < <(yunohost app list --output-as json 2>/dev/null | python3 -c \
  'import json,sys; print("\n".join(a["id"] for a in json.load(sys.stdin).get("apps",[])))')

is_installed() { local a; for a in "${INSTALLED[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }

app_is_hollow() {                       # 0 = creuse, donc à reconstruire
  local app="$1" dom="$2"
  is_installed "$app" || return 1
  if [ -n "$dom" ] && [ ! -f "/etc/nginx/conf.d/$dom.d/$app.conf" ]; then
    local other
    other="$(find /etc/nginx/conf.d -name "$app.conf" 2>/dev/null | head -1 || true)"
    [ -z "$other" ] && return 0
  fi
  if mysql -N -B -e "show databases;" 2>/dev/null | grep -qx "$app"; then
    mysql -N -B -e "select user from mysql.user;" 2>/dev/null | grep -qx "$app" || return 0
  fi
  return 1
}

### ─── 4. DÉCISION ──────────────────────────────────────────────────────────
STEP="sélection des applications"
TO_RESTORE=()
for row in "${APP_TABLE[@]}"; do
  IFS='|' read -r app dom path <<<"$row"
  if ! app_selectionnee "$app"; then
    log "$app non retenu dans la sélection — ignoré"
    record "$app" "écarté de la sélection"
    continue
  fi
  if ! archive_has "$app"; then
    warn "$app absent de l'archive — ignoré"
    record "$app" "absent de l'archive"
    continue
  fi
  if [ "$FORCE_ALL" = 1 ]; then
    TO_RESTORE+=("$app"); record "$app" "à restaurer (forcé)"
  elif app_is_hollow "$app" "$dom"; then
    warn "$app est dans un état incohérent — reconstruction"
    TO_RESTORE+=("$app"); record "$app" "à reconstruire (état creux)"
  else
    TO_RESTORE+=("$app"); record "$app" "à restaurer"
  fi
done
[[ ${#TO_RESTORE[@]} -gt 0 ]] || die "aucune application à restaurer"
log "À restaurer : ${TO_RESTORE[*]}"

### ─── 4 bis. DOMAINES D'ORIGINE ────────────────────────────────────────────
# YunoHost restaure une application sur le domaine qu'elle avait en PRODUCTION ;
# le change-url vers le domaine .local n'intervient qu'ensuite. Ce domaine
# d'origine doit donc exister sur le réplica, sinon la restauration échoue.
#
# Il suffit qu'un seul domaine d'origine manque pour que l'application
# concernée échoue APRÈS avoir été désinstallée. On vérifie donc avant, et on
# refuse de continuer plutôt que de casser le réplica.
#
# Le balayage de l'archive coûte quelques minutes : c'est le prix d'une
# validation qui évite un réplica hors service.
STEP="contrôle des domaines d'origine"
log "Lecture des domaines d'origine dans l'archive (balayage complet)"
SETTINGS_DIR="$(mktemp -d)"
tar xf "$ARCHIVE_FILE" -C "$SETTINGS_DIR" --wildcards \
    'apps/*/settings/settings.yml' './apps/*/settings/settings.yml' 2>/dev/null || true

src_domain_of() {
  local app="$1" f
  for f in "$SETTINGS_DIR/apps/$app/settings/settings.yml" \
           "$SETTINGS_DIR/./apps/$app/settings/settings.yml"; do
    if [ -f "$f" ]; then
      sed -n 's/^domain:[[:space:]]*//p' "$f" | head -1 || true
      return
    fi
  done
}

MISSING_SRC=()
# On mémorise « domaine de prod → domaine de l'arche » tant que l'archive est
# encore dépliée : la section 7 bis en a besoin et SETTINGS_DIR disparaît ici.
declare -a DOMAIN_MAP=()
for app in "${TO_RESTORE[@]}"; do
  d="$(src_domain_of "$app")"
  [ -n "$d" ] || continue
  for row in "${APP_TABLE[@]}"; do
    if [ "${row%%|*}" = "$app" ]; then
      rest="${row#*|}"; dst="${rest%%|*}"
      if [ "$d" != "$dst" ] \
         && ! printf '%s\n' "${DOMAIN_MAP[@]:-}" | grep -qxF "$d|$dst"; then
        DOMAIN_MAP+=("$d|$dst")
      fi
      break
    fi
  done
  printf '%s\n' "${YNH_DOMAINS[@]:-}" | grep -qx "$d" && continue
  warn "$app était servi sur « $d », domaine ABSENT du réplica"
  printf '%s\n' "${MISSING_SRC[@]:-}" | grep -qx "$d" || MISSING_SRC+=("$d")
done
rm -rf "$SETTINGS_DIR"

if [ ${#MISSING_SRC[@]} -gt 0 ]; then
  for d in "${MISSING_SRC[@]}"; do warn "  à créer :  yunohost domain add $d"; done
  die "domaines d'origine manquants — arrêt AVANT toute désinstallation"
fi
log "Tous les domaines d'origine sont présents"

### ─── 4 ter. CONTRÔLES ANTI-RANÇONGICIEL ──────────────────────────────────
# Placés ICI, et nulle part ailleurs : la section 6 DÉSINSTALLE les applications
# avant de restaurer. C'est le point de non-retour. Une archive syntaxiquement
# valide mais dont les données ont été chiffrées passerait tous les contrôles
# précédents, et l'arche se détruirait elle-même en la restaurant.
#
# Principe directeur : DANS LE DOUTE, NE RIEN FAIRE. Une nuit sans réplication
# se rattrape ; une arche écrasée par une sauvegarde empoisonnée, non.
STEP="contrôles anti-rançongiciel"
log "Contrôles anti-rançongiciel"

SIZE_DELTA_MAX="${PRA_SIZE_DELTA_MAX:-40}"      # écart toléré à la médiane, en %
ANOMALY_ACTION="${PRA_ANOMALY_ACTION:-bloquer}" # bloquer | alerter
# Motifs de notes de rançon. Volontairement RESTRICTIF : « README.txt » seul est
# banal et bloquerait chaque nuit. On cible les verbes de rançon et les
# extensions de chiffrement, pas les noms de fichiers ordinaires.
RANSOM_PATTERN="${PRA_RANSOM_PATTERN:-(DECRYPT|DECRYPTION|RECOVER[-_ ]?(YOUR[-_ ]?)?FILES|RESTORE[-_ ]?(YOUR[-_ ]?)?FILES|HOW[-_ ]?TO[-_ ]?(DECRYPT|RECOVER)|YOUR[-_ ]?FILES[-_ ]?ARE[-_ ]?ENCRYPTED)[^/]*\\.(txt|html|hta|README)$|\\.(locked|encrypted|crypted|lockbit|conti|ryk|wncry|makop|phobos|djvu)$}"

declare -a ANOMALIES=()
signaler() { ANOMALIES+=("$1"); warn "  ANOMALIE : $1"; }

# ── 1. Notes de rançon et extensions de chiffrement ────────────────────────
# Le signal le plus fiable : un rançongiciel laisse presque toujours sa note.
log "  recherche de notes de rançon dans l'archive"
if trouve="$(tar tf "$ARCHIVE_FILE" 2>/dev/null | grep -Ei -m 3 "$RANSOM_PATTERN" || true)" \
   && [ -n "$trouve" ]; then
  signaler "trace de rançongiciel dans l'archive : $(printf '%s' "$trouve" | tr '\n' ' ')"
fi

# ── 2. Taille comparée à la médiane des archives précédentes ───────────────
# Le chiffrement est incompressible : la taille change franchement, dans un
# sens ou dans l'autre. On compare à la MÉDIANE et non à la dernière archive,
# pour ne pas se faire entraîner par une seule nuit déjà anormale.
taille="$(stat -c %s "$ARCHIVE_FILE" 2>/dev/null || echo 0)"
mapfile -t autres < <(find "$BACKUP_SRC" -maxdepth 1 -type f -name '*.tar' \
  ! -name '*-docker.tar' ! -path "$ARCHIVE_FILE" -printf '%s\n' 2>/dev/null | sort -n)
if [ "${#autres[@]}" -ge 3 ] && [ "$taille" -gt 0 ]; then
  mediane="${autres[$(( ${#autres[@]} / 2 ))]}"
  if [ "$mediane" -gt 0 ]; then
    ecart=$(( (taille - mediane) * 100 / mediane ))
    ecart_abs=${ecart#-}
    log "  taille : $((taille / 1024 / 1024)) Mo, médiane $((mediane / 1024 / 1024)) Mo (écart ${ecart} %)"
    [ "$ecart_abs" -gt "$SIZE_DELTA_MAX" ] \
      && signaler "taille de l'archive à ${ecart} % de la médiane (seuil ±${SIZE_DELTA_MAX} %)"
  fi
else
  log "  taille : historique insuffisant (${#autres[@]} archive(s)), comparaison ignorée"
fi

# ── 3. Chute du nombre d'applications ──────────────────────────────────────
# Un chiffrement ou une destruction partielle fait disparaître des applications
# de la sauvegarde. Une baisse est suspecte ; une hausse est normale.
nb_apps="$(tar xOf "$ARCHIVE_FILE" info.json 2>/dev/null \
  | python3 -c 'import json,sys
try: print(len(json.load(sys.stdin).get("apps") or {}))
except Exception: print(0)' 2>/dev/null || echo 0)"
# LE CONTRÔLE N'AVAIT JAMAIS TOURNÉ, FAUTE D'HISTORIQUE À COMPARER.
#
# Il cherche des « <archive>.info.json » à côté des .tar — que personne
# n'écrivait. Résultat : « historique insuffisant : 0 référence(s) » à chaque
# nuit depuis l'origine, et une garde anti-rançongiciel inerte qui annonçait
# poliment son abstention.
#
# On constitue donc l'historique NOUS-MÊMES, depuis les archives déjà là : dix
# secondes par archive de 12 Go, une seule fois, puis c'est en cache. Aucune
# coordination avec la production, et cela vaut rétroactivement.
#
# Borné aux dix plus récentes : au-delà, la médiane ne gagne rien et l'on
# ferait relire des archives que la rétention supprimera bientôt.
_manquants=0
while IFS= read -r _arc; do
  [ -n "$_arc" ] || continue
  [ -f "$_arc.info.json" ] && continue
  if tar xOf "$_arc" info.json > "$_arc.info.json.tmp" 2>/dev/null \
     && [ -s "$_arc.info.json.tmp" ]; then
    mv -f "$_arc.info.json.tmp" "$_arc.info.json"
    _manquants=$((_manquants + 1))
  else
    rm -f "$_arc.info.json.tmp"
  fi
done < <(find "$BACKUP_SRC" -maxdepth 1 -type f -name '[0-9]*-[0-9]*.tar' \
         -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -10 | cut -d' ' -f2-)
[ "$_manquants" -gt 0 ] && log "  historique : $_manquants archive(s) indexée(s) pour la comparaison"

# Un « .info.json » dont l'archive a disparu fausserait la médiane avec un état
# que la rétention a déjà écarté.
find "$BACKUP_SRC" -maxdepth 1 -type f -name '*.tar.info.json' 2>/dev/null \
  | while IFS= read -r _si; do [ -f "${_si%.info.json}" ] || rm -f "$_si"; done

# L'archive du jour est EXCLUE : se comparer à soi-même tire la médiane vers
# la valeur qu'on cherche justement à mettre en doute.
mapfile -t nb_precedents < <(find "$BACKUP_SRC" -maxdepth 1 -type f -name '*.info.json' \
  ! -name "$(basename "$ARCHIVE_FILE").info.json" \
  -printf '%p\n' 2>/dev/null | while read -r f; do
    python3 -c 'import json,sys
try: print(len(json.load(open(sys.argv[1])).get("apps") or {}))
except Exception: pass' "$f" 2>/dev/null
  done | sort -n)
if [ "$nb_apps" -gt 0 ] && [ "${#nb_precedents[@]}" -ge 3 ]; then
  attendu="${nb_precedents[$(( ${#nb_precedents[@]} / 2 ))]}"
  log "  applications : $nb_apps (médiane précédente : $attendu)"
  [ "$nb_apps" -lt "$attendu" ] \
    && signaler "$nb_apps applications dans l'archive contre $attendu habituellement"
elif [ "$nb_apps" -eq 0 ]; then
  signaler "nombre d'applications illisible dans info.json"
else
  # Un contrôle qui s'abstient doit le DIRE : un silence se lit comme un succès.
  log "  applications : $nb_apps (historique insuffisant : ${#nb_precedents[@]} référence(s), comparaison ignorée)"
fi

# ── 4. Incompressibilité d'un échantillon — AVERTISSEMENT SEULEMENT ────────
# Du contenu chiffré ne se compresse pas. Mais une sauvegarde contient déjà
# beaucoup de données compressées (images, PDF, archives) : le signal est trop
# bruité pour bloquer dessus. Il sert à éclairer les autres anomalies.
if [ "$taille" -gt 67108864 ]; then
  brut=33554432
  comp="$(dd if="$ARCHIVE_FILE" bs=1M count=32 skip=$(( taille / 2 / 1048576 )) \
          2>/dev/null | gzip -1 -c 2>/dev/null | wc -c)"
  if [ "${comp:-0}" -gt 0 ]; then
    ratio=$(( comp * 100 / brut ))
    log "  compressibilité d'un échantillon : ${ratio} % (100 % = incompressible)"
    [ "$ratio" -ge 99 ] && warn "  échantillon quasi incompressible — cohérent avec du chiffrement"
  fi
fi

# ── Verdict des contrôles ──────────────────────────────────────────────────
if [ ${#ANOMALIES[@]} -gt 0 ]; then
  resume="$(printf '%s ; ' "${ANOMALIES[@]}")"
  if [ "$ANOMALY_ACTION" = "alerter" ]; then
    warn "${#ANOMALIES[@]} anomalie(s) — PRA_ANOMALY_ACTION=alerter, restauration POURSUIVIE"
    notifier alerte "Anomalies détectées, restauration poursuivie" \
      "${resume}Mode « alerter » actif : l'arche restaure malgré tout. Vérifier sans tarder."
  else
    notifier echec "Anomalies dans l'archive — restauration REFUSÉE" \
      "${resume}L'arche conserve son état précédent et n'a rien désinstallé. Si c'est un faux positif, relancer avec PRA_ANOMALY_ACTION=alerter ou ajuster PRA_SIZE_DELTA_MAX."
    die "${#ANOMALIES[@]} anomalie(s) détectée(s) — restauration refusée, l'arche est intacte"
  fi
else
  log "  aucune anomalie"
fi

if [ "$DRY_RUN" = 1 ]; then
  STEP="validation terminée"
  VERDICT="archive valide"
  log "Mode validation : archive conforme et contrôlée, réplica non modifié."
  exit 0
fi

### ─── 5. PRÉPARATION DE L'ARCHIVE ──────────────────────────────────────────
# notify_push doit être désactivé AVANT restauration, sinon la restauration de
# Nextcloud échoue. On extrait donc, on corrige, on ré-archive — mais sans la
# copie préalable de la v1, ce qui économise 12 Go d'écritures.
STEP="préparation de l'archive"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR/extracted"
tar xf "$ARCHIVE_FILE" -C "$WORKDIR/extracted"
log "Extraction faite"

SET_FILE="$WORKDIR/extracted/apps/nextcloud/settings/settings.yml"
if [ -f "$SET_FILE" ]; then
  if grep -q "enable_notify_push: '1'" "$SET_FILE"; then
    sed -i "s/enable_notify_push: '1'/enable_notify_push: '0'/" "$SET_FILE"
    log "notify_push désactivé dans l'archive"
  else
    log "notify_push déjà inactif"
  fi
else
  warn "settings.yml de Nextcloud introuvable, correctif non appliqué"
fi

# ── CHEMINS NODE, CORRIGÉS DANS L'ARCHIVE ───────────────────────────────────
# Même principe que notify_push, et pour la même raison : certaines choses
# doivent être vraies AVANT que YunoHost ne lise l'archive, parce qu'il replie
# toute la restauration si le service ne démarre pas.
#
# Les paquets qui tournent sous node inscrivent dans leur unité systemd le chemin
# EXACT de leur version — /opt/node_n/n/versions/node/22.23.1/bin. Or « n install
# 22 » installe « la dernière 22.x DU JOUR » : deux machines provisionnées à des
# dates différentes n'ont pas la même. Un chiffre d'écart, le chemin n'existe
# pas ici, le lanceur (« #!/usr/bin/env node ») ne trouve rien, le service sort
# en 127 et YunoHost annonce « Nothing was restored ».
#
# YunoHost provisionne pourtant la BONNE version et met son réglage à jour
# (nodejs_version: 22.23.2) — mais il restaure le fichier d'unité TEL QUEL, comme
# une configuration système. C'est donc l'unité qu'il faut corriger, pas le
# réglage.
#
# On réécrit ici, dans l'archive, vers la version la plus récente de la MÊME
# MAJEURE présente sur l'arche. La majeure est respectée : servir node 24 à une
# application qui demande 22 serait échanger une panne franche contre une panne
# subtile.
#
# Le repli /usr/local/bin/node reste installé, mais il ne devrait plus rien
# porter : il ne sert que si aucune version de la majeure demandée n'existe
# encore — cas d'une PREMIÈRE restauration, où « n » n'a pas encore tourné.
STEP="chemins node dans l'archive"
_NODE_RACINE="/opt/node_n/n/versions/node"
if [ -d "$_NODE_RACINE" ]; then
  _n_corriges=0
  while IFS= read -r _unite; do
    [ -f "$_unite" ] || continue
    # « || true » : la PLUPART des unités ne citent aucune version node, et c'est
    # le cas NORMAL. Sans lui, grep rend 1, « pipefail » fait échouer la
    # substitution et « set -e » abat le script — juste après une correction
    # réussie, donc en laissant croire que c'est elle qui a échoué.

    _v="$(grep -oE "$_NODE_RACINE/[0-9]+\.[0-9]+\.[0-9]+" "$_unite" 2>/dev/null \
          | head -1 | sed "s|.*/||" || true)"
    # Pas de version littérale : c'est le gabarit (« __PATH_WITH_NODEJS__ »),
    # rendu par YunoHost à l'installation. Rien à y corriger.
    [ -n "$_v" ] || continue
    [ -x "$_NODE_RACINE/$_v/bin/node" ] && continue   # déjà présente ici

    _maj="${_v%%.*}" _remp=""
    for _cand in "$_NODE_RACINE/$_maj".*; do
      [ -x "$_cand/bin/node" ] || continue
      _cand="${_cand##*/}"
      if [ -z "$_remp" ] \
         || [ "$(printf '%s\n%s\n' "$_remp" "$_cand" | sort -V | tail -1)" = "$_cand" ]; then
        _remp="$_cand"
      fi
    done

    _app="$(printf '%s' "$_unite" | sed 's|.*/extracted/apps/||; s|/.*||')"
    if [ -z "$_remp" ]; then
      log "  $_app : node $_v absent et aucune version $_maj.x ici —"
      log "    la restauration provisionnera la majeure, le repli prendra le relais"
      continue
    fi
    if sed -i "s|$_NODE_RACINE/$_v/|$_NODE_RACINE/$_remp/|g" "$_unite"; then
      log "  $_app : node $_v → $_remp corrigé dans l'archive"
      _n_corriges=$((_n_corriges + 1))
    else
      warn "  $_app : réécriture du chemin node impossible dans l'archive"
    fi
  done < <(find "$WORKDIR/extracted/apps" -type f -name '*.service' 2>/dev/null)
  [ "$_n_corriges" -eq 0 ] && log "aucun chemin node à corriger dans l'archive"
fi

PREPARED="$ARCHIVE_DST/$ARCHIVE_NAME.tar"
tar cf "$WORKDIR/$ARCHIVE_NAME.tar" -C "$WORKDIR/extracted" .
mv -f "$WORKDIR/$ARCHIVE_NAME.tar" "$PREPARED"      # même FS : instantané
chmod 600 "$PREPARED"
rm -rf "$WORKDIR/extracted"
log "Archive préparée : $PREPARED"

### ─── 5 bis. RELEVÉ DES DOMAINES, AVANT TOUTE RESTAURATION ────────────────
# Il FAUT relever ici, et pas après : « yunohost domain list » lit l'annuaire
# LDAP. Restaurer conf_ldap remplace la branche « ou=domains » par celle de la
# production, où les domaines propres à l'arche — les .local des reverse proxies —
# n'existent pas. YunoHost ne les oublie pas seulement pour le courrier : il les
# oublie TOUT COURT, alors que nginx continue de les servir.
#
# Un domaine retiré de l'annuaire disparaît de « yunohost domain list » dans la
# seconde : une réparation qui interrogerait cette commande APRÈS la
# restauration ne verrait donc plus rien à réparer.

STEP="relevé des domaines"
declare -a DOMAINES_AVANT=()
if [[ "$SYSTEM_PARTS" == *conf_ldap* ]]; then
  mapfile -t DOMAINES_AVANT < <(yunohost domain list --output-as plain 2>/dev/null \
    | grep -v '^#' | grep -v '^[[:space:]]*$' | sort -u)
  log "Domaines relevés avant restauration : ${#DOMAINES_AVANT[@]}"
fi

### ─── 6. DÉSINSTALLATION PUIS RESTAURATION ─────────────────────────────────
# Ce n'est qu'ici, l'archive validée et préparée, qu'on touche au réplica.

# UN DOMAINE SANS CERTIFICAT BLOQUE TOUTE OPÉRATION SUR LES APPLICATIONS.
#
# conf_ldap apporte les domaines de la production. L'arche n'a évidemment pas
# leurs certificats, et il suffit d'UN SEUL manquant pour que YunoHost refuse
# d'installer, de restaurer ou de modifier quoi que ce soit :
#   « Impossible de lire le fichier du certificat pour le domaine … »
# Un domaine hérité la nuit précédente peut ainsi empêcher de réinstaller le
# mandataire de l'interface de pilotage — donc d'accéder à l'outil qui sert à
# réparer. Le dispositif se mordrait la queue.
#
# On délivre donc un auto-signé à tout domaine qui en manque. L'arche sert des
# noms .local sur un réseau fermé : une autorité publique n'y a aucun sens, et le
# navigateur avertira de toute façon. Ce qui compte, c'est que YunoHost ait un
# fichier à lire.
#
# Appelé DEUX FOIS : avant la restauration, pour réparer ce qu'une nuit
# précédente a laissé, et après celle du système, pour les domaines qui viennent
# d'arriver. Idempotent.
certifier_domaines_sans_cert() {
  local dom n=0
  while read -r dom; do
    [ -n "$dom" ] || continue
    [ -f "/etc/yunohost/certs/$dom/crt.pem" ] && continue
    if yunohost domain cert install "$dom" --self-signed >/dev/null 2>&1; then
      log "  certificat auto-signé délivré à $dom"
      n=$((n + 1))
    else
      warn "  certificat NON délivré à $dom — les opérations sur les applications échoueront"
    fi
  done < <(yunohost domain list --output-as plain 2>/dev/null \
           | grep -v '^#' | grep -v '^[[:space:]]*$' | sort -u)
  [ "$n" -eq 0 ] && log "  tous les domaines ont un certificat"
  return 0
}

# Rétablit dans l'annuaire les domaines propres à l'arche que la restauration de
# conf_ldap fait disparaître. Idempotent : chaque domaine est vérifié avant
# d'être ajouté, donc appelable plusieurs fois sans dommage.
#
# Défini ici pour être appelable JUSTE APRÈS la restauration du système, et non
# seulement en section 7 quater : c'est le décalage entre les deux qui cause la
# panne.

retablir_domaines_arche() {
  [ "${#DOMAINES_AVANT[@]}" -gt 0 ] || return 0
  command -v ldapsearch >/dev/null 2>&1 && command -v ldapadd >/dev/null 2>&1 || {
    warn "ldapsearch/ldapadd absents — domaines de l'arche non rétablis"; return 0; }
  local dom
  for dom in "${DOMAINES_AVANT[@]}"; do
    [ -n "$dom" ] || continue
    ldapsearch -x -H ldapi:/// -b "ou=domains,dc=yunohost,dc=org" \
      "(virtualdomain=$dom)" dn 2>/dev/null | grep -q "^dn:" && continue
    if printf 'dn: virtualdomain=%s,ou=domains,dc=yunohost,dc=org\nobjectClass: mailDomain\nobjectClass: top\nvirtualdomain: %s\n' \
         "$dom" "$dom" | ldapadd -Q -Y EXTERNAL -H ldapi:/// >/dev/null 2>&1; then
      log "domaine $dom rétabli dans l'annuaire"
    else
      warn "domaine $dom absent de l'annuaire et non rétabli"
    fi
  done
  # Republier les noms .local. Le hook de YunoBox relance yunomdns sur les
  # ÉVÉNEMENTS RÉSEAU ; une restauration ne change pas le réseau, elle change les
  # DOMAINES — le hook ne se déclenche donc pas, et un nom retiré puis remis
  # cesse de résoudre jusqu'à une relance manuelle.

  systemctl restart yunomdns 2>/dev/null \
    && log "publication mDNS des noms .local relancée" || true
}

# LES MOTEURS PARTAGÉS NE DOIVENT PAS DEVENIR ORPHELINS.
#
# On désinstalle TOUTES les applications avant d'en restaurer une seule. Entre
# les deux, plus personne ne réclame MariaDB : YunoHost retire le méta-paquet de
# dépendances de la dernière application concernée, et l'autoremove d'apt PURGE
# mariadb-server — fichiers de configuration compris.
#
# Le retrait du méta-paquet de la dernière application emporte mariadb-server,
# son client, galera et les extensions PHP. Le mécanisme se répare en général
# par accident — restaurer la première application réinstalle la base — mais si
# la restauration échoue avant, le réplica reste sans base de données, donc sans
# aucune de ses applications.
#
# « apt-mark manual » coupe la cause à la racine : un paquet marqué manuel n'est
# jamais retiré par autoremove. Ne pas compter sur la réparation fortuite d'une
# étape ultérieure, qui par définition n'a pas lieu quand ça se passe mal.
STEP="certificats des domaines"
log "Contrôle des certificats avant toute opération"
certifier_domaines_sans_cert

STEP="protection des moteurs de données"
for paquet in mariadb-server postgresql redis-server; do
  if dpkg -l "$paquet" 2>/dev/null | grep -q "^ii"; then
    apt-mark manual "$paquet" >/dev/null 2>&1 \
      && log "  $paquet protégé de l'autoremove" \
      || warn "  impossible de protéger $paquet — surveiller sa présence après restauration"
  fi
done

STEP="désinstallation"
for app in "${TO_RESTORE[@]}"; do
  if is_installed "$app"; then
    log "Désinstallation de $app"
    yunohost app remove "$app" || warn "échec de la désinstallation de $app"
  fi
done

# Filet de sécurité : si un moteur a malgré tout disparu, on le remet AVANT de
# restaurer, sinon chaque application à base de données échouera une par une.
STEP="contrôle des moteurs après désinstallation"
if ! command -v mysql >/dev/null 2>&1; then
  warn "MariaDB a disparu pendant la désinstallation — réinstallation"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    mariadb-server >/dev/null 2>&1 \
    && { log "  mariadb-server réinstallé"; systemctl start mariadb 2>/dev/null || true; } \
    || warn "  ÉCHEC — les applications à base de données ne pourront pas être restaurées"
fi

STEP="restauration"
log "Restauration de ${#TO_RESTORE[@]} applications"

# DEUX APPELS SÉPARÉS, LES APPLICATIONS D'ABORD.
#
# Un seul appel portant les applications ET conf_ldap échoue en bloc. YunoHost
# restaure le système en premier : conf_ldap remplace la branche « ou=domains »
# par celle de la production, les domaines propres au réplica disparaissent,
# puis app_ssowatconf() tombe sur les applications installées sur ces domaines
# devenus inconnus — StopIteration, « critical error during restoration », et
# TOUTE la restauration abandonnée. Les applications ne sont alors jamais
# touchées, la base purgée juste avant ne revient pas, et le réplica se
# retrouve sans aucun service.
#
# Le garde-fou existait déjà — la section 7 quater recrée ces domaines — mais il
# était après la commande, alors que YunoHost meurt dedans. Un filet placé après
# la chute ne rattrape personne.
#
# Les applications sont donc restaurées seules, puis le système à part. Un échec
# sur l'annuaire ne peut plus emporter les applications avec lui.
if yunohost backup restore "$ARCHIVE_NAME" --apps "${TO_RESTORE[@]}" --force; then
  log "Restauration terminée"
else
  warn "la restauration a signalé une erreur, contrôle application par application"
fi

# Parties SYSTÈME, appel distinct. Vide par défaut hors conf_ldap :
# « conf_ynh_settings » et « conf_ynh_certs » portent la configuration des
# domaines de production et entreraient en conflit avec ceux de l'arche.
# « conf_ldap » apporte les utilisateurs, les groupes et les permissions — sans
# lui, l'arche dérive silencieusement de la production et personne ne peut s'y
# connecter le jour venu. Réglable depuis la webapp.
if [ -n "${SYSTEM_PARTS// /}" ]; then
  STEP="parties système"
  read -r -a _sp <<< "$SYSTEM_PARTS"
  log "Parties système, appel séparé : ${_sp[*]}"
  if yunohost backup restore "$ARCHIVE_NAME" --system "${_sp[@]}" --force; then
    log "  parties système restaurées"
  else
    # Un échec est ATTENDU avec conf_ldap tant que des applications de l'arche
    # vivent sur des .local : YunoHost restaure l'annuaire, puis échoue en
    # reconstruisant la configuration SSO. L'annuaire est déjà en place à ce
    # moment — c'est la reconstruction qui manque, et on la refait juste après.
    warn "  parties système : erreur signalée (attendu avec conf_ldap)"
  fi
  # IMMÉDIATEMENT : rétablir les domaines, puis reconstruire le SSO. Ne pas
  # attendre une section ultérieure — c'est exactement l'erreur qui coûte la nuit
  # entière.
  # LA SÉQUENCE COMPLÈTE, DANS CET ORDRE. Chaque maillon dépend du précédent, et
  # il en manquait un : nginx.
  #
  #   1. les domaines dans l'annuaire — sinon YunoHost ignore leur existence ;
  #   2. un certificat pour chacun — sinon toute opération sur une application
  #      échoue ;
  #   3. les vhosts nginx — sinon les domaines n'ont AUCUN bloc « server » ;
  #   4. la configuration SSO — sinon le portail et les permissions divergent.
  #
  # Omettre le maillon 3 donne une panne trompeuse : les répertoires
  # /etc/nginx/conf.d/<domaine>.d/ contiennent bien les configurations des
  # applications, mais aucun fichier <domaine>.conf ne les inclut. Les domaines
  # locaux tombent alors sur le serveur par défaut, qui redirige vers
  # /yunohost/admin — on croit à un problème de permission SSO alors que nginx ne
  # connaît tout simplement pas le domaine.

  retablir_domaines_arche

  log "  certificats des domaines hérités de la production"
  certifier_domaines_sans_cert

  # nginx AVANT ssowat : ssowat s'appuie sur les vhosts existants.
  if yunohost tools regen-conf nginx --force >/dev/null 2>&1; then
    log "  vhosts nginx reconstruits"
  else
    warn "  vhosts nginx NON reconstruits — les domaines .local tomberont sur"
    warn "    le serveur par défaut (redirection vers /yunohost/admin)"
  fi

  # « yunohost app ssowatconf » et NON « regen-conf ssowat » : cette catégorie
  # n'existe pas — la commande rendait « No regen-conf categories named 'ssowat' »
  # et l'avertissement sortait à chaque restauration, en désignant une panne
  # imaginaire — tout le reste de la séquence fonctionne, seul ce maillon est mal
  # nommé.

  if yunohost app ssowatconf >/dev/null 2>&1; then
    log "  configuration SSO reconstruite"
  else
    warn "  configuration SSO non reconstruite — vérifier l'accès au portail"
  fi

  # CONTRÔLE EFFECTIF, et non la confiance dans les codes de retour ci-dessus :
  # un domaine sans vhost est invisible à tout ce qui précède.
  _sans_vhost=""
  while read -r _d; do
    [ -n "$_d" ] || continue
    [ -f "/etc/nginx/conf.d/$_d.conf" ] || _sans_vhost="$_sans_vhost $_d"
  done < <(yunohost domain list --output-as plain 2>/dev/null \
           | grep -v '^#' | grep -v '^[[:space:]]*$' | sort -u)
  if [ -n "${_sans_vhost// /}" ]; then
    warn "  domaines SANS bloc server nginx :$_sans_vhost"
    warn "    ils redirigeront vers /yunohost/admin. Corriger avec :"
    warn "    yunohost tools regen-conf nginx --force"
  else
    log "  tous les domaines ont un bloc server nginx"
  fi
fi

# Vérification effective, indépendamment du code de retour de YunoHost.
STEP="contrôle après restauration"
mapfile -t INSTALLED < <(yunohost app list --output-as json 2>/dev/null | python3 -c \
  'import json,sys; print("\n".join(a["id"] for a in json.load(sys.stdin).get("apps",[])))')
FAILED=()
for row in "${APP_TABLE[@]}"; do
  IFS='|' read -r app dom path <<<"$row"
  printf '%s\n' "${TO_RESTORE[@]}" | grep -qx "$app" || continue
  if is_installed "$app" && ! app_is_hollow "$app" "$dom"; then
    record "$app" "restaurée"
  else
    record "$app" "ÉCHEC"; FAILED+=("$app")
  fi
done

### ─── 7. RÉGLAGES POST-RESTAURATION ───────────────────────────────────────
STEP="réglages des URL"

# Vérifie que l'URL est RÉELLEMENT en place : le code de retour de change-url
# ne suffit pas, certains paquets le renvoient à 0 sans avoir tout réécrit.
url_is_applied() {
  local app="$1" dom="$2" path="$3" cur_dom cur_path
  cur_dom="$(yunohost app setting "$app" domain 2>/dev/null || true)"
  cur_path="$(yunohost app setting "$app" path 2>/dev/null || true)"
  [ "$cur_dom" = "$dom" ] || return 1
  [ "${cur_path%/}" = "${path%/}" ] || return 1
  [ -f "/etc/nginx/conf.d/$dom.d/$app.conf" ] || return 1
  return 0
}

# Certains paquets ont un script change_url incomplet ou absent : seule une mise
# à niveau forcée réexécute toute la configuration. On garde donc ce filet, mais
# il ne se déclenche QUE si la vérification échoue — au lieu d'être appliqué
# chaque nuit à toutes les applications, ce qui provoquait des échecs sur VLAN
# isolé (sources injoignables) et faisait courir un standby après la dernière
# version alors qu'on veut de la stabilité.
ensure_url() {
  local app="$1" dom="$2" path="$3"
  if url_is_applied "$app" "$dom" "$path"; then
    log "URL de $app déjà conforme ($dom$path)"; return 0
  fi
  if yunohost app change-url "$app" --domain "$dom" --path "$path" 2>/dev/null \
     && url_is_applied "$app" "$dom" "$path"; then
    log "URL de $app → $dom$path"; return 0
  fi
  warn "change-url insuffisant pour $app — reconfiguration forcée"
  if yunohost app upgrade "$app" --force 2>/dev/null \
     && url_is_applied "$app" "$dom" "$path"; then
    log "URL de $app rétablie après reconfiguration forcée"; return 0
  fi
  warn "URL de $app NON conforme (attendu $dom$path) — à vérifier à la main"
  return 1
}

for row in "${APP_TABLE[@]}"; do
  IFS='|' read -r app dom path <<<"$row"
  [ -z "$path" ] && continue          # coturn et assimilés : pas d'URL web
  is_installed "$app" || continue
  printf '%s\n' "${FAILED[@]:-}" | grep -qx "$app" && continue
  ensure_url "$app" "$dom" "$path" || record "$app" "restaurée, URL à vérifier"
done

STEP="Collabora"
if command -v "$PHP_BIN" >/dev/null 2>&1 && [ -f "$NEXTCLOUD_OCC" ] && is_installed nextcloud; then
  occ() { sudo -u "$OCC_USER" "$PHP_BIN" -d memory_limit=1G "$NEXTCLOUD_OCC" "$@"; }

  # Nextcloud 33 crée /tmp/sfi_file_sequence_<instanceid> en 0700 pour son
  # générateur d'identifiants Snowflake (lib/private/Snowflake/FileSequence.php).
  # Le répertoire appartient au PREMIER utilisateur qui l'a créé : si ce n'est
  # pas « nextcloud », toute commande occ échoue ensuite sur
  # « File sequence directory exists but is not writable ».
  #
  # En pratique le propriétaire est la PREMIÈRE application restaurée par ce
  # script, pas Nextcloud : le cas se reproduit donc à chaque restauration. Ce
  # sont des verrous transitoires (TTL 30 s) : les supprimer est sans effet de
  # bord, ils sont recréés au bon propriétaire.

  for sfi in /tmp/sfi_file_sequence_*; do
    [ -d "$sfi" ] || continue
    sfi_owner="$(stat -c %U "$sfi" 2>/dev/null || echo '?')"
    if [ "$sfi_owner" != "$OCC_USER" ]; then
      log "verrous Snowflake appartenant à « $sfi_owner » — suppression"
      rm -rf "$sfi"
    fi
  done
  # La v1 écrivait « ✔ installé » dans la branche d'ERREUR : les journaux
  # annonçaient donc un succès précisément quand la commande échouait.
  for app in onlyoffice richdocumentscode; do
    if occ app:remove "$app" >/dev/null 2>&1; then log "$app retiré de Nextcloud"
    else log "$app déjà absent"; fi
  done
  for app in richdocuments richdocumentscode_arm64; do
    if occ app:install "$app" >/dev/null 2>&1; then log "$app installé"
    elif occ app:enable "$app" >/dev/null 2>&1; then log "$app activé"
    else warn "$app : installation ET activation ont échoué"; fi
  done

  # Un domaine .local ne peut pas avoir de certificat public : YunoHost le signe
  # avec sa propre autorité. Or Nextcloud s'appelle lui-même en HTTPS pour la
  # découverte du serveur Collabora, avec un magasin de certificats qui lui est
  # propre — d'où l'échec « cURL error 60 » que le réglage applicatif
  # disable_certificate_verification ne corrige PAS. Il faut importer l'autorité.
  #
  # Le repli ne sert que si le réglage est illisible — Nextcloud est alors déjà
  # cassé, et la suite se contentera d'avertir plutôt que d'agir à l'aveugle.
  NC_DOMAIN="$(yunohost app setting nextcloud domain 2>/dev/null || echo "${PRA_NEXTCLOUD_DOMAIN:-localhost}")"
  NC_PATH="$(yunohost app setting nextcloud path 2>/dev/null || echo /nextcloud)"
  CRT="/etc/yunohost/certs/$NC_DOMAIN/crt.pem"

  # On NE prend PAS /etc/yunohost/certs/<domaine>/ca.pem, comme le faisait la v1.
  # Ce lien peut mener à une autorité qui n'est PAS celle ayant signé le
  # certificat servi par nginx : YunoHost régénère son autorité sans réémettre la
  # feuille. L'import réussit alors sans rien résoudre, et la découverte échoue
  # toujours en « self-signed certificate in chain ».
  #
  # La seule source fiable est la chaîne RÉELLEMENT SERVIE : crt.pem contient la
  # feuille puis son autorité émettrice. On la vérifie avant de l'installer —
  # ajouter un point d'ancrage de confiance sans contrôle serait pire que le mal.
  TMP_CA="$(mktemp /tmp/ynh-ca-XXXXXX.pem)"
  TMP_LEAF="$(mktemp /tmp/ynh-leaf-XXXXXX.pem)"
  if [ -r "$CRT" ] \
     && awk 'BEGIN{n=0} /BEGIN CERT/{n++} n==1' "$CRT" > "$TMP_LEAF" 2>/dev/null \
     && awk 'BEGIN{n=0} /BEGIN CERT/{n++} n>=2' "$CRT" > "$TMP_CA" 2>/dev/null \
     && [ -s "$TMP_CA" ] \
     && openssl verify -CAfile "$TMP_CA" "$TMP_LEAF" >/dev/null 2>&1; then
    chmod 644 "$TMP_CA"
    # Magasin SYSTÈME : c'est celui que consulte curl, donc PHP, donc Nextcloud
    # quand il va chercher sa propre découverte WOPI.
    if install -m 644 "$TMP_CA" /usr/local/share/ca-certificates/yunohost-arche-ca.crt \
       && update-ca-certificates >/dev/null 2>&1; then
      log "autorité de $NC_DOMAIN installée dans le magasin système"
    else
      warn "installation de l'autorité dans le magasin système impossible"
    fi
    # Magasin propre à Nextcloud, consulté par certains de ses appels.
    if occ security:certificates:import "$TMP_CA" >/dev/null 2>&1; then
      log "autorité importée dans Nextcloud ($NC_DOMAIN)"
    else
      warn "import de l'autorité dans Nextcloud impossible"
    fi
    systemctl restart "${PHP_BIN}-fpm" 2>/dev/null || true
  else
    warn "autorité émettrice introuvable ou invalide dans $CRT"
    warn "  la bureautique en ligne restera inutilisable"
  fi
  rm -f "$TMP_CA" "$TMP_LEAF"

  # ── Bureautique en ligne : la ramener sur le réplica ───────────────────────
  # wopi_url vit dans la BASE de Nextcloud, pas dans un réglage YunoHost : il
  # échappe donc entièrement à l'adaptation des URL de cette section et reste
  # pointé sur le domaine de PRODUCTION après restauration. Autrement dit, le
  # seul jour où le réplica sert — production morte — ouvrir un document
  # échouerait, Nextcloud allant chercher son moteur sur le serveur en panne. Le
  # moteur embarqué arm64 est installé juste au-dessus : on l'utilise.

  MOTEUR=""
  for a in richdocumentscode_arm64 richdocumentscode; do
    if occ app:getpath "$a" >/dev/null 2>&1; then MOTEUR="$a"; break; fi
  done
  if [ -n "$MOTEUR" ]; then
    occ config:app:set richdocuments wopi_url \
      --value="https://${NC_DOMAIN}${NC_PATH%/}/apps/$MOTEUR/proxy.php?req=" >/dev/null 2>&1 || true
    occ config:app:set richdocuments public_wopi_url \
      --value="https://$NC_DOMAIN" >/dev/null 2>&1 || true
    # activate-config exécute le contrôle intégré de Nextcloud : il récupère la
    # découverte, valide les types MIME et les capacités. On ne se contente pas
    # de son code de retour, on exige la preuve qu'un moteur a été détecté.
    if occ richdocuments:activate-config 2>&1 | grep -q "Detected WOPI server"; then
      log "bureautique en ligne → moteur local $MOTEUR (${NC_DOMAIN}${NC_PATH%/})"
    else
      warn "bureautique en ligne : $MOTEUR ne répond pas, documents non ouvrables"
    fi
  else
    warn "aucun moteur Collabora embarqué — bureautique en ligne indisponible"
  fi
fi

### ─── 7 ter. ORDONNANCEMENT AU DÉMARRAGE ──────────────────────────────────
# Certaines applications YunoHost ne déclarent AUCUNE dépendance vers le service
# dont elles ont besoin. Au démarrage de la machine elles perdent la course, et
# systemd abandonne après 5 tentatives en 10 s : le service reste mort jusqu'à
# une intervention.
#
# Le symptôme est toujours le même : « Connection refused » vers Redis, MySQL ou
# PostgreSQL, puis « Start request repeated too quickly ». Or le réplica
# REDÉMARRE chaque nuit — c'est son mode de fonctionnement normal — et
# l'application manquante est souvent celle qu'on vient consulter en crise.
#
# On ne modifie pas l'unité elle-même, que la restauration réécrit : on pose un
# complément dans <unité>.service.d/, réappliqué ici à chaque nuit.
### ─── 7 quater. DOMAINES PROPRES À L'ARCHE ────────────────────────────────
# La restauration de conf_ldap remplace la branche « ou=domains » par celle de la
# production. Les domaines propres au réplica — ceux en « .local » sur lesquels
# ses applications sont servies — n'y sont pas et disparaissent donc du LDAP,
# alors que YunoHost et nginx continuent de les servir.
#
# Aucune conséquence visible : ces entrées ne servent qu'au routage du courrier,
# que l'arche ne fait pas. Mais un annuaire qui ignore des domaines que la machine
# héberge est un état incohérent, et les états incohérents se paient plus tard.
# Deuxième passage, en filet. Le rétablissement a normalement déjà eu lieu juste
# après la restauration du système ; cet appel rattrape un domaine perdu par une
# étape intermédiaire. Idempotent, donc sans effet si tout est en ordre.
STEP="domaines de l'arche"
retablir_domaines_arche

### ─── 7 quinquies. AUCUNE APPLICATION NE DOIT RESTER SUR LA PRODUCTION ─────
# Une application restaurée qui garde le domaine de production est inaccessible
# depuis l'arche — et elle l'est précisément le jour où l'on en a besoin, puisque
# ce domaine pointe alors vers une machine morte ou compromise.
#
# Le cas passe facilement inaperçu : l'application est restaurée, active, et
# seul l'accès manque. La règle est simple et vaut d'être vérifiée à chaque
# nuit : TOUTE application servie par le réplica doit l'être sur un domaine
# « .local ».
STEP="vérification des domaines applicatifs"
if command -v yunohost >/dev/null 2>&1; then
  restantes=""
  while read -r app; do
    [ -n "$app" ] || continue
    dom="$(yunohost app setting "$app" domain 2>/dev/null)"
    case "$dom" in
      ""|*.local) : ;;
      *) restantes="$restantes $app($dom)" ;;
    esac
  done <<< "$(yunohost app list --output-as json 2>/dev/null \
              | python3 -c 'import json,sys
try:
    for a in json.load(sys.stdin)["apps"]: print(a["id"])
except Exception: pass' 2>/dev/null)"

  if [ -n "$restantes" ]; then
    warn "applications restées hors d'un domaine .local :$restantes"
    warn "  elles seront inaccessibles depuis l'arche — ajoutez-les à APP_TABLE"
    notifier alerte "Applications hors .local" \
      "Sur l'arche, ces applications gardent un domaine de production et seront donc inaccessibles en crise :$restantes"
  else
    log "Toutes les applications sont servies sur un domaine .local"
  fi
fi

### ─── 7 sexies. LES PORTES DE SECOURS DOIVENT RESTER OUVERTES ───────────────
# SSOwat DEVANT UNE APPLICATION QUI S'AUTHENTIFIE SEULE REND SA PORTE DE SECOURS
# INACCESSIBLE.
#
# Une application qui s'authentifie elle-même — par OIDC auprès d'un
# fournisseur local, par exemple — peut offrir une entrée par mot de passe pour
# le jour où ce fournisseur ou l'annuaire ne répondent plus. Or la restauration
# rapporte la permission de la PRODUCTION, où elle est — à juste titre —
# réservée aux utilisateurs authentifiés : SSOwat intercepte alors la requête et
# renvoie au portail. On ne peut donc jamais atteindre la porte de secours, qui
# n'existe que pour le cas où le portail est mort. Le symptôme trompe : le
# domaine redirige vers /yunohost/sso alors que l'application répond
# parfaitement sur son port local.
#
# On force donc « visitors » SUR L'ARCHE UNIQUEMENT, et à chaque restauration —
# sinon la permission de production revient chaque nuit. Ce n'est pas une
# ouverture au sens large : l'arche vit sur un réseau fermé, et l'application
# demande ses propres identifiants derrière.
STEP="permissions des portes de secours"
# Identifiants YunoHost des applications concernées, séparés par des ESPACES —
# c'est la forme qu'écrit la configuration. Vide par défaut : sans déclaration
# explicite, aucune permission n'est ouverte.
: "${PRA_PERMS_VISITEURS:=}"
read -r -a _perms_visiteurs <<< "$PRA_PERMS_VISITEURS"
for _perm in "${_perms_visiteurs[@]:-}"; do
[ -n "$_perm" ] || continue
is_installed "$_perm" || continue
  # JSON et non le texte : « allowed » se présente tantôt sur une ligne
  # (« allowed: visitors »), tantôt en liste multiligne. Un grep sur la première
  # forme rate la seconde et l'on croit devoir agir alors que tout va bien.
  if yunohost user permission info "$_perm.main" --output-as json 2>/dev/null \
     | python3 -c 'import json,sys
try:    a = json.load(sys.stdin).get("allowed", [])
except Exception: sys.exit(1)
sys.exit(0 if "visitors" in (a if isinstance(a, list) else [a]) else 1)' 2>/dev/null; then
    log "  $_perm : déjà ouvert aux visiteurs"
    continue
  fi
  if yunohost user permission add "$_perm.main" visitors >/dev/null 2>&1; then
    log "  $_perm : ouvert aux visiteurs (authentification assurée par l'application)"
  else
    warn "  $_perm : permission NON modifiée — SSOwat masquera la porte de secours"
  fi
done

STEP="ordonnancement des services"
# « application|unité » par ligne : l'unité dont l'application a besoin au
# démarrage. Vide par défaut, donc sans effet tant que rien n'est déclaré.
declare -A DEPENDANCES=()
DEPENDANCES_FICHIER="${PRA_DEPENDANCES:-/etc/pra/dependances.list}"
if [ -r "$DEPENDANCES_FICHIER" ]; then
while IFS= read -r _ligne; do
case "$_ligne" in ''|\#*) continue ;; esac
_app="${_ligne%%|*}"; _dep="${_ligne#*|}"
[ -n "$_app" ] && [ -n "$_dep" ] && [ "$_app" != "$_ligne" ] \
&& DEPENDANCES["$_app"]="$_dep"
done < "$DEPENDANCES_FICHIER"
unset _app _dep _ligne
fi
for app in "${!DEPENDANCES[@]}"; do
  is_installed "$app" || continue
  dep="${DEPENDANCES[$app]}"
  systemctl list-unit-files "$dep" >/dev/null 2>&1 || {
    warn "  $dep absent — dépendance de $app non posée"; continue; }
  d="/etc/systemd/system/${app}.service.d"
  mkdir -p "$d"
  cat > "$d/pra-ordre.conf" <<CONF
# Posé par pra_restore_replica.sh — ne pas modifier à la main.
[Unit]
After=$dep
Wants=$dep
# Laisser le temps au service dont il dépend : 10 tentatives sur 5 minutes au
# lieu de 5 sur 10 secondes.
StartLimitIntervalSec=300
StartLimitBurst=10

[Service]
RestartSec=5
CONF
  log "ordonnancement de $app après $dep"
done
systemctl daemon-reload 2>/dev/null || true

STEP="redémarrage des services"
systemctl restart nginx || warn "nginx n'a pas redémarré"
systemctl restart "${PHP_BIN}-fpm" 2>/dev/null || warn "${PHP_BIN}-fpm n'a pas redémarré"
systemctl restart mariadb 2>/dev/null || systemctl restart mysql 2>/dev/null || true

### ─── 8. PURGE ─────────────────────────────────────────────────────────────
# Une purge limitée à *.tar laisse s'accumuler les fichiers temporaires de rsync
# (.nom.tar.XXXXXX), abandonnés par tout transfert interrompu : plusieurs
# gigaoctets invisibles.
STEP="purge"

# Conserve inconditionnellement les KEEP_MIN archives les plus récentes, puis
# n'applique le critère d'âge qu'au-delà. Garantit qu'il reste toujours de quoi
# restaurer, même après une longue série d'échecs.
purge_dir() {
  local dir="$1" also_info="$2" f raison
  local -i garde=0 purge=0

  # Rétention grand-père/père/fils si la bibliothèque est disponible ; sinon on
  # retombe sur l'ancien comportement plutôt que de ne rien purger du tout.
  if ! declare -F decisions_gfs >/dev/null; then
    warn "$RETENTION_LIB absent — rétention par ancienneté simple"
    purge_dir_ancien "$dir" "$also_info"
    return
  fi

  # Le danger d'un schéma à trois strates n'est pas de trop garder, c'est de
  # supprimer la mauvaise catégorie — d'où l'intérêt de journaliser les décisions
  # sans agir pendant quelques semaines avant de faire confiance au schéma. Mais
  # l'autre danger est le plus pressant : ne rien supprimer finit par remplir le
  # disque. L'application est donc le défaut ; PRA_PURGE_APPLIQUER=0 rend le
  # compte rendu seul.
  while read -r verdict f raison; do
    case "$verdict" in
      GARDER) garde+=1; log "  garder  $(basename "$f")  ${raison}" ;;
      PURGER)
        purge+=1
        if [ "$PURGE_APPLIQUER" = 1 ]; then
          rm -f "$f"
          [ "$also_info" = 1 ] && rm -f "${f%.tar}.info.json"
          rm -f "${f}.sha256"
          log "  PURGÉ   $(basename "$f")"
        else
          log "  à purger $(basename "$f")  (compte rendu seul)"
        fi
        ;;
    esac
  done < <(decisions_gfs "$dir")

  if [ "$PURGE_APPLIQUER" = 1 ]; then
    log "$dir : $garde conservée(s), $purge supprimée(s)"
  else
    log "$dir : $garde conservée(s), $purge à purger — PRA_PURGE_APPLIQUER=1 pour agir"
  fi
}

# Comportement historique, conservé comme repli si la bibliothèque de
# rétention est absente : mieux vaut une purge simple que pas de purge.
purge_dir_ancien() {
  local dir="$1" also_info="$2" i n
  local -a files
  mapfile -t files < <(find "$dir" -maxdepth 1 -type f -name '*.tar' \
      -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  n=${#files[@]}
  if [ "$n" -le "$KEEP_MIN" ]; then
    log "$dir : $n archive(s) — conservation garantie (minimum $KEEP_MIN)"
    return
  fi
  for ((i = KEEP_MIN; i < n; i++)); do
    if [ -n "$(find "${files[i]}" -mtime "+$RETENTION_DAYS" -print -quit 2>/dev/null)" ]; then
      rm -f "${files[i]}"
      [ "$also_info" = 1 ] && rm -f "${files[i]%.tar}.info.json"
      log "purge : $(basename "${files[i]}")"
    fi
  done
  log "$dir : $n archive(s), $KEEP_MIN conservée(s) d'office, purge au-delà de $RETENTION_DAYS jours"
}

purge_dir "$ARCHIVE_DST" 1
purge_dir "$BACKUP_SRC" 0

# Une purge limitée à *.tar laisse derrière elle les fichiers temporaires de
# rsync (.nom.tar.XXXXXX) qu'un transfert interrompu abandonne.
find "$BACKUP_SRC" -maxdepth 1 -type f -name '.*.tar.*' -mtime +1 -delete
find "$BACKUP_SRC" -type d -name '.rsync-partial' -empty -delete 2>/dev/null || true
# Les quarantaines : un instantané à l'empreinte non conforme est renommé
# « *.corrompu-<horodatage> » plutôt que supprimé — c'est un indice si la
# production envoie des fichiers altérés. Trente jours suffisent à l'examiner ;
# au-delà, c'est un fichier de 28 Mo que plus personne ne regardera.
find "$BACKUP_SRC" -maxdepth 1 -type f -name '*.corrompu-*' -mtime +30 \
  -print -delete 2>/dev/null | while IFS= read -r _q; do
    log "purge quarantaine : $(basename "$_q")"
  done || true
# Les archives contiennent les données de toutes les applications : elles ne
# doivent jamais être lisibles par le tout-venant.
chmod 600 "$BACKUP_SRC"/*.tar 2>/dev/null || true

### ─── 7 bis. CLIENTS OIDC DE DEX ──────────────────────────────────────────
# Les clients statiques de dex listent des URI de redirection ABSOLUES, figées
# sur les domaines de production. Sur le réplica, les applications répondent sur
# leurs domaines « .local » : dex refuse alors la redirection et la connexion
# est impossible, sans que rien d'autre ne paraisse cassé — le symptôme le plus
# difficile à rattacher à sa cause.
#
# On AJOUTE l'URI du réplica sans retirer celle de production : une URI en trop
# est sans effet, une URI manquante interdit toute connexion. La configuration
# est reconstruite par regenerate_config.sh à partir de config.yaml.d/, c'est
# donc bien là qu'il faut écrire pour que la correction survive.
STEP="clients OIDC de dex"
# Chemins de l'application dex de YunoHost ; redéfinissables si la pile diffère.
DEX_CLIENTS="${PRA_DEX_CLIENTS:-/var/www/dex/config.yaml.d}"
if [ -d "$DEX_CLIENTS" ] && [ ${#DOMAIN_MAP[@]} -gt 0 ]; then
  log "Adaptation des URI de redirection OIDC"
  if DEX_AJOUTS="$(printf '%s\n' "${DOMAIN_MAP[@]}" | python3 -c '
import sys, os, re, glob

pairs = [l.strip().split("|", 1) for l in sys.stdin if "|" in l]
ajouts = []
for f in sorted(glob.glob(os.path.join(sys.argv[1], "*"))):
    if not os.path.isfile(f):
        continue
    try:
        lignes = open(f, encoding="utf-8").read().splitlines()
    except OSError:
        continue
    presentes = set(lignes)
    sortie, change = [], False
    for ligne in lignes:
        sortie.append(ligne)
        m = re.match(r"^(\s*)-\s*(https?://\S+)$", ligne)
        if not m:
            continue
        indent, uri = m.groups()
        for src, dst in pairs:
            if src not in uri:
                continue
            neuve = f"{indent}- {uri.replace(src, dst)}"
            if neuve not in presentes:
                sortie.append(neuve)
                presentes.add(neuve)
                ajouts.append(f"{os.path.basename(f)} : {neuve.strip()[2:]}")
                change = True
    if change:
        open(f, "w", encoding="utf-8").write("\n".join(sortie) + "\n")
print("\n".join(ajouts))
' "$DEX_CLIENTS" 2>&1)"; then
    if [ -n "$DEX_AJOUTS" ]; then
      while IFS= read -r l; do log "  + $l"; done <<< "$DEX_AJOUTS"
      # Reconstruire la configuration et redémarrer, sinon dex garde l'ancienne.
      [ -x /var/www/dex/regenerate_config.sh ] && /var/www/dex/regenerate_config.sh || true
      systemctl restart dex 2>/dev/null || warn "  redémarrage de dex impossible"
      sleep 2
      if systemctl is-active --quiet dex; then
        log "  dex redémarré avec les URI de l'arche"
      else
        warn "  dex ne redémarre pas après adaptation"; FAILED+=("dex")
      fi
    else
      log "  aucune URI à adapter"
    fi
  else
    warn "  adaptation des clients OIDC en échec : $DEX_AJOUTS"
  fi
fi

### ─── 8 aleph. CHEMINS NODE DES UNITÉS VENUES DE LA PRODUCTION ─────────────
# LE REPLI EST UN AIRBAG, PAS UNE RÉPARATION.
#
# Les paquets qui tournent sous node écrivent dans leur unité systemd le chemin
# EXACT de leur version. « n install 22 » installant « la dernière 22.x DU JOUR »,
# deux machines provisionnées à des dates différentes divergent d'un chiffre, et
# le chemin n'existe donc pas ici — d'où
# « env: node: No such file or directory », service en 127, et YunoHost qui
# replie TOUTE la restauration.
#
# /usr/local/bin/node rattrape ce cas et permet à la restauration d'aboutir. Mais
# il choisit la version la plus récente installée, TOUTES MAJEURES CONFONDUES :
# le jour où une autre application installera node 24, n8n le recevrait aussi.
# La panne serait reportée, pas supprimée.
#
# On réécrit donc le chemin vers une version qui existe, EN RESPECTANT LA MAJEURE.
# L'application ne dépend alors plus du repli, qui redevient ce qu'il doit être :
# un filet pour le passage suivant.
if [ "$REPARER_BINAIRES" = 1 ]; then
  STEP="chemins node des unités"
  _node_racine="/opt/node_n/n/versions/node"
  if [ -d "$_node_racine" ]; then
    for _u in /etc/systemd/system/*.service; do
      [ -f "$_u" ] || continue
      # La version citée par l'unité, s'il y en a une. « || true » pour la même
      # raison qu'en section 5 : la plupart des unités du système n'en citent
      # aucune, et sans lui grep rend 1, pipefail fait échouer la substitution et
      # set -e abat le script sur un cas parfaitement normal.
      _v="$(grep -oE "$_node_racine/[0-9]+\.[0-9]+\.[0-9]+" "$_u" 2>/dev/null \
            | head -1 | sed "s|.*/||" || true)"
      [ -n "$_v" ] || continue
      [ -x "$_node_racine/$_v/bin/node" ] && continue   # elle existe : rien à faire

      # Glob et non « ls | grep » : les noms de version sont numériques, mais la
      # règle vaut quand même — un glob ne se fait pas surprendre par un nom
      # inattendu dans le répertoire.
      _maj="${_v%%.*}"
      _remp=""
      for _cand in "$_node_racine/$_maj".*; do
        [ -x "$_cand/bin/node" ] || continue
        _cand="${_cand##*/}"
        if [ -z "$_remp" ] \
           || [ "$(printf '%s\n%s\n' "$_remp" "$_cand" | sort -V | tail -1)" = "$_cand" ]; then
          _remp="$_cand"
        fi
      done
      _nom="$(basename "$_u")"
      if [ -z "$_remp" ]; then
        warn "  $_nom réclame node $_v (absent) et AUCUNE version $_maj.x n'est installée"
        warn "    le service ne tiendra que par le repli /usr/local/bin/node"
        continue
      fi
      if sed -i "s|$_node_racine/$_v/|$_node_racine/$_remp/|g" "$_u"; then
        log "  $_nom : node $_v → $_remp (version absente remplacée)"
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart "$_nom" 2>/dev/null \
          && log "    service redémarré sur la bonne version" \
          || warn "    redémarrage refusé — vérifier « systemctl status $_nom »"
      else
        warn "  $_nom : réécriture du chemin node impossible"
      fi
    done
  fi
fi

# ── COFFRE DES BINAIRES DE LA BONNE ARCHITECTURE ────────────────────────────
#
# L'ARCHE NE DOIT PAS DÉPENDRE D'INTERNET POUR SE RÉPARER.
#
# La réparation d'un binaire x86 passe par « yunohost app upgrade --force », qui
# retélécharge — parfois en extrayant une image Docker officielle. Une panne de
# DNS de quelques secondes suffit alors à laisser l'application inexécutable
# jusqu'au matin ; quand c'est le fournisseur d'identité, personne ne se
# connecte à rien.
#
# Or le jour d'une vraie crise, le réseau est exactement ce dont on ne dispose
# pas. On garde donc une copie de chaque binaire réparé avec succès, et l'on s'en
# sert quand le téléchargement échoue. L'arche apprend de ses propres réparations
# et devient autonome — ce qu'elle aurait toujours dû être.
#
# On ne copie QUE ce dont on a vérifié l'architecture : un binaire x86 mis au
# coffre serait un piège qui se déclencherait la nuit où l'on en a besoin.
_binaire_du_service() {         # $1 application -> chemin du binaire, ou rien
  local app="$1" exe
  exe="$(systemctl show -p ExecStart --value "$app" 2>/dev/null \
         | sed -nE 's/.*path=([^ ;]+).*/\1/p' | head -1 || true)"
  [ -n "$exe" ] && [ -f "$exe" ] || return 0
  # LES BINAIRES DE DEBIAN NE NOUS REGARDENT PAS.
  #
  # Le coffre existe pour les binaires que l'application APPORTE — ceux que la
  # production a compilés pour x86 et qui n'ont rien à faire ici. Ce qui vient
  # d'un paquet Debian est déjà de la bonne architecture, puisque apt l'a
  # installé sur cette machine, et se répare par « apt install --reinstall ».
  #
  # Sans ce filtre, une unité sans vrai binaire met « /bin/true » au coffre : on
  # archive quelques kilo-octets pour rien, et une éventuelle « réparation »
  # remplacerait /bin/true par lui-même en annonçant un succès.
  case "$exe" in
    /bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/lib/*) return 0 ;;
  esac
  printf '%s' "$exe"
}

_garder_binaire_local() {       # $1 application  $2 coffre
  local app="$1" coffre="$2" exe
  exe="$(_binaire_du_service "$app")" || return 0
  [ -n "$exe" ] || return 0
  # Vérification avant mise au coffre : on n'archive pas un binaire qu'on ne
  # pourrait pas exécuter. Le critère est celui de la détection ci-dessous, pris
  # à l'envers — tout ce qui n'est PAS x86 sur cette machine est bon.
  case "$(file -b "$exe" 2>/dev/null)" in
    *x86-64*|*80386*) return 0 ;;
  esac
  mkdir -p "$coffre/$app" 2>/dev/null || return 0
  if cp -a "$exe" "$coffre/$app/$(basename "$exe")" 2>/dev/null; then
    printf '%s\n' "$exe" > "$coffre/$app/.chemin" 2>/dev/null || true
  fi
  return 0
}

_restaurer_binaire_local() {    # $1 application  $2 coffre
  local app="$1" coffre="$2" cible copie
  [ -f "$coffre/$app/.chemin" ] || return 1
  cible="$(cat "$coffre/$app/.chemin" 2>/dev/null)"
  [ -n "$cible" ] || return 1
  copie="$coffre/$app/$(basename "$cible")"
  [ -f "$copie" ] || return 1
  # LA DATE DE MISE AU COFFRE, PAS CELLE DU BINAIRE.
  #
  # « cp -a » conserve l'horodatage d'origine : dater la copie afficherait la date
  # de COMPILATION du binaire pour une entrée déposée le matin même, et
  # l'exploitant en conclurait qu'on lui rétablit un fichier vieux de plusieurs
  # mois. Le fichier « .chemin », lui, est écrit au moment du dépôt.
  log "  $app : réparation par le réseau impossible — copie locale mise au coffre le $(date -r "$coffre/$app/.chemin" '+%d/%m à %Hh%M' 2>/dev/null || echo '?')"
  mkdir -p "$(dirname "$cible")" 2>/dev/null || true
  # ÉCRIRE À CÔTÉ PUIS RENOMMER, JAMAIS PAR-DESSUS.
  #
  # On ne peut pas écraser le binaire d'un processus en cours : le noyau rend
  # « Text file busy » (ETXTBSY). Un « cp » direct échoue donc exactement dans le
  # cas où le coffre doit servir — le service tourne encore, mal, avec un binaire
  # de la mauvaise architecture. Le piège vaut aussi pour les tests : on ne peut
  # pas non plus casser un binaire en cours d'exécution pour éprouver la
  # réparation.
  #
  # « mv » remplace l'entrée du répertoire sans toucher à l'inode que le
  # processus tient ouvert : l'opération réussit, et le nouveau binaire prend
  # effet au redémarrage qui suit.
  local tmp="$cible.coffre.$$"
  cp -a "$copie" "$tmp" 2>/dev/null || return 1
  chmod +x "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$cible" 2>/dev/null || { rm -f "$tmp"; return 1; }
  systemctl restart "$app" 2>/dev/null || true
  sleep 3
  systemctl is-active --quiet "$app"
}

### ─── 8 bis. VÉRIFICATION D'EXÉCUTABILITÉ ─────────────────────────────────
# Quand la production et le réplica n'ont pas la même architecture — x86_64
# contre arm64, le cas courant d'un réplica sur petite carte — YunoHost restaure
# fidèlement les fichiers d'une application, y compris les binaires
# précompilés, qui sont alors INEXÉCUTABLES ici : restaurés « avec succès » et
# incapables de démarrer, « Exec format error ». Une restauration muette sur ce
# point donne un réplica qui paraît sain et ne l'est pas. On vérifie donc
# réellement.
STEP="vérification d'exécutabilité"
log "Vérification de l'architecture des binaires restaurés"

# Un service en échec est un service en échec, quoi qu'en dise la restauration.
declare -a SERVICES_MORTS=()
while IFS= read -r s; do
  [ -n "$s" ] || continue
  # mariadb.socket échoue par activation par socket alors que mariadb tourne :
  # sans conséquence, on ne le compte pas.
  [ "$s" = "mariadb.socket" ] && continue
  SERVICES_MORTS+=("$s")
  warn "  service en échec : $s"
done < <(systemctl list-units --state=failed --no-pager --plain --no-legend 2>/dev/null | awk '{print $1}')

if [ ${#SERVICES_MORTS[@]} -gt 0 ]; then
  warn "services en échec après restauration : ${SERVICES_MORTS[*]}"
  FAILED+=("services-en-echec")
fi

ARCH_ATTENDUE="$(dpkg --print-architecture 2>/dev/null || echo arm64)"

# On n'inspecte QUE les binaires réellement lancés par un service : un balayage
# large remonte des faux positifs (Moodle livre mimetex pour Linux/Windows/
# FreeBSD, n8n embarque une dépendance optionnelle x64) qui ne gênent rien. Un
# contrôle qui alerte chaque nuit à tort finit par être ignoré — et c'est
# précisément le jour où il aurait eu raison.
declare -a BINAIRES_ETRANGERS=()
while IFS= read -r bin; do
  [ -f "$bin" ] || continue
  case "$(file -b "$bin" 2>/dev/null)" in
    *x86-64*|*80386*)
      printf '%s\n' "${BINAIRES_ETRANGERS[@]:-}" | grep -qxF "$bin" && continue
      BINAIRES_ETRANGERS+=("$bin")
      warn "  binaire d'un service compilé pour x86 : $bin"
      ;;
  esac
done < <(systemctl show '*.service' --property=ExecStart --no-pager 2>/dev/null \
         | sed -n 's/.*path=\([^ ;]*\).*/\1/p' | sort -u)

if [ ${#BINAIRES_ETRANGERS[@]} -gt 0 ]; then
  warn "${#BINAIRES_ETRANGERS[@]} binaire(s) de service inexécutables sur $ARCH_ATTENDUE"

  # RÉPARATION AUTOMATIQUE, et non un simple constat.
  #
  # La sauvegarde YunoHost recopie fidèlement les binaires précompilés : les
  # applications concernées reviennent INEXÉCUTABLES à CHAQUE restauration. Se
  # contenter de le signaler condamnerait le réplica à les avoir hors service
  # toutes les nuits — ce qui vide le dispositif de son sens. « yunohost app
  # upgrade --force » retélécharge selon les architectures du manifeste, ou
  # recompile depuis les sources.
  #
  # On déduit l'application du NOM DU SERVICE, qui coïncide chez YunoHost, et on
  # vérifie qu'elle est bien installée avant d'agir — jamais de nom deviné passé
  # à une commande qui modifie le système.
  if [ "$REPARER_BINAIRES" = 1 ]; then
    # On réinterroge YunoHost ici plutôt que de réutiliser la liste capturée
    # AVANT la restauration : celle-ci ignore une application restaurée qui
    # n'existait pas auparavant. Et on ne passe jamais un nom deviné à une
    # commande qui modifie le système.
    mapfile -t INSTALLED_MAINTENANT < <(yunohost app list --output-as plain 2>/dev/null \
      | grep -v '^#' | grep -vE '^\s*$')

    declare -a a_reparer=()
    for unite in "${SERVICES_MORTS[@]:-}"; do
      app="${unite%.service}"
      [ -n "$app" ] || continue
      printf '%s\n' "${INSTALLED_MAINTENANT[@]:-}" | grep -qxF "$app" || continue
      printf '%s\n' "${a_reparer[@]:-}" | grep -qxF "$app" || a_reparer+=("$app")
    done

    # LA RÉPARATION A BESOIN D'INTERNET, ET C'EST UN DÉFAUT DE CONCEPTION.
    #
    # « yunohost app upgrade --force » retélécharge le binaire de la bonne
    # architecture — parfois en extrayant une image Docker officielle, donc en
    # plusieurs couches. Une panne de DNS de quelques secondes fait échouer
    # l'ensemble, et l'application reste morte jusqu'au matin ; quand c'est le
    # fournisseur d'identité, PERSONNE ne se connecte à quoi que ce soit.
    #
    # C'est inacceptable pour une machine de secours : le jour d'une crise, le
    # réseau est précisément ce dont on ne dispose pas. On garde donc une copie
    # locale de chaque binaire réparé avec succès, et l'on s'en sert quand le
    # réseau fait défaut. L'arche apprend de ses propres réparations.
    coffre="${PRA_BINAIRES_ARM64:-/var/lib/pra/binaires-$ARCH_ATTENDUE}"
    mkdir -p "$coffre" 2>/dev/null || true

    for app in "${a_reparer[@]:-}"; do
      [ -n "$app" ] || continue
      log "  réparation de $app (retéléchargement ou recompilation pour $ARCH_ATTENDUE)"
      # DEUX TENTATIVES. La panne du 31/07 était transitoire : la même commande a
      # réussi le matin sans rien changer. Une seconde chance à quinze secondes
      # d'intervalle aurait épargné une nuit entière de fournisseur d'identité à
      # terre. La sortie n'est plus jetée : « 2>/dev/null » m'a empêché de
      # connaître la cause, et une erreur qu'on ne lit pas est une erreur qu'on ne
      # corrigera pas.
      sortie=""; tentative=1; reussi=1
      while [ "$tentative" -le 2 ]; do
        sortie="$(yunohost app upgrade "$app" --force 2>&1)" && { reussi=0; break; }
        if [ "$tentative" = 1 ]; then
          # On nomme la cause probable plutôt que de dire « en échec ».
          if printf '%s' "$sortie" | grep -qiE "could not resolve|name or service not known|temporary failure"; then
            warn "  $app : la réparation exige Internet et la résolution DNS a échoué"
          else
            warn "  $app : première tentative en échec — $(printf '%s' "$sortie" | grep -iE 'error|échec' | tail -1 | cut -c1-120)"
          fi
          log "  nouvelle tentative dans 15 s"
          sleep 15
        fi
        tentative=$((tentative + 1))
      done

      if [ "$reussi" != 0 ]; then
        # DERNIER RECOURS : la copie locale d'une réparation antérieure. C'est
        # elle qui rend l'arche autonome le jour où le réseau manque.
        if _restaurer_binaire_local "$app" "$coffre"; then
          log "  $app rétabli depuis la copie locale (sans réseau)"
        fi
      fi

      # LE SEUL JUGE EST LE SERVICE. Peu importe par quelle voie il a été
      # réparé — téléchargement, seconde tentative, copie locale : ce qui compte
      # est qu'il tourne. C'est la leçon de la journée du 30/07 appliquée ici.
      if systemctl is-active --quiet "$app"; then
        {
          log "  $app réparé et actif"
          record "$app" "réparé (binaire $ARCH_ATTENDUE)"
          # On met la copie locale à jour : c'est elle qui sauvera la prochaine
          # nuit sans réseau.
          _garder_binaire_local "$app" "$coffre"
          # Une étape antérieure a pu l'inscrire en échec — la section 7 bis
          # tente de redémarrer dex après avoir adapté ses clients OIDC, et
          # échoue forcément puisque son binaire vient d'être restauré en x86.
          # Sans ce retrait, le verdict serait « partiel » CHAQUE nuit alors que
          # tout finit bien, et un verdict qui alerte toujours cesse d'être lu.
          declare -a restant=()
          for e in "${FAILED[@]:-}"; do
            [ -n "$e" ] && [ "$e" != "$app" ] && restant+=("$e")
          done
          FAILED=("${restant[@]:-}")
        }
      else
        warn "  $app TOUJOURS INACTIF après réparation"
        warn "    sans lui, les connexions par OIDC ne fonctionneront pas"
        FAILED+=("$app")
      fi
    done
    [ "${#a_reparer[@]}" -gt 0 ] || warn "  aucune application identifiée — réparation manuelle nécessaire"
  else
    warn "  PRA_REPARER_BINAIRES=0 : réparation désactivée"
    warn "  remède : yunohost app upgrade <app> --force"
    FAILED+=("binaires-non-arm64")
  fi
fi

### ─── 8 bis suite. ALIMENTER LE COFFRE, POUR TOUTES LES APPLICATIONS ───────
#
# NE PAS SE PRÉPARER SEULEMENT À LA PANNE D'HIER.
#
# Les applications dont on CONNAÎT le défaut d'architecture sont réparées chaque
# nuit. Mais rien ne garantit que la prochaine application ajoutée à la table
# n'aura pas le même défaut — et l'on ne s'en apercevrait qu'une nuit de crise,
# sans réseau pour la réparer.
#
# On met donc au coffre le binaire de TOUTE application restaurée dont le service
# tourne et dont l'architecture est la bonne. C'est une copie de fichiers déjà
# présents : aucun téléchargement, et l'on ne garde qu'un binaire par application.
#
# La copie n'est refaite que si le binaire a changé — sinon on récrirait des
# dizaines de mégaoctets chaque nuit pour rien, sur une carte SD.
if [ "$REPARER_BINAIRES" = 1 ]; then
  STEP="coffre des binaires"
  _coffre="${PRA_BINAIRES_ARM64:-/var/lib/pra/binaires-$ARCH_ATTENDUE}"
  mkdir -p "$_coffre" 2>/dev/null || true
  _n_coffre=0
  for _a in "${TO_RESTORE[@]:-}"; do
    [ -n "$_a" ] || continue
    systemctl is-active --quiet "$_a" 2>/dev/null || continue
    _exe="$(_binaire_du_service "$_a")" || continue
    [ -n "$_exe" ] || continue
    # Ne recopier que si le contenu diffère : la comparaison coûte moins cher que
    # l'écriture, et l'usure d'une carte SD est un vrai sujet sur ce matériel.
    if [ -f "$_coffre/$_a/$(basename "$_exe")" ] \
       && cmp -s "$_exe" "$_coffre/$_a/$(basename "$_exe")"; then
      continue
    fi
    if _garder_binaire_local "$_a" "$_coffre"; then
      [ -f "$_coffre/$_a/.chemin" ] && _n_coffre=$((_n_coffre + 1))
    fi
  done
  if [ "$_n_coffre" -gt 0 ]; then
    log "Coffre des binaires : $_n_coffre mis à jour ($(du -sh "$_coffre" 2>/dev/null | cut -f1) au total)"
  fi
fi

### ─── 8 ter. RÉ-ÉVALUATION DES ÉCHECS ─────────────────────────────────────
# « services-en-echec » est inscrit AVANT la réparation : sans ré-examen, les
# services réparés et actifs sont bien retirés un par un de la liste, mais le
# verdict reste « partiel » à cause du seul marqueur de synthèse. Un verdict qui
# alerte chaque nuit alors que tout finit bien cesse d'être lu ; c'est le défaut
# même que la levée d'échec vise à éviter.
#
# On juge donc sur l'état FINAL de la machine, pas sur le constat initial.
if printf '%s\n' "${FAILED[@]:-}" | grep -qxF "services-en-echec"; then
  mapfile -t ENCORE_MORTS < <(systemctl list-units --state=failed --no-pager --plain --no-legend 2>/dev/null \
    | awk '{print $1}' | grep -v '^mariadb\.socket$' || true)
  if [ "${#ENCORE_MORTS[@]}" -eq 0 ]; then
    log "  tous les services signalés sont repartis — échec « services-en-echec » levé"
    declare -a sans_marqueur=()
    for e in "${FAILED[@]:-}"; do
      [ "$e" != "services-en-echec" ] && sans_marqueur+=("$e")
    done
    FAILED=("${sans_marqueur[@]:-}")
  else
    warn "  services toujours en échec : ${ENCORE_MORTS[*]}"
  fi
fi

# Compactage. « FAILED=("${restant[@]:-}") » sur un tableau vide produit UN
# élément : la chaîne vide. Le test « ${#FAILED[@]} -gt 0 » valait alors vrai, et
# le verdict devenait « partiel » sans qu'aucun motif ne s'affiche — un défaut
# introduit par la levée d'échec elle-même.
declare -a FAILED_NETS=()
for e in "${FAILED[@]:-}"; do
  [ -n "$e" ] && FAILED_NETS+=("$e")
done
FAILED=("${FAILED_NETS[@]:-}")
[ -n "${FAILED[0]:-}" ] || FAILED=()

### ─── 9. VERDICT ───────────────────────────────────────────────────────────
STEP="terminé"
if [ ${#FAILED[@]} -gt 0 ]; then
  VERDICT="partiel"
  warn "applications en échec : ${FAILED[*]}"
  notifier echec "Restauration partielle" \
    "En échec : ${FAILED[*]}. L'arche est restaurée mais incomplète — à examiner."
  exit 0
fi
VERDICT="succès"
log "Applications restaurées, binaires exécutables, aucun service en échec"
