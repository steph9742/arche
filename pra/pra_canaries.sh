#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# pra_canaries.sh — canaris d'intégrité pour la détection de rançongiciel.
#
#   Sur la PRODUCTION :   pra_canaries.sh deployer
#                         pra_canaries.sh empreintes
#   Sur l'ARCHE :         pra_canaries.sh rebaser     (interroge la prod en SSH)
#                         pra_canaries.sh verifier    (contrôle ponctuel)
#
# PRINCIPE. Des fichiers témoins posés à plusieurs endroits de la production,
# dont l'arche vérifie l'empreinte avant chaque réplication. S'ils changent ou
# deviennent illisibles, la production est chiffrée : l'arche s'abstient.
#
# DEUX RÈGLES DE CONCEPTION, contre-intuitives mais décisives :
#
#  1. UN CANARI EST UN APPÂT. Les rançongiciels choisissent leurs cibles par
#     EXTENSION : ils chiffrent .docx, .pdf, .xlsx, .jpg et ignorent les
#     fichiers de configuration. Un « .canary » dans /root serait contourné par
#     la plupart des familles — un canari qui ne chante jamais. D'où ces noms de
#     documents ordinaires, posés au milieu de vraies données.
#
#  2. JAMAIS DE « chattr +i ». L'immuabilité protégerait le canari du
#     chiffrement, donc supprimerait le signal. Un canari doit être aussi
#     vulnérable que ce qu'il surveille.
#
#  3. IL DOIT ÊTRE LISIBLE par le compte que l'arche emploie en SSH — elle le
#     hache à distance sans privilège. Le répertoire d'un autre utilisateur,
#     protégé par une ACL, donne un canari perpétuellement « absent » : un faux
#     positif chronique, soit exactement ce qu'on cherche à éviter. L'ACL peut
#     empêcher jusqu'au « stat », sans rien dire de plus explicite.
#
# EMPLACEMENTS. Choisis pour couvrir des partitions et des arborescences
# différentes, et pour éviter tout ce que YunoHost gère : « yunohost app
# remove » efface /home/yunohost.app/<app>, ce qui produirait des faux positifs
# à chaque réinstallation.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ─── Configuration commune ───────────────────────────────────────────────────
# Éditée par la webapp Arche, lue par les scripts. La webapp n'est qu'un éditeur :
# si elle est absente ou cassée, la réplication continue exactement pareil.
# Le fichier emploie « : "${VAR:=valeur}" », qui n'affecte QUE les variables non
# définies : une variable passée à la main sur la ligne de commande reste donc
# prioritaire (PRA_DRY_RUN=1, PRA_ONLY=…).
# shellcheck source=/dev/null
[ -r "${PRA_CONF:-/etc/pra/pra.conf}" ] && . "${PRA_CONF:-/etc/pra/pra.conf}"


MANIFESTE="${PRA_CANARY_MANIFEST:-/etc/pra/canaries.list}"
# Compte et adresse de la production, déclarés dans pra.conf. Sans eux, le
# script ne peut rien hacher à distance et le dira.
PROD_USER="${PRA_PROD_USER:-}"
PROD_HOST="${PRA_SERVER1:-}"

# Le hachage se fait à distance : sans compte ni adresse, autant le dire ici
# plutôt que de laisser ssh échouer sur « @ ».
if [ -z "$PROD_USER" ] || [ -z "$PROD_HOST" ]; then
printf 'PRA_PROD_USER et PRA_SERVER1 doivent être définis dans %s.\n' \
"${PRA_CONF:-/etc/pra/pra.conf}" >&2
exit 1
fi

# Un canari par arborescence surveillée. PRA_CANARY_PATHS permet de remplacer
# la liste entière (chemins séparés par des espaces).
# AUCUN CHEMIN PAR DÉFAUT, ET C'EST VOULU.
#
# Publier la liste des fichiers témoins dans un dépôt de code revient à donner à
# un attaquant la liste des fichiers à NE PAS toucher — et le dépôt est souvent
# hébergé sur la machine même que les canaris protègent. Les rançongiciels
# ciblés lisent les dépôts et les configurations.
#
# Les emplacements réels vivent donc uniquement dans /etc/pra/pra.conf
# (root, 600), jamais dans le code. Voir README.md pour le choix des appâts.
if [ -n "${PRA_CANARY_PATHS:-}" ]; then
  read -r -a CANARIS <<< "$PRA_CANARY_PATHS"
else
  CANARIS=()
fi

if [ ${#CANARIS[@]} -eq 0 ] && [ "${1:-}" != "verifier" ]; then
  cat >&2 <<'AUCUN_CANARI'
Aucun emplacement de canari défini.

  Renseignez PRA_CANARY_PATHS dans /etc/pra/pra.conf — depuis la webapp Arche,
  ou à la main. Les chemins ne sont volontairement pas codés dans ce script :
  ils ne doivent pas se retrouver dans un dépôt de code.

  Ce sont des APPÂTS : donnez-leur des noms de documents ordinaires, avec des
  extensions que les rançongiciels ciblent (.docx, .pdf, .xlsx), posés au milieu
  de vraies données.
AUCUN_CANARI
  exit 1
fi

usage() { sed -n '2,12p' "$0"; exit 1; }

# Contenu déterministe : l'empreinte doit être reproductible, sinon impossible
# de distinguer une dérive légitime d'un chiffrement. Le texte explique ce
# qu'est le fichier — un canari mystérieux finit supprimé par un collègue, et
# ce risque-là est bien plus probable qu'un attaquant qui lirait le contenu.
contenu() {
  cat <<EOF
TÉMOIN D'INTÉGRITÉ — PLAN DE REPRISE D'ACTIVITÉ
Ne pas supprimer, ne pas modifier, ne pas déplacer.

Ce fichier sert à détecter un chiffrement malveillant. Son empreinte est
vérifiée chaque nuit par l'arche de survie avant toute réplication. Toute
modification interrompt la sauvegarde et déclenche une alerte.

Emplacement : $1
Cellule cyber — Université de Franche-Comté
EOF
}

deployer() {
  local cree=0 existe=0 echec=0
  for c in "${CANARIS[@]}"; do
    if [ -f "$c" ]; then
      printf '  déjà en place : %s\n' "$c"; existe=$((existe + 1)); continue
    fi
    if ! mkdir -p "$(dirname "$c")" 2>/dev/null; then
      printf '  ÉCHEC (répertoire) : %s\n' "$c"; echec=$((echec + 1)); continue
    fi
    if contenu "$c" > "$c" 2>/dev/null; then
      # Lisible par tous : le canari doit être une cible ordinaire, pas un
      # fichier privilégié qu'un rançongiciel tournant sans droits ignorerait.
      chmod 644 "$c" 2>/dev/null || true
      printf '  créé : %s\n' "$c"; cree=$((cree + 1))
    else
      printf '  ÉCHEC (écriture) : %s\n' "$c"; echec=$((echec + 1))
    fi
  done
  printf '\n%d créé(s), %d déjà présent(s), %d en échec\n' "$cree" "$existe" "$echec"
  [ "$echec" -gt 0 ] && return 1
  printf 'Étape suivante, sur le réplica :  pra_canaries.sh rebaser\n'
  return 0
}

# Format sha256sum standard : « empreinte␣␣chemin ».
#
# RETOUR TOUJOURS NUL. Terminer sur un « [ -f ] » suffit à tout fausser : dès
# qu'un canari de la liste n'existe pas encore, la fonction sort en statut non
# nul et « rebaser » annonce « production injoignable » alors que la connexion
# est parfaite. Un message d'erreur qui désigne la mauvaise cause fait perdre
# plus de temps qu'une absence de message.
#
# Les manquants sont signalés sur la SORTIE D'ERREUR, qui ne pollue donc pas le
# manifeste construit depuis la sortie standard.
empreintes() {
  local manquants=0
  for c in "${CANARIS[@]}"; do
    if [ -f "$c" ]; then
      sha256sum "$c" 2>/dev/null
    else
      printf 'absent sur cette machine : %s\n' "$c" >&2
      manquants=$((manquants + 1))
    fi
  done
  [ "$manquants" -eq 0 ] || printf '%d canari(s) introuvable(s)\n' "$manquants" >&2
  return 0
}

rebaser() {
  local tmp
  tmp="$(mktemp)"
  # On demande à la production ses propres empreintes. PRA_CANARY_PATHS est
  # transmis pour que les deux côtés parlent de la même liste.
  # On conserve la sortie d'erreur du distant : elle nomme les canaris absents,
  # information qu'il faut voir plutôt que masquer.
  local err; err="$(mktemp)"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=20 "$PROD_USER@$PROD_HOST" \
       "PRA_CANARY_PATHS='${CANARIS[*]}' bash -s" < "$0" empreintes \
       > "$tmp" 2>"$err"; then
    printf 'ÉCHEC de la connexion à %s@%s :\n' "$PROD_USER" "$PROD_HOST" >&2
    sed 's/^/  /' "$err" >&2
    rm -f "$tmp" "$err"; return 1
  fi
  if [ -s "$err" ]; then
    printf 'Signalé par la production :\n' >&2
    sed 's/^/  /' "$err" >&2
  fi
  rm -f "$err"
  if [ ! -s "$tmp" ]; then
    printf 'ÉCHEC : aucune empreinte reçue. Les canaris sont-ils déployés ?\n' >&2
    printf '  Sur la production :  pra_canaries.sh deployer\n' >&2
    rm -f "$tmp"; return 1
  fi
  mkdir -p "$(dirname "$MANIFESTE")"
  mv -f "$tmp" "$MANIFESTE"
  chmod 600 "$MANIFESTE"
  printf 'Manifeste écrit : %s (%d canari(s))\n' "$MANIFESTE" "$(wc -l < "$MANIFESTE")"
  sed 's/^/  /' "$MANIFESTE"
}

# ── VERDICT : trois issues, pas deux ────────────────────────────────────────
#
#   0  tout est intact
#   1  DÉFAUT — un contenu a changé, ou trop de canaris ont disparu
#   2  AVERTISSEMENT — une disparition isolée, sans modification
#
# Pourquoi cette distinction. Un contenu MODIFIÉ, c'est un chiffrement sur
# place : presque aucune cause bénigne, le signal est concluant à lui seul. Une
# DISPARITION, en revanche, peut venir d'un rançongiciel comme d'un ménage, d'un
# « rsync --delete » ou d'un collègue.
#
# Le cas s'observe vite : un canari posé dans un répertoire que son application
# nettoie selon ses propres règles disparaît, et mettre les deux cas sur le même
# plan fait refuser la réplication de toute une nuit pour cela.
#
# Un fichier qui disparaît est du ménage ; plusieurs la même nuit sont un
# événement. Le seuil est réglable et vaut 1 par défaut : une absence tolérée.
verifier() {
  [ -r "$MANIFESTE" ] || { printf 'Aucun manifeste (%s) — contrôle désactivé.\n' "$MANIFESTE"; return 0; }
  local attendu chemin vu ok=0 modifies=0 absents=0
  local absents_max="${PRA_CANARY_ABSENTS_MAX:-1}"
  local vus; vus="$(mktemp)"
  # UN SEUL appel SSH pour tous les canaris : autant de connexions que de
  # fichiers ralentirait inutilement et multiplierait les causes d'échec.
  cut -d' ' -f3- "$MANIFESTE" | tr '\n' '\0' \
    | ssh -o BatchMode=yes -o ConnectTimeout=20 "$PROD_USER@$PROD_HOST" \
        "xargs -0 -r sha256sum 2>/dev/null" > "$vus" 2>/dev/null || true

  while read -r attendu chemin; do
    [ -n "$chemin" ] || continue
    vu="$(awk -v p="$chemin" '{ s=$1; $1=""; sub(/^ +/,""); if ($0==p) print s }' "$vus")"
    if [ -z "$vu" ]; then
      printf 'ABSENT     %s\n' "$chemin"; absents=$((absents + 1))
    elif [ "$vu" != "$attendu" ]; then
      printf 'MODIFIÉ    %s (empreinte %s)\n' "$chemin" "$vu"; modifies=$((modifies + 1))
    else
      ok=$((ok + 1))
    fi
  done < <(sed 's/  */ /' "$MANIFESTE")
  rm -f "$vus"

  printf '%d intact(s), %d modifié(s), %d absent(s)\n' "$ok" "$modifies" "$absents"

  if [ "$modifies" -gt 0 ]; then
    printf 'DÉFAUT : un contenu a changé — chiffrement sur place suspecté.\n'
    return 1
  fi
  if [ "$absents" -gt "$absents_max" ]; then
    printf 'DÉFAUT : %d canaris absents (seuil %d) — disparition groupée suspecte.\n' \
           "$absents" "$absents_max"
    return 1
  fi
  if [ "$absents" -gt 0 ]; then
    printf 'AVERTISSEMENT : %d absence isolée, tolérée. Vérifier si elle est légitime,\n' "$absents"
    printf '  puis « pra_canaries.sh rebaser » ou choisir un autre emplacement.\n'
    return 2
  fi
  return 0
}

case "${1:-}" in
  deployer)   deployer ;;
  empreintes) empreintes ;;
  rebaser)    rebaser ;;
  verifier)   verifier ;;
  *)          usage ;;
esac
