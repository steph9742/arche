#!/bin/bash
###############################################################################
# Sauvegarde YunoHost quotidienne — À EXÉCUTER SUR LA PRODUCTION      version 2
#
# Corrections par rapport à la v1, et pourquoi :
#
#  1. LE MODE MAINTENANCE EST TOUJOURS LEVÉ. La v1 finissait par un
#     « occ maintenance:mode --off », mais sous « set -euo pipefail » un échec
#     de « yunohost backup create » avortait le script AVANT cette ligne. Si
#     YunoHost avait mis Nextcloud en maintenance pour la sauvegarde, la
#     PRODUCTION restait indisponible jusqu'à intervention humaine. C'est le
#     défaut le plus risqué de la v1 ; il est traité par un trap.
#
#  2. PERMISSIONS. L'archive contient les données de toutes les applications,
#     coffres de mots de passe compris : un « chmod 777 » la rendrait lisible ET
#     modifiable par tout compte du serveur. Elle est donc en 0640 root:pra —
#     ni lisible par tous, ni illisible par le compte non privilégié qui assure
#     le transfert vers le réplica, qu'un 0600 bloquerait.
#     Prérequis à créer une fois sur la production :
#       groupadd -f pra && usermod -aG pra <compte-de-transfert>
#       chown root:pra /transferts/backups && chmod 2750 /transferts/backups
#     Le bit setgid du répertoire fait hériter le groupe aux fichiers créés.
#
#  3. RÉTENTION. Supprimer à « -mtime +1 » suffit à tout perdre : si le réplica
#     rate une nuit, l'archive du jour disparaît DÉFINITIVEMENT. On conserve
#     donc un nombre minimum d'archives quel que soit leur âge.
#
#  4. EMPREINTE. Un sha256 est publié à côté de l'archive : le réplica peut
#     vérifier que son transfert n'a pas été tronqué.
#
#  5. Verrou, journal et fichier d'état, pour que l'échec ne soit pas silencieux.
#
# Usage :
#   yunohost_backup_daily.sh              sauvegarde normale
#   PRA_DRY_RUN=1 …                        montre ce qui serait fait
###############################################################################
set -euo pipefail

# ─── Configuration commune ───────────────────────────────────────────────────
# Éditée par la webapp Arche (rôle « production »), lue ici. L'idiome
# « : "${VAR:=valeur}" » n'affecte que les variables non définies : une valeur
# passée sur la ligne de commande reste prioritaire.
# shellcheck source=/dev/null
[ -r "${PRA_CONF:-/etc/pra/pra.conf}" ] && . "${PRA_CONF:-/etc/pra/pra.conf}"


SRC_DIR="/home/yunohost.backup/archives"
DST_DIR="${PRA_DST_DIR:-/transferts/backups}"
LOG="/var/log/yunohost_backup_daily.log"
STATE="/var/lib/pra/backup-daily.json"
LOCK="/run/yunohost_backup_daily.lock"

# On garde KEEP_MIN archives quoi qu'il arrive, puis on applique l'âge. Une
# purge purement calendaire vide la chaîne après une série d'échecs.
# Rétention grand-père/père/fils. PRA_PURGE_APPLIQUER=1 pour supprimer
# réellement ; par défaut le script se contente d'un compte rendu.
RETENTION_LIB="${PRA_RETENTION_LIB:-/usr/local/sbin/pra_retention.sh}"
# Appliquer par défaut : le mode « compte rendu seul », utile le temps de
# vérifier les décisions, finit par remplir le disque et casser la restauration.
# PRA_PURGE_APPLIQUER=0 pour revenir au constat.
PURGE_APPLIQUER="${PRA_PURGE_APPLIQUER:-1}"
# shellcheck source=/dev/null
[ -r "$RETENTION_LIB" ] && . "$RETENTION_LIB"

KEEP_MIN="${PRA_KEEP_MIN:-4}"
RETENTION_DAYS="${PRA_RETENTION_DAYS:-4}"
DRY_RUN="${PRA_DRY_RUN:-0}"
# 0640 : le compte non privilégié qui tire les archives vers le réplica doit
# pouvoir les lire, sans les exposer à tous les comptes du serveur.
ARCHIVE_MODE="${PRA_ARCHIVE_MODE:-640}"
# Groupe donnant à l'arche le droit de lire les archives.
ARCHIVE_GROUP="${PRA_ARCHIVE_GROUP:-pra}"

BACKUP_NAME="$(date +%Y%m%d-%H%M%S)"
MAINT_TOUCHED=0

# Nextcloud n'utilise pas forcément le PHP par défaut du système.
# « || true » : sans ce fichier, grep rend 1, « pipefail » fait échouer
# l'affectation et « set -e » abat le script au démarrage — le repli sur les
# versions installées, juste dessous, ne serait jamais atteint.
PHP_BIN="${PRA_PHP_BIN:-$(
  p="$(grep -ohE 'php[0-9]+\.[0-9]+' /etc/cron.d/nextcloud 2>/dev/null | head -1 || true)"
  if [ -n "$p" ]; then printf '%s' "$p"
  else for c in php8.4 php8.3 php8.2 php; do
         # « if » et non « && » : voir pra_restore_replica.sh — un « && » qui
         # échoue en dernière itération abat le script sous « set -e ».
         if command -v "$c" >/dev/null 2>&1; then printf '%s' "$c"; break; fi
       done
  fi
  true)}"
OCC="/var/www/nextcloud/occ"

mkdir -p "$DST_DIR" "$(dirname "$STATE")"
exec >> "$LOG" 2>&1
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn() { log "ATTENTION  $*"; }

### ─── SORTIE PROPRE, QUOI QU'IL ARRIVE ────────────────────────────────────
# Le point central de cette version : on ne quitte jamais en laissant la
# production en mode maintenance.
on_exit() {
  local code=$?
  # « -f » et non « -x » : occ n'est pas exécutable, il s'invoque via php. Ce
  # test était faux et désactivait silencieusement tout ce filet de sécurité.
  if [ -f "$OCC" ] && command -v "$PHP_BIN" >/dev/null 2>&1; then
    if sudo -u nextcloud "$PHP_BIN" --define apc.enable_cli=1 "$OCC" \
         maintenance:mode --off >/dev/null 2>&1; then
      [ "$MAINT_TOUCHED" = 1 ] && log "mode maintenance Nextcloud levé"
    else
      warn "IMPOSSIBLE de lever le mode maintenance — VÉRIFIER LA PRODUCTION"
    fi
  fi
  printf '{"date":"%s","archive":"%s","code":%d,"verdict":"%s"}\n' \
    "$(date -Is)" "$BACKUP_NAME" "$code" \
    "$([ $code -eq 0 ] && echo succes || echo echec)" > "$STATE" 2>/dev/null || true
  log "===== FIN (code $code) ====="
}
trap on_exit EXIT

exec 9>"$LOCK"
flock -n 9 || { log "sauvegarde déjà en cours — abandon"; exit 0; }

log "===== DÉBUT SAUVEGARDE $BACKUP_NAME ====="
[[ "$(id -u)" -eq 0 ]] || { warn "à exécuter en root"; exit 1; }

# Un « mv » entre systèmes de fichiers différents est une copie complète de
# 12 Go, pas un renommage : autant le savoir.
if [ "$(stat -c %d "$SRC_DIR" 2>/dev/null)" != "$(stat -c %d "$DST_DIR" 2>/dev/null)" ]; then
  warn "$SRC_DIR et $DST_DIR sont sur des systèmes de fichiers différents :"
  warn "le déplacement recopiera l'archive entière au lieu de la renommer"
fi

### ─── SAUVEGARDE ───────────────────────────────────────────────────────────
# Périmètre. « --apps » sans argument prend TOUTES les applications ; pour en
# écarter, il faut au contraire énumérer celles qu'on garde. On liste donc les
# applications installées et on retire les exclusions — plutôt que de maintenir
# à la main une liste de ce qu'on garde, qui oublierait toute nouveauté.
#
# Réglage PRA_BACKUP_EXCLUDE (webapp, rôle production). Une application écartée
# ne pourra PAS être restaurée : c'est un arbitrage, pas une optimisation. Le
# journal doit donc dire précisément ce qui a été laissé de côté.
EXCLURE="${PRA_BACKUP_EXCLUDE:-}"
AVEC_SYSTEME="${PRA_BACKUP_SYSTEM:-1}"

declare -a BK_ARGS=()
if [ -n "${EXCLURE// /}" ]; then
  mapfile -t GARDEES < <(
    yunohost app list --output-as json 2>/dev/null \
      | EXCL="$EXCLURE" python3 -c '
import json, os, sys
exclues = set(os.environ.get("EXCL", "").split())
try:
    apps = json.load(sys.stdin).get("apps") or []
except Exception:
    sys.exit(1)
for a in apps:
    nom = a.get("id") or a.get("name")
    if nom and nom not in exclues:
        print(nom)
'
  )
  if [ ${#GARDEES[@]} -eq 0 ]; then
    # Sans liste fiable, on préfère TOUT sauvegarder : une archive trop grosse
    # se rattrape, une archive incomplète découverte en crise, non.
    warn "liste des applications illisible — sauvegarde complète par sécurité"
    BK_ARGS=(--apps)
  else
    BK_ARGS=(--apps "${GARDEES[@]}")
    log "Applications écartées : $EXCLURE"
    log "Applications sauvegardées : ${#GARDEES[@]}"
  fi
else
  BK_ARGS=(--apps)
fi
[ "$AVEC_SYSTEME" = "1" ] && BK_ARGS+=(--system)

MAINT_TOUCHED=1        # YunoHost peut basculer Nextcloud en maintenance ici
log "Création de la sauvegarde YunoHost (${BK_ARGS[*]})"
if [ "$DRY_RUN" = 1 ]; then
  log "[à blanc] yunohost backup create ${BK_ARGS[*]} --name $BACKUP_NAME"
else
  yunohost backup create "${BK_ARGS[@]}" --name "$BACKUP_NAME"
fi

ARCHIVE="$SRC_DIR/$BACKUP_NAME.tar"
if [ "$DRY_RUN" != 1 ]; then
  [ -s "$ARCHIVE" ] || { warn "archive absente ou vide : $ARCHIVE"; exit 1; }
  SIZE="$(du -h "$ARCHIVE" | cut -f1)"
  log "Archive créée : $SIZE"
fi

### ─── DÉPLACEMENT ET EMPREINTE ─────────────────────────────────────────────
if [ "$DRY_RUN" != 1 ]; then
  log "Déplacement vers $DST_DIR"
  mv "$ARCHIVE" "$DST_DIR/"
  chmod "$ARCHIVE_MODE" "$DST_DIR/$BACKUP_NAME.tar"   # v1 : 777
  log "Calcul de l'empreinte"
  sha256sum "$DST_DIR/$BACKUP_NAME.tar" | cut -d' ' -f1 \
    > "$DST_DIR/$BACKUP_NAME.tar.sha256"
  chmod "$ARCHIVE_MODE" "$DST_DIR/$BACKUP_NAME.tar.sha256"

  # GROUPE EXPLICITE, et non le bit setgid du répertoire.
  #
  # Le setgid ne s'applique qu'aux fichiers CRÉÉS dans le répertoire, pas à ceux
  # qui y sont DÉPLACÉS : « mv » conserve le groupe d'origine. L'archive arrivait
  # donc en root:root alors que le répertoire est root:pra, et le compte non
  # privilégié du réplica — membre de « pra » — ne peut alors pas la lire, et la
  # réplication échoue sur « aucune archive du jour côté production » alors que
  # l'archive existe bel et bien.
  if ! chgrp "$ARCHIVE_GROUP" "$DST_DIR/$BACKUP_NAME.tar" \
             "$DST_DIR/$BACKUP_NAME.tar.sha256" 2>/dev/null; then
    warn "groupe « $ARCHIVE_GROUP » non appliqué : l'arche ne pourra pas lire"
    warn "  l'archive. Vérifier que ce groupe existe (groupadd $ARCHIVE_GROUP)."
  fi
  log "Archive en $(stat -c '%U:%G %a' "$DST_DIR/$BACKUP_NAME.tar")"
fi

### ─── RÉTENTION ────────────────────────────────────────────────────────────
purge_dir() {
  # « ${2:-1} » et non « $2 » : sous « set -u » un appel à un seul argument fait
  # AVORTER le script — ici, juste après une sauvegarde parfaitement réussie. Le
  # journal annonce alors « FIN (code 1) » sur une archive saine, et la rétention
  # ne tourne jamais.
  # Le défaut vaut 1 (supprimer aussi le .info.json) parce que c'est le cas du
  # répertoire de YunoHost, celui où ce fichier existe.
  local dir="$1" also_info="${2:-1}" f raison
  local -i garde=0 purge=0

  # Rétention grand-père/père/fils si la bibliothèque est disponible ; sinon on
  # retombe sur l'ancien comportement plutôt que de ne rien purger du tout.
  if ! declare -F decisions_gfs >/dev/null; then
    warn "$RETENTION_LIB absent — rétention par ancienneté simple"
    purge_dir_ancien "$dir" "$also_info"
    return
  fi

  # APPLICATION DÉSACTIVÉE PAR DÉFAUT. Le danger d'un schéma à trois strates
  # n'est pas de trop garder, c'est de supprimer la mauvaise catégorie — et cela
  # ne se voit qu'après. On journalise donc les décisions pendant quelques
  # semaines avant de laisser le script effacer quoi que ce soit.
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
  local dir="$1" i n
  local -a f
  mapfile -t f < <(find "$dir" -maxdepth 1 -type f -name '20*.tar' \
      -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
  n=${#f[@]}
  if [ "$n" -le "$KEEP_MIN" ]; then
    log "$dir : $n archive(s), conservation garantie (minimum $KEEP_MIN)"
    return
  fi
  for ((i = KEEP_MIN; i < n; i++)); do
    if [ -n "$(find "${f[i]}" -mtime "+$RETENTION_DAYS" -print -quit 2>/dev/null)" ]; then
      [ "$DRY_RUN" = 1 ] && { log "[à blanc] purge $(basename "${f[i]}")"; continue; }
      rm -f "${f[i]}" "${f[i]}.sha256" "${f[i]%.tar}.info.json"
      log "purge : $(basename "${f[i]}")"
    fi
  done
}
# Les deux répertoires ne contiennent pas la même chose : « mv » ne déplace que
# le .tar, donc le .info.json écrit par YunoHost reste dans SON répertoire. D'où
# deux valeurs différentes, et non un argument qu'on aurait oublié.
purge_dir "$DST_DIR" 0      # /transferts/backups : .tar + .sha256 seulement
purge_dir "$SRC_DIR" 1      # /home/yunohost.backup/archives : .info.json présent

# Instantané Docker, s'il a été demandé. La planification l'exécute par son
# propre cron à 01:00 ; ce drapeau sert aux sauvegardes lancées À LA MAIN, qui
# autrement ne contiendraient QUE le volet YunoHost — et l'arche répliquerait
# alors des piles Docker datant de la veille sans que personne ne le voie.
if [ "${PRA_AVEC_DOCKER:-0}" = 1 ]; then
  SNAP="${PRA_DOCKER_SNAPSHOT_BIN:-/usr/local/sbin/pra_docker_snapshot.sh}"
  if [ -x "$SNAP" ]; then
    log "Enchaînement de l'instantané Docker"
    bash "$SNAP" \
      && log "Instantané Docker terminé" \
      || warn "Instantané Docker en échec — voir son journal"
  else
    warn "$SNAP absent — instantané Docker ignoré"
  fi
fi

log "Sauvegarde terminée"
