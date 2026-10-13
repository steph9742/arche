#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# install.sh — installe la webapp Arche et les scripts du PRA sur le réplica.
#
#   sudo ./scripts/install.sh
#
# Idempotent : relançable sans risque pour mettre à jour une installation.
# N'écrase JAMAIS /etc/pra/pra.conf ni /etc/pra/canaries.list — ce sont les
# réglages et les empreintes de référence de l'exploitant.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# RÔLE de cette installation. « arche » (défaut) ou « production ».
#
# GARDE-FOU ESSENTIEL : pra_nightly.sh ÉTEINT la machine en fin de course (c'est
# voulu, l'arche doit rester hors ligne entre deux nuits). Installer son unité
# systemd sur le serveur de PRODUCTION l'éteindrait chaque nuit. Le rôle
# « production » n'installe donc ni ce script ni son unité — jamais.
ROLE="${ARCHE_ROLE:-arche}"
case "$ROLE" in
  arche|production) ;;
  *) echo "ARCHE_ROLE doit valoir « arche » ou « production »." >&2; exit 1 ;;
esac

# DÉTECTION DE LA MACHINE — garde-fou contre l'erreur d'aiguillage.
#
# Lancer l'installation « production » sur le RÉPLICA fait exactement ce qu'elle
# promet, au mauvais endroit : le garde-fou anti-extinction retire le nocturne,
# le script de restauration et son unité. La minuterie, elle, reste active — la
# réplication de la nuit échoue simplement, sans que rien ne l'annonce.
#
# L'erreur est facile : /tmp/arche-src existe des deux côtés et la commande se
# copie-colle. On vérifie donc que le rôle demandé correspond à la machine, et
# on refuse plutôt que de détruire. ARCHE_FORCE_ROLE=1 pour passer outre.
_indices_arche=0
[ -f /etc/systemd/system/pra-nightly.timer ] && _indices_arche=1
[ -f /var/lib/pra/status.json ] && _indices_arche=1
[ -f /etc/pra/canaries.list ] && _indices_arche=1

if [ "$ROLE" = "production" ] && [ "$_indices_arche" = 1 ] \
   && [ "${ARCHE_FORCE_ROLE:-0}" != "1" ]; then
  cat >&2 <<'FIN_DU_REFUS'
REFUS : cette machine ressemble à l'ARCHE, pas à la production.

  Indices trouvés : minuterie pra-nightly, état du PRA ou manifeste de canaris.

  Installer le rôle « production » ici supprimerait pra_nightly.sh,
  pra_restore_replica.sh, pra_docker_restore.sh et l'unité pra-nightly —
  autrement dit toute la réplication nocturne.

  Sur l'arche :        sudo ./scripts/install.sh
  Sur la production :  sudo ARCHE_ROLE=production ./scripts/install.sh
  Passer outre :       ARCHE_FORCE_ROLE=1
FIN_DU_REFUS
  exit 1
fi

DEST="${ARCHE_DEST:-/opt/arche}"
UTILISATEUR="${ARCHE_USER:-archeapp}"
ENVDIR="${ARCHE_ENVDIR:-/etc/arche}"
SBIN="${ARCHE_SBIN:-/usr/local/sbin}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
avert() { printf '\033[1;33m!!\033[0m %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || { echo "À lancer en root." >&2; exit 1; }

# ── 1. Compte de service ────────────────────────────────────────────────────
if ! id -u "$UTILISATEUR" >/dev/null 2>&1; then
  log "Création du compte de service $UTILISATEUR"
  useradd --system --home-dir "$DEST" --shell /usr/sbin/nologin "$UTILISATEUR"
fi

# ── 2. Scripts du PRA ───────────────────────────────────────────────────────
# Sur la production : uniquement ce qui la concerne. Les scripts de l'arche y
# seraient au mieux inutiles, au pire dangereux (extinction de la machine).
if [ "$ROLE" = "production" ]; then
  # pra_retention.sh est une BIBLIOTHÈQUE sourcée par yunohost_backup_daily.sh :
  # sans elle, la rétention retombe silencieusement sur l'ancienne purge par
  # ancienneté. Elle appartient donc aux deux rôles.
  SCRIPTS=(yunohost_backup_daily.sh pra_docker_snapshot.sh pra_canaries.sh
           pra_notify.sh pra_retention.sh pra_recu_verifier.sh)
else
  SCRIPTS=()
  for s in "$SRC"/pra/*.sh; do SCRIPTS+=("$(basename "$s")"); done
  # pra_page_secours.py est en Python : il lit du JSON, produit du HTML et
  # invoque qrencode. L'écrire en shell aurait demandé trois fois plus de lignes
  # pour un résultat plus fragile.
  for s in "$SRC"/pra/*.py; do
    [ -e "$s" ] && SCRIPTS+=("$(basename "$s")")
  done
fi

# UN SCRIPT « EN COURS D'EXÉCUTION », ET NON UN SCRIPT SIMPLEMENT MENTIONNÉ.
#
# « pgrep -f /usr/local/sbin/x.sh » compare la ligne de commande ENTIÈRE de tous
# les processus : un « grep x.sh », un éditeur ouvert sur le fichier, ou un shell
# dont la charge contient ce chemin suffisent à faire croire que le script tourne.
# L'installation le saute alors, et l'on repart avec une version périmée en
# croyant avoir déployé — panne silencieuse, la pire espèce.
# Il suffit que les commandes de vérification citent le chemin dans la même
# session SSH pour que trois déploiements successifs restent sans effet.
#
# On inspecte donc argv : le script tourne si argv[0] EST son chemin, ou si
# argv[0] est un interpréteur et argv[1] son chemin. Un chemin cité en troisième
# argument — le cas d'un grep — ne compte pas.
_script_tourne() {
  local chemin="$1" p args
  for p in /proc/[0-9]*; do
    [ -r "$p/cmdline" ] || continue
    [ "${p##*/}" = "$$" ] && continue
    mapfile -d '' -t args < "$p/cmdline" 2>/dev/null || continue
    [ "${args[0]:-}" = "$chemin" ] && return 0
    case "${args[0]:-}" in
      bash|sh|*/bash|*/sh|*/dash)
        [ "${args[1]:-}" = "$chemin" ] && return 0 ;;
    esac
  done
  return 1
}

log "Installation des scripts ($ROLE) dans $SBIN"
for nom in "${SCRIPTS[@]}"; do
  [ -f "$SRC/pra/$nom" ] || { avert "$nom introuvable dans le dépôt"; continue; }
  # NE PAS REMPLACER UN SCRIPT EN COURS D'EXÉCUTION. bash relit son fichier au
  # fil de l'exécution : le remplacer sous ses pieds le fait dérailler à la
  # prochaine ligne lue, sans message clair.
  #
  # Le cas se produit sur les scripts longs : remplacer celui qui télécharge
  # depuis des heures laisse DEUX processus écrire le même fichier — image
  # corrompue, rattrapée par la somme de contrôle — ou fait tourner une version
  # dépassée pendant des heures.
  if _script_tourne "$SBIN/$nom"; then
    avert "$nom est EN COURS D'EXÉCUTION — non remplacé"
    avert "  arrêtez-le puis relancez l'installation, sinon il déraillera"
    continue
  fi
  install -m 750 -o root -g root "$SRC/pra/$nom" "$SBIN/$nom"
  printf '   %s\n' "$nom"
done

if [ "$ROLE" = "arche" ] && [ -f "$SRC/pra/pra-nightly.service" ]; then
  install -m 644 -o root -g root "$SRC/pra/pra-nightly.service" \
    /etc/systemd/system/pra-nightly.service
  # LE MINUTEUR, sans quoi le service n'est jamais déclenché. S'il manque au
  # dépôt, l'installation produit un dispositif complet et inerte, ce qui ne se
  # voit pas — tout est « installé ».
  if [ -f "$SRC/pra/pra-nightly.timer" ]; then
    # ON NE RALLUME PAS UN MINUTEUR QU'ON A DÉLIBÉRÉMENT ÉTEINT.
    #
    # Une installation qui réactive le minuteur arrêté quelques minutes plus tôt
    # pour pouvoir travailler laisse le nocturne se déclencher et éteindre la
    # machine en pleine restauration manuelle.
    # « enable --now » inconditionnel transforme un déploiement — geste anodin —
    # en extinction programmée, et rien ne le laissait deviner.
    #
    # On relève donc l'état AVANT, et on le rétablit. Une première installation
    # (unité absente) active le minuteur, sans quoi le dispositif serait complet
    # et inerte ; une réinstallation respecte le choix en place.
    _timer_existait=0; _timer_actif=0
    if [ -f /etc/systemd/system/pra-nightly.timer ]; then
      _timer_existait=1
      systemctl is-enabled pra-nightly.timer >/dev/null 2>&1 && _timer_actif=1
    fi
    install -m 644 -o root -g root "$SRC/pra/pra-nightly.timer" \
      /etc/systemd/system/pra-nightly.timer
    systemctl daemon-reload
    if [ "$_timer_existait" = 1 ] && [ "$_timer_actif" = 0 ]; then
      avert "Minuteur pra-nightly laissé DÉSACTIVÉ — il l'était avant cette installation."
      avert "  AUCUNE réplication nocturne ne se déclenchera. Pour la rétablir :"
      avert "    sudo systemctl enable --now pra-nightly.timer"
    else
      systemctl enable --now pra-nightly.timer >/dev/null 2>&1 \
        && log "Minuteur pra-nightly actif : $(systemctl show -p TimersCalendar --value pra-nightly.timer 2>/dev/null | head -1)" \
        || avert "pra-nightly.timer n'a pas pu être activé — la réplication ne se déclenchera PAS"
    fi
  else
    avert "pra-nightly.timer introuvable dans le dépôt — rien ne déclenchera la réplication"
  fi

  # LES PILES DOCKER AU DÉMARRAGE. Les fichiers « compose » viennent de la
  # production et ne portent pas tous une politique de redémarrage : après une
  # extinction, la plupart des conteneurs d'une pile peuvent rester à terre. La
  # nuit, la restauration les relance, si bien que cela ne se voit pas — seul un
  # démarrage manuel le révèle, c'est-à-dire celui qu'on fait pour travailler.
  if [ -f "$SRC/pra/pra-piles-docker.service" ]; then
    install -m 644 -o root -g root "$SRC/pra/pra-piles-docker.service" \
      /etc/systemd/system/pra-piles-docker.service
    systemctl daemon-reload
    systemctl enable pra-piles-docker.service >/dev/null 2>&1 \
      && log "Piles Docker relancées à chaque démarrage" \
      || avert "pra-piles-docker n'a pas pu être activé — les piles resteront à terre après une extinction"
  fi

  # LE FILET DE RÉVEIL. Sans lui, une extinction manuelle laisse l'arche sans
  # alarme : elle ne se rallume plus, et une machine éteinte n'alerte personne.
  # Il n'agit que si aucune alarme future n'est armée, donc il ne peut pas
  # contrarier le nocturne.
  if [ -f "$SRC/pra/pra-reveil-filet.service" ]; then
    install -m 644 -o root -g root "$SRC/pra/pra-reveil-filet.service" \
      /etc/systemd/system/pra-reveil-filet.service
    systemctl daemon-reload
    systemctl enable --now pra-reveil-filet.service >/dev/null 2>&1 \
      && log "Filet de réveil actif : toute extinction laissera une alarme armée" \
      || avert "pra-reveil-filet n'a pas pu être activé — une extinction manuelle laissera l'arche endormie"
  fi

  # LOGROTATE APRÈS FAIL2BAN. Rattrapé au réveil de 02:00, logrotate passait
  # parfois avant fail2ban, échouait sur sa rotation, et la restauration de la
  # nuit hérite d'un service en échec : verdict « partiel » pour une course qui
  # n'a rien à voir avec elle. Voir le fichier lui-même.
  if [ -f "$SRC/pra/logrotate-apres-fail2ban.conf" ]; then
    install -d -m 755 /etc/systemd/system/logrotate.service.d
    install -m 644 -o root -g root "$SRC/pra/logrotate-apres-fail2ban.conf" \
      /etc/systemd/system/logrotate.service.d/arche-apres-fail2ban.conf
    systemctl daemon-reload
    # VÉRIFIÉ, pas supposé : une surcharge mal placée est ignorée sans un mot.
    if systemctl show logrotate.service -p After 2>/dev/null | grep -q "fail2ban.service"; then
      log "logrotate attend désormais fail2ban au réveil"
    else
      avert "la surcharge logrotate n'a pas pris — la course avec fail2ban reste possible"
    fi
  fi
elif [ "$ROLE" = "production" ]; then
  log "Unité pra-nightly NON installée (elle éteindrait la production)"
  # Et si une installation antérieure l'avait déposée par erreur, on la retire.
  if [ -f /etc/systemd/system/pra-nightly.service ]; then
    avert "pra-nightly.service présent sur la PRODUCTION — désactivation"
    systemctl disable --now pra-nightly.service 2>/dev/null || true
    rm -f /etc/systemd/system/pra-nightly.service
  fi
  rm -f "$SBIN/pra_nightly.sh" "$SBIN/pra_restore_replica.sh" \
        "$SBIN/pra_docker_restore.sh"

  # Les deux planifications de la production. Elles vivaient hors suivi de
  # versions — la sauvegarde dans la crontab de root, l'instantané Docker dans un
  # /etc/cron.d écrit à la main. Une reconstruction les aurait perdues.
  for planif in pra-backup pra-docker-snapshot pra-recu-verifier; do
    if [ -f "$SRC/pra/cron.d/$planif" ]; then
      install -m 644 -o root -g root "$SRC/pra/cron.d/$planif" "/etc/cron.d/$planif"
      log "Planification $planif installée"
    else
      avert "pra/cron.d/$planif introuvable dans le dépôt"
    fi
  done
  # L'API D'ÉTAT DE L'ARCHE, EN LECTURE LIBRE.
  #
  # Deux informations sans jeton : l'arche est-elle restaurée, et depuis quand.
  # Le fichier est écrit par pra_recu_verifier.sh ; nginx ne fait que le servir.
  #
  # ON VÉRIFIE QUE ÇA RÉPOND, on ne se contente pas d'avoir posé le fichier.
  # Une configuration nginx déposée puis rejetée laisserait un dispositif « bien
  # installé » et muet — c'est la faute que ce script existe pour empêcher, et
  # elle est d'autant plus probable ici que SSOwat peut s'interposer.
  _dom="${PRA_ETAT_DOMAINE:-$(yunohost domain main-domain --output-as plain 2>/dev/null)}"
  if [ -n "$_dom" ] && [ -d "/etc/nginx/conf.d/$_dom.d" ] \
     && [ -f "$SRC/pra/nginx/pra-etat.conf" ]; then
    install -d -m 755 /var/www/pra-etat
    install -m 644 -o root -g root "$SRC/pra/nginx/pra-etat.conf" \
      "/etc/nginx/conf.d/$_dom.d/pra-etat.conf"
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || true
      # Premier remplissage, pour ne pas laisser un 404 jusqu'au quart d'heure suivant.
      "$SBIN/pra_recu_verifier.sh" --publier >/dev/null 2>&1 || true
      # « RELOAD » EST ASYNCHRONE. Les anciens processus nginx servent encore
      # quelques instants avec l'ANCIENNE configuration. Interrogée aussitôt,
      # l'URL rend donc la réponse d'avant : la même configuration annonce
      # « 302 : SSOwat s'interpose » ici et 200 là, selon qu'on a attendu une seconde
      # ou non après le rechargement. Un contrôle qui mesure l'état
      # précédent au lieu du nouveau est pire qu'aucun contrôle : il fait chercher
      # une panne qui n'existe pas. On redemande donc quelques secondes avant de
      # conclure ; une réponse encore fausse au bout de ce temps, elle, est réelle.
      _code=000
      for _essai in 1 2 3 4 5 6 7 8 9 10; do
        _code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                 "https://$_dom/pra/etat.json" 2>/dev/null || echo 000)"
        [ "$_code" = 200 ] && break
        sleep 1
      done
      case "$_code" in
        200) log "État de l'arche publié : https://$_dom/pra/etat.json" ;;
        404) avert "https://$_dom/pra/etat.json rend 404 — aucun reçu encore reçu, ou alias incorrect" ;;
        302|401|403) avert "https://$_dom/pra/etat.json rend $_code : SSOwat s'interpose, l'API n'est PAS publique" ;;
        *)   avert "https://$_dom/pra/etat.json rend $_code — à vérifier à la main" ;;
      esac
    else
      rm -f "/etc/nginx/conf.d/$_dom.d/pra-etat.conf"
      avert "nginx a REFUSÉ la configuration de l'API d'état — retirée, rien n'a changé"
    fi
  else
    avert "API d'état non installée : domaine principal introuvable ou pra/nginx/pra-etat.conf absent"
  fi

  # On ne TOUCHE PAS à la crontab de root : y supprimer une ligne serait une
  # modification destructive d'un fichier que l'exploitant gère lui-même. Mais un
  # doublon lancerait deux sauvegardes en parallèle sur la même archive, alors on
  # le dit clairement.
  if crontab -l -u root 2>/dev/null | grep -qE "yunohost_backup_daily|pra_docker_snapshot"; then
    avert "DOUBLON : la crontab de root contient encore une de ces planifications."
    avert "  Deux exécutions simultanées se marcheraient dessus. À retirer à la main :"
    avert "  sudo crontab -e -u root"
  fi
fi

# ── 2 bis. Données de l'application ─────────────────────────────────────────
# L'annuaire de crise y est écrit par la webapp, sous son compte non privilégié,
# et relu par le générateur de la page de secours. Sans ce répertoire, la
# première saisie échoue — et l'échec ne se voit qu'au moment où quelqu'un tente
# d'enregistrer des numéros.
install -d -m 750 -o "$UTILISATEUR" -g "$UTILISATEUR" /var/lib/arche
log "Répertoire de données : /var/lib/arche"

# ── 2 bis suite. Autorité interne, pour la connexion OIDC ───────────────────
# Les domaines « .local » sont signés par l'autorité interne de YunoHost. Sans
# elle, l'application refuse le certificat de dex et la connexion nominative est
# impossible — « self-signed certificate in certificate chain ».
#
# Le fichier /etc/ssl/certs/ca-yunohost_crt.pem ne convient PAS : il porte le
# certificat du domaine, pas l'autorité. On extrait celle-ci de la poignée de
# main locale, et on ne la garde que si elle est auto-signée et valide bien le
# certificat du domaine.
if [ "$ROLE" != "production" ] && command -v openssl >/dev/null 2>&1; then
  dom_local="$(yunohost app setting dex domain 2>/dev/null \
  || echo "${PRA_DOMAINE_PRINCIPAL:-localhost}")"
  ca_tmp="$(mktemp)"
  if echo | openssl s_client -connect 127.0.0.1:443 -servername "$dom_local" \
       -showcerts 2>/dev/null | awk '/BEGIN CERT/{n++} n==2' > "$ca_tmp" \
     && [ -s "$ca_tmp" ] \
     && openssl verify -CAfile "$ca_tmp" "$ca_tmp" >/dev/null 2>&1; then
    install -d -m 755 /var/lib/pra
    install -m 644 -o root -g root "$ca_tmp" /var/lib/pra/ca-yunohost.pem
    log "Autorité interne installée : /var/lib/pra/ca-yunohost.pem"
  else
    avert "autorité interne non extraite — la connexion OIDC échouera en TLS"
  fi
  rm -f "$ca_tmp"
fi

# ── 2 bis bis. Repli « node » (arche seulement) ─────────────────────────────
# Les unités systemd restaurées portent le chemin EXACT de la version de node de
# la PRODUCTION. « n install 22 » n'installant pas la même 22.x selon le jour, ce
# chemin n'existe pas sur l'arche : « /usr/bin/env: node: No such file or
# directory », service en 127, et YunoHost REPLIE TOUTE LA RESTAURATION avant
# qu'aucune réparation d'après-coup ne puisse intervenir.
# C'est ce qui rend certaines applications node irrécupérables.
# Ce lanceur résout la version à chaque appel, et ne sert QUE quand le PATH du
# service a échoué. Voir les commentaires du fichier pour la limite assumée.
if [ "$ROLE" != "production" ]; then
  if [ -e /usr/local/bin/node ] && ! grep -q "repli installé par Arche" /usr/local/bin/node 2>/dev/null; then
    avert "/usr/local/bin/node existe et n'est pas le nôtre — repli node NON installé"
  else
    install -m 755 -o root -g root "$SRC/pra/node-repli" /usr/local/bin/node
    log "Repli « node » installé (/usr/local/bin/node)"
  fi
fi

# ── 2 ter. Page de secours (arche seulement) ────────────────────────────────
# Elle doit s'afficher quand plus rien ne s'affiche : servie en HTTP simple sur
# un port dédié, joignable PAR ADRESSE IP. Le portail YunoHost, lui, refuse
# l'IP — sans cette page, une arche dont le nom ne résout pas est inatteignable.
if [ "$ROLE" != "production" ]; then
  log "Installation de la page de secours"

  install -d -m 755 /usr/local/share/arche
  install -d -m 755 /var/www/arche-secours
  install -m 644 -o root -g root "$SRC/gabarits/page-secours.html" \
  /usr/local/share/arche/page-modele.html
  # Les pages propres au site — un guide pas à pas, un mode opératoire — se
  # déposent simplement dans /var/www/arche-secours : pra_page_secours.py les
  # reprend sous la seconde porte, sans rien à déclarer. L'outil n'en fournit
  # aucune : leur contenu n'appartient qu'à l'organisation qui s'en sert.
  # Les manuels hors ligne, servis sur le même port que la page de secours.
  install -d -m 755 /var/www/arche-manuels

  # Fichier volontairement NON nommé d'après un domaine : YunoHost ne régénère
  # que ses « <domaine>.conf », celui-ci lui est étranger et survit donc aux
  # régénérations, y compris pendant la restauration nocturne.
  install -m 644 -o root -g root "$SRC/pra/nginx/zz-arche-secours.conf" \
          /etc/nginx/conf.d/zz-arche-secours.conf
  # Les manuels sous le portail, en plus du port 8080 : la page de secours est
  # publiée aux deux endroits et ses liens sont relatifs. Sans ce bloc, le lien
  # « manuels » rend 404 depuis /accueil/ — le chemin qu'on emprunte le plus.
  # Le répertoire du domaine n'existe que si YunoHost y sert déjà quelque chose.
  _dom_portail="${PRA_DOMAINE_PRINCIPAL:-$(yunohost domain main-domain --output-as plain 2>/dev/null)}"
  if [ -n "$_dom_portail" ] && [ -d "/etc/nginx/conf.d/$_dom_portail.d" ]; then
  install -m 644 -o root -g root "$SRC/pra/nginx/zzz-arche-manuels-portail.conf" \
  "/etc/nginx/conf.d/$_dom_portail.d/zzz-arche-manuels-portail.conf"
  fi

  install -m 644 -o root -g root "$SRC/pra/arche-page-secours.service" \
          /etc/systemd/system/arche-page-secours.service
  install -m 644 -o root -g root "$SRC/pra/arche-page-secours.timer" \
          /etc/systemd/system/arche-page-secours.timer

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx || avert "rechargement de nginx en échec"
  else
    avert "configuration nginx invalide : la page de secours n'est pas servie"
  fi

  # Sans ouverture du pare-feu, la page n'existe que pour la machine elle-même.
  if command -v yunohost >/dev/null 2>&1; then
    yunohost firewall allow TCP 8080 >/dev/null 2>&1 \
      || avert "port 8080 non ouvert : la page de secours restera locale"
  fi

  systemctl daemon-reload
  systemctl enable --now arche-page-secours.timer >/dev/null 2>&1 \
    || avert "minuterie de la page de secours non activée"
  /usr/local/sbin/pra_page_secours.py >/dev/null 2>&1 \
    || avert "première génération de la page de secours en échec"
fi

# ── 3. Application ──────────────────────────────────────────────────────────
log "Installation de l'application dans $DEST"
mkdir -p "$DEST"
cp -a "$SRC/app" "$DEST/"
cp -a "$SRC/helper" "$DEST/"
cp -a "$SRC/pyproject.toml" "$DEST/"
[ -f "$SRC/README.md" ] && cp -a "$SRC/README.md" "$DEST/"

# LES CONVERTISSEURS DE DOCUMENTATION, INSTALLÉS PENDANT QU'IL Y A INTERNET.
#
# Trois documentations ne sont récupérables que par leur source — Markdown et
# AsciiDoc — parce que leurs sites refusent les automates. Servies telles
# quelles, elles s'affichent en texte brut : 800 fichiers sans titre, sans
# table des matières, sans lien cliquable entre eux. Illisibles au moment où
# elles servent.
#
# pandoc et asciidoctor les rendent en HTML une fois pour toutes, à la copie.
# C'est délibérément fait À L'AVANCE plutôt qu'au moment de la lecture : le
# jour de la crise, il ne reste que des fichiers HTML statiques, sans
# convertisseur, sans JavaScript, sans rien à installer.
#
# Leur absence n'est pas bloquante — le dépôt garde les sources — mais elle se
# dit, parce qu'on ne la découvrirait qu'en ouvrant un manuel en urgence.
if [ "$ROLE" = "arche" ]; then
  _manquants=()
  command -v pandoc >/dev/null 2>&1 || _manquants+=(pandoc)
  ls -d /usr/share/rubygems-integration/all/gems/asciidoctor-*/bin/asciidoctor \
     >/dev/null 2>&1 || command -v asciidoctor >/dev/null 2>&1 \
     || _manquants+=(ruby-asciidoctor)
  # qrencode : le QR de la page de crise dans YunoBox. Absent, la carte affiche
  # l'adresse seule et le dit — on ne code PAS le QR nous-mêmes, un encodeur
  # maison subtilement faux produirait une image qui ne se scanne pas, et on ne
  # le découvrirait que le téléphone à la main, le jour de la crise.
  command -v qrencode >/dev/null 2>&1 || _manquants+=(qrencode)
  if [ "${#_manquants[@]}" -gt 0 ]; then
    log "Installation des convertisseurs de documentation : ${_manquants[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      "${_manquants[@]}" >/dev/null 2>&1 \
      && log "  convertisseurs installés" \
      || avert "  ÉCHEC : les manuels en Markdown et AsciiDoc resteront en texte brut"
  fi
fi

if [ ! -d "$DEST/.venv" ]; then
  log "Création de l'environnement Python"
  python3 -m venv "$DEST/.venv"
fi
log "Installation des dépendances"
"$DEST/.venv/bin/pip" install --quiet --upgrade pip
"$DEST/.venv/bin/pip" install --quiet -e "$DEST"

# APPROPRIATION — point de sécurité central, à ne pas « simplifier ».
#
# TOUT /opt/arche appartient à root et n'est accessible qu'en LECTURE au compte
# de service. La webapp n'a besoin d'écrire nulle part ici : chaque opération
# privilégiée passe par le helper.
#
# Un « chown -R archeapp » sur ce répertoire, même corrigé ensuite pour le seul
# fichier du helper, ouvre DEUX élévations de privilèges vers root :
#
#  1. .venv/bin/python3 est l'interpréteur du shebang du helper, lancé en root
#     via sudo. Qui peut le remplacer devient root.
#  2. Pour un script Python, sys.path[0] est SON PROPRE RÉPERTOIRE. Qui peut
#     écrire dans helper/ y dépose un faux « argparse.py » ou « json.py », qui
#     sera importé à la place de celui de la bibliothèque standard — en root.
#
# Le second est le plus sournois : posséder le répertoire suffit, sans jamais
# toucher au fichier du helper lui-même.
chown -R root:root "$DEST"
chmod -R go-w "$DEST"
find "$DEST" -type d -exec chmod 755 {} +
chmod 750 "$DEST/helper/arche-helper"

# ── 4. Règle sudo ───────────────────────────────────────────────────────────
log "Installation de la règle sudo"
install -m 440 -o root -g root "$SRC/helper/sudoers.d/arche" /etc/sudoers.d/arche
if ! visudo -c -q -f /etc/sudoers.d/arche; then
  rm -f /etc/sudoers.d/arche
  echo "Règle sudo invalide — annulée." >&2; exit 1
fi

# ── 5. Configuration ────────────────────────────────────────────────────────
mkdir -p "$ENVDIR" /etc/pra /var/lib/pra
chmod 750 "$ENVDIR"
if [ ! -f "$ENVDIR/arche.env" ]; then
  log "Génération de $ENVDIR/arche.env"
  secret="$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | cut -c1-40)"
  cat > "$ENVDIR/arche.env" <<EOF
ARCHE_ROLE=$ROLE
ARCHE_ROOT_PATH=/arche
ARCHE_AUTH_MODE=proxy
ARCHE_SESSION_SECRET=$secret
ARCHE_HOST=127.0.0.1
ARCHE_PORT=8770
EOF
  chmod 640 "$ENVDIR/arche.env"
  chown root:"$UTILISATEUR" "$ENVDIR/arche.env"
else
  avert "$ENVDIR/arche.env existe déjà — conservé tel quel."
  # Le rôle, en revanche, doit refléter l'installation demandée : le laisser
  # divergent afficherait l'interface de l'autre volet.
  if grep -q '^ARCHE_ROLE=' "$ENVDIR/arche.env"; then
    sed -i "s|^ARCHE_ROLE=.*|ARCHE_ROLE=$ROLE|" "$ENVDIR/arche.env"
  else
    printf 'ARCHE_ROLE=%s\n' "$ROLE" >> "$ENVDIR/arche.env"
  fi
  log "Rôle appliqué : $ROLE"
fi

# On ne crée qu'un squelette : écraser les réglages de l'exploitant à chaque
# mise à jour serait une régression silencieuse du dispositif de sécurité.
if [ ! -f /etc/pra/pra.conf ]; then
  log "Création d'un /etc/pra/pra.conf vide"
  printf '# Réglages du PRA — à compléter depuis la webapp Arche.\n' \
    > /etc/pra/pra.conf
  chmod 600 /etc/pra/pra.conf
else
  avert "/etc/pra/pra.conf existe déjà — conservé tel quel."
fi

# ── 6. Service ──────────────────────────────────────────────────────────────
log "Installation du service systemd"
install -m 644 -o root -g root "$SRC/systemd/arche.service" \
  /etc/systemd/system/arche.service
systemctl daemon-reload
systemctl enable arche.service
# RESTART, et non « enable --now » : celui-ci démarre un service arrêté mais ne
# redémarre PAS un service déjà en marche. Le code neuf restait alors sur le
# disque tandis que le processus continuait avec l'ancien — les gabarits
# réclament un filtre absent du code chargé, d'où une erreur 500 sur une
# installation en apparence réussie.
systemctl restart arche.service

sleep 2
if systemctl is-active --quiet arche.service; then
  log "Arche ($ROLE) est démarrée sur http://127.0.0.1:8770"
else
  avert "Le service n'a pas démarré :"
  journalctl -u arche.service -n 15 --no-pager || true
  exit 1
fi

# LE DOSSIER PAPIER. Le script en a besoin des .md : on les pose à côté de la
# webapp, ce qui rend aussi la documentation lisible depuis la machine elle-même
# le jour où l'on n'a plus accès au dépôt Git.
if [ "$ROLE" = "arche" ] && [ -d "$SRC/doc" ]; then
install -d -m 755 "$DEST/doc"
install -m 644 -o root -g root "$SRC"/doc/*.md "$DEST/doc/"
log "Documentation déposée dans $DEST/doc"
fi

# YUNOBOX — LE TABLEAU DE BORD DE LA MACHINE.
#
# Un composant posé à la main par son propre script, puis jamais repris, vit
# HORS de toute installation. Cela se découvre en cherchant
# pourquoi la carte « Page de crise » n'apparaissait pas — le déployé datait du
# 1er août, et il lui manquait aussi la carte Machine et le correctif du
# scanner Wi-Fi. Un composant sans chemin d'installation dérive en silence :
# c'est précisément la faute que ce script existe pour empêcher.
#
# On appelle SON installateur plutôt que de recopier sa logique ici : il est
# rejouable, il CONSERVE le jeton existant, et il sait poser le hook mDNS et
# l'unité. Il affiche en fin de course l'URL d'accès, jeton compris — normal,
# on est root sur la machine, et ce jeton est déjà lisible dans
# /etc/yunobox/token.
#
# Son échec n'interrompt pas l'installation : YunoBox est un confort, la
# réplication est l'essentiel. Mais il se dit.
if [ "$ROLE" = "arche" ] && [ -x "$SRC/yunobox/install.sh" ]; then
  log "Installation de YunoBox"
  if bash "$SRC/yunobox/install.sh"; then
    log "  YunoBox installée et redémarrée"
  else
    avert "  YunoBox n'a pas pu être installée — journalctl -u yunobox -n 40"
  fi
fi

# CE QUI EST POSÉ EST-IL CE QU'ON VOULAIT POSER ?
#
# Une même faute peut survivre plusieurs fois à sa correction : le dépôt est
# juste, l'artefact sur la machine ne l'est pas. Un déploiement partiel
# ne se voit pas — tout paraît installé, et l'on cherche le bogue dans le code.
# On compare donc ce qui vient d'être écrit à sa source, et on le dit.
if [ "$ROLE" = "arche" ]; then
  _ecarts=0
  if ! cmp -s "$SRC/gabarits/page-secours.html" /usr/local/share/arche/page-modele.html; then
  avert "le modèle de la page de secours déployé DIFFÈRE du dépôt"
  _ecarts=$((_ecarts + 1))
  fi
  # YunoBox entre dans le contrôle : c'est le composant le plus susceptible de
  # dériver, puisqu'il a son propre installateur. Un contrôle qui ne couvre pas
  # ce qui dérive ne sert à rien.
  for _y in yunobox.py static/index.html; do
    [ -f "$SRC/yunobox/$_y" ] || continue
    if ! cmp -s "$SRC/yunobox/$_y" "/opt/yunobox/$_y"; then
      avert "YunoBox : $_y déployé DIFFÈRE du dépôt"
      _ecarts=$((_ecarts + 1))
    fi
  done
  [ "$_ecarts" -eq 0 ] && log "Pages de crise et YunoBox : conformes au dépôt"
fi

cat <<'FIN'

Étapes suivantes
────────────────
 1. Exposer la webapp : application « Reverse Proxy » de YunoHost vers
    127.0.0.1:8770, restreinte au groupe des administrateurs. L'accès est alors
    filtré par SSOwat et ARCHE_AUTH_MODE=proxy convient.
    Pour un accès autonome par tunnel SSH, basculer en mode « password » :
      ARCHE_AUTH_MODE=password
      ARCHE_ADMIN_PASSWORD_HASH=$(/opt/arche/.venv/bin/python -c \
        "from app.security import hash_password; print(hash_password('votre-mot-de-passe'))")

 2. Renseigner les réglages depuis la webapp — en particulier les alertes Talk,
    sans lesquelles AUCUN échec ne vous sera signalé.

 3. Déployer les canaris sur la PRODUCTION :
      sudo pra_canaries.sh deployer
    puis, sur l'arche, enregistrer leurs empreintes :
      sudo pra_canaries.sh rebaser

FIN
