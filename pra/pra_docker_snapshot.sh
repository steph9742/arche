#!/bin/bash
###############################################################################
# PRA Docker Snapshot — À EXÉCUTER SUR LA PRODUCTION
#
# Produit /transferts/backups/AAAAMMJJ-HHMMSS-docker.tar, récupéré par le rsync
# du réplica en même temps que l'archive YunoHost.
#
# Principes retenus, et pourquoi :
#
#  1. AUCUNE COPIE DE BASE À CHAUD. Copier le répertoire de données pendant que
#     le moteur écrit donne un instantané déchiré, inutilisable. Les bases
#     passent par pg_dump exécuté DANS le conteneur. Pour un SQLite, on arrête
#     le service quelques secondes plutôt que d'en copier une version douteuse.
#
#  2. LES GROS VOLUMES DE JOURNAUX NE SONT PAS DANS CE TAR. Un répertoire qui
#     croît de plusieurs dizaines de gigaoctets par mois se réplique par rsync
#     incrémental, pas en le réarchivant chaque nuit. Voir pra_nightly.sh.
#
#  3. ON EXPÉDIE LES SOURCES, PAS LES IMAGES. La production ne publie pas
#     forcément d'image pour l'architecture du réplica, et l'émulation d'un gros
#     projet serait très lente : le réplica construit lui-même, en natif.
#
#  4. LES SECRETS RESTENT EN CLAIR DANS LE TAR, en 0600. Les chiffrer ici
#     serait cosmétique : le réplica a besoin de la clé pour restaurer, elle
#     serait donc sur le réplica. La vraie protection d'une machine qu'on peut
#     emporter, c'est le chiffrement du disque, pas celui du fichier.
#
# Usage :
#   pra_docker_snapshot.sh              instantané complet
#   PRA_NO_STOP=1 …                     n'arrête aucun conteneur (SQLite risqué)
#   PRA_DRY_RUN=1 …                     montre ce qui serait fait
###############################################################################
set -euo pipefail

OUT_DIR="${PRA_OUT_DIR:-/transferts/backups}"
WORK="${PRA_WORK:-/var/tmp/pra_docker}"
LOG="/var/log/pra_docker_snapshot.log"
STATE="/var/lib/pra/docker-snapshot.json"
DRY_RUN="${PRA_DRY_RUN:-0}"
NO_STOP="${PRA_NO_STOP:-0}"
# 0640, même raison que pour l'archive YunoHost : le transfert vers le
# réplica se fait sous un compte non privilégié, un 0600 le bloque.
ARCHIVE_MODE="${PRA_ARCHIVE_MODE:-640}"
TODAY="$(date +%Y%m%d)"
# L'HEURE DANS LE NOM, comme pour l'archive YunoHost — et pour la même raison.
#
# « AAAAMMJJ-docker.tar » n'a qu'une granularité au jour : un instantané manuel
# pris le même jour que celui du cron porterait LE MÊME NOM. Or le magasin du
# réplica est en écriture unique (« --ignore-existing », protection délibérée
# contre un rançongiciel qui réécrirait les copies) : l'instantané manuel ne
# serait donc JAMAIS transféré, et une restauration lancée exprès derrière une
# sauvegarde manuelle repartirait en silence sur l'état de la nuit.
#
# On ne touche pas à --ignore-existing — c'est le nom qui était fautif.
TARGET="$OUT_DIR/$TODAY-$(date +%H%M%S)-docker.tar"

# Même précaution que dans pra_restore_replica.sh : si la sortie standard est
# DÉJÀ ce journal — cas d'un lancement par le helper, qui y redirige — « tee »
# écrirait chaque ligne deux fois. On ne double que vers une destination
# différente, pour que les lignes remontent dans le journal de l'appelant.
# « -ef » compare le périphérique et l'inode : c'est la seule façon fiable de
# savoir que deux chemins désignent le MÊME fichier. Une comparaison de chaînes
# ne suffit pas — et si elle échoue des deux côtés, deux résultats vides se
# valent, ce qui supprimerait la sortie au lieu de la dédoubler.
# Si /dev/stdout est indisponible, le test est faux et l'on double : l'ancien
# comportement, jamais une perte silencieuse.
if [ /dev/stdout -ef "$LOG" ]; then
  ECHO_STDOUT=0
else
  ECHO_STDOUT=1
fi
log() {
  local l; l="$(printf '[%s] %s' "$(date '+%F %T')" "$*")"
  printf '%s\n' "$l" >> "$LOG"
  [ "$ECHO_STDOUT" = 1 ] && printf '%s\n' "$l" || true
}
warn() { log "ATTENTION  $*"; }
die()  { log "ÉCHEC  $*"; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then log "[à blanc] $*"; else "$@"; fi; }

[[ "$(id -u)" -eq 0 ]] || die "à exécuter en root"
command -v docker >/dev/null || die "docker absent"

exec 9>"/run/pra_docker_snapshot.lock"
flock -n 9 || die "instantané déjà en cours"

mkdir -p "$OUT_DIR" "$(dirname "$STATE")"
rm -rf "$WORK"; mkdir -p "$WORK"/{compose,env,db,data,src,secrets}
log "==== DÉBUT INSTANTANÉ DOCKER $TODAY ===="

### ─── INVENTAIRE DES PILES ─────────────────────────────────────────────────
#
# Une pile par ligne dans /etc/pra/piles.list (voir exemples/piles.list) :
#
#   nom|compose=/chemin/docker-compose.yml|port=8080|env=/chemin/.env|…
#
# Champs reconnus — tous facultatifs sauf « compose » :
#
#   compose=   la composition elle-même
#   port=      port publié sur l'hôte, informatif, repris dans le manifeste
#   config=    fichier de configuration monté, à emporter (répétable)
#   env=       fichier d'environnement (secrets) de la pile
#   secrets=   répertoire de secrets de la pile
#   db=        conteneur PostgreSQL à vidanger (répétable)
#   donnees=   répertoire de données monté, à archiver (répétable) ;
#              « chemin:exclusion » pour écarter un sous-répertoire
#   arret=     conteneur à arrêter le temps de la copie des données
#   source=    répertoire de sources, à reconstruire sur le réplica
#
# Rien n'est codé en dur ici : l'inventaire décrit UNE installation, l'outil
# n'en connaît aucune.
PILES=()
PILES_FICHIER="${PRA_PILES:-/etc/pra/piles.list}"
if [ -r "$PILES_FICHIER" ]; then
  while IFS= read -r _l; do
    case "$_l" in ''|\#*) continue ;; esac
    PILES+=("$_l")
  done < "$PILES_FICHIER"
fi
[ "${#PILES[@]}" -gt 0 ] || die "aucune pile déclarée dans $PILES_FICHIER
     Voir exemples/piles.list. Sans inventaire, cet instantané serait vide,
     et le réplica restaurerait des piles de la veille sans que rien ne le dise."
log "${#PILES[@]} pile(s) déclarée(s)"

# Valeurs d'un champ, une par ligne. Les champs répétables rendent plusieurs
# lignes ; un champ absent ne rend rien.
champs() {                       # ligne, clé
  printf '%s' "$1" | tr '|' '\n' | sed -n "s/^$2=//p"
}
# Première valeur seulement, pour les champs uniques.
champ() { champs "$1" "$2" | head -1; }

### ─── 1. Compositions et configurations montées ───────────────────────────
log "Collecte des compositions"
for row in "${PILES[@]}"; do
  name="${row%%|*}"
  file="$(champ "$row" compose)"
  port="$(champ "$row" port)"
  [ -n "$name" ] || { warn "ligne sans nom de pile, ignorée"; continue; }
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    warn "$name : composition introuvable (${file:-champ compose absent})"
    continue
  fi
  d="$WORK/compose/$name"; mkdir -p "$d"
  cp -a "$file" "$d/"
  log "  $name ← $(basename "$file")${port:+  (port $port)}"

  # Les configurations montées suivent la composition, en conservant leur
  # chemin RELATIF : une pile qui monte « deploy/nginx.conf » doit le retrouver
  # au même endroit sur le réplica.
  #
  # Emporter un MODÈLE plutôt qu'un fichier rendu, quand la pile en rend un au
  # démarrage : un fichier rendu porterait les URL de la production.
  base="$(dirname "$file")"
  while IFS= read -r conf; do
    [ -n "$conf" ] || continue
    if [ ! -f "$conf" ]; then warn "  $name : $conf introuvable"; continue; fi
    rel="${conf#"$base"/}"
    [ "$rel" = "$conf" ] && rel="$(basename "$conf")"
    install -D -m 644 "$conf" "$d/$rel"
    log "    config : $rel"
  done < <(champs "$row" config)
done

### ─── 2. Fichiers d'environnement ─────────────────────────────────────────
log "Collecte des fichiers d'environnement"
for row in "${PILES[@]}"; do
  name="${row%%|*}"
  f="$(champ "$row" env)"
  [ -n "$f" ] || continue
  if [ ! -f "$f" ]; then warn "  $name : $f absent"; continue; fi
  install -m 600 "$f" "$WORK/env/$name.env"
  log "  $name.env"
done

### ─── 2 bis. Répertoires de secrets ───────────────────────────────────────
# LE PENDANT INDISPENSABLE DE LA RESTAURATION.
#
# Le script de restauration recrée le répertoire de secrets d'une pile, lui pose
# le propriétaire attendu par le conteneur, et avertit quand un fichier manque.
# Si rien ne les collecte ici, cet avertissement devient structurel : aucune
# restauration ne peut le satisfaire, et l'on découvre en crise qu'on ne peut
# pas entrer dans l'application.
#
# Ces fichiers sont des secrets en clair. Ils rejoignent une archive qui en
# contient déjà — les .env — écrite en 600, root, dans un répertoire restreint.
# Le modèle de menace ne change pas ; ce qui changerait, c'est de les oublier.
log "Collecte des répertoires de secrets"
for row in "${PILES[@]}"; do
  name="${row%%|*}"
  d="$(champ "$row" secrets)"
  [ -n "$d" ] || continue
  if [ ! -d "$d" ]; then log "  $name : pas de répertoire de secrets"; continue; fi
  install -d -m 700 "$WORK/secrets/$name"
  n=0
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    install -m 600 "$f" "$WORK/secrets/$name/$(basename "$f")"
    n=$((n + 1))
  done
  if [ "$n" -eq 0 ]; then
    warn "  $name : répertoire de secrets présent mais vide"
  else
    log "  $name : $n fichier(s)"
  fi
done

### ─── 3. Bases PostgreSQL — dump cohérent dans le conteneur ───────────────
# Les identifiants sont résolus par le shell DU CONTENEUR, jamais devinés depuis
# l'hôte. Trois raisons :
#   - il connaît ses propres POSTGRES_USER / POSTGRES_PASSWORD / POSTGRES_DB ;
#   - le mot de passe ne transite pas par la ligne de commande de l'hôte, donc
#     il n'apparaît ni dans « ps » ni dans les journaux ;
#   - « -h /var/run/postgresql » force la socket locale même si PGHOST impose du
#     TCP dans l'environnement du conteneur, cas où l'authentification réclame
#     un mot de passe alors que la socket est en confiance.
PG_ENV='PGPASSWORD="${POSTGRES_PASSWORD:-}" '
PG_ARGS='-h /var/run/postgresql -U "${POSTGRES_USER:-postgres}"'

dump_pg() {
  local container="$1" out="$2" err who
  docker inspect "$container" >/dev/null 2>&1 || { warn "$container absent"; return; }

  local probe="${PG_ENV}psql ${PG_ARGS} -d \"\${POSTGRES_DB:-postgres}\" -tAc 'select 1'"
  if ! docker exec "$container" sh -c "$probe" >/dev/null 2>&1; then
    warn "$container : connexion PostgreSQL impossible, dump abandonné"
    while IFS= read -r l; do warn "    $l"; done \
      < <(docker exec "$container" sh -c "$probe" 2>&1 | head -4)
    return
  fi

  who="$(docker exec "$container" sh -c 'printf %s "${POSTGRES_USER:-postgres}"' 2>/dev/null || true)"
  log "  $container (rôle ${who:-postgres})"
  if [ "$DRY_RUN" = 1 ]; then log "[à blanc] pg_dumpall → $out"; return; fi

  err="$(mktemp)"
  if docker exec "$container" sh -c "${PG_ENV}pg_dumpall ${PG_ARGS}" 2>"$err" \
       | gzip -6 > "$out" && [ -s "$out" ]; then
    log "    $(du -h "$out" | cut -f1)"
  else
    rm -f "$out"
    warn "$container : pg_dumpall a échoué"
    while IFS= read -r l; do warn "    $l"; done < <(head -4 "$err")
  fi
  rm -f "$err"
}

log "Dumps PostgreSQL"
for row in "${PILES[@]}"; do
  name="${row%%|*}"
  mapfile -t _bases < <(champs "$row" db)
  i=0
  for conteneur in "${_bases[@]:-}"; do
    [ -n "$conteneur" ] || continue
    i=$((i + 1))
    # Le nom du dump porte celui de la PILE : c'est par lui que la restauration
    # retrouve le conteneur cible. Plusieurs bases dans une pile sont suffixées.
    if [ "${#_bases[@]}" -gt 1 ]; then
      dump_pg "$conteneur" "$WORK/db/$name-$i.sql.gz"
    else
      dump_pg "$conteneur" "$WORK/db/$name.sql.gz"
    fi
  done
done

### ─── 4. Données montées ──────────────────────────────────────────────────
# Un répertoire de données monté hors volume Docker. Deux précautions :
#   - exclure ce qui est déjà vidangé par ailleurs (le répertoire de données
#     d'un PostgreSQL, par exemple) : « chemin:exclusion » ;
#   - arrêter quelques secondes le conteneur qui écrit, quand son format ne
#     supporte pas la copie à chaud — un SQLite copié à chaud peut être tronqué.
log "Données montées"
for row in "${PILES[@]}"; do
  name="${row%%|*}"
  arret="$(champ "$row" arret)"
  mapfile -t _donnees < <(champs "$row" donnees)
  i=0
  for spec in "${_donnees[@]:-}"; do
    [ -n "$spec" ] || continue
    chemin="${spec%%:*}"; exclusion=""
    case "$spec" in *:*) exclusion="${spec#*:}" ;; esac
    if [ ! -d "$chemin" ]; then warn "  $name : $chemin absent"; continue; fi
    i=$((i + 1))
    if [ "${#_donnees[@]}" -gt 1 ]; then out="$WORK/data/$name-$i.tar.gz"
    else out="$WORK/data/$name.tar.gz"; fi

    declare -a _excl=()
    [ -n "$exclusion" ] && _excl=(--exclude="$exclusion")
    if [ -n "$arret" ] && [ "$NO_STOP" != 1 ]; then
      run docker stop "$arret"
      run tar czf "$out" "${_excl[@]}" -C "$(dirname "$chemin")" "$(basename "$chemin")"
      run docker start "$arret"
      log "  $name : arrêt/copie/redémarrage de $arret"
    else
      [ -n "$arret" ] && warn "  $name : copie à chaud de $arret, cohérence NON garantie"
      run tar czf "$out" "${_excl[@]}" -C "$(dirname "$chemin")" "$(basename "$chemin")"
    fi
    [ "$DRY_RUN" = 1 ] || log "  $name : $(du -h "$out" | cut -f1)"
  done
done

### ─── 5. Sources à construire sur le réplica ──────────────────────────────
# On exclut ce qui est régénérable : le réplica reconstruira. Sans ces
# exclusions, le contexte pèserait plusieurs gigaoctets pour rien.
SRC_EXCLUDES=(
  --exclude='.git' --exclude='node_modules' --exclude='dist' --exclude='build'
  --exclude='.next' --exclude='.turbo' --exclude='target' --exclude='__pycache__'
  --exclude='*.log' --exclude='.env'
)

log "Contextes de construction"
for row in "${PILES[@]}"; do
  name="${row%%|*}"
  s="$(champ "$row" source)"
  [ -n "$s" ] || continue
  if [ ! -d "$s" ]; then warn "  $name : $s absent"; continue; fi
  run tar czf "$WORK/src/$name.tar.gz" "${SRC_EXCLUDES[@]}" \
      -C "$(dirname "$s")" "$(basename "$s")"
  [ "$DRY_RUN" = 1 ] || log "  $name : $(du -h "$WORK/src/$name.tar.gz" | cut -f1)"
done

### ─── 6. Manifeste ────────────────────────────────────────────────────────
# L'instantané se décrit lui-même : le script de restauration n'a rien à
# supposer, et l'interface de pilotage peut l'afficher.
log "Écriture du manifeste"
{
  printf '{\n  "date": "%s",\n  "source": "%s",\n' "$(date -Is)" "$(hostname)"
  printf '  "architecture_source": "%s",\n' "$(uname -m)"
  printf '  "piles": [\n'
  first=1
  for row in "${PILES[@]}"; do
    name="${row%%|*}"
    [ $first -eq 0 ] && printf ',\n'
    printf '    {"nom": "%s", "compose": "%s", "port_hote": "%s", "sources": %s}' \
      "$name" "$(champ "$row" compose)" "$(champ "$row" port)" \
      "$([ -n "$(champ "$row" source)" ] && echo true || echo false)"
    first=0
  done
  printf '\n  ]\n}\n'
} > "$WORK/manifest.json"

### ─── 7. Assemblage ───────────────────────────────────────────────────────
log "Assemblage de $TARGET"
if [ "$DRY_RUN" = 1 ]; then
  log "[à blanc] contenu préparé dans $WORK"
  find "$WORK" -type f -printf '  %P (%s octets)\n' | sort
  exit 0
fi

tar cf "$TARGET.part" -C "$WORK" .
mv -f "$TARGET.part" "$TARGET"
chmod "$ARCHIVE_MODE" "$TARGET"        # contient les .env ET les secrets
SIZE="$(du -h "$TARGET" | cut -f1)"
sha256sum "$TARGET" | cut -d' ' -f1 > "$TARGET.sha256"
chmod "$ARCHIVE_MODE" "$TARGET.sha256"

# Groupe explicite, et non le bit setgid du répertoire : son effet dépend de la
# façon dont le fichier est arrivé — créé sur place ou déplacé.
if ! chgrp "${PRA_ARCHIVE_GROUP:-pra}" "$TARGET" "$TARGET.sha256" 2>/dev/null; then
  warn "groupe « ${PRA_ARCHIVE_GROUP:-pra} » non appliqué : le réplica ne pourra pas lire l'instantané"
fi
log "Instantané prêt : $TARGET ($SIZE)"

# Rétention : cinq instantanés minimum conservés quel que soit leur âge, comme
# pour les archives YunoHost. Une purge purement calendaire viderait tout après
# une série d'échecs.
mapfile -t snaps < <(find "$OUT_DIR" -maxdepth 1 -name '*-docker.tar' \
    -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
for ((i = "${PRA_SNAP_KEEP_MIN:-5}"; i < ${#snaps[@]}; i++)); do
  if [ -n "$(find "${snaps[i]}" -mtime "+${PRA_SNAP_RETENTION_DAYS:-7}" -print -quit)" ]; then
    rm -f "${snaps[i]}" "${snaps[i]}.sha256"
    log "  purge : $(basename "${snaps[i]}")"
  fi
done

printf '{"date":"%s","fichier":"%s","taille":"%s","verdict":"succes"}\n' \
  "$(date -Is)" "$TARGET" "$SIZE" > "$STATE"
rm -rf "$WORK"
log "==== FIN INSTANTANÉ DOCKER ===="
