#!/bin/bash
###############################################################################
# pra_forgejo_sync.sh — publie les dépôts de /srv/git dans la forge locale
#
# ── POURQUOI DEPUIS /srv/git ET NON DEPUIS GITLAB ───────────────────────────
# Forgejo sait tirer un miroir depuis GitLab nativement. On ne s'en sert pas, et
# c'est délibéré :
#
#  - la source devient /srv/git, elle-même issue de l'archive du jour, donc
#    passée par les contrôles anti-rançongiciel. Un miroir tiré directement de
#    la production suivrait fidèlement un chiffrement ;
#  - aucune dépendance à la joignabilité de la production au moment de la
#    synchronisation — or l'arche n'est éveillée qu'une heure par nuit ;
#  - aucun jeton GitLab à détenir sur une machine transportable et non chiffrée.
#
# Forgejo n'est donc que la vitrine. /srv/git reste le chemin garanti : le jour
# où la forge est cassée — restauration ratée, base corrompue —
# « git clone /srv/git/projet.git » fonctionne encore, sans aucun service.
#
# ── LE JETON ────────────────────────────────────────────────────────────────
# Portée « write:repository » uniquement, jamais « all ». Il est transmis à git
# par un auxiliaire d'authentification lisant l'ENVIRONNEMENT : le mettre dans
# l'URL ou sur la ligne de commande l'exposerait à tout utilisateur local via
# « ps », /proc/PID/cmdline étant lisible par tous.
###############################################################################
set -uo pipefail

# shellcheck source=/dev/null
[ -r "${PRA_CONF:-/etc/pra/pra.conf}" ] && . "${PRA_CONF:-/etc/pra/pra.conf}"

SOURCE="${PRA_GIT_DEST:-/srv/git}"
GIT_BASE="${PRA_FORGEJO_GIT:-http://127.0.0.1:6000}"
PROPRIO="${PRA_FORGEJO_OWNER:-cellule-cyber}"
JETON="${PRA_FORGEJO_TOKEN:-}"
LOG="${PRA_FORGEJO_LOG:-/var/log/pra_forgejo.log}"

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

[ -n "$JETON" ] || { warn "PRA_FORGEJO_TOKEN absent de la configuration"; exit 1; }
[ -d "$SOURCE" ] || { warn "$SOURCE absent — lancer pra_gitlab_extract.sh d'abord"; exit 1; }

log "==== SYNCHRONISATION VERS LA FORGE ===="

# Auxiliaire d'authentification : git l'appelle et lit sa sortie. Le jeton ne
# passe donc ni par argv ni par l'URL.
ASKPASS="$(mktemp)"
chmod 700 "$ASKPASS"
cat > "$ASKPASS" <<'EOF'
#!/bin/sh
# git demande d'abord le nom d'utilisateur, puis le mot de passe.
case "$1" in
  *sername*) printf '%s' "$FJ_USER" ;;
  *) printf '%s' "$FJ_TOKEN" ;;
esac
EOF
trap 'rm -f "$ASKPASS"' EXIT INT TERM

declare -i pousses=0 rates=0
for depot in "$SOURCE"/*.git; do
  [ -d "$depot" ] || continue
  nom="$(basename "$depot" .git)"

  # AUCUN APPEL À L'API. Le dépôt est créé par la poussée elle-même
  # (ENABLE_PUSH_CREATE_USER / _ORG), ce qui évite d'accorder au jeton la portée
  # « write:user » — nécessaire à « POST /user/repos », et qui permettrait aussi
  # de modifier le compte.
  #
  # Le propriétaire est une ORGANISATION, et non un compte personnel : une équipe
  # dont la portée est « tous les dépôts » y donne accès
  # automatiquement à chaque dépôt créé par cette poussée — sans geste par dépôt,
  # sans appel d'API, et sans élargir ce jeton. Ses membres sont eux-mêmes
  # synchronisés depuis le groupe LDAP « admins » par Forgejo.
  #
  # Revers assumé : ce réglage vit dans app.ini, qu'une mise à jour du paquet
  # YunoHost peut réécrire. D'où le diagnostic explicite en cas d'échec, plutôt
  # qu'un « poussée impossible » sans cause.
  # --mirror pousse TOUTES les références et supprime côté forge celles qui ont
  # disparu de la source. C'est voulu ici : la source est l'archive validée du
  # jour, elle fait autorité. La sauvegarde, elle, reste l'archive elle-même —
  # jamais cette forge.
  if FJ_USER="$PROPRIO" FJ_TOKEN="$JETON" GIT_ASKPASS="$ASKPASS" \
     GIT_TERMINAL_PROMPT=0 \
     git -C "$depot" push --mirror --quiet \
         "$GIT_BASE/$PROPRIO/$nom.git" 2>>"$LOG"; then
    pousses+=1
  else
    warn "  poussée de $nom en échec"
    # Cause la plus probable après une mise à jour du paquet : la création à la
    # poussée a été désactivée. On le dit, au lieu de laisser chercher.
    # Le réglage à vérifier dépend de la nature du propriétaire : une
    # organisation exige ENABLE_PUSH_CREATE_ORG, un compte personnel
    # ENABLE_PUSH_CREATE_USER. Ne contrôler que le second, comme le faisait la
    # v1, laissait sans explication l'échec le plus probable après une mise à
    # jour du paquet — qui réécrit app.ini.
    INI="${PRA_FORGEJO_INI:-/var/www/forgejo/custom/conf/app.ini}"
    for reglage in ENABLE_PUSH_CREATE_ORG ENABLE_PUSH_CREATE_USER; do
      if ! grep -qE "^${reglage} *= *true" "$INI" 2>/dev/null; then
        warn "  $reglage n'est pas actif dans app.ini —"
        warn "  une mise à jour de Forgejo l'a probablement réécrit. À rétablir."
      fi
    done
    rates+=1
  fi
done

log "$pousses dépôt(s) publié(s), $rates en échec"
[ "$rates" -eq 0 ] || exit 1
log "==== FIN ===="
