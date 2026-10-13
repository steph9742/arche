#!/bin/bash
# pra_reveil_filet.sh — garantir qu'une alarme RTC future existe à l'extinction.
#
# L'arche ne se rallume que par son horloge matérielle : sans alarme armée, elle
# reste éteinte jusqu'à une intervention — et une machine éteinte n'alerte
# personne.
#
# En marche normale, pra_nightly.sh arme l'alarme suivante en sortant. Deux cas
# la laissent sans successeur : un démarrage hors de la fenêtre nocturne (le
# nocturne ne fait rien, donc n'arme rien) et une extinction lancée à la main.
#
# Ce filet s'exécute à l'arrêt du système et n'agit QUE si aucune alarme future
# n'est armée : il ne remplace jamais celle du nocturne.
#
#   PRA_FILET_WAKE_AT   heure de repli (défaut « 02:00 tomorrow »)
#
set -uo pipefail

ALARME="${PRA_RTC_WAKEALARM:-/sys/class/rtc/rtc0/wakealarm}"
LOG="${PRA_LOG:-/var/log/pra_nightly.log}"
HEURE="${PRA_FILET_WAKE_AT:-02:00 tomorrow}"

log() { printf '[%s] filet de réveil : %s\n' "$(date '+%F %T')" "$*" >> "$LOG" 2>/dev/null || true; }

[ -e "$ALARME" ] || { log "pas d'alarme RTC sur cette machine — rien à faire"; exit 0; }

maintenant="$(date +%s)"
courante="$(cat "$ALARME" 2>/dev/null || true)"
# Le noyau rend une ligne vide quand aucune alarme n'est armée. Tout ce qui n'est
# pas un entier est traité comme « aucune » : mieux vaut armer une fois de trop.
case "$courante" in
  ''|*[!0-9]*) courante=0 ;;
esac

if [ "$courante" -gt "$maintenant" ]; then
  log "alarme déjà armée pour $(date -d "@$courante" '+%F %T') — laissée en place"
  exit 0
fi

cible="$(date -d "$HEURE" +%s 2>/dev/null)" || { log "heure de repli invalide : $HEURE"; exit 0; }
# Une alarme dans le passé ne sonne jamais et rien ne le signale.
while [ "$cible" -le "$maintenant" ]; do cible=$((cible + 86400)); done

# Remise à zéro obligatoire : écrire par-dessus une alarme armée échoue.
echo 0 > "$ALARME" 2>/dev/null || true
if echo "$cible" > "$ALARME" 2>/dev/null; then
  log "aucune alarme à venir — réveil de secours armé pour $(date -d "@$cible" '+%F %T')"
else
  log "ÉCHEC de l'armement : la machine ne se rallumera PAS seule"
fi
exit 0
