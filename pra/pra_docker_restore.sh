#!/bin/bash
###############################################################################
# PRA Docker Restore — à exécuter sur le RÉPLICA.
#
# Consomme l'instantané AAAAMMJJ-docker.tar produit par pra_docker_snapshot.sh
# sur la production, puis :
#   - reconstruit les images maison pour l'architecture LOCALE : la production
#     ne publie pas forcément d'image pour l'architecture du réplica, et
#     l'émulation d'un gros projet serait très lente ;
#   - restaure les dumps PostgreSQL dans des conteneurs neufs ;
#   - restaure les données montées en bind ;
#   - démarre chaque pile en liant les ports sur 127.0.0.1 UNIQUEMENT, via un
#     fichier de surcharge : nginx est leur seul consommateur, et Docker
#     contourne le pare-feu de l'hôte, donc publier sur 0.0.0.0 exposerait les
#     conteneurs sur le VLAN en court-circuitant le SSO et les journaux.
#
# Ce script ne traite QUE les piles répliquées depuis la production.
#
# Usage :
#   pra_docker_restore.sh                  restauration complète
#   PRA_DRY_RUN=1 …                        montre sans rien faire
#   PRA_ONLY=pile1,pile2 …                 se limite à certaines piles
#   PRA_SKIP_BUILD=1 …                     ne reconstruit pas les images
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


SRC_DIR="${PRA_SRC_DIR:-/transferts/backups}"
ROOT="${PRA_DOCKER_ROOT:-/opt/pra-docker}"
WORK="$ROOT/.work"
LOG="/var/log/pra_docker_restore.log"
STATE_DIR="/var/lib/pra"
STATUS="$STATE_DIR/docker-status.json"
LOCK="/run/pra_docker_restore.lock"

DRY_RUN="${PRA_DRY_RUN:-0}"
# PRA_ONLY : restriction PONCTUELLE, passée sur la ligne de commande.
# PRA_DOCKER_STACKS : sélection PERSISTANTE, écrite par la webapp. Vide = toutes.
# La première a priorité, pour qu'un essai manuel ne dépende pas de la
# configuration enregistrée.
#
# Même décalage de 24 h que pour les applications YunoHost : la sélection est
# faite sur l'inventaire de la veille. Une pile choisie hier et absente de
# l'instantané du jour est simplement ignorée — voir « aucune source pour ».
ONLY="${PRA_ONLY:-${PRA_DOCKER_STACKS:-}}"
# LA CONF ÉCRIT SES LISTES À L'ESPACE, wanted() COMPARE À LA VIRGULE.
#
# La configuration écrit ses listes séparées par des espaces, comme
# PRA_RESTORE_APPS. Or wanted() cherche « ,pile, » dans « ,$ONLY, » : avec des
# espaces, aucune pile ne correspondrait jamais, et le script annoncerait
# « 0 pile à traiter » en se déclarant en succès. On accepte donc les deux
# écritures. À noter : un essai avec UNE seule pile ne révèle pas ce défaut,
# puisqu'il n'y a pas de séparateur.
ONLY="$(printf '%s' "$ONLY" | tr -s ' \t' ',')"
SKIP_BUILD="${PRA_SKIP_BUILD:-0}"

declare -a RESULTS=()
declare -a FAILED_STACKS=()
STEP="démarrage"
VERDICT="en cours"

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
die()  { VERDICT="échec"; log "ÉCHEC  $*"; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then log "[à blanc] $*"; else "$@"; fi; }
record() {                       # une pile = une entrée : « démarrée » remplace
  local i                        # « image construite », sans clé JSON en double.
  for i in "${!RESULTS[@]}"; do
    if [ "${RESULTS[$i]%%=*}" = "$1" ]; then RESULTS[$i]="$1=$2"; return; fi
  done
  RESULTS+=("$1=$2")
}

write_status() {
  mkdir -p "$STATE_DIR"
  { printf '{\n  "horodatage": "%s",\n  "verdict": "%s",\n  "etape": "%s",\n' \
      "$(date -Is)" "$VERDICT" "$STEP"
    printf '  "piles": {\n'
    local first=1 r
    for r in "${RESULTS[@]:-}"; do
      [ -z "$r" ] && continue
      [ $first -eq 0 ] && printf ',\n'
      printf '    "%s": "%s"' "${r%%=*}" "${r#*=}"; first=0
    done
    printf '\n  }\n}\n'
  } > "$STATUS.tmp" && mv -f "$STATUS.tmp" "$STATUS"
}

# LE VERDICT DOIT MESURER LE TRAVAIL, PAS LE CODE DE SORTIE.
#
# Un script qui s'arrête proprement au milieu sort avec 0 : il se déclarerait
# donc en « succès » après avoir démarré une pile sur six, les autres jamais
# lancées. Sur un outil qu'on ne consulte qu'en crise, c'est pire qu'une panne
# franche — ça fait ranger le dossier.
#
# On compte donc les piles réellement traitées et l'on refuse « succès » s'il en
# manque. PILES_ATTENDUES est renseigné à la lecture du manifeste, PILES_TRAITEES
# à chaque démarrage mené à son terme.
PILES_ATTENDUES=0
PILES_TRAITEES=0
on_exit() {
  local code=$?
  if [ "$code" -ne 0 ]; then
    VERDICT="échec"
  elif [ "$PILES_ATTENDUES" -gt 0 ] && [ "$PILES_TRAITEES" -lt "$PILES_ATTENDUES" ]; then
    # Arrêt silencieux : on le NOMME, plutôt que de laisser « succès » mentir.
    VERDICT="INTERROMPU ($PILES_TRAITEES/$PILES_ATTENDUES piles)"
    log "ATTENTION  le script s'est arrêté avant d'avoir traité toutes les piles :"
    log "  $PILES_TRAITEES sur $PILES_ATTENDUES. Les autres n'ont PAS été démarrées."
  elif [ "$VERDICT" = "en cours" ]; then
    VERDICT="succès"
  fi
  write_status
  log "==== FIN — $VERDICT (étape : $STEP) ===="
}
trap on_exit EXIT

wanted() {                       # 0 si la pile doit être traitée
  [ -z "$ONLY" ] && return 0
  printf '%s' ",$ONLY," | grep -q ",$1,"
}

### ─── PRÉREQUIS ────────────────────────────────────────────────────────────
[[ "$(id -u)" -eq 0 ]] || die "à exécuter en root"
exec 9>"$LOCK"; flock -n 9 || die "restauration Docker déjà en cours"

if ! command -v docker >/dev/null 2>&1; then
  die "Docker absent. Installation :
       curl -fsSL https://get.docker.com | sh
     Puis fermer le port 2375 s'il a été ouvert :
       yunohost firewall disallow TCP 2375"
fi
docker compose version >/dev/null 2>&1 || die "le greffon « docker compose » manque"
[ "$(uname -m)" = "aarch64" ] || warn "architecture $(uname -m), arm64 attendu"

mkdir -p "$ROOT" "$STATE_DIR"
log "==== DÉBUT RESTAURATION DOCKER ===="

### ─── 1. INSTANTANÉ ────────────────────────────────────────────────────────
STEP="lecture de l'instantané"
# L'INSTANTANÉ DOIT CORRESPONDRE À L'ARCHIVE YUNOHOST RESTAURÉE.
#
# Prendre toujours le plus récent a une conséquence : quand on choisit une
# archive YunoHost ANTÉRIEURE parce qu'on soupçonne un chiffrement,
# le volet Docker restaurait quand même l'instantané du jour — c'est-à-dire
# potentiellement celui qui est chiffré. Le sélecteur d'archive ne protégeait
# alors que la moitié du dispositif, et l'autre moitié ramenait la contamination.
#
# Le nommage rend l'appariement sûr : « AAAAMMJJ-HHMMSS.tar » côté YunoHost,
# « AAAAMMJJ-docker.tar » côté Docker. Un même jour, deux fichiers.
#
#   PRA_DOCKER_SNAPSHOT : un instantané désigné, nom exact ;
#   PRA_JOUR            : le jour à apparier, transmis par le script de
#                         restauration quand il enchaîne le volet Docker ;
#   sinon               : le plus récent, comme avant.
STEP="lecture de l'instantané"
SNAP=""
if [ -n "${PRA_DOCKER_SNAPSHOT:-}" ]; then
  # Nom seul, jamais un chemin : aucun caractère de chemin ne franchit ce filtre.
  case "$PRA_DOCKER_SNAPSHOT" in
    */*|..*) die "instantané : nom de fichier attendu, pas un chemin" ;;
  esac
  SNAP="$SRC_DIR/$PRA_DOCKER_SNAPSHOT"
  [ -f "$SNAP" ] || die "instantané désigné introuvable : $PRA_DOCKER_SNAPSHOT"
  log "Instantané DÉSIGNÉ : $(basename "$SNAP")"
elif [ -n "${PRA_JOUR:-}" ] && compgen -G "$SRC_DIR/${PRA_JOUR}-docker.tar" > /dev/null \
     || { [ -n "${PRA_JOUR:-}" ] && compgen -G "$SRC_DIR/${PRA_JOUR}-*-docker.tar" > /dev/null; }; then
  # PLUSIEURS INSTANTANÉS PEUVENT PORTER LE MÊME JOUR depuis que l'heure figure
  # dans le nom — celui du cron et un manuel, typiquement. On prend LE PLUS
  # PROCHE DANS LE TEMPS de l'archive : une sauvegarde manuelle de 17h28 se
  # marie avec l'instantané de 17h45 qu'elle a déclenché, pas avec celui de
  # 01h00 — et l'archive nocturne de 00h00 avec celui de 01h00, pas avec un
  # manuel de l'après-midi. L'ancien nommage sans heure vaut 000000.
  #
  # PRA_HEURE (HHMMSS) vient de l'archive ; à défaut, on prend le plus récent
  # du jour — le cas d'un appel manuel où seul le jour est connu.
  SNAP="$(find "$SRC_DIR" -maxdepth 1 -type f \
            \( -name "${PRA_JOUR}-docker.tar" -o -name "${PRA_JOUR}-[0-9]*-docker.tar" \) \
            -printf '%f\n' 2>/dev/null \
          | python3 -c '
import re, sys
heure = (sys.argv[1] or "").strip()
noms = [l.strip() for l in sys.stdin if l.strip()]
def h(n):
    m = re.match(r"\d{8}-(\d{6})-docker\.tar$", n)
    return int(m.group(1)) if m else 0
if not noms:
    sys.exit(0)
if re.fullmatch(r"\d{6}", heure):
    ref = int(heure)
    noms.sort(key=lambda n: abs(h(n) - ref))
else:
    noms.sort(key=h, reverse=True)
print(noms[0])' "${PRA_HEURE:-}")"
  [ -n "$SNAP" ] || die "appariement au $PRA_JOUR : liste vide malgré le motif — incohérence"
  SNAP="$SRC_DIR/$SNAP"
  log "Instantané apparié à l'archive du $PRA_JOUR${PRA_HEURE:+ (au plus près de ${PRA_HEURE})} : $(basename "$SNAP")"
elif [ -n "${PRA_JOUR:-}" ]; then
  # Le jour est connu mais son instantané manque. On NE prend PAS le plus récent
  # en silence : ce serait exactement le piège qu'on vient de corriger. On prend
  # le plus récent qui ne soit pas POSTÉRIEUR au jour demandé.
  SNAP="$(find "$SRC_DIR" -maxdepth 1 -type f -name '*-docker.tar' 2>/dev/null \
          | sed 's|.*/||' | sort | awk -v j="$PRA_JOUR" '$0 <= j"-docker.tar"' \
          | tail -1)"
  if [ -n "$SNAP" ]; then
    SNAP="$SRC_DIR/$SNAP"
    warn "aucun instantané Docker du $PRA_JOUR — repli sur $(basename "$SNAP")"
    warn "  ANTÉRIEUR au jour demandé, jamais postérieur : restaurer des piles plus"
    warn "  récentes que l'archive ramènerait ce qu'on cherche à éviter"
  else
    die "aucun instantané Docker au $PRA_JOUR ou avant — préciser PRA_DOCKER_SNAPSHOT"
  fi
fi
if [ -z "$SNAP" ]; then
  SNAP="$(find "$SRC_DIR" -maxdepth 1 -type f -name '*-docker.tar' \
          -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
fi
[ -n "$SNAP" ] || die "aucun instantané *-docker.tar dans $SRC_DIR"
log "Instantané : $(basename "$SNAP") ($(du -h "$SNAP" | cut -f1))"

if [ -f "$SNAP.sha256" ]; then
  if [ "$(sha256sum "$SNAP" | cut -d' ' -f1)" = "$(cat "$SNAP.sha256")" ]; then
    log "Empreinte conforme"
  else
    # LA PROMESSE ÉTAIT FAUSSE SOUS ÉCRITURE UNIQUE. « il sera retéléchargé » :
    # non — le magasin est en --ignore-existing, un fichier présent n'est JAMAIS
    # réécrit. Un instantané tronqué serait donc resté en place et aurait fait
    # échouer CHAQUE nuit avec ce même message, indéfiniment, jusqu'à une
    # intervention manuelle.
    #
    # On met le fichier en QUARANTAINE — renommé, pas supprimé : si la
    # production envoie des fichiers corrompus, ces copies sont des indices —
    # et l'on libère le nom : le prochain transfert rapatriera une copie
    # saine, et la rétention purge les quarantaines après trente jours.
    _quar="$SNAP.corrompu-$(date +%Y%m%d%H%M%S)"
    mv -f "$SNAP" "$_quar" 2>/dev/null || true
    mv -f "$SNAP.sha256" "$_quar.sha256" 2>/dev/null || true
    die "empreinte NON conforme — instantané mis en quarantaine ($(basename "$_quar")), le prochain transfert rapatriera une copie saine"
  fi
else
  warn "pas d'empreinte fournie, intégrité non vérifiée"
fi

rm -rf "$WORK"; mkdir -p "$WORK"
tar xf "$SNAP" -C "$WORK"
[ -f "$WORK/manifest.json" ] || die "manifeste absent de l'instantané"
log "Manifeste lu"

# Combien de piles doivent être démarrées à la fin. Sert au verdict : sans ce
# décompte, un arrêt au milieu passait pour un succès.
for _d in "$WORK"/compose/*/; do
  [ -d "$_d" ] || continue
  wanted "$(basename "$_d")" && PILES_ATTENDUES=$((PILES_ATTENDUES + 1))
done
log "  $PILES_ATTENDUES pile(s) à traiter"

### ─── 2. CONFIGURATIONS ET SECRETS ─────────────────────────────────────────
STEP="mise en place des configurations"
for d in "$WORK"/compose/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  wanted "$name" || continue
  install -d -m 755 "$ROOT/$name"
  cp -a "$d". "$ROOT/$name/"
  # Les .env portent des secrets : jamais lisibles par tous.
  if [ -f "$WORK/env/$name.env" ]; then
    install -m 600 "$WORK/env/$name.env" "$ROOT/$name/.env"
    log "  $name : composition + .env"
  else
    log "  $name : composition (pas de .env)"
  fi
  # Les .secrets, quand l'instantané en porte. Le propriétaire définitif est posé
  # plus loin, par l'adaptateur de la pile, qui seul sait quel identifiant
  # d'utilisateur attend le conteneur.
  if [ -d "$WORK/secrets/$name" ]; then
    install -d -m 700 "$ROOT/$name/.secrets"
    n=0
    for s in "$WORK/secrets/$name"/*; do
      [ -f "$s" ] || continue
      install -m 600 "$s" "$ROOT/$name/.secrets/$(basename "$s")"
      n=$((n + 1))
    done
    [ "$n" -gt 0 ] && log "    .secrets : $n fichier(s) en place"
  fi
done

### ─── 3. SURCHARGE DES PORTS : 127.0.0.1 UNIQUEMENT ───────────────────────
# On n'édite pas la composition venue de la prod : on ajoute un fichier de
# surcharge, mécanisme prévu par Docker Compose.
STEP="adaptation des piles au réplica"

# « ports: !override » et non « ports: » seul : Docker Compose FUSIONNE les
# listes au lieu de les remplacer. Sans ce marqueur, le service héritait du
# « 3002:3002 » de la production ET du « 127.0.0.1:3002:3002 » de la surcharge :
# il liait 0.0.0.0:3002 puis échouait à lier 127.0.0.1:3002, déjà couvert.
# d'où « failed to bind host port : address already in use ». Les maps
# (environment) fusionnent par clé, elles, donc une variable redéfinie ici
# l'emporte — c'est ce qu'on veut.
#
# Le nom du SERVICE dans la composition n'est pas celui du conteneur : une pile
# peut fixer « container_name » et nommer son service autrement. Coder le nom en
# dur produit un service fantôme — « has neither an image nor a build context ».
# On identifie donc le service PAR LE PORT qu'il publie, ce qui s'adapte seul.
service_publishing() {           # fichier compose, port
  docker compose -f "$1" config --format json 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
port = sys.argv[1]
for name, svc in (d.get("services") or {}).items():
    for p in (svc.get("ports") or []):
        if port in (str(p.get("published", "")), str(p.get("target", ""))):
            # Le port interne diffère souvent du port publié (un mandataire
            # publie 8080 vers un nginx qui écoute sur 80) : on le remonte.
            print(name, p.get("target", port))
            sys.exit(0)
sys.exit(1)' "$2"
}

override() {                     # pile, port, [lignes d'environnement]
  local stack="$1" port="$2"; shift 2
  wanted "$stack" || return 0
  local dir="$ROOT/$stack"
  [ -d "$dir" ] || return 0

  local base svc target
  base="$(find "$dir" -maxdepth 1 -type f \( -name 'docker-compose.yml' \
          -o -name 'docker-compose.yaml' -o -name 'compose.yml' \
          -o -name 'compose.yaml' \) | head -1 || true)"
  [ -n "$base" ] || { warn "$stack : composition introuvable"; return 0; }

  if ! svc="$(cd "$dir" && service_publishing "$(basename "$base")" "$port")" \
       || [ -z "$svc" ]; then
    warn "$stack : aucun service ne publie le port $port — surcharge ignorée"
    return 0
  fi
  target="${svc##* }"; svc="${svc%% *}"
  [ -n "$target" ] || target="$port"

  local f="$dir/docker-compose.override.yml"
  {
    printf '# Généré par pra_docker_restore.sh — NE PAS MODIFIER À LA MAIN.\n'
    printf '# Ports restreints à la boucle locale : nginx est le seul\n'
    printf '# consommateur, et Docker contourne le pare-feu de l'"'"'hôte.\n'
    printf 'services:\n  %s:\n    ports: !override\n      - "127.0.0.1:%s:%s"\n' \
           "$svc" "$port" "$target"
    if [ "$#" -gt 0 ]; then
      printf '    environment:\n'
      printf '      %s\n' "$@"
    fi
  } > "$f"
  chmod 600 "$f"
  log "  $stack : service « $svc » → 127.0.0.1:$port (interne $target)${1:+ (+ environnement adapté)}"
}

# Liaison des ports sur la boucle locale, pile par pile.
#
# Les compositions venues de la production publient souvent leurs ports sur
# toutes les interfaces. Sur un réplica joignable par d'autres machines, c'est
# une exposition qu'on ne veut pas : on réécrit donc la publication en
# 127.0.0.1 au moyen d'un docker-compose.override.yml.
#
#   PRA_DOCKER_PORTS="pile:port pile:port …"
#
# Tout ajustement plus fin — variable d'environnement, réécriture d'URL —
# relève d'un adaptateur de pile (voir plus bas).
for _liaison in ${PRA_DOCKER_PORTS:-}; do
  case "$_liaison" in
    *:*) override "${_liaison%%:*}" "${_liaison##*:}" ;;
    *)   warn "PRA_DOCKER_PORTS : « $_liaison » ignoré (format attendu pile:port)" ;;
  esac
done

# L'AUTORITÉ INTERNE, EXTRAITE UNE FOIS POUR TOUTES LES PILES.
#
# Le chemin est global, et non « local » à un adaptateur : plusieurs piles en ont
# le même besoin. Sous « set -u », une variable vue par une seule fonction fait
# mourir le script sur « unbound variable » — et l'erreur désigne alors la pile
# suivante, pas la vraie cause.
CA_PUB="${PRA_CA_PUB:-$STATE_DIR/ca-yunohost.pem}"
_ca_tentee=0
extraire_ca_yunohost() {
  [ "$_ca_tentee" = 1 ] && return 0
  _ca_tentee=1
  local dom_arche="$1" ca_tmp
  ca_tmp="$(mktemp)"
  mkdir -p "$STATE_DIR"
  # La CA de YunoHost est en root:ssl-cert 640 ; les conteneurs tournent sous un
  # compte non privilégié (bunjs, uid 1001) et ne peuvent pas la lire — Bun
  # signale « load failed: system library » puis rejette le certificat. Un
  # certificat d'AUTORITÉ est une donnée publique, contrairement à la clé
  # privée : on en dépose une copie lisible plutôt que d'ouvrir l'original.
  # ATTENTION AU FICHIER QU'ON PREND. « /etc/ssl/certs/ca-yunohost_crt.pem »
  # porte le certificat AUTO-SIGNÉ du DOMAINE, pas l'autorité qui le signe.
  # Fourni comme autorité, il ne valide rien et la vérification TLS échoue
  # quand même.
  #
  # L'autorité réellement présentée — « CN=yunohost.org, O=yunohost » — ne se
  # trouve nulle part sous /etc ni /usr/share. On l'extrait donc de la poignée
  # de main, EN LOCAL, sur 127.0.0.1 où aucune interception n'est possible, puis
  # on vérifie qu'elle est auto-signée ET qu'elle valide le certificat du
  # domaine. Sans ces deux contrôles, on stockerait n'importe quoi sous le nom
  # d'« autorité ».
  #
  # Sans cela, la découverte OIDC échoue en « self-signed certificate in
  # certificate chain ». Les conteneurs, eux, ne s'en aperçoivent pas : ils
  # désactivent la vérification TLS, ce qui masque le défaut.
  if echo | openssl s_client -connect 127.0.0.1:443 -servername "$dom_arche" \
       -showcerts 2>/dev/null | awk '/BEGIN CERT/{n++} n==2' > "$ca_tmp" \
     && [ -s "$ca_tmp" ] \
     && openssl verify -CAfile "$ca_tmp" "$ca_tmp" >/dev/null 2>&1 \
     && openssl verify -CAfile "$ca_tmp" \
          "/etc/yunohost/certs/$dom_arche/crt.pem" >/dev/null 2>&1; then
    install -m 644 "$ca_tmp" "$CA_PUB"
    log "  autorité interne extraite et vérifiée : $CA_PUB"
  else
    warn "  autorité de YunoHost non extraite : la découverte OIDC échouera en TLS"
  fi
  rm -f "$ca_tmp"
}

# ── ADAPTATEURS PAR PILE — POINT D'EXTENSION ───────────────────────────────
#
# Une pile venue de la production a parfois besoin d'ajustements propres au
# réplica : réécriture d'URL et de noms d'hôtes codés en dur, montage de
# l'autorité interne, droits d'un fichier de secret, URI de retour OIDC. Ces
# ajustements dépendent entièrement de l'application : ils ne sont donc pas
# codés ici.
#
# Si « $ADAPTATEURS/<pile>.sh » existe, il est SOURCÉ après la mise en place de
# la composition et avant la construction des images. Il dispose de :
#
#   $name   nom de la pile              $dir    son répertoire (compose, .env)
#   $WORK   instantané déplié           $ROOT   racine des piles
#   $CA_PUB copie lisible de l'autorité interne (si extraite)
#   log, warn, run, override, wanted, extraire_ca_yunohost
#
# Sourcé et non exécuté : l'adaptateur voit ces fonctions et peut modifier les
# fichiers de la pile. Il tourne en root, comme ce script — n'y mettre que du
# code dont on répond.
ADAPTATEURS="${PRA_ADAPTATEURS:-/etc/pra/adaptateurs}"
for dir in "$ROOT"/*/; do
  [ -d "$dir" ] || continue
  name="$(basename "$dir")"
  [ "$name" = ".work" ] && continue
  wanted "$name" || continue
  [ -r "$ADAPTATEURS/$name.sh" ] || continue
  log "  $name : adaptateur $ADAPTATEURS/$name.sh"
  # shellcheck source=/dev/null
  . "$ADAPTATEURS/$name.sh" || warn "  $name : adaptateur en échec"
done
unset dir name

# Les compositions venues de la production peuvent contenir des secrets en clair
# (JWT_SECRET_KEY du tableau blanc, par exemple) : elles ne doivent pas rester
# lisibles par tous sur le réplica.
find "$ROOT" -maxdepth 2 -type f \( -name '*.yml' -o -name '*.yaml' -o -name '.env' \) \
     -exec chmod 600 {} + 2>/dev/null || true

# Les piles en réseau « host » échappent à la liaison sur la boucle locale : la
# surcharge de ports ne s'y applique pas et leurs services écoutent sur toutes
# les interfaces. On le signale pile par pile — c'est à arbitrer, pas à corriger
# d'autorité ici.
for _d in "$ROOT"/*/; do
  [ -d "$_d" ] || continue
  _n="$(basename "$_d")"
  [ "$_n" = ".work" ] && continue
  if grep -qsE '^[[:space:]]*network_mode:[[:space:]]*"?host"?' \
       "$_d"docker-compose.yml "$_d"docker-compose.yaml \
       "$_d"compose.yml "$_d"compose.yaml; then
    warn "$_n en réseau host : ses ports ne sont pas liés à la boucle locale"
  fi
done
unset _d _n

### ─── 4. CONSTRUCTION DES IMAGES ──────────────────────────────────────────
STEP="construction des images"
if [ "$SKIP_BUILD" = 1 ]; then
  log "PRA_SKIP_BUILD=1 : construction ignorée"
else
  for tgz in "$WORK"/src/*.tar.gz; do
    [ -f "$tgz" ] || continue
    name="$(basename "$tgz" .tar.gz)"
    wanted "$name" || continue
    log "Extraction des sources de $name"
    run tar xzf "$tgz" -C "$ROOT"
    if [ "$DRY_RUN" = 1 ]; then log "[à blanc] docker compose build dans $ROOT/$name"; continue; fi

    # Adaptation des sources à l'architecture du réplica.
    #
    # Le verrou de dépendances a été produit sur l'architecture de la production.
    # Sur une autre, le gestionnaire résout des dépendances optionnelles
    # différentes et « --frozen-lockfile » refuse de poursuivre : « lockfile had
    # changes, but lockfile is frozen ». On relâche donc le gel ICI, côté réplica,
    # et on le journalise — jamais en silence.
    #
    # Conséquence assumée : les versions résolues sur l'arche peuvent différer
    # très légèrement de celles de la production. Le correctif propre serait de
    # produire côté production un verrou couvrant les deux architectures.
    while IFS= read -r df; do
      if grep -q 'bun install --frozen-lockfile' "$df" 2>/dev/null; then
        sed -i 's/bun install --frozen-lockfile/bun install/g' "$df"
        log "  gel du verrou relâché dans $(basename "$(dirname "$df")")/$(basename "$df")"
      fi
      # Node laisse son tas grossir jusqu'à la mémoire disponible : une compilation
      # peut atteindre plusieurs gigaoctets et se faire tuer (code 137) sur une
      # petite machine. En plafonnant, le ramasse-miettes travaille plus tôt et la
      # compilation passe.
      if grep -qE '^RUN +bun run ' "$df" 2>/dev/null \
         && ! grep -q 'max-old-space-size' "$df" 2>/dev/null; then
        sed -i -E 's/^(RUN +)(bun run )/\1NODE_OPTIONS=--max-old-space-size=3072 \2/' "$df"
        log "  tas Node plafonné à 3 Go dans $(basename "$(dirname "$df")")/$(basename "$df")"
      fi
    done < <(find "$ROOT/$name" -type f -name 'Dockerfile*' 2>/dev/null)

    # Construction SERVICE PAR SERVICE. « docker compose build » construit en
    # parallèle : deux compilations lourdes démarrent alors ensemble et somment
    # leurs pics de mémoire. Séquentiellement, le pic est divisé d'autant.
    blog="$(mktemp)"
    mapfile -t build_svcs < <(cd "$ROOT/$name" && docker compose config --format json 2>/dev/null \
      | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for n, s in (d.get("services") or {}).items():
    if s.get("build"): print(n)')
    build_ok=1
    for bsvc in "${build_svcs[@]:-}"; do
      [ -n "$bsvc" ] || continue
      log "  construction de « $bsvc »"
      # DEUX TENTATIVES. La construction télécharge des dépendances : elle dépend
      # donc du réseau, et le réseau rate — « Fail extracting tarball » est un
      # incident de téléchargement, pas une erreur de code. Une panne transitoire ne
      # mérite pas qu'on abandonne la pile pour la nuit.
      if (cd "$ROOT/$name" && docker compose build "$bsvc") >> "$blog" 2>&1; then
        continue
      fi
      warn "  $name/$bsvc : première construction en échec — nouvelle tentative dans 15 s"
      sleep 15
      if ! (cd "$ROOT/$name" && docker compose build "$bsvc") >> "$blog" 2>&1; then
        build_ok=0; break
      fi
      log "  $name/$bsvc : construit à la seconde tentative"
    done
    if [ "$build_ok" = 1 ]; then
      log "  $name construit localement"
      record "$name" "image construite"
    else
      warn "  échec de construction de $name"
      # 30 lignes utiles : cinq ne suffisaient pas à identifier la cause.
      grep -vE '^#[0-9]+ (sha256|extracting|transferring|DONE|CACHED)' "$blog" \
        | tail -30 | while IFS= read -r l; do warn "    $l"; done
      record "$name" "ÉCHEC de construction"
      printf '%s\n' "${FAILED_STACKS[@]:-}" | grep -qx "$name" || FAILED_STACKS+=("$name")
    fi
    rm -f "$blog"
  done
fi

### ─── 5. DONNÉES EN BIND ───────────────────────────────────────────────────
STEP="restauration des données"
# Certaines piles gardent leurs données hors des volumes Docker, dans un
# répertoire monté. L'instantané les apporte sous « data/<nom>.tar.gz », mais la
# destination dépend de la composition et ne se devine pas :
#
#   PRA_DOCKER_DONNEES="nom:/chemin/de/destination …"
#
# Une archive sans destination déclarée est SIGNALÉE et non extraite : déplier
# une arborescence au hasard sur le disque serait pire que de ne rien faire.
for _tgz in "$WORK"/data/*.tar.gz; do
  [ -f "$_tgz" ] || continue
  _nom="$(basename "$_tgz" .tar.gz)"
  _dest=""
  for _couple in ${PRA_DOCKER_DONNEES:-}; do
    [ "${_couple%%:*}" = "$_nom" ] && _dest="${_couple#*:}"
  done
  if [ -z "$_dest" ]; then
    warn "données « $_nom » : aucune destination déclarée (PRA_DOCKER_DONNEES) — ignorées"
    continue
  fi
  log "Données $_nom → $_dest"
  run mkdir -p "$_dest"
  run tar xzf "$_tgz" -C "$_dest"
done
unset _tgz _nom _dest _couple

### ─── 6. DÉMARRAGE DES PILES ───────────────────────────────────────────────
STEP="démarrage des piles"
for d in "$ROOT"/*/; do
  name="$(basename "$d")"
  [ "$name" = ".work" ] && continue
  wanted "$name" || continue
  # Les trois sauts qui suivent sont VOLONTAIRES et journalisés : ils comptent
  # donc comme traités. Sans cela le verdict crierait « INTERROMPU » sur un
  # déroulement normal — et une alerte qui se déclenche à tort ne sera plus lue.
  compose="$(find "$d" -maxdepth 1 -name 'docker-compose.yml' -o -maxdepth 1 -name 'compose.yaml' | head -1 || true)"
  [ -n "$compose" ] || { warn "$name : aucune composition"
                         PILES_TRAITEES=$((PILES_TRAITEES + 1)); continue; }
  # CONSTRUCTION EN ÉCHEC : ON TENTE L'IMAGE PRÉCÉDENTE AVANT D'ABANDONNER.
  #
  # « up » relancerait la construction et reproduirait l'échec — d'où
  # « --no-build », qui exige que l'image existe déjà. Sans ce repli, une pile
  # reste à terre toute la nuit pour un incident de téléchargement, alors que ses
  # images de la veille sont toujours là.
  #
  # Une image de la veille avec des données d'aujourd'hui n'est pas sans
  # risque : si le schéma a changé entre-temps, l'application peut refuser de
  # démarrer ou se comporter étrangement. Mais un service dégradé qu'on sait
  # dégradé vaut mieux qu'un service absent — à condition de le DIRE.
  if printf '%s\n' "${FAILED_STACKS[@]:-}" | grep -qx "$name"; then
    if [ "$DRY_RUN" != 1 ] \
       && (cd "$d" && docker compose up -d --no-build) >/dev/null 2>&1; then
      warn "$name : construction en échec — démarré avec l'IMAGE PRÉCÉDENTE"
      warn "  les données viennent de cette nuit, l'image de la dernière"
      warn "  construction réussie : vérifiez la pile avant de vous y fier"
      record "$name" "démarré sur l'image précédente"
    else
      warn "$name : construction en échec et aucune image utilisable — à terre"
    fi
    PILES_TRAITEES=$((PILES_TRAITEES + 1))
    continue
  fi
  log "Démarrage de $name"
  if [ "$DRY_RUN" = 1 ]; then log "[à blanc] docker compose up -d"
                              PILES_TRAITEES=$((PILES_TRAITEES + 1)); continue; fi
  # UNE TÂCHE PONCTUELLE QUI ÉCHOUE NE DOIT PAS COUCHER LA PILE.
  #
  # Une pile peut déclarer « depends_on: migrate: service_completed_successfully ».
  # Les piles démarrent AVANT la restauration des bases : la migration s'exécute
  # donc contre la base de la veille, qui porte déjà le schéma, et meurt en
  # « duplicate_object » — parce que les fichiers de migration ont été
  # régénérés en amont et que leurs empreintes ne correspondent plus au journal.
  # La condition n'étant pas remplie, app et server restent « created » : la
  # pile entière est à terre pour une tâche qui n'avait rien à faire.
  #
  # Ce n'est pas à l'arche de réconcilier le code et la base de la production —
  # elle les reproduit fidèlement, c'est son travail. Mais elle peut démarrer ce
  # qui peut l'être, et le dire.
  mapfile -t _ponct < <( (cd "$d" && docker compose config --format json) 2>/dev/null \
      | python3 -c 'import json,sys
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
vus = set()
for s in (d.get("services") or {}).values():
    dep = s.get("depends_on") or {}
    if isinstance(dep, dict):
        for n, c in dep.items():
            if isinstance(c, dict) and c.get("condition") == "service_completed_successfully":
                vus.add(n)
for n in sorted(vus): print(n)' 2>/dev/null)

  _demarre_pile() {
    (cd "$d" && docker compose up -d 2>&1 | tail -3) && return 0
    [ "${#_ponct[@]}" -gt 0 ] || return 1
    warn "  $name : « ${_ponct[*]} » en échec — on démarre le reste sans elle"
    warn "    (base et code de la production ne concordent pas : à traiter LÀ-BAS)"
    local _s _saut _ok=1
    while IFS= read -r _s; do
      [ -n "$_s" ] || continue
      _saut=0
      for _j in "${_ponct[@]}"; do [ "$_s" = "$_j" ] && _saut=1; done
      [ "$_saut" = 1 ] && continue
      (cd "$d" && docker compose up -d --no-deps "$_s") >/dev/null 2>&1 || _ok=0
    done < <( (cd "$d" && docker compose config --services) 2>/dev/null)
    return "$([ "$_ok" = 1 ] && echo 0 || echo 1)"
  }
  if _demarre_pile; then
    # « docker compose up » réussit dès que les conteneurs sont LANCÉS. Il ne
    # dit rien de ceux qui meurent dans la seconde qui suit — et c'est le cas le
    # plus fréquent après une restauration : toute la pile remonte d'un coup, et
    # le mandataire interne démarre avant que le conteneur applicatif soit
    # résolvable. nginx échoue alors net au chargement, sans jamais réessayer.
    #
    # Une pile déclarée « démarrée » peut ainsi rendre 502 pendant des heures. Un
    # compte rendu qui affirme le succès d'un service mort est pire que pas de
    # compte rendu du tout.
    sleep 8
    # LE CODE DE SORTIE, PAS SEULEMENT L'ÉTAT.
    #
    # Une tâche à usage unique — migration de schéma, initialisation — s'exécute
    # puis SORT. Son état est « exited » et c'est un succès, pas une panne.
    # Le filtre précédent tentait d'écarter « exited(0) », mais ce motif ne peut
    # jamais correspondre : {{.State}} vaut « exited » tout court, le code n'y
    # figure pas. Il fallait {{.ExitCode}}.
    # Le compte rendu annonçait donc des « piles en échec » qui fonctionnaient,
    # leurs conteneurs de migration ayant rendu 0. Crier au loup dans un outil
    # qu'on ne consulte qu'en crise est aussi grave que taire une vraie panne :
    # les deux détruisent la confiance.
    # Les tâches ponctuelles sont jugées À PART : « migrate » en échec sur une
    # base qui porte déjà son schéma n'est pas une pile à terre — app, server
    # et reverse tournent. La compter parmi les morts faisait MOURIR le script
    # une ligne plus bas : la « nouvelle tentative » relançait « up -d »
    # complet, qui échouait sur la même dépendance, et ce retour non nul sous
    # « set -e » abattait la restauration AVANT le rechargement des bases.
    _morts() {
      (cd "$d" && docker compose ps --all \
         --format '{{.Service}} {{.State}} {{.ExitCode}}' 2>/dev/null) \
        | awk -v ponct=" ${_ponct[*]:-} " \
          '$2 != "running" && !($2 == "exited" && $3 == 0) \
           && index(ponct, " " $1 " ") == 0 {print $1}' \
        | tr '\n' ' '
    }
    for _j in "${_ponct[@]:-}"; do
      [ -n "$_j" ] || continue
      _ec="$( (cd "$d" && docker compose ps --all \
               --format '{{.Service}} {{.State}} {{.ExitCode}}' 2>/dev/null) \
             | awk -v s="$_j" '$1 == s && $2 == "exited" && $3 != 0 {print $3}')"
      [ -n "$_ec" ] && warn "  $name : tâche ponctuelle « $_j » en échec (code $_ec) — non bloquant ici, désaccord code/base à traiter sur la PRODUCTION"
    done
    morts="$(_morts)"
    if [ -n "${morts// /}" ]; then
      warn "$name : conteneurs à terre après lancement :$morts"
      log "  nouvelle tentative — course au démarrage probable"
      (cd "$d" && docker compose up -d >/dev/null 2>&1) || true
      sleep 8
      morts="$(_morts)"
    fi

    # ── L'ACCESSIBILITÉ, ET NON L'ÉTAT DES CONTENEURS ───────────────────────
    #
    # Tous les conteneurs peuvent tourner et la pile répondre 502 quand même.
    # Le nginx interne ne résout le nom du conteneur applicatif QU'UNE FOIS, au
    # chargement. Si l'applicatif est recréé — ce que fait toute restauration —
    # son adresse change et le mandataire garde l'ancienne :
    #     app est en    172.21.0.4
    #     nginx tentait 172.21.0.2
    # C'est la cause des 502 persistants sur une pile par ailleurs déclarée
    # « démarrée ».
    #
    # Pire : l'ancien remède relançait TOUTE la pile, donc recréait l'applicatif
    # et reproduisait le décalage. Il entretenait le défaut qu'il croyait corriger.
    #
    # Le bon geste est de ne relancer QUE le mandataire, pour qu'il résolve à
    # nouveau. On l'identifie sans deviner son nom : c'est le service qui publie
    # le port sur 127.0.0.1.
    # « || true » OBLIGATOIRE : une pile sans port publié sur 127.0.0.1 — celles en
    # réseau « host » — fait rendre 1 à grep. Sous « pipefail », la substitution
    # échoue et « set -e » abat le script au milieu de la restauration. Ici,
    # « rien à sonder » est un cas NORMAL, pas une erreur.
    _sonde_port="$( (cd "$d" && docker compose ps --format '{{.Service}} {{.Ports}}' 2>/dev/null) \
                    | grep -oE '127\.0\.0\.1:[0-9]+' | head -1 | cut -d: -f2 || true )"
    _sonde_svc="$( (cd "$d" && docker compose ps --format '{{.Service}} {{.Ports}}' 2>/dev/null) \
                    | awk '/127\.0\.0\.1:[0-9]+/ {print $1; exit}' || true )"
    _code_http() {
      curl -s -o /dev/null -w '%{http_code}' --max-time 6 \
           "http://127.0.0.1:$1/" 2>/dev/null || echo 000
    }
    if [ -n "$_sonde_port" ] && command -v curl >/dev/null 2>&1; then
      _c="$(_code_http "$_sonde_port")"
      # ATTENDRE L'AMONT AVANT DE DIAGNOSTIQUER UNE ADRESSE PÉRIMÉE.
      #
      # La pile vient d'être relancée : son mandataire répond aussitôt, l'amont met
      # des dizaines de secondes. Lire ce 502 immédiat comme « mandataire sur une
      # adresse périmée » déclenche une relance inutile, chaque nuit, pour un service
      # qui allait répondre. Un diagnostic faux répété apprend à ignorer le vrai.
      #
      # On patiente d'abord ; seul un 502 qui DURE justifie le remède.
      _injoignable() { case "$1" in 000|502|503|504) return 0 ;; esac; return 1; }
      _attendu=0
      while _injoignable "$_c" && [ "$_attendu" -lt "${PRA_DOCKER_PATIENCE_S:-90}" ]; do
        sleep 10
        _attendu=$((_attendu + 10))
        _c="$(_code_http "$_sonde_port")"
      done
      if [ "$_attendu" -gt 0 ] && ! _injoignable "$_c"; then
        log "  $name : le port $_sonde_port répond après ${_attendu} s — démarrage lent, rien à relancer"
      fi
      # 000 = rien n'écoute ; 502/503/504 = le mandataire n'atteint pas l'amont.
      case "$_c" in
        000|502|503|504)
          warn "$name : le port $_sonde_port répond $_c — mandataire probablement sur une adresse périmée"
          if [ -n "$_sonde_svc" ]; then
            log "  relance du seul mandataire « $_sonde_svc » (et non de la pile)"
            (cd "$d" && docker compose restart "$_sonde_svc" >/dev/null 2>&1) || true
            sleep 6
            _c="$(_code_http "$_sonde_port")"
          fi
          case "$_c" in
            000|502|503|504)
              warn "$name : toujours $_c après relance du mandataire"
              record "$name" "INJOIGNABLE (port $_sonde_port : $_c)"
              printf '%s\n' "${FAILED_STACKS[@]:-}" | grep -qx "$name" || FAILED_STACKS+=("$name")
              ;;
            *) log "  $name : mandataire joignable après relance (code $_c)" ;;
          esac
          ;;
        *)
          # DIRE CE QUE LA SONDE MESURE, ET RIEN DE PLUS.
          #
          # Elle vérifie que le mandataire RÉPOND, pas que l'application est saine au
          # chemin interrogé. Une pile servie sous un sous-chemin rend 404 sur sa
          # racine, et c'est la preuve que son nginx fonctionne. Un compte rendu qui
          # inquiète à tort est aussi nuisible qu'un compte rendu qui rassure à tort.
          log "  $name : mandataire joignable (code $_c sur la racine du port $_sonde_port)"
          ;;
      esac
    fi

    if [ -n "${morts// /}" ]; then
      warn "$name : encore à terre après réessai :$morts"
      record "$name" "DÉMARRAGE INCOMPLET :$morts"
      printf '%s\n' "${FAILED_STACKS[@]:-}" | grep -qx "$name" || FAILED_STACKS+=("$name")
    elif ! printf '%s\n' "${FAILED_STACKS[@]:-}" | grep -qx "$name"; then
      record "$name" "démarrée"
    fi
    # Traitée : menée jusqu'au bout du contrôle, qu'elle soit saine ou non. Ce
    # décompte mesure la COUVERTURE, pas la santé — laquelle est dans « record ».
    PILES_TRAITEES=$((PILES_TRAITEES + 1))
  else
    warn "$name : démarrage en échec"; record "$name-demarrage" "ÉCHEC"
    PILES_TRAITEES=$((PILES_TRAITEES + 1))
    printf '%s\n' "${FAILED_STACKS[@]:-}" | grep -qx "$name" || FAILED_STACKS+=("$name")
  fi
done

### ─── 7. DUMPS POSTGRESQL ──────────────────────────────────────────────────
# Après le démarrage : les conteneurs de base doivent tourner pour ingérer.
STEP="restauration des bases"
# Mêmes précautions que côté production : le shell du conteneur résout ses
# propres identifiants, et la socket locale est forcée pour éviter le cas où
# PGHOST impose du TCP avec authentification par mot de passe.
PG_ENV='PGPASSWORD="${POSTGRES_PASSWORD:-}" '
PG_ARGS='-h /var/run/postgresql -U "${POSTGRES_USER:-postgres}"'

restore_pg() {
  local dump="$1" container="$2" stack="$3" who i=0 err
  [ -f "$dump" ] || return 0
  wanted "$stack" || return 0
  if ! docker inspect "$container" >/dev/null 2>&1; then
    warn "$container absent, dump non restauré"; record "$stack-db" "conteneur absent"; printf '%s\n' "${FAILED_STACKS[@]:-}" | grep -qx "$stack" || FAILED_STACKS+=("$stack"); return
  fi

  # PostgreSQL vient peut-être de démarrer : on attend qu'il accepte vraiment
  # une connexion, pas seulement que le conteneur soit lancé.
  # « postgres » et non la base applicative : celle-ci peut légitimement ne pas
  # exister — un essai précédent peut l'avoir effacée sans la recharger — et la
  # sonde attendrait alors deux minutes sur un serveur parfaitement vivant avant
  # de déclarer la pile en échec.
  local probe="${PG_ENV}psql ${PG_ARGS} -d postgres -tAc 'select 1'"
  until docker exec "$container" sh -c "$probe" >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -gt 60 ]; then
      warn "$container n'accepte pas de connexion après 2 min"
      while IFS= read -r l; do warn "    $l"; done \
        < <(docker exec "$container" sh -c "$probe" 2>&1 | head -4)
      record "$stack-db" "ÉCHEC connexion"; printf '%s\n' "${FAILED_STACKS[@]:-}" | grep -qx "$stack" || FAILED_STACKS+=("$stack"); return
    fi
    sleep 2
  done

  who="$(docker exec "$container" sh -c 'printf %s "${POSTGRES_USER:-postgres}"' 2>/dev/null || true)"
  log "Restauration de $(basename "$dump") dans $container (rôle ${who:-postgres})"
  if [ "$DRY_RUN" = 1 ]; then log "[à blanc] psql < $dump"; return; fi

  # ON DÉTRUIT LES BASES AVANT DE LES RECHARGER — sinon rien ne se recharge.
  #
  # Ces dumps sont des pg_dumpall : « CREATE DATABASE », « \connect »,
  # « CREATE TABLE », « COPY ». Rejoués dans un cluster qui a DÉJÀ ces bases,
  # chaque CREATE échoue en « already exists » et chaque COPY en doublons de
  # clés — le tout rangé dans les « erreurs non bloquantes ». Les bases restent
  # alors figées à leur premier import, et quelques dizaines d'« erreurs non
  # bloquantes » par nuit le disent sans que personne ne l'entende. Le volume
  # PostgreSQL survit aux redémarrages des piles : seul le tout premier
  # chargement, sur cluster vierge, a réellement fonctionné.
  #
  # On efface donc chaque base QUE LE DUMP S'APPRÊTE À RECRÉER — la liste vient
  # du dump lui-même, pas d'une devinette — après avoir coupé ses connexions.
  local _bases _b
  mapfile -t _bases < <(gunzip -c "$dump" \
    | grep -oE '^CREATE DATABASE "?[A-Za-z0-9_-]+"?' \
    | awk '{print $3}' | tr -d '"' | sort -u)
  if [ "${#_bases[@]}" -eq 0 ]; then
    warn "  aucun CREATE DATABASE dans le dump — chargement sans purge préalable"
  fi
  for _b in "${_bases[@]:-}"; do
    [ -n "$_b" ] || continue
    docker exec "$container" sh -c \
      "${PG_ENV}psql ${PG_ARGS} -d postgres -qc \
       \"select pg_terminate_backend(pid) from pg_stat_activity where datname = '$_b'\"" \
      >/dev/null 2>&1 || true
    if docker exec "$container" sh -c \
         "${PG_ENV}psql ${PG_ARGS} -d postgres -qc 'DROP DATABASE IF EXISTS \"$_b\"'" \
         >/dev/null 2>&1; then
      log "  base « $_b » effacée avant rechargement"
    else
      warn "  base « $_b » : suppression impossible — le chargement sera partiel"
    fi
  done

  err="$(mktemp)"
  # « -d » EXPLICITE. Sans lui, psql se connecte à une base portant le nom de
  # l'utilisateur : un rôle sans base homonyme fait échouer la restauration. Ces
  # dumps sont des sauvegardes de grappe (pg_dumpall) qui portent leurs propres
  # « \connect » : la base d'entrée n'est qu'un point d'accroche.
  # « -o /dev/null » : psql renvoie les tuples de résultat (setval, set_config…)
  # sur sa sortie standard, qui polluait le journal du PRA. Les erreurs, elles,
  # restent captées dans $err.
  # L'ANCRAGE SE FAIT SUR « postgres », PAS SUR LA BASE APPLICATIVE.
  #
  # On vient de l'effacer : s'y connecter échoue instantanément, le « || true »
  # avale l'échec, et le dump n'est jamais chargé. « postgres » existe toujours
  # dans ces images, et on ne l'efface jamais.
  gunzip -c "$dump" \
    | docker exec -i "$container" sh -c \
        "${PG_ENV}psql ${PG_ARGS} -d postgres -q -o /dev/null" 2>"$err" || true

  # On ne se fie PAS au code de retour : sans « ON_ERROR_STOP », psql sort en 0
  # même si chaque instruction a échoué. On compte les tables réellement créées.
  local count
  # « || true » : si le chargement a échoué, la base applicative n'existe pas et
  # cette requête meurt — sous « set -e », la substitution tuait le script au
  # lieu de laisser la branche « échec » rendre un compte rendu honnête.
  count="$(docker exec "$container" sh -c \
    "${PG_ENV}psql ${PG_ARGS} -d \"\${POSTGRES_DB:-postgres}\" -tAc \
     \"select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')\"" \
    2>/dev/null | tr -dc '0-9' || true)"

  if [ -n "$count" ] && [ "$count" -gt 0 ]; then
    log "  base restaurée — $count tables"
    record "$stack-db" "restaurée ($count tables)"
    # LES APPLICATIONS SONT RELANCÉES APRÈS LE CHARGEMENT. On vient de couper
    # leurs connexions et de remplacer la base sous leurs pieds : un serveur
    # d'application qui garde son pool sur l'ancienne grappe sert des erreurs —
    # ou pire, un cache du vieux schéma. On relance ce qui TOURNE, sauf le
    # conteneur de base lui-même, tout juste rechargé.
    local _svc_db _s
    _svc_db="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' \
               "$container" 2>/dev/null || true)"
    while IFS= read -r _s; do
      [ -n "$_s" ] && [ "$_s" != "$_svc_db" ] || continue
      (cd "$ROOT/$stack" && docker compose restart "$_s") >/dev/null 2>&1 || true
    done < <( (cd "$ROOT/$stack" && docker compose ps --format '{{.Service}}') 2>/dev/null)
    log "  applications de $stack relancées sur la base rechargée"
    # Les « already exists » sont attendus : rôles et base sont créés par
    # l'image avant l'injection du dump. On ne signale que le reste.
    local other
    other="$(grep -v 'already exists' "$err" | grep -c 'ERROR\|FATAL' || true)"
    [ "${other:-0}" -gt 0 ] && warn "  ($other erreurs non bloquantes, voir le journal)"
  else
    warn "  échec de restauration — aucune table dans la base"
    while IFS= read -r l; do warn "    $l"; done < <(grep 'ERROR\|FATAL' "$err" | head -4)
    record "$stack-db" "ÉCHEC"
    # Une base vide invalide la pile entière : le verdict doit le refléter.
    printf '%s\n' "${FAILED_STACKS[@]:-}" | grep -qx "$stack" || FAILED_STACKS+=("$stack")
  fi
  rm -f "$err"
}
# Les dumps de l'instantané, pile par pile. Le nom du CONTENEUR ne se déduit pas
# de celui du dump : Compose le forme à partir du projet et du service
# (« <pile>-postgres-1 »), mais une composition peut le fixer autrement
# (« <pile>_postgres »). On le déclare, et à défaut on tente la forme usuelle :
#
#   PRA_DOCKER_BASES="pile:conteneur …"
for _dump in "$WORK"/db/*.sql.gz; do
  [ -f "$_dump" ] || continue
  _pile="$(basename "$_dump" .sql.gz)"
  _conteneur="${_pile}-postgres-1"
  for _decl in ${PRA_DOCKER_BASES:-}; do
    [ "${_decl%%:*}" = "$_pile" ] && _conteneur="${_decl#*:}"
  done
  restore_pg "$_dump" "$_conteneur" "$_pile"
done
unset _dump _pile _conteneur _decl

STEP="terminé"
if [ ${#FAILED_STACKS[@]} -gt 0 ]; then
  VERDICT="partiel"
  warn "piles en échec : ${FAILED_STACKS[*]}"
  log "Restauration Docker terminée AVEC des échecs"
else
  log "Restauration Docker terminée"
fi
