#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# pra_notify.sh — alerte du PRA vers une conversation Nextcloud Talk.
#
#   pra_notify.sh <niveau> <titre> [détail…]
#     niveau : echec | alerte | info
#
# Appelé à chaque échec par pra_nightly.sh et pra_restore_replica.sh. Trois
# règles, dans cet ordre :
#
#  1. NE JAMAIS FAIRE ÉCHOUER L'APPELANT : sort toujours en 0. Une notification
#     ratée ne doit pas interrompre une réplication qui fonctionne.
#  2. TOUJOURS JOURNALISER LOCALEMENT, même quand l'envoi échoue : c'est la
#     seule trace qui subsiste si le serveur de destination est hors service.
#  3. Le destinataire vit sur la PRODUCTION. En cas de sinistre majeur — le
#     scénario qui déclenche le plus d'alertes — le message n'arrivera donc pas.
#     C'est assumé : le journal local et l'état sur l'arche font foi.
#
# AUTHENTIFICATION — bot Talk, et non compte utilisateur. Nextcloud Talk n'y
# emploie pas l'authentification Basic : chaque requête porte
#
#   X-Nextcloud-Talk-Bot-Random     valeur aléatoire, 32 caractères minimum
#   X-Nextcloud-Talk-Bot-Signature  HMAC-SHA256 de (random + message), en hexa,
#                                   avec le secret du bot comme clé
#
# Préférable à un mot de passe : le secret ne circule jamais, il ne sert qu'à
# signer, et le « random » interdit de rejouer un message capté.
#
# Configuration dans /etc/pra/pra.conf (root, 600) :
#   NC_TALK_URL="https://nextcloud.exemple.org"
#   NC_TALK_ROOM="jeton_de_la_conversation"
#   NC_TALK_SECRET="secret_du_bot"
#   NC_TALK_IP="192.0.2.10"       # facultatif : par défaut PRA_SERVER1
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

CONF="${PRA_CONF:-/etc/pra/pra.conf}"
LOG="/var/log/pra_notify.log"
TIMEOUT="${PRA_NOTIFY_TIMEOUT:-15}"

niveau="${1:-info}"; shift || true
titre="${1:-sans titre}"; shift || true
detail="$*"

horodatage="$(date '+%F %T')"
machine="$(hostname -s 2>/dev/null || echo arche)"

journal() { printf '[%s] %s\n' "$horodatage" "$*" >> "$LOG" 2>/dev/null || true; }

journal "[$niveau] $titre ${detail:+— $detail}"

# shellcheck source=/dev/null
[ -r "$CONF" ] && . "$CONF" 2>/dev/null || true

if [ -z "${NC_TALK_URL:-}" ] || [ -z "${NC_TALK_ROOM:-}" ] \
   || [ -z "${NC_TALK_SECRET:-}" ]; then
  journal "envoi ignoré : configuration Talk absente ou incomplète dans $CONF"
  exit 0
fi

case "$niveau" in
  echec)  marque="🔴 PRA — ÉCHEC" ;;
  alerte) marque="🟠 PRA — ALERTE" ;;
  *)      marque="🔵 PRA — info" ;;
esac

message="$marque
**$titre**
${detail:+$detail
}_${machine} · ${horodatage}_"

# ÉPINGLAGE DE LA DESTINATION, sans rapport avec le TLS mais indispensable.
#
# Les domaines de la production sont restaurés comme domaines YunoHost sur
# l'arche : son résolveur local les renvoie donc vers elle-même. Une alerte
# adressée au nom de la production partirait vers le nginx de l'arche, et le
# certificat rencontré serait sa copie restaurée — périmée.
#
# « --resolve » fixe l'adresse IP en conservant le nom pour le SNI et l'en-tête
# Host : la vérification TLS reste pleinement active. Désactiver le contrôle du
# certificat masquerait le défaut au lieu de le corriger.
declare -a epingle=()
_hote="${NC_TALK_URL#*://}"; _hote="${_hote%%/*}"; _port="443"
case "$_hote" in
  *:*) _port="${_hote##*:}"; _hote="${_hote%%:*}" ;;
esac
_ip="${NC_TALK_IP:-${PRA_SERVER1:-}}"
if [ -n "$_ip" ] && [ -n "$_hote" ]; then
  epingle=(--resolve "$_hote:$_port:$_ip")
  journal "destination épinglée : $_hote:$_port -> $_ip"
else
  journal "AVERTISSEMENT : destination non épinglée — le nom risque de résoudre"
  journal "  vers l'arche elle-même. Renseigner NC_TALK_IP."
fi

# Vérification TLS active par défaut : le message décrit l'état interne du
# dispositif. NC_TALK_CACERT désigne une autorité interne ; NC_TALK_INSECURE=1
# reste possible mais se signale bruyamment.
declare -a verif=()
if [ -n "${NC_TALK_CACERT:-}" ] && [ -r "${NC_TALK_CACERT:-}" ]; then
  verif=(--cacert "$NC_TALK_CACERT")
elif [ "${NC_TALK_INSECURE:-0}" = "1" ]; then
  verif=(--insecure)
  journal "AVERTISSEMENT : vérification TLS désactivée."
fi

# 64 caractères hexadécimaux : au-delà du minimum de 32, et sans caractère
# susceptible de gêner un en-tête HTTP.
aleatoire="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

# Le secret passe par l'ENVIRONNEMENT, jamais en argument : /proc/PID/cmdline
# est lisible par tous, /proc/PID/environ seulement par le propriétaire du
# processus. « openssl dgst -hmac "$secret" » l'exposerait via « ps ».
signature="$(
  NC_S="$NC_TALK_SECRET" NC_R="$aleatoire" NC_M="$message" python3 - <<'PY' 2>>"$LOG"
import hashlib, hmac, os
secret = os.environ["NC_S"].encode()
# La signature porte sur la concaténation random + message, dans cet ordre.
donnees = (os.environ["NC_R"] + os.environ["NC_M"]).encode()
print(hmac.new(secret, donnees, hashlib.sha256).hexdigest())
PY
)"

if [ -z "$signature" ]; then
  journal "ÉCHEC : signature non calculée (python3 absent ou secret illisible)"
  exit 0
fi

# --data-urlencode : le serveur décode avant de vérifier la signature, le texte
# signé et le texte reçu concordent donc.
code="$(curl -sS "${epingle[@]}" "${verif[@]}" --max-time "$TIMEOUT" \
  -o /dev/null -w '%{http_code}' \
  -H 'OCS-APIRequest: true' \
  -H 'Accept: application/json' \
  -H "X-Nextcloud-Talk-Bot-Random: $aleatoire" \
  -H "X-Nextcloud-Talk-Bot-Signature: $signature" \
  --data-urlencode "message=$message" \
  "$NC_TALK_URL/ocs/v2.php/apps/spreed/api/v1/bot/$NC_TALK_ROOM/message" \
  2>>"$LOG")" || code="000"

case "$code" in
  20*) journal "notification transmise (HTTP $code)" ;;
  000) journal "ÉCHEC d'envoi : destination injoignable, ou certificat refusé" ;;
  60)  journal "ÉCHEC d'envoi : certificat non vérifiable — renseigner NC_TALK_CACERT" ;;
  401) journal "ÉCHEC d'envoi : signature refusée — vérifier NC_TALK_SECRET" ;;
  403) journal "ÉCHEC d'envoi : bot non autorisé dans cette conversation" ;;
  404) journal "ÉCHEC d'envoi : bot ou conversation introuvable (NC_TALK_ROOM)" ;;
  *)   journal "ÉCHEC d'envoi (HTTP $code)" ;;
esac

exit 0
