"""Le jeton anti-CSRF, et surtout : AUCUNE route POST ne doit y échapper.

Le mécanisme est une dépendance déclarée route par route (voir app/csrf.py pour
la raison). Le risque est donc l'oubli lors de l'ajout d'une route. Ce fichier
énumère les routes POST de l'application et échoue si l'une n'est pas protégée :
c'est ce test, et non la vigilance, qui garantit la couverture.
"""
from __future__ import annotations

import re

import pytest


def _routes_post(app):
    for route in app.routes:
        for methode in getattr(route, "methods", None) or ():
            if methode == "POST":
                yield route


def test_toute_route_post_est_protegee():
    from app.csrf import verifier
    from app.main import app

    nues = []
    for route in _routes_post(app):
        deps = getattr(getattr(route, "dependant", None), "dependencies", [])
        if not any(getattr(d, "call", None) is verifier for d in deps):
            nues.append(route.path)
    assert not nues, (
        "routes POST sans protection anti-CSRF : " + ", ".join(sorted(nues))
    )
    # Garde-fou : si l'énumération ne trouve plus rien, le test ne prouve rien.
    assert list(_routes_post(app)), "aucune route POST détectée — test inopérant"


def _jeton(client, chemin="/reglages"):
    page = client.get(chemin).text
    m = re.search(r'name="_csrf" value="([^"]+)"', page)
    assert m, "le formulaire ne contient pas de jeton"
    return m.group(1)


def test_post_sans_jeton_est_refuse(client):
    r = client.post("/actions/tester-alerte", follow_redirects=True)
    assert "Formulaire expiré ou invalide" in r.text
    assert "Alerte transmise" not in r.text


def test_post_avec_mauvais_jeton_est_refuse(client):
    r = client.post("/actions/tester-alerte", data={"_csrf": "faux"},
                    follow_redirects=True)
    assert "Formulaire expiré ou invalide" in r.text


def test_post_avec_bon_jeton_passe(client):
    r = client.post("/actions/tester-alerte", data={"_csrf": _jeton(client)},
                    follow_redirects=True)
    assert "Alerte transmise" in r.text


def test_restauration_exige_le_jeton(client):
    """La route la plus destructrice : elle désinstalle avant de restaurer."""
    r = client.post("/actions/restaurer", data={"mode": "reel"},
                    follow_redirects=True)
    assert "Restauration réelle lancée" not in r.text
    r = client.post("/actions/restaurer",
                    data={"mode": "reel", "_csrf": _jeton(client, "/")},
                    follow_redirects=True)
    assert "Restauration réelle lancée" in r.text


def test_le_jeton_change_apres_deconnexion(client_password):
    premier = _jeton(client_password, "/login-secours")
    client_password.post("/login-secours",
                         data={"password": "sesame-de-test", "_csrf": premier},
                         follow_redirects=True)
    client_password.get("/logout")
    assert _jeton(client_password, "/login-secours") != premier
