"""Le gabarit de la page de secours ne porte aucun lien absolu.

La page est servie par DEUX portes : en clair sur le port de secours, par
adresse IP (« http://<ip>:8080/ »), et à travers le portail sous « /accueil/ ».
Ses liens sont donc relatifs par nécessité — un « /manuels/ » viserait la racine
du SERVEUR et non celle de la page : il marche à la première porte et rend 404 à
la seconde, celle qu'on emprunte dès que le nom résout, c'est-à-dire presque
toujours.

Le même raisonnement vaut pour les pages que chaque site dépose à côté : le
mécanisme de miroir les reprend sous la seconde porte sans réécrire leur
contenu. Ce test garde donc le gabarit ET toute page trouvée dans gabarits/.
"""

import re
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
GABARITS = sorted((RACINE / "gabarits").glob("*.html"))

# Les substitutions du générateur (« {{YUNOBOX}} ») portent des URL complètes
# calculées à chaud : elles ne sont pas en cause.
LIEN_ABSOLU = re.compile(r'href=\\?"(/[^"\\]*)')


def test_il_y_a_bien_un_gabarit_a_examiner():
    # Un glob vide ferait passer ce test sans rien vérifier.
    noms = {p.name for p in GABARITS}
    assert "page-secours.html" in noms, noms


def test_aucun_lien_absolu_dans_les_gabarits():
    fautifs = []
    for page in GABARITS:
        for lien in sorted(set(LIEN_ABSOLU.findall(page.read_text(encoding="utf-8")))):
            fautifs.append(f"{page.name} : {lien}")
    assert not fautifs, (
        "liens absolus, donc morts sous /accueil/ :\n  " + "\n  ".join(fautifs))


def test_le_gabarit_porte_les_substitutions_attendues():
    """Un gabarit dont une substitution a été renommée se déploie sans erreur et
    affiche « {{ADRESSES}} » tel quel — sur la page de dernier recours."""
    modele = (RACINE / "gabarits" / "page-secours.html").read_text(encoding="utf-8")
    attendues = {"{{FRAICHEUR}}", "{{ADRESSES}}", "{{QR}}", "{{LIGNE_HOSTS}}",
                 "{{ANNUAIRE}}", "{{MANUELS}}", "{{YUNOBOX}}"}
    generateur = (RACINE / "pra" / "pra_page_secours.py").read_text(encoding="utf-8")
    posees = set(re.findall(r'"(\{\{[A-Z_]+\}\})"', generateur))
    assert attendues <= posees, "le générateur ne pose plus : " + ", ".join(
        sorted(attendues - posees))
    manquantes = {j for j in attendues if j not in modele}
    assert not manquantes, "absentes du gabarit : " + ", ".join(sorted(manquantes))
