#!/bin/bash
###############################################################################
# pra_gitlab_extract.sh — dépôts git consultables, extraits de l'archive
#
# Déplie les dépôts GitLab de l'archive YunoHost du jour en dépôts nus sous
# /srv/git/, avec leurs VRAIS NOMS, et écrit un manifeste.
#
# ── POURQUOI ────────────────────────────────────────────────────────────────
# Le code de la cellule est DÉJÀ sauvegardé : le paquet YunoHost embarque la
# sauvegarde native de GitLab, soit ~16 Mo dans les 12 Go de chaque nuit. Il n'y
# a donc rien à sauvegarder de plus.
#
# Ce qui manquait, c'était l'ACCÈS. Dérouler 12 Go pour atteindre 16 Mo en pleine
# crise est disproportionné. Ce script fait ce travail une fois par nuit, en
# quelques secondes, et laisse des dépôts directement clonables :
#
#     git clone /srv/git/mon-projet.git
#
# Aucun GitLab n'est nécessaire — et c'est heureux, il ne peut pas tourner sur
# l'arche. Depuis GitLab 14 les dépôts sont sauvegardés en BUNDLES git, et un
# bundle se clone comme un dépôt distant.
#
# ── LE NOMMAGE, QUI EST TOUT LE SUJET ───────────────────────────────────────
# GitLab range ses dépôts en « stockage haché » : le chemin sur disque est le
# SHA-256 de l'IDENTIFIANT du projet. On lit donc la table « projects » du
# vidage de base contenu dans la même sauvegarde, on calcule l'empreinte de
# chaque identifiant, et on retrouve quel bundle correspond à quel projet.
#
# Sans cela, on hériterait de neuf fichiers nommés « 4b2277… » et il faudrait
# les cloner tous pour savoir lequel on cherche.
#
# Usage :
#   pra_gitlab_extract.sh            depuis l'archive du jour
#   PRA_GL_ARCHIVE=… pra_gitlab_extract.sh   depuis une archive précise
###############################################################################
set -uo pipefail

# shellcheck source=/dev/null
[ -r "${PRA_CONF:-/etc/pra/pra.conf}" ] && . "${PRA_CONF:-/etc/pra/pra.conf}"

BACKUP_SRC="${PRA_BACKUP_DIR:-/transferts/backups}"
DEST="${PRA_GIT_DEST:-/srv/git}"
LOG="${PRA_GL_LOG:-/var/log/pra_gitlab.log}"
TODAY="$(date +%Y%m%d)"

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

ARCHIVE="${PRA_GL_ARCHIVE:-}"
if [ -z "$ARCHIVE" ]; then
  ARCHIVE="$(find "$BACKUP_SRC" -maxdepth 1 -type f \
    -regextype posix-extended -regex ".*/${TODAY}-[0-9]{6}\.tar" 2>/dev/null | sort | tail -1)"
fi
[ -n "$ARCHIVE" ] && [ -f "$ARCHIVE" ] || { warn "aucune archive du jour dans $BACKUP_SRC"; exit 1; }

log "==== EXTRACTION DES DÉPÔTS GIT ===="
log "Archive : $(basename "$ARCHIVE")"

TRAVAIL="$(mktemp -d)"
# La sauvegarde GitLab contient gitlab-secrets.json : on ne laisse pas traîner
# une extraction lisible, et on nettoie même en cas d'interruption.
chmod 700 "$TRAVAIL"
trap 'rm -rf "$TRAVAIL"' EXIT INT TERM

# ── 1. Sortir la sauvegarde GitLab de l'archive ─────────────────────────────
if ! tar xf "$ARCHIVE" -C "$TRAVAIL" --wildcards '*last_gitlab_backup.tar' 2>/dev/null; then
  warn "extraction impossible"; exit 1
fi
GLTAR="$(find "$TRAVAIL" -name 'last_gitlab_backup.tar' | head -1)"
[ -n "$GLTAR" ] || { log "aucune sauvegarde GitLab dans cette archive — rien à faire"; exit 0; }
log "Sauvegarde GitLab : $(du -h "$GLTAR" | cut -f1)"

mkdir -p "$TRAVAIL/gl"
tar xf "$GLTAR" -C "$TRAVAIL/gl" 2>/dev/null || { warn "sauvegarde GitLab illisible"; exit 1; }

# ── 2. Bundles présents ─────────────────────────────────────────────────────
mapfile -t BUNDLES < <(find "$TRAVAIL/gl/repositories" -name '*.bundle' 2>/dev/null)
if [ "${#BUNDLES[@]}" -eq 0 ]; then
  warn "aucun bundle — version de GitLab antérieure au format bundle ?"
  exit 1
fi
log "Bundles : ${#BUNDLES[@]}"

# ── 3. Noms des projets, depuis le vidage de base de la même sauvegarde ─────
DUMP="$TRAVAIL/gl/db/database.sql.gz"
CORRESP="$TRAVAIL/correspondance.txt"
: > "$CORRESP"
if [ -r "$DUMP" ]; then
  DUMP="$DUMP" python3 <<'PY' > "$CORRESP" 2>/dev/null || true
import gzip, hashlib, os, sys

# On lit le bloc COPY de la table « projects » : la première ligne donne l'ordre
# des colonnes, ce qui évite de le supposer — il change d'une version à l'autre.
colonnes, dans_bloc = [], False
with gzip.open(os.environ["DUMP"], "rt", errors="replace") as f:
    for ligne in f:
        if not dans_bloc:
            if ligne.startswith("COPY public.projects ("):
                colonnes = [c.strip() for c in
                            ligne[ligne.index("(") + 1:ligne.index(")")].split(",")]
                dans_bloc = True
            continue
        if ligne.startswith("\\."):
            break
        champs = ligne.rstrip("\n").split("\t")
        if len(champs) < len(colonnes):
            continue
        d = dict(zip(colonnes, champs))
        ident, chemin = d.get("id"), d.get("path")
        if not (ident and ident.isdigit() and chemin):
            continue
        # Stockage haché : le répertoire est le SHA-256 de l'identifiant décimal.
        print(f"{hashlib.sha256(ident.encode()).hexdigest()}\t{chemin}\t{ident}")
PY
  log "Projets nommés dans le vidage : $(grep -c '' "$CORRESP")"
else
  warn "vidage de base absent — les dépôts garderont leur nom haché"
fi

# ── 4. Déplier ──────────────────────────────────────────────────────────────
mkdir -p "$DEST"
chmod 750 "$DEST"
MANIFESTE="$DEST/MANIFESTE.txt"
{
  printf '# Dépôts extraits de %s le %s\n' "$(basename "$ARCHIVE")" "$(date '+%F %T')"
  printf '# Clonage :  git clone %s/<nom>.git\n\n' "$DEST"
} > "$MANIFESTE"

declare -i faits=0 rates=0
for b in "${BUNDLES[@]}"; do
  # …/@hashed/xx/yy/<empreinte>.git/last/001.bundle  ou  <empreinte>.wiki.git/…
  rep="$(basename "$(dirname "$(dirname "$b")")")"     # <empreinte>.git
  empreinte="${rep%.git}"; suffixe=""
  case "$empreinte" in
    *.wiki) empreinte="${empreinte%.wiki}"; suffixe=".wiki" ;;
    *.design) empreinte="${empreinte%.design}"; suffixe=".design" ;;
  esac

  nom="$(awk -F'\t' -v h="$empreinte" '$1==h {print $2; exit}' "$CORRESP")"
  ident="$(awk -F'\t' -v h="$empreinte" '$1==h {print $3; exit}' "$CORRESP")"
  # Repli sur l'empreinte tronquée : mieux qu'un échec, et le manifeste
  # explique de quoi il s'agit.
  [ -n "$nom" ] || nom="inconnu-${empreinte:0:12}"

  cible="$DEST/${nom}${suffixe}.git"
  # On reconstruit à côté puis on remplace : une extraction interrompue ne doit
  # pas laisser un dépôt à moitié écrit là où on ira le chercher en crise.
  tmp="$(mktemp -d -p "$DEST" .tmp.XXXXXX)"
  if git clone --quiet --bare "$b" "$tmp/depot.git" 2>/dev/null; then
    rm -rf "$cible"
    mv "$tmp/depot.git" "$cible"
    faits+=1
    printf '%-34s id=%-4s %s\n' "${nom}${suffixe}.git" "${ident:-?}" "$empreinte" >> "$MANIFESTE"
  else
    warn "clonage impossible : ${nom}${suffixe}"
    rates+=1
  fi
  rm -rf "$tmp"
done

chmod -R go-w "$DEST" 2>/dev/null || true

# ── 5. Dépôts devenus orphelins ─────────────────────────────────────────────
# On ne SUPPRIME rien : ne pas propager une destruction est un principe du
# dispositif, comme « --ignore-existing » sur les archives. Un rançongiciel qui
# vide GitLab ne doit pas vider l'arche.
#
# Mais on le DIT, sinon /srv/git accumule en silence des dépôts qui n'existent
# plus — et un projet renommé laisse son ancien nom derrière lui sans trace.
declare -a orphelins=()
for existant in "$DEST"/*.git; do
  [ -d "$existant" ] || continue
  n="$(basename "$existant" .git)"
  grep -qE "^${n}(\.wiki|\.design)?\.git " "$MANIFESTE" 2>/dev/null && continue
  orphelins+=("$n")
done
if [ "${#orphelins[@]}" -gt 0 ]; then
  warn "absents de l'archive du jour, conservés par précaution : ${orphelins[*]}"
  warn "  (dépôt supprimé ou renommé côté GitLab — à retirer à la main si voulu)"
  printf '\n# Absents de cette archive, conservés : %s\n' "${orphelins[*]}" >> "$MANIFESTE"
fi

log "$faits dépôt(s) déplié(s) dans $DEST, $rates en échec"
log "Manifeste : $MANIFESTE"
[ "$rates" -eq 0 ] || exit 1
log "==== FIN ===="
