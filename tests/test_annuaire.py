"""L'annuaire de crise.

Ce qui compte ici n'est pas la mise en forme mais trois garanties :

  - une ligne vide ne crée pas une entrée fantôme — le formulaire en propose
    toujours cinq d'avance, et les enregistrer produirait un annuaire troué ;
  - un saut de ligne injecté dans un champ ne casse pas la page de secours, qui
    reprend ces valeurs telles quelles ;
  - le journal d'audit dit QUE la liste a changé sans recopier les numéros : un
    annuaire est une donnée personnelle, et le journal est lisible par tous les
    administrateurs.
"""
from __future__ import annotations

import json
import re

import pytest

from app import annuaire


@pytest.fixture()
def fichier(tmp_path, monkeypatch):
    """Détourne l'annuaire vers un fichier temporaire.

    Piège à connaître : la fixture « client » SUPPRIME tous les modules « app.* »
    de sys.modules et les réimporte. L'objet module importé en tête de ce fichier
    n'est donc plus celui qu'utilise l'application. Sans les trois précautions
    ci-dessous, on rustine un module obsolète pendant que la webapp écrit dans
    /var/lib/arche — et le test échoue sans dire pourquoi.
    """
    import sys

    chemin = tmp_path / "annuaire.json"
    # 1. Pour toute réimportation ultérieure : le module lit cette variable.
    monkeypatch.setenv("ARCHE_ANNUAIRE", str(chemin))
    # 2. Pour le module que l'application utilise en ce moment.
    vivant = sys.modules.get("app.annuaire")
    if vivant is not None:
        monkeypatch.setattr(vivant, "FICHIER", chemin)
    # 3. Pour la copie importée en tête de ce fichier, qu'utilisent les tests
    #    qui n'ont pas besoin de la webapp.
    monkeypatch.setattr(annuaire, "FICHIER", chemin)
    return chemin


def test_annuaire_absent_ne_leve_pas(fichier):
    """Un annuaire jamais créé doit s'ouvrir, pas planter : c'est justement la
    page où l'on va le créer."""
    assert annuaire.lire() == {"entrees": [], "modifie": None, "par": None}


def test_annuaire_illisible_ne_leve_pas(fichier):
    """Un fichier corrompu ne doit pas empêcher d'ouvrir la page pour le
    corriger — sinon la seule issue serait un accès SSH."""
    fichier.write_text("{ceci n'est pas du JSON", encoding="utf-8")
    assert annuaire.lire()["entrees"] == []


def test_lignes_vides_ecartees(fichier):
    annuaire.ecrire([
        {"nom": "Yves", "telephone": "0102030405"},
        {"nom": "", "role": "", "telephone": "", "courriel": "", "remarque": ""},
        {"nom": "", "role": "", "telephone": "", "courriel": "", "remarque": ""},
    ], auteur="alex")
    entrees = annuaire.lire()["entrees"]
    assert len(entrees) == 1
    assert entrees[0]["nom"] == "Yves"


def test_ligne_sans_nom_mais_avec_numero_est_gardee(fichier):
    """Un numéro sans nom reste utile — « astreinte hébergeur », par exemple."""
    annuaire.ecrire([{"telephone": "0800000000", "role": "astreinte"}],
                    auteur="rssi")
    assert len(annuaire.lire()["entrees"]) == 1


def test_caracteres_de_controle_neutralises(fichier):
    """La page de secours reprend ces valeurs telles quelles : un saut de ligne
    y casserait la mise en page, et un caractère de contrôle passerait dans le
    HTML sans qu'on le voie."""
    annuaire.ecrire([{"nom": "Ghislain\nCERT", "remarque": "a\x00b\x1fc"}],
                    auteur="rssi")
    e = annuaire.lire()["entrees"][0]
    assert "\n" not in e["nom"] and "\x00" not in e["remarque"]
    assert e["nom"].startswith("Ghislain")


def test_valeurs_tronquees(fichier):
    annuaire.ecrire([{"nom": "x" * 500}], auteur="rssi")
    assert len(annuaire.lire()["entrees"][0]["nom"]) <= annuaire.LONGUEUR_MAX


def test_nombre_d_entrees_plafonne(fichier):
    annuaire.ecrire([{"nom": f"p{i}"} for i in range(annuaire.ENTREES_MAX + 40)],
                    auteur="rssi")
    assert len(annuaire.lire()["entrees"]) <= annuaire.ENTREES_MAX


def test_ecriture_atomique_et_droits(fichier):
    annuaire.ecrire([{"nom": "Yves"}], auteur="alex")
    assert fichier.exists()
    charge = json.loads(fichier.read_text(encoding="utf-8"))
    assert charge["par"] == "alex" and charge["modifie"]
    # Aucun fichier temporaire ne doit subsister à côté.
    assert not list(fichier.parent.glob(".annuaire-*"))


def test_resume_ne_recopie_pas_les_numeros():
    """Le journal d'audit est lisible par tous les administrateurs : il doit dire
    que la liste a changé, pas republier les coordonnées."""
    avant = [{"nom": "Yves", "telephone": "0102030405"}]
    apres = [{"nom": "Yves", "telephone": "0601020304"},
             {"nom": "Chloé", "telephone": "0700000000"}]
    texte = annuaire.resume(avant, apres)
    assert "Chloé" in texte
    assert "0601020304" not in texte and "0102030405" not in texte
    assert not re.search(r"\d{8,}", texte)


def test_resume_signale_les_retraits():
    texte = annuaire.resume([{"nom": "Pascal"}], [])
    assert "retrait" in texte and "Pascal" in texte


def test_page_annuaire_absente_de_la_production(client_production):
    """La production n'a pas de page de secours à alimenter : proposer l'annuaire
    là-bas ferait saisir les numéros sur la machine qui disparaît."""
    assert "/annuaire" not in client_production.get("/").text


def test_parcours_complet(client, fichier):
    """Formulaire, envoi, relecture — la chaîne entière, comme au navigateur."""
    page = client.get("/annuaire")
    assert page.status_code == 200
    m = re.search(r'name="_csrf" value="([^"]+)"', page.text)
    assert m, "aucun jeton anti-CSRF dans le formulaire"

    reponse = client.post("/annuaire", data={
        "_csrf": m.group(1),
        "nom": ["Yves Jacquet", ""],
        "role": ["RSSI", ""],
        "telephone": ["01 02 03 04 05", ""],
        "courriel": ["yves@example.org", ""],
        "remarque": ["astreinte", ""],
    }, follow_redirects=True)
    assert reponse.status_code == 200
    assert "Yves Jacquet" in reponse.text
    assert "01 02 03 04 05" in reponse.text


def test_bouton_ajouter_ligne_present(client, fichier):
    """Le bouton d'ajout doit exister, et les lignes vierges du gabarit rester :
    sans JavaScript, ce sont elles qui permettent encore de saisir."""
    page = client.get("/annuaire").text
    assert 'id="ajouter-ligne"' in page
    # Deux lignes vierges d'avance, donc au moins deux champs « nom » vides.
    assert page.count('name="nom" value=""') >= 2


def test_le_formulaire_reste_utilisable_sans_script(client, fichier):
    """Le bouton est caché tant que le script ne l'a pas révélé : une page dont
    le JavaScript ne s'exécute pas ne doit pas montrer un bouton inerte."""
    page = client.get("/annuaire").text
    m = re.search(r'<button[^>]*id="ajouter-ligne"[^>]*>', page)
    assert m and "hidden" in m.group(0)
