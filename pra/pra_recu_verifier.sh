#!/bin/bash
# pra_recu_verifier.sh — CÔTÉ PRODUCTION : l'arche a-t-elle donné signe de vie ?
#
# L'arche dépose un reçu après chaque restauration (voir pra_recu.sh, côté
# arche). Ce script est l'autre moitié du dispositif — sans lui, les reçus
# s'empileraient sans que personne ne les lise.
#
# Il fait DEUX choses, et il faut les distinguer :
#   — il PUBLIE l'état dans un JSON servi en lecture libre, à chaque passage ;
#   — il ALERTE sur Talk, seulement quand on le lui demande (passage quotidien).
# D'où « --publier » : le passage fréquent rafraîchit l'API sans réveiller
# personne. Une alerte qui se répète tous les quarts d'heure cesse d'être lue.
#
# ── CE QU'IL SURVEILLE, ET POURQUOI L'ABSENCE COMPTE PLUS QUE LE CONTENU ────
# Un reçu qui dit « échec » est un problème connu : l'arche s'est réveillée,
# elle a travaillé, elle le dit. L'ABSENCE de reçu est le vrai signal — elle
# couvre d'un coup les deux pannes que rien d'autre ne distingue : l'arche qui
# ne se réveille plus, et l'arche réveillée dont la restauration échoue avant
# d'avoir pu parler.
#
# 26 heures de seuil, et non 24 : la restauration dure une heure et peut
# déborder. Un seuil trop serré crie au loup.
#
# ── L'API EST SANS JETON, DONC ON Y MET LE MINIMUM ─────────────────────────
# C'est de l'information d'exploitation, faite pour qu'une supervision la lise
# sans identifiant. Mais « sans jeton » veut dire « lisible par quiconque
# atteint ce domaine » : on publie donc des DÉCOMPTES, jamais les noms des
# applications en échec — ceux-là restent dans l'alerte Talk et dans le reçu sur
# disque. Et rien, jamais, qui concerne l'arche elle-même : le reçu n'en porte
# déjà rien, par construction.
#
# ── LA PRODUCTION NE SAIT PAS OÙ EST L'ARCHE, ET N'EN A PAS BESOIN ─────────
# Constater qu'aucun reçu n'est arrivé ne demande aucune connaissance de
# l'arche : c'est un fichier absent dans un répertoire local. Rien ici ne
# contacte l'arche, rien ne peut la contacter.
#
# ── LE REÇU EST UNE DONNÉE, JAMAIS UN ORDRE ───────────────────────────────
# Il est écrit par une autre machine. On le lit avec un analyseur JSON, on ne le
# « source » jamais, et on ne réinjecte rien de son contenu dans un shell.
#
# Usage :  pra_recu_verifier.sh [--publier]
#   PRA_RECU_DIR       répertoire des reçus, inscriptible par le compte SSH
#                      de l'arche (défaut /var/lib/pra/recus-arche)
#   PRA_ETAT_JSON      fichier publié (défaut /var/www/pra-etat/etat.json)
#   PRA_RECU_SEUIL_H   âge maximal toléré, en heures (défaut 26)
#   PRA_RECU_GARDE_J   ancienneté au-delà de laquelle on purge (défaut 90)
set -uo pipefail

PUBLIER_SEUL=0
[ "${1:-}" = "--publier" ] && PUBLIER_SEUL=1

RECU_DIR="${PRA_RECU_DIR:-/var/lib/pra/recus-arche}"
ETAT_JSON="${PRA_ETAT_JSON:-/var/www/pra-etat/etat.json}"
SEUIL_H="${PRA_RECU_SEUIL_H:-26}"
GARDE_J="${PRA_RECU_GARDE_J:-90}"
# /usr/local/sbin, là où install.sh pose les scripts. Un chemin erroné rendrait
# « [ -x ] » faux et abandonnerait TOUTES les alertes en silence.
NOTIFY="${PRA_NOTIFY_BIN:-/usr/local/sbin/pra_notify.sh}"
LOG="${PRA_RECU_LOG:-/var/log/pra_recus.log}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

# UN SEUL PASSAGE À LA FOIS.
#
# La planification lance « --publier » tous les quarts d'heure ET le passage
# complet une fois par jour : les deux tombent à la même seconde une fois sur
# quatre. Sans verrou, ils écrivent les mêmes fichiers et le second trouve le
# sien déjà renommé — il journalise un échec alors que l'autre vient de publier,
# et deux écritures entremêlées peuvent publier un JSON tronqué.
#
# Un verrou plutôt qu'un décalage d'horaire : une installation ou un lancement à
# la main tombent eux aussi n'importe quand. On ATTEND au lieu d'abandonner — le
# passage de 08:00 porte l'alerte du jour et ne doit pas être sauté ; un passage
# dure moins d'une seconde, soixante suffisent largement.
exec 9>"${PRA_RECU_VERROU:-/run/pra_recu_verifier.lock}"
if ! flock -w 60 9; then
  log "un autre passage tient le verrou depuis plus de 60 s — abandon de celui-ci"
  exit 1
fi

# État calculé une fois, publié une fois, alerté une fois. Les trois étapes
# lisent les mêmes variables : un état publié qui ne correspondrait pas à
# l'alerte envoyée serait pire que pas d'API du tout.
ETAT="inconnu"; VERDICT="inconnu"; MODE="?"; ARCHIVE=""
AGE_H=-1; APPS_KO=0; PILES_KO=0; MOTIF=""; HORODATAGE=""

DERNIER=""
if [ -d "$RECU_DIR" ]; then
  DERNIER="$(find "$RECU_DIR" -maxdepth 1 -type f -name '*.json' \
             -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2- || true)"
fi

if [ -z "$DERNIER" ]; then
  # Répertoire absent ou vide : l'arche n'a JAMAIS déposé, ou quelqu'un a
  # effacé. Les deux méritent la même conclusion — on ne sait pas si elle vit.
  ETAT="jamais_vue"
  MOTIF="Aucun reçu dans $RECU_DIR. L'arche ne s'est jamais manifestée, ou les reçus ont été supprimés."
else
  AGE_H=$(( ( $(date +%s) - $(stat -c %Y "$DERNIER") ) / 3600 ))
  # Champs bornés et nettoyés : ils viennent d'une autre machine, et ni une
  # alerte ni un JSON public ne sont un endroit où recopier du texte non contrôlé.
  # Heredoc dans une fonction et non dans « $( … ) » : bash 3.2 s'y perd sur la
  # première apostrophe.
  _resumer() {
    RECU="$1" python3 <<'PY' 2>/dev/null
import json, os, re

def propre(v, taille=60):
    return re.sub(r"[^\w .:,()°+-]", "", str(v), flags=re.UNICODE)[:taille]

try:
    with open(os.environ["RECU"], encoding="utf-8") as f:
        d = json.load(f)
except Exception:
    print("VERDICT=illisible")
    raise SystemExit(0)

apps = d.get("applications") or {}
piles = d.get("piles_docker") or {}
print("HORODATAGE=%s" % propre(d.get("horodatage", ""), 40))
print("VERDICT=%s" % propre(d.get("verdict", "inconnu"), 40))
print("MODE=%s" % propre(d.get("mode", "?"), 20))
print("ARCHIVE=%s" % propre(d.get("archive", ""), 40))
print("APPS_KO=%d" % len(apps.get("echouees") or []))
print("PILES_KO=%d" % len(piles.get("echouees") or []))
PY
  }
  RESUME="$(_resumer "$DERNIER" || true)"
  HORODATAGE="$(printf '%s' "$RESUME" | sed -n 's/^HORODATAGE=//p')"
  VERDICT="$(printf '%s' "$RESUME" | sed -n 's/^VERDICT=//p')"
  MODE="$(printf '%s' "$RESUME" | sed -n 's/^MODE=//p')"
  ARCHIVE="$(printf '%s' "$RESUME" | sed -n 's/^ARCHIVE=//p')"
  APPS_KO="$(printf '%s' "$RESUME" | sed -n 's/^APPS_KO=//p')"; APPS_KO="${APPS_KO:-0}"
  PILES_KO="$(printf '%s' "$RESUME" | sed -n 's/^PILES_KO=//p')"; PILES_KO="${PILES_KO:-0}"

  if [ "$AGE_H" -ge "$SEUIL_H" ]; then
    ETAT="silencieuse"
    MOTIF="Dernier reçu : $(basename "$DERNIER") (${AGE_H} h), seuil ${SEUIL_H} h. L'arche ne s'est pas réveillée, ou sa restauration s'est arrêtée avant d'avoir pu le dire."
  else
    case "$VERDICT" in
      succès|succes)
        if [ "$APPS_KO" -gt 0 ] || [ "$PILES_KO" -gt 0 ]; then
          ETAT="incomplete"
          MOTIF="Archive $ARCHIVE : ${APPS_KO} application(s) et ${PILES_KO} pile(s) en échec. L'arche a fini sa nuit, mais elle n'est pas complète."
        else
          ETAT="vivante"
        fi ;;
      # « PARTIEL » N'EST NI UN SUCCÈS NI UN ÉCHEC. L'arche a restauré, mais
      # pas entièrement : restauree=false dans l'API, et l'alerte le dit tel
      # quel. L'appeler « échec » ferait chercher une panne qui n'existe pas.
      partiel)
        ETAT="incomplete"
        MOTIF="Verdict « partiel » ($MODE, archive $ARCHIVE) : l'arche a restauré, mais pas entièrement. Voir le journal de l'arche." ;;
      # L'arche s'est réveillée et a parlé, mais n'a RIEN restauré cette nuit :
      # son dernier état date d'avant. Le distinguer d'un échec oriente vers la
      # bonne cause — production injoignable, quorum, pause — plutôt que vers
      # la restauration elle-même.
      non_faite)
        ETAT="non_faite"
        MOTIF="L'arche a déposé son reçu sans avoir restauré cette nuit (production injoignable, quorum non atteint ou pause ?). Dernière restauration réelle : ${HORODATAGE:-inconnue}." ;;
      illisible)
        ETAT="recu_illisible"
        MOTIF="$(basename "$DERNIER") n'est pas un JSON exploitable." ;;
      *)
        ETAT="en_echec"
        MOTIF="Verdict « $VERDICT » ($MODE, archive $ARCHIVE), reçu il y a ${AGE_H} h." ;;
    esac
  fi
fi

# ── PUBLICATION ────────────────────────────────────────────────────────────
# Écriture atomique : une supervision qui lirait un fichier à moitié écrit
# conclurait à une panne. Le décompte des échecs sort, pas les noms.
publier() {
  local dossier; dossier="$(dirname "$ETAT_JSON")"
  mkdir -p "$dossier" 2>>"$ERREUR_FICHIER" || return 1
  # Nom temporaire UNIQUE, dans le même répertoire pour que « mv » reste
  # atomique. Le verrou empêche déjà deux passages simultanés ; ceci empêche
  # qu'un nom partagé redevienne un point de collision s'il venait à manquer.
  local tmp; tmp="$(mktemp "$ETAT_JSON.XXXXXX" 2>>"$ERREUR_FICHIER")" || return 1
  ETAT="$ETAT" HORODATAGE="$HORODATAGE" python3 <<'JSON' > "$tmp" 2>>"$ERREUR_FICHIER" || { rm -f "$tmp"; return 1; }
import json, os
e = os.environ
# DEUX INFORMATIONS, PAS TROIS. L'arche est-elle restaurée, et depuis quand.
# Tout le reste — verdict détaillé, archive, applications en échec, seuil —
# reste dans l'alerte Talk et dans le reçu sur disque : cette API est sans
# jeton, donc lisible par quiconque atteint ce domaine, et chaque champ publié
# est un champ qu'on ne pourra plus reprendre.
print(json.dumps({
    "restauree": e["ETAT"] == "vivante",
    "derniere_restauration": e["HORODATAGE"] or None,
}, ensure_ascii=False, indent=2, sort_keys=True))
JSON
  chmod 644 "$tmp" 2>>"$ERREUR_FICHIER" && mv -f "$tmp" "$ETAT_JSON" 2>>"$ERREUR_FICHIER" \
    || { rm -f "$tmp"; return 1; }
}
# LA CAUSE, PAS SEULEMENT LE CONSTAT. « publication impossible » sans motif
# oblige à deviner ce que « 2>/dev/null » a avalé : l'erreur réelle est
# journalisée.
ERREUR_FICHIER="$(mktemp)"
trap 'rm -f "$ERREUR_FICHIER"' EXIT
cause() { tr '\n' ' ' < "$ERREUR_FICHIER" | head -c 300; : > "$ERREUR_FICHIER"; }
publier || { c="$(cause)"; log "publication impossible dans $ETAT_JSON${c:+ : $c}"; }

# ── ÉTAT DÉTAILLÉ, PRIVÉ, POUR LA WEBAPP DE LA PRODUCTION ─────────────────
#
# La webapp de la production affiche une carte « Arche : dernière
# restauration ». Elle lit CE fichier, écrit par CE passage : la carte montre
# donc la décision même qui produit l'API et l'alerte. Une seconde lecture des
# reçus côté webapp finirait par diverger — une carte verte sur une alerte
# rouge.
#
# Privé (640, root), à la différence de l'API : on peut y mettre le motif et les
# NOMS des applications en échec, que la page publique ne dira jamais. Rafraîchi
# à chaque passage, y compris celui des quinze minutes.
ETAT_PRIVE="${PRA_RECU_ETAT_PRIVE:-/var/lib/pra/recu-etat.json}"
publier_detail() {
  mkdir -p "$(dirname "$ETAT_PRIVE")" 2>>"$ERREUR_FICHIER" || return 1
  local tmp; tmp="$(mktemp "$ETAT_PRIVE.XXXXXX" 2>>"$ERREUR_FICHIER")" || return 1
  ETAT="$ETAT" MOTIF="$MOTIF" VERDICT="$VERDICT" MODE="$MODE" ARCHIVE="$ARCHIVE" \
  HORODATAGE="$HORODATAGE" AGE_H="$AGE_H" SEUIL_H="$SEUIL_H" RECU="$DERNIER" \
  python3 <<'DETAIL' > "$tmp" 2>>"$ERREUR_FICHIER" || { rm -f "$tmp"; return 1; }
import json, os, re, datetime
e = os.environ

def noms(liste):
    # Des identifiants d'applications, rien d'autre : ils viennent d'un fichier
    # écrit par une autre machine et finiront dans une page HTML.
    return [re.sub(r"[^\w.-]", "", str(n))[:60] for n in (liste or [])][:40]

apps, piles = {}, {}
if e.get("RECU"):
    try:
        with open(e["RECU"], encoding="utf-8") as f:
            d = json.load(f)
        apps, piles = d.get("applications") or {}, d.get("piles_docker") or {}
    except Exception:
        pass

age = int(e["AGE_H"])
print(json.dumps({
    "etat": e["ETAT"],
    "motif": e["MOTIF"],
    "verdict": e["VERDICT"],
    "mode": e["MODE"],
    "archive": e["ARCHIVE"],
    "derniere_restauration": e["HORODATAGE"] or None,
    "age_heures": None if age < 0 else age,
    "seuil_heures": int(e["SEUIL_H"]),
    "recu": os.path.basename(e["RECU"]) if e.get("RECU") else None,
    "applications_en_echec": noms(apps.get("echouees")),
    "applications_ignorees": noms(apps.get("ignorees")),
    "piles_en_echec": noms(piles.get("echouees")),
    "controle_le": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
}, ensure_ascii=False, indent=2, sort_keys=True))
DETAIL
  chmod 640 "$tmp" 2>>"$ERREUR_FICHIER" && mv -f "$tmp" "$ETAT_PRIVE" 2>>"$ERREUR_FICHIER" \
    || { rm -f "$tmp"; return 1; }
}
publier_detail || { c="$(cause)"; log "état détaillé impossible à écrire dans $ETAT_PRIVE${c:+ : $c}"; }

[ "$PUBLIER_SEUL" = 1 ] && exit 0

# ── ALERTE ─────────────────────────────────────────────────────────────────
alerter() {
  log "ALERTE : $1 — $2"
  # UNE ALERTE QUI NE PART PAS DOIT LE DIRE. « [ -x ] && … || true » abandonne
  # en silence : le chien de garde constaterait chaque panne sans en signaler
  # aucune, et rien ne le trahirait.
  if [ ! -x "$NOTIFY" ]; then
    log "ALERTE NON ENVOYÉE : pra_notify.sh introuvable ($NOTIFY)"
    return 0
  fi
  "$NOTIFY" alerte "$1" "$2" >/dev/null 2>&1 \
    || log "ALERTE NON ENVOYÉE : pra_notify.sh a échoué (Talk injoignable ?)"
}

case "$ETAT" in
  vivante)
    log "OK — reçu de ${AGE_H} h, $MODE, archive $ARCHIVE"
    ;;
  jamais_vue)      alerter "Arche : aucun reçu de restauration" "$MOTIF" ;;
  silencieuse)     alerter "Arche : silencieuse depuis ${AGE_H} h" "$MOTIF" ;;
  incomplete)      alerter "Arche : restauration réussie mais incomplète" "$MOTIF" ;;
  non_faite)       alerter "Arche : aucune restauration cette nuit" "$MOTIF" ;;
  recu_illisible)  alerter "Arche : reçu illisible" "$MOTIF" ;;
  *)               alerter "Arche : restauration en échec" "$MOTIF" ;;
esac

# ── PURGE ──────────────────────────────────────────────────────────────────
# Les reçus sont minuscules, mais rien ne les reprenait : un répertoire qui
# grossit sans fin finit par surprendre. Trois mois d'historique suffisent à
# constater une panne intermittente.
find "$RECU_DIR" -maxdepth 1 -type f -name '*.json' -mtime "+$GARDE_J" -delete 2>/dev/null || true
# Un dépôt interrompu laisse un « .part » : sans valeur passé un jour.
find "$RECU_DIR" -maxdepth 1 -type f -name '*.json.part' -mtime +1 -delete 2>/dev/null || true

[ "$ETAT" = "vivante" ] && exit 0
exit 1
