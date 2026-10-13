"""L'app est servie sous un SOUS-CHEMIN, et tous ses liens doivent en tenir compte.

Sur l'arche, la webapp vit derrière un reverse proxy en `/arche`. Le proxy retire
ce préfixe avant de passer la requête, donc l'application ne le voit pas dans
`request.url.path` — c'est `ARCHE_ROOT_PATH` qui le lui apprend, et l'aide
`redirect()` qui le remet devant chaque redirection.

`request.url_for()` ne le fait PAS : RootPathMiddleware retire le préfixe sans
poser `scope["root_path"]` (à dessein, sinon le service des fichiers statiques
casse). url_for produit donc « /depot » au lieu de « /arche/depot ».

Ce n'est pas une subtilité théorique : le bouton « Mettre à jour » du dépôt
renvoie alors vers `https://replica.local/depot/login?redirect=/files/` — la page
de connexion de l'application qui occupe ce chemin. Le défaut est invisible en
développement, où root_path est vide et où les deux formes coïncident.

D'où ces tests, qui montent l'application AVEC un préfixe.
"""

from __future__ import annotations

import re

import pytest


def test_aucune_redirection_par_url_for(client):
    """Garde-fou de relecture : `request.url_for` ne doit pas servir à construire
    une redirection. Le commentaire de `_uri_retour` l'explique déjà — il a
    pourtant été contourné cinq fois."""
    from pathlib import Path

    source = (Path(__file__).resolve().parent.parent / "app" / "main.py").read_text(
        encoding="utf-8"
    )
    fautives = [
        l.strip()
        for l in source.splitlines()
        if "url_for(" in l and not l.lstrip().startswith("#")
        and "RedirectResponse" in l
    ]
    assert not fautives, (
        "redirections construites avec url_for — elles perdront le préfixe de "
        "sous-chemin :\n  " + "\n  ".join(fautives)
    )


@pytest.fixture()
def client_prefixe(tmp_path, monkeypatch):
    """La même application, montée sous « /arche » comme sur l'arche."""
    import stat
    import sys
    from pathlib import Path

    from tests.conftest import FAUX_HELPER, RACINE

    helper = tmp_path / "faux-helper"
    helper.write_text(FAUX_HELPER)
    helper.chmod(helper.stat().st_mode | stat.S_IEXEC)

    monkeypatch.setenv("ARCHE_HELPER", str(helper))
    monkeypatch.setenv("ARCHE_SUDO", "")
    monkeypatch.setenv("ARCHE_AUTH_MODE", "proxy")
    monkeypatch.setenv("ARCHE_SESSION_SECRET", "essai")
    monkeypatch.setenv("ARCHE_ROOT_PATH", "/arche")
    monkeypatch.setenv("FAUX_MEMOIRE", str(tmp_path / "conf.json"))
    monkeypatch.setenv("FAUX_RACINE", str(RACINE))

    for module in [m for m in list(sys.modules) if m.startswith("app")]:
        del sys.modules[module]
    from app.config import get_settings

    get_settings.cache_clear()
    from app.main import app
    from fastapi.testclient import TestClient

    with TestClient(app, base_url="http://essai") as c:
        yield c


def _jeton(client, chemin):
    m = re.search(r'name="_csrf" value="([^"]+)"', client.get(chemin).text)
    assert m, f"aucun jeton dans {chemin}"
    return m.group(1)


def test_les_liens_de_navigation_portent_le_prefixe(client_prefixe):
    r = client_prefixe.get("/arche/")
    assert r.status_code == 200
    assert 'href="/arche/reglages"' in r.text
    assert 'href="/arche/depot"' in r.text
    # Et surtout : aucun lien de navigation vers la racine nue.
    assert 'href="/reglages"' not in r.text
    assert 'href="/depot"' not in r.text or 'href="/arche/depot"' in r.text


@pytest.mark.parametrize(
    "action,chemin",
    [("majour", "/arche/depot/majour"),
     ("verifier", "/arche/depot/verifier"),
     ("nettoyer", "/arche/depot/nettoyer")],
)
def test_le_depot_redirige_sous_le_prefixe(client_prefixe, action, chemin):
    """Sans préfixe, la redirection mène à « /depot » — l'application qui
    occupe ce chemin — et à son écran de connexion."""
    jeton = _jeton(client_prefixe, "/arche/depot")
    r = client_prefixe.post(chemin, data={"_csrf": jeton}, follow_redirects=False)
    assert r.status_code == 303, r.status_code
    cible = r.headers["location"]
    assert cible.endswith("/arche/depot"), (
        f"redirection vers « {cible} » : le préfixe /arche est perdu, "
        "l'utilisateur atterrit sur FileBrowser"
    )


def test_l_annuaire_redirige_sous_le_prefixe(client_prefixe):
    """Même défaut, même correctif — il touchait aussi l'annuaire de crise."""
    jeton = _jeton(client_prefixe, "/arche/annuaire")
    r = client_prefixe.post("/arche/annuaire",
                            data={"_csrf": jeton, "nom_0": "", "role_0": "",
                                  "tel_0": "", "courriel_0": "", "note_0": ""},
                            follow_redirects=False)
    assert r.status_code == 303
    assert r.headers["location"].endswith("/arche/annuaire"), r.headers["location"]


def test_la_sonde_de_sante_redirige_sous_le_prefixe(client_prefixe):
    jeton = _jeton(client_prefixe, "/arche/sante")
    r = client_prefixe.post("/arche/sante", data={"_csrf": jeton},
                            follow_redirects=False)
    assert r.status_code == 303
    assert r.headers["location"].endswith("/arche/sante"), r.headers["location"]
