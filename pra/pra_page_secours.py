#!/usr/bin/env python3
"""Génère la page de secours de l'arche.

Cette page est la seule qui doit s'afficher quand plus rien ne s'affiche : ni
SSO, ni dex, ni Nextcloud, ni base de données. Elle est donc produite à l'avance,
en HTML pur, et servie telle quelle — aucun calcul au moment où l'on en a besoin,
aucune dépendance à un service qui pourrait être mort.

Elle est régénérée :
  - au démarrage de la machine ;
  - à chaque changement de réseau, par le hook NetworkManager de YunoBox ;
  - en fin de restauration nocturne ;
  - toutes les dix minutes, pour rafraîchir le verdict et l'annuaire.

Deux destinations, volontairement indépendantes l'une de l'autre :
  - /var/www/arche-secours/    servie par nginx sur le port 8080, en HTTP simple,
                               joignable PAR ADRESSE IP, sans nom ni certificat ;
  - /var/www/my_webapp/www/    servie par le portail, sous /accueil.

La première existe parce que le portail YunoHost refuse l'accès par IP : sans
elle, un réplica dont le nom ne résout pas est totalement inatteignable. Elle est
en HTTP délibérément — un avertissement de certificat auto-signé sur la page de
dernier recours serait une faute, et le contenu est public.
"""

import html
import json
import os
import re
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

MODELE = "/usr/local/share/arche/page-modele.html"
STATUT = "/var/lib/pra/status.json"
# L'annuaire vit dans la racine du dépôt de fichiers : les administrateurs
# l'éditent ainsi DEPUIS UN NAVIGATEUR, sans SSH ni accès à la machine. C'est la
# seule partie de la page que quelqu'un doit pouvoir changer un jour de crise.
# Source principale : saisie dans l'interface Arche, à /annuaire.
ANNUAIRE_JSON = "/var/lib/arche/annuaire.json"
# Source de repli, éditable depuis le dépôt par un navigateur, pour qui préfère
# écrire sa propre mise en page.
ANNUAIRE = "/home/yunohost.app/filebrowser/annuaire-de-crise.html"
# Noms que le réplica sert, annoncés dans la ligne « hosts » de la page pour
# qui veut atteindre les applications par leur nom sans DNS. Le nom principal
# d'abord, puis les autres, séparés par des espaces — c'est la forme qu'écrit la
# configuration. Rien par défaut : la page montre alors un gabarit à compléter.
DOMAINES_LOCAUX = [d for d in
                   [os.environ.get("PRA_DOMAINE_PRINCIPAL", "").strip()]
                   + os.environ.get("PRA_DOMAINES_LOCAUX", "").split() if d]
PORT_SECOURS = 8080
PORT_YUNOBOX = 8723

DESTINATIONS = ("/var/www/arche-secours/index.html",
                "/var/www/my_webapp/www/index.html")

# Interfaces à ignorer : boucle locale, ponts Docker et interfaces virtuelles de
# conteneurs. Les annoncer enverrait quelqu'un sur une adresse joignable par la
# seule machine qui n'en a pas besoin.
IGNORER = re.compile(r"^(lo|docker|br-|veth|virbr)")


def adresses():
    """Les adresses IPv4 réellement utilisables pour joindre l'arche."""
    try:
        sortie = subprocess.run(["ip", "-4", "-br", "addr"],
                                capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    trouvees = []
    for ligne in sortie.splitlines():
        champs = ligne.split()
        if len(champs) < 3 or IGNORER.match(champs[0]) or champs[1] != "UP":
            continue
        for cidr in champs[2:]:
            ip = cidr.split("/")[0]
            if ip and ip not in trouvees:
                trouvees.append(ip)
    return trouvees


def qr_svg(url):
    """Le QR code, en SVG inline — aucune image à charger, aucun service tiers."""
    try:
        r = subprocess.run(["qrencode", "-t", "SVG", "-m", "1", "-o", "-", url],
                           capture_output=True, text=True, timeout=10)
        if r.returncode != 0:
            return ""
        # On retire la déclaration XML et la DTD : le SVG est inséré dans du
        # HTML, où elles seraient au mieux ignorées, au pire mal interprétées.
        svg = re.sub(r"<\?xml[^>]*\?>|<!DOCTYPE[^>]*>", "", r.stdout).strip()
        return svg
    except (OSError, subprocess.SubprocessError):
        return ""


def fraicheur():
    """Encart sur la dernière réplication.

    C'est l'information la plus importante de la page : avant de s'appuyer sur
    cette copie, il faut savoir si elle date de cette nuit ou de trois semaines.
    Une arche qui n'a pas répliqué depuis dix jours ressemble en tout point à une
    arche à jour — sauf sur ce point, et il est décisif.
    """
    try:
        with open(STATUT, encoding="utf-8") as f:
            d = json.load(f)
    except (OSError, ValueError):
        return ('<div class="enc mal"><strong>Fraîcheur inconnue.</strong> '
                "Aucun compte rendu de réplication n'a pu être lu. Vérifiez la "
                "date des données avant de vous appuyer dessus.</div>")

    horodatage = str(d.get("horodatage", ""))
    verdict = str(d.get("verdict", "inconnu"))
    archive = str(d.get("archive", ""))

    quand, age_h = horodatage, None
    try:
        t = datetime.fromisoformat(horodatage)
        if t.tzinfo is None:
            t = t.replace(tzinfo=timezone.utc)
        age_h = (datetime.now(timezone.utc) - t).total_seconds() / 3600
        quand = t.strftime("%d/%m/%Y à %H:%M")
    except ValueError:
        pass

    if age_h is None:
        classe, tete = "att", "Dernière réplication"
    elif age_h > 48:
        classe = "mal"
        tete = "Données ANCIENNES — %d jours" % int(age_h // 24)
    elif verdict in ("succes", "succès", "ok"):
        classe, tete = "bien", "Données à jour"
    else:
        classe, tete = "att", "Dernière réplication : %s" % verdict

    detail = "Réplication du %s" % quand
    if archive:
        detail += " — archive %s" % html.escape(archive)
    if age_h is not None and age_h > 48:
        detail += (". <strong>Ce n'est pas normal</strong> : la réplication "
                   "tourne chaque nuit. Quelque chose l'en empêche depuis "
                   "plusieurs jours.")
    return ('<div class="enc %s"><strong>%s.</strong> %s.</div>'
            % (classe, html.escape(tete), detail))


ANNUAIRE_INITIAL = """<!-- ANNUAIRE DE CRISE — éditez ce fichier depuis le dépôt
     de fichiers, il est repris dans la page de secours à la prochaine
     régénération. Du HTML simple suffit : <p>, <strong>, <table>. -->
<div class="enc att">
  <p><strong>À compléter.</strong> L'annuaire de crise — équipe, CERT,
  hébergeur, assurance, juridique — n'est pas encore renseigné.</p>
  <p>Il vit aujourd'hui dans Nextcloud. Or si Nextcloud tombe avec la
  production, personne n'appelle personne. Ces numéros doivent figurer
  <em>ici</em>, et sur une copie imprimée gardée hors des deux machines.</p>
  <p>Pour les saisir : ouvrez <strong>l'interface Arche</strong>, page
  <em>Annuaire</em>, remplissez le tableau, enregistrez. Cette page se met à
  jour dans les dix minutes.</p>
</div>
"""


def annuaire_json():
    """L'annuaire saisi dans l'interface Arche, rendu en tableau.

    C'est la source PRINCIPALE : des champs structurés valent mieux que du
    HTML libre, personne ne casse la page en oubliant une
    balise, et l'interface journalise qui a changé quoi.

    Tout est échappé : ces valeurs viennent d'un formulaire, et même saisies par
    un administrateur elles n'ont pas à pouvoir injecter du balisage.
    """
    try:
        with open(ANNUAIRE_JSON, encoding="utf-8") as f:
            donnees = json.load(f)
    except (OSError, ValueError):
        return None

    entrees = [e for e in donnees.get("entrees", []) if isinstance(e, dict)]
    if not entrees:
        return None

    lignes = []
    for e in entrees:
        nom = html.escape(str(e.get("nom", "")))
        role = html.escape(str(e.get("role", "")))
        tel = html.escape(str(e.get("telephone", "")))
        courriel = html.escape(str(e.get("courriel", "")))
        remarque = html.escape(str(e.get("remarque", "")))
        # Le téléphone est cliquable : sur un mobile, en crise, on compose
        # depuis la page plutôt que de recopier un numéro à la main.
        cell_tel = ('<a href="tel:%s">%s</a>'
                    % (html.escape(re.sub(r"[^\d+]", "", str(e.get("telephone", "")))),
                       tel)) if tel else ""
        cell_mail = ('<a href="mailto:%s">%s</a>' % (courriel, courriel)) if courriel else ""
        lignes.append(
            "<tr><td><strong>%s</strong>%s</td><td>%s</td><td>%s</td></tr>"
            % (nom,
               '<span class="q">%s</span>' % role if role else "",
               cell_tel,
               cell_mail + ('<span class="q">%s</span>' % remarque if remarque else "")))

    quand = donnees.get("modifie") or ""
    pied = ""
    if quand:
        pied = ('<p class="sous">Mis à jour le %s%s.</p>'
                % (html.escape(quand[:10]),
                   " par " + html.escape(str(donnees.get("par") or ""))
                   if donnees.get("par") else ""))
    return ("<table><tr><th>Qui</th><th>Téléphone</th><th>Courriel</th></tr>"
            + "".join(lignes) + "</table>" + pied)


def annuaire():
    """L'annuaire, par ordre de préférence des sources.

    1. Le JSON saisi dans l'interface Arche — structuré, tracé, échappé.
    2. Le fragment HTML du dépôt — conservé pour qui préfère écrire lui-même sa
       mise en page, et parce qu'il ne demande aucune authentification de
       portail. Injecté tel quel : c'est du HTML d'administrateur, au même
       niveau de confiance que la page.
    3. À défaut, l'encart qui dit où saisir les numéros.
    """
    depuis_json = annuaire_json()
    if depuis_json:
        return depuis_json

    try:
        with open(ANNUAIRE, encoding="utf-8") as f:
            contenu = f.read().strip()
        if contenu:
            return contenu
    except OSError:
        # Volontairement PAS de création automatique. Depuis que l'interface
        # Arche porte l'annuaire, un fichier créé d'office ici enverrait au
        # mauvais endroit celui qui cherche où saisir les numéros. Ce fragment
        # reste une voie délibérée, pour qui veut écrire sa propre mise en page.
        pass
    return ANNUAIRE_INITIAL


DOC = "/var/www/arche-manuels"


def manuels():
    """La ligne vers les manuels, seulement s'il y en a.

    Un lien qui mène à « cet emplacement est inaccessible » fait douter de tout
    le reste de la page — et sur celle-ci, douter coûte cher.
    """
    try:
        n = sum(1 for _ in os.scandir(DOC))
    except OSError:
        n = 0
    if n <= 1:          # le seul index de remplacement ne compte pas
        return ""
    # Lien RELATIF : les manuels sont servis par le même serveur que cette page,
    # sur le port de secours. Une URL absolue supposerait que le nom du réplica
    # résolve — or cette page existe précisément pour le cas contraire.
    return ('<tr><td><a href="manuels/">Manuels</a></td>'
            '<td>Les notices des outils du dépôt'
            '<span class="q">DFIR ORC, Ventoy, Clonezilla, SystemRescue…</span>'
            '</td></tr>')


def ecrire(chemin, contenu):
    """Écriture atomique : une page tronquée serait servie telle quelle."""
    dossier = os.path.dirname(chemin)
    try:
        os.makedirs(dossier, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=dossier, prefix=".page-")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(contenu)
        os.chmod(tmp, 0o644)
        os.replace(tmp, chemin)
        return True
    except OSError as e:
        print("  %s : %s" % (chemin, e), file=sys.stderr)
        return False


# Les pages statiques du dispositif ne sont pas engendrées : on les recopie
# telles quelles à côté de la page de secours. Une page engendrée plus tard par
# un autre outil est absente au premier passage — le miroir l'ignore alors, et
# la reprend dès qu'elle existe. Une page annoncée sur l'accueil et absente sous
# l'une des deux portes est la faute la plus facile à commettre ici, et la plus
# coûteuse.
def pages_statiques(source):
    """Les pages déposées à côté de la page de secours, à reprendre telles quelles.

    Rien à déclarer : il suffit de poser un fichier .html dans le répertoire
    servi sur le port de secours. « index.html » est exclu — c'est la page de
    secours elle-même, régénérée juste au-dessus.
    """
    try:
        noms = sorted(os.listdir(source))
    except OSError:
        return []
    return [n for n in noms if n.endswith(".html") and n != "index.html"]


def mirroir_pages_statiques():
    """DEUX PORTES D'ENTRÉE, LE MÊME CONTENU DERRIÈRE.

    La page de secours est publiée à deux endroits : /var/www/arche-secours,
    servi en clair sur le port 8080, et /var/www/my_webapp/www, servi par le
    portail sous /accueil/. Poser le guide et la page des gestes dans le seul
    premier emplacement rend 404 depuis /accueil/ : le seul chemin qui marche
    est alors celui que personne n'emprunte quand le nom résout.

    Les liens des pages sont RELATIFS : à condition que les fichiers soient là,
    les mêmes pages fonctionnent sous les deux entrées sans rien savoir de
    l'adresse par laquelle on les atteint.
    """
    source = os.path.dirname(DESTINATIONS[0])
    n = 0
    for dest in DESTINATIONS[1:]:
        cible_dir = os.path.dirname(dest)
        for nom in pages_statiques(source):
            src = os.path.join(source, nom)
            if not os.path.isfile(src):
                continue
            try:
                with open(src, encoding="utf-8") as f:
                    if ecrire(os.path.join(cible_dir, nom), f.read()):
                        n += 1
            except OSError as e:
                print("  %s : %s" % (nom, e), file=sys.stderr)
    return n


def main():
    try:
        with open(MODELE, encoding="utf-8") as f:
            page = f.read()
    except OSError as e:
        print("modèle illisible : %s" % e, file=sys.stderr)
        return 1

    ips = adresses()
    principale = ips[0] if ips else None
    url = "http://%s:%d/" % (principale, PORT_SECOURS) if principale else ""
    yunobox = "http://%s:%d/" % (principale, PORT_YUNOBOX) if principale \
        else "http://<adresse de l'arche>:%d/" % PORT_YUNOBOX

    if ips:
        liens = "\n".join('<a href="http://%s:%d/">http://%s:%d/</a>'
                          % (ip, PORT_SECOURS, ip, PORT_SECOURS) for ip in ips)
        ligne_hosts = "%s  %s" % (ips[0], " ".join(DOMAINES_LOCAUX)
                                  or "<nom-du-réplica>")
    else:
        liens = ('<p class="sous">Aucune adresse réseau : la machine n\'est '
                 'raccordée à rien. Branchez un câble, ou activez un partage de '
                 'connexion.</p>')
        ligne_hosts = "<adresse du réplica>  %s" % (
            " ".join(DOMAINES_LOCAUX) or "<nom-du-réplica>")

    page = (page
            .replace("{{FRAICHEUR}}", fraicheur())
            .replace("{{ADRESSES}}", liens)
            .replace("{{QR}}", qr_svg(url) if url else "")
            .replace("{{LIGNE_HOSTS}}", html.escape(ligne_hosts))
            .replace("{{ANNUAIRE}}", annuaire())
            .replace("{{MANUELS}}", manuels())
            .replace("{{YUNOBOX}}", html.escape(yunobox))
            .replace("{{GENEREE}}", datetime.now().strftime("%d/%m/%Y à %H:%M")))

    ecrites = sum(1 for d in DESTINATIONS if ecrire(d, page))
    miroirs = mirroir_pages_statiques()
    print("page de secours régénérée (%d/%d destinations, %d adresse(s), "
          "%d page(s) miroir)" % (ecrites, len(DESTINATIONS), len(ips), miroirs))
    return 0 if ecrites else 1


if __name__ == "__main__":
    sys.exit(main())
