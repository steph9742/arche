#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# pra_retention.sh — rétention « grand-père / père / fils ».
#
# Bibliothèque destinée à être SOURCÉE, pas exécutée :
#     . /usr/local/sbin/pra_retention.sh
#     decisions_gfs /transferts/backups
#
# ── POURQUOI CE SCHÉMA ──────────────────────────────────────────────────────
# Une rétention par simple ancienneté laisse une faille précise : un chiffrement
# passé inaperçu plus longtemps qu'on ne garde d'archives empoisonne tout le
# magasin. Avec cinq archives quotidiennes, cinq nuits y suffisent.
#
# Conserver quelques jalons plus anciens — des lundis, des premiers du mois —
# porte la profondeur à plusieurs mois pour un coût marginal, et garantit qu'il
# reste toujours un point de reprise antérieur à une infection lente.
#
# ── POURQUOI LA DATE VIENT DU NOM, PAS DE mtime ─────────────────────────────
# La date de modification d'un fichier recopié est celle de la copie, pas celle
# de la sauvegarde : un rsync, un déplacement ou une restauration la réécrivent.
# Le nom « AAAAMMJJ-HHMMSS.tar » porte la date réelle, c'est donc lui qui fait foi.
#
# ── SORTIE ──────────────────────────────────────────────────────────────────
# Une ligne par archive, la plus récente d'abord :
#     GARDER <chemin> <raison>
#     PURGER <chemin>
# Aucune suppression n'a lieu ici : cette bibliothèque ne fait que trancher,
# l'appelant décide d'agir ou de se contenter d'un compte rendu.
# ─────────────────────────────────────────────────────────────────────────────

# decisions_gfs <répertoire> [jours] [lundis] [mois] [plancher]
decisions_gfs() {
  local dir="${1:?répertoire attendu}"
  local jours="${2:-${PRA_GFS_JOURS:-4}}"
  local lundis="${3:-${PRA_GFS_LUNDIS:-2}}"
  local mois="${4:-${PRA_GFS_MOIS:-3}}"
  local plancher="${5:-${PRA_KEEP_MIN:-4}}"

  DIR="$dir" JOURS="$jours" LUNDIS="$lundis" MOIS="$mois" PLANCHER="$plancher" \
  python3 <<'PY'
import os, re, sys
from datetime import date
from pathlib import Path

dossier   = Path(os.environ["DIR"])
jours     = int(os.environ["JOURS"])
lundis    = int(os.environ["LUNDIS"])
mois      = int(os.environ["MOIS"])
plancher  = int(os.environ["PLANCHER"])

# DEUX FAMILLES D'ARCHIVES, traitées SÉPARÉMENT :
#   AAAAMMJJ-HHMMSS.tar         sauvegarde YunoHost
#   AAAAMMJJ[-HHMMSS]-docker.tar  instantané des piles Docker
#
# Les mélanger fausserait les comptages — huit fichiers pour quatre jours — et
# pourrait garder deux instantanés Docker en croyant garder deux jours. Chaque
# famille reçoit donc le même jeu de règles, appliqué à part.
#
# Un fichier dont le nom n'entre dans aucune famille n'est JAMAIS purgé : mieux
# vaut garder un inconnu que supprimer par méprise. Les trois nommages doivent
# figurer dans le motif, sinon les instantanés passent pour des inconnus et le
# magasin gonfle sans bruit.
MOTIF = re.compile(r"^(\d{4})(\d{2})(\d{2})-(\d{6}-docker|\d{6}|docker)\.tar$")

familles = {}
inconnus = []
for f in sorted(dossier.glob("*.tar")):
    m = MOTIF.match(f.name)
    if not m:
        inconnus.append(f)
        continue
    try:
        d = date(int(m.group(1)), int(m.group(2)), int(m.group(3)))
    except ValueError:
        inconnus.append(f)
        continue
    famille = "docker" if m.group(4).endswith("docker") else "yunohost"
    familles.setdefault(famille, []).append((d, f))

garder = {}          # chemin -> raison


def retenir(chemin, raison):
    # La première raison est la plus forte : on ne l'écrase pas, on cumule, pour
    # que le compte rendu explique vraiment la décision.
    if chemin in garder:
        if raison not in garder[chemin]:
            garder[chemin] += f", {raison}"
    else:
        garder[chemin] = raison


for famille, archives in familles.items():
    # Du plus récent au plus ancien.
    archives.sort(key=lambda x: (x[0], x[1].name), reverse=True)

    # ── 1. Plancher absolu ──────────────────────────────────────────────────
    # Indépendant de toute date : après une longue série d'échecs, il doit
    # rester de quoi restaurer même si tout est « trop vieux ».
    for _, f in archives[:plancher]:
        retenir(f, f"plancher ({plancher} plus récentes)")

    # ── 2. Les fils : les N derniers JOURS DISTINCTS présents ───────────────
    # Des jours présents, non des jours calendaires : si la réplication a
    # manqué trois nuits, on garde les quatre derniers jours DISPONIBLES.
    jours_vus = []
    for d, f in archives:
        if d not in jours_vus:
            if len(jours_vus) >= jours:
                break
            jours_vus.append(d)
        if d in jours_vus:
            retenir(f, f"jour récent ({d.isoformat()})")

    # ── 3. Les pères : les N derniers LUNDIS ────────────────────────────────
    lundis_vus = []
    for d, f in archives:
        if d.weekday() != 0:
            continue
        if d not in lundis_vus:
            if len(lundis_vus) >= lundis:
                break
            lundis_vus.append(d)
        if d in lundis_vus:
            retenir(f, f"lundi ({d.isoformat()})")

    # ── 4. Les grands-pères : le PREMIER du mois, sur les N derniers mois ───
    # « Premier » au sens de la plus ancienne archive du mois, et non du 1er du
    # calendrier : le 1er peut n'avoir aucune sauvegarde.
    premiers = {}
    for d, f in reversed(archives):          # du plus ancien au plus récent
        premiers.setdefault((d.year, d.month), (d, f))
    for cle in sorted(premiers, reverse=True)[:mois]:
        d, f = premiers[cle]
        retenir(f, f"premier du mois ({d.isoformat()})")

# ── Sortie ──────────────────────────────────────────────────────────────────
for famille in sorted(familles):
    for _, f in familles[famille]:
        if f in garder:
            print(f"GARDER {f} [{famille}] {garder[f]}")
        else:
            print(f"PURGER {f} [{famille}]")

for f in inconnus:
    print(f"GARDER {f} nom non reconnu — jamais purgé par précaution")
PY
}
