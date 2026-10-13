#!/bin/bash
# pra_recu.sh — déposer chez la production la preuve que l'arche a travaillé.
#
# ── LE PROBLÈME ─────────────────────────────────────────────────────────────
# L'arche s'éteint à la fin de sa nuit. Son silence est donc AMBIGU : rien ne
# distingue « tout s'est bien passé » de « elle ne s'est pas réveillée ».
#
# Elle dépose donc un reçu chez la production avant de s'éteindre. L'ABSENCE de
# reçu devient le signal, et elle couvre les deux pannes d'un coup : pas
# réveillée, ou réveillée sans succès. Le contrôle, côté production, est
# pra_recu_verifier.sh.
#
# ── CE QUI NE DOIT JAMAIS CHANGER ───────────────────────────────────────────
# CE CANAL EST EN ÉCRITURE SEULE. L'arche dépose et ne relit RIEN. Le jour où la
# production laisserait ici un fichier que l'arche vient lire et honorer, le
# modèle « pull » serait inversé sans que personne ne s'en aperçoive : la
# production commanderait l'arche. C'est la protection de fond du dispositif.
#
# ── CE QUE LA PRODUCTION APPREND, ET CE QU'ELLE N'APPREND PAS ───────────────
# Elle connaît déjà l'adresse de l'arche : c'est l'arche qui ouvre la connexion
# SSH, et sshd l'inscrit dans auth.log. Ce qu'on tient vraiment :
#   — la production ne détient aucun identifiant vers l'arche ;
#   — le reçu ne NOMME rien : ni adresse, ni nom d'hôte, ni jeton, ni URL.
# D'où la construction par LISTE BLANCHE de champs, jamais par recopie d'un
# fichier d'état, et un garde-fou qui refuse l'envoi si une adresse IP ou le nom
# de la machine s'y est glissé malgré tout.
#
# Le dépôt a lieu dans la session SSH qu'on ouvre de toute façon pour la
# réplication : la production ne voit ni connexion nouvelle, ni horaire nouveau.
#
# Usage :
#   pra_recu.sh <nocturne|manuel> [code de sortie]
#
#   PRA_PROD_USER      compte SSH sur la production
#   PRA_SERVER1        adresse de la production
#   PRA_RECU_DIR       répertoire de dépôt, inscriptible par ce compte
#   PRA_RECU_OFF=1     n'envoie rien (mise au point)
#   PRA_RECU_MONTRER=1 affiche le reçu sans l'envoyer
set -uo pipefail

MODE="${1:-manuel}"
CODE="${2:-0}"

STATE_DIR="${PRA_STATE_DIR:-/var/lib/pra}"
LOG="${PRA_LOG:-/var/log/pra_nightly.log}"
PROD_USER="${PRA_PROD_USER:-}"
PROD_HOST="${PRA_SERVER1:-}"
RECU_DIR="${PRA_RECU_DIR:-/var/lib/pra/recus-arche}"

log() { printf '[%s] reçu : %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

[ "${PRA_RECU_OFF:-0}" = 1 ] && { log "PRA_RECU_OFF=1 — aucun dépôt"; exit 0; }

# ── CONSTRUCTION PAR LISTE BLANCHE ──────────────────────────────────────────
# On ne recopie AUCUN fichier d'état tel quel : on extrait les champs voulus,
# nommément. Une recopie embarquerait tôt ou tard un chemin, un nom d'hôte ou un
# champ ajouté plus tard sans qu'on y pense.
#
# Le heredoc vit dans une FONCTION et non dans « $( … ) » : bash 3.2 relit le
# contenu d'un heredoc placé dans une substitution de commande et s'y perd à la
# première apostrophe.
_construire() {
  MODE="$MODE" CODE="$CODE" STATE_DIR="$STATE_DIR" python3 <<'PY'
import json, os, re, datetime

MAINTENANT = datetime.datetime.now().astimezone()

# UN ÉTAT DE LA VEILLE N'EST PAS UNE RESTAURATION DE CETTE NUIT.
#
# Quand le nocturne s'arrête AVANT de restaurer — production injoignable, quorum
# non atteint, pause — status.json reste celui de la veille. Le lire tel quel
# ferait annoncer « succès », et la production publierait « restaurée » pour une
# nuit où rien n'a été restauré. Une nuit dure moins d'une heure : au-delà de
# douze, l'état est périmé et on le dit.
PEREMPTION_H = 12

def lire(nom):
    try:
        with open(os.path.join(os.environ["STATE_DIR"], nom)) as f:
            return json.load(f)
    except Exception:
        return {}

def age_h(d):
    try:
        t = datetime.datetime.fromisoformat(d["horodatage"])
        return (MAINTENANT - t).total_seconds() / 3600
    except Exception:
        return None

# LE CLASSEMENT SUIT LES MARQUES DES SCRIPTS, PAS UNE DEVINETTE.
#
# Les scripts écrivent leurs échecs en MAJUSCULES (voir les « record » de
# pra_restore_replica.sh et pra_docker_restore.sh) : on s'y fie. Juger sur des
# mots comme « restauré » ou « démarré » classerait en échec un rechargement de
# base (« restaurée (46 tables) ») ou une application absente de l'archive, et
# produirait une alerte quotidienne injustifiée.
#
# Ce qui est absent ou non sélectionné est un CHOIX, pas un échec : compté à part.
ECHEC = re.compile(r"ÉCHEC|ECHEC|INJOIGNABLE|INCOMPLET|INEXÉCUTABLE|conteneur absent", re.I)
NEUTRE = re.compile(r"non couverte|absent de l.archive", re.I)

def classer(d):
    ok, ko, ignorees = 0, [], []
    for nom, valeur in sorted((d or {}).items()):
        v = str(valeur)
        if ECHEC.search(v):
            ko.append(nom)
        elif NEUTRE.search(v):
            ignorees.append(nom)
        else:
            ok += 1
    return {"reussies": ok, "echouees": ko, "ignorees": ignorees}

VIDE = {"reussies": 0, "echouees": [], "ignorees": [], "a_jour": False}

etat, dock = lire("status.json"), lire("docker-status.json")
a_etat, a_dock = age_h(etat), age_h(dock)
etat_frais = bool(etat) and a_etat is not None and a_etat <= PEREMPTION_H
dock_frais = bool(dock) and a_dock is not None and a_dock <= PEREMPTION_H

if not etat:
    verdict = "inconnu"
elif not etat_frais:
    verdict = "non_faite"
else:
    verdict = etat.get("verdict") or "inconnu"

recu = {
    "schema": 2,
    # L'heure de la RESTAURATION, pas celle du dépôt : c'est la date que la
    # production publie, et le dépôt a lieu plusieurs minutes plus tard, après le
    # volet Docker et la sonde. Pour un état périmé, c'est la date de la dernière
    # restauration réelle — exactement ce qu'on veut savoir.
    "horodatage": etat.get("horodatage") or "",
    "depose_le": MAINTENANT.isoformat(timespec="seconds"),
    "mode": os.environ["MODE"],
    "code": int(os.environ["CODE"] or 0),
    "verdict": verdict,
    "etape": (etat.get("etape") or "") if etat_frais else "",
    "archive": (etat.get("archive") or "") if etat_frais else "",
    "duree_s": (etat.get("duree_s") or 0) if etat_frais else 0,
    "applications": classer(etat.get("applications")) if etat_frais else VIDE,
    "piles_docker": classer(dock.get("piles")) if dock_frais else VIDE,
}
print(json.dumps(recu, ensure_ascii=False, indent=2, sort_keys=True))
PY
}
CORPS="$(_construire)" || { log "construction impossible — aucun dépôt"; exit 1; }

# ── GARDE-FOU : RIEN QUI LOCALISE L'ARCHE NE SORT ───────────────────────────
# La liste blanche devrait suffire. Ce contrôle est le second rempart, parce que
# la faute serait invisible : un reçu qui fuite une adresse part sans erreur, et
# personne ne relit un fichier déposé chez quelqu'un d'autre. On préfère ne rien
# envoyer, et le dire.
_interdits="$(printf '%s\n' "$(hostname 2>/dev/null)" "$(hostname -f 2>/dev/null)" \
              | grep -v '^$' | sort -u)"
if printf '%s' "$CORPS" | grep -qE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b'; then
  log "REFUS : le reçu contient une adresse IP — rien n'est envoyé"
  exit 1
fi
while IFS= read -r _nom; do
  [ -n "$_nom" ] || continue
  if printf '%s' "$CORPS" | grep -qiF "$_nom"; then
    log "REFUS : le reçu contient le nom de la machine — rien n'est envoyé"
    exit 1
  fi
done <<< "$_interdits"

# Ce qui sortirait, sans rien envoyer : un canal qu'on ne peut pas inspecter
# avant de s'en servir finit par transporter n'importe quoi.
if [ "${PRA_RECU_MONTRER:-0}" = 1 ]; then
  printf '%s\n' "$CORPS"
  exit 0
fi

# ── DÉPÔT ───────────────────────────────────────────────────────────────────
# Non bloquant par construction : l'extinction et le réveil priment. Un reçu
# manquant se verra côté production, c'est tout l'intérêt du dispositif.
if [ -z "$PROD_USER" ] || [ -z "$PROD_HOST" ]; then
  log "destination non configurée (PRA_PROD_USER, PRA_SERVER1) — aucun dépôt"
  exit 1
fi
NOM="$(date +%Y%m%d-%H%M%S).json"
if printf '%s\n' "$CORPS" | ssh -o BatchMode=yes -o ConnectTimeout=15 \
      -o StrictHostKeyChecking=accept-new "$PROD_USER@$PROD_HOST" \
      "mkdir -p '$RECU_DIR' && chmod 700 '$RECU_DIR' && cat > '$RECU_DIR/$NOM.part' \
       && mv '$RECU_DIR/$NOM.part' '$RECU_DIR/$NOM'" 2>/dev/null; then
  log "déposé chez la production : $NOM ($MODE, code $CODE)"
  exit 0
fi
# Le seul cas normal d'échec : la production est à terre — c'est-à-dire
# précisément le jour où l'arche sert. On le journalise sans dramatiser.
log "dépôt impossible (production injoignable ?) — l'absence sera vue là-bas"
exit 1
