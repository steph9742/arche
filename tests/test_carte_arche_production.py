"""Sur la production, voir si l'arche a restauré — sans aller la chercher.

La question vient toujours de la production : « où est-ce que je vois que le
réplica a bien restauré ? ». Les reçus, l'API publique et l'alerte peuvent
exister sans que la webapp de la production n'en montre rien — il faut alors
aller lire des fichiers en root.

Ce que ces tests protègent :
  — la carte affiche la DÉCISION du vérificateur (recu-etat.json), jamais une
    seconde lecture des reçus qui pourrait diverger de l'alerte et de l'API ;
  — un état autre que « restaurée » remonte dans « À traiter », motif compris ;
  — rien de tout cela n'apparaît côté arche, qui n'a pas de reçus à lire ;
  — l'état privé porte les noms, que l'API publique ne dira jamais.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

RACINE = Path(__file__).resolve().parent.parent
VERIFIER = RACINE / "pra" / "pra_recu_verifier.sh"


def _etat(recu):
    return {"archives": [], "instantanes": [], "services_morts": [],
            "restauration_en_cours": False, "sauvegarde_en_cours": False,
            "canaris_configures": True, "recu": recu}


RESTAUREE = {
    "etat": "vivante", "motif": "", "verdict": "succès", "mode": "nocturne",
    "archive": "20260915-000001", "derniere_restauration": "2026-09-15T02:46:59+02:00",
    "age_heures": 6, "seuil_heures": 26, "recu": "20260915-025017.json",
    "applications_en_echec": [], "applications_ignorees": ["reverseproxy__8"],
    "piles_en_echec": [], "controle_le": "2026-09-15T09:00:00+02:00",
}


def _page(client, monkeypatch, recu):
    import app.helper.client as helper
    monkeypatch.setattr(helper, "etat", lambda: _etat(recu))
    r = client.get("/")
    assert r.status_code == 200
    return r.text


def test_la_carte_dit_restauree_et_depuis_quand(client_production, monkeypatch):
    page = _page(client_production, monkeypatch, RESTAUREE)
    assert "Arche : dernière restauration" in page
    assert "Restaurée" in page
    assert "2026-09-15 à 02:46" in page
    assert "20260915-000001" in page
    assert "il y a 6 h" in page
    # Un choix n'est pas un échec : il est montré, mais à part.
    assert "Non restaurées, par choix" in page and "reverseproxy__8" in page
    assert "Applications en échec" not in page


def test_une_arche_muette_remonte_dans_a_traiter(client_production, monkeypatch):
    muette = dict(RESTAUREE, etat="silencieuse", age_heures=50,
                  motif="Dernier reçu : 20260913-025017.json (50 h), seuil 26 h.")
    page = _page(client_production, monkeypatch, muette)
    assert "Silencieuse" in page
    assert "À traiter" in page
    assert "Arche : Silencieuse — Dernier reçu : 20260913-025017.json (50 h)" in page


def test_les_echecs_sont_nommes(client_production, monkeypatch):
    incomplete = dict(RESTAUREE, etat="incomplete", applications_en_echec=["moodle"],
                      piles_en_echec=["wiki"], motif="Archive 20260915-000001 : …")
    page = _page(client_production, monkeypatch, incomplete)
    assert "Incomplète" in page
    assert "Applications en échec" in page and "moodle" in page
    assert "Piles Docker en échec" in page and "wiki" in page


def test_sans_etat_la_carte_le_dit(client_production, monkeypatch):
    page = _page(client_production, monkeypatch, None)
    assert "Arche : dernière restauration" in page
    assert "pas encore tourné" in page


def test_rien_cote_arche(client, monkeypatch):
    page = _page(client, monkeypatch, RESTAUREE)
    assert "Arche : dernière restauration" not in page


def _journal(client, monkeypatch, quoi):
    import app.helper.client as helper
    monkeypatch.setattr(helper, "journal", lambda q, n=200: {
        "lignes": ["[2026-09-15 08:00:00] OK — reçu de 5 h"], "fichier": "/var/log/pra_recus.log"})
    r = client.get(f"/journal/{quoi}")
    assert r.status_code == 200
    return r.text


def test_l_onglet_des_recus_existe_cote_production(client_production, monkeypatch):
    page = _journal(client_production, monkeypatch, "recus")
    assert "Reçus de l&#39;arche" in page or "Reçus de l'arche" in page


def test_pas_d_onglet_des_recus_cote_arche(client, monkeypatch):
    page = _journal(client, monkeypatch, "nightly")
    assert "Reçus de l" not in page


def test_le_helper_autorise_le_journal_et_expose_l_etat():
    src = (RACINE / "helper" / "arche-helper").read_text(encoding="utf-8")
    assert '"recus": Path("/var/log/pra_recus.log")' in src
    assert '"recu": _json_si_possible(ETAT_DIR / "recu-etat.json")' in src
    # Le vérificateur écrit là où le helper lit.
    verif = VERIFIER.read_text(encoding="utf-8")
    assert 'PRA_RECU_ETAT_PRIVE:-/var/lib/pra/recu-etat.json' in verif


besoin_gnu = pytest.mark.skipif(sys.platform == "darwin",
                                reason="« find -printf » et « stat -c » sont des outils GNU")


@besoin_gnu
def test_l_etat_prive_porte_la_decision_et_les_noms(tmp_path):
    """Exécute le VRAI vérificateur : l'état privé doit dire la même chose que
    l'API publique, avec en plus ce que celle-ci ne dira jamais."""
    recus = tmp_path / "recus"
    recus.mkdir()
    recu = recus / "20260915-025017.json"
    recu.write_text(json.dumps({
        "schema": 2, "verdict": "succès", "mode": "nocturne",
        "horodatage": "2026-09-15T02:46:59+02:00", "archive": "20260915-000001",
        "applications": {"reussies": 20, "echouees": ["moodle"], "ignorees": ["reverseproxy__8"]},
        "piles_docker": {"reussies": 6, "echouees": [], "ignorees": []},
    }), encoding="utf-8")
    quand = time.time() - 2 * 3600
    os.utime(recu, (quand, quand))

    prive = tmp_path / "prive" / "recu-etat.json"
    public = tmp_path / "public" / "etat.json"
    env = dict(os.environ, PRA_RECU_DIR=str(recus), PRA_ETAT_JSON=str(public),
               PRA_RECU_ETAT_PRIVE=str(prive), PRA_NOTIFY_BIN=str(tmp_path / "absent"),
               PRA_RECU_LOG=str(tmp_path / "v.log"))
    subprocess.run(["bash", str(VERIFIER), "--publier"], capture_output=True, text=True, env=env)

    d = json.loads(prive.read_text(encoding="utf-8"))
    assert d["etat"] == "incomplete"
    assert d["applications_en_echec"] == ["moodle"]
    assert d["applications_ignorees"] == ["reverseproxy__8"]
    assert d["derniere_restauration"] == "2026-09-15T02:46:59+02:00"
    assert d["recu"] == "20260915-025017.json"
    assert d["motif"]
    assert oct(prive.stat().st_mode)[-3:] == "640"
    # Et l'API publique, elle, n'en dit que deux choses — la même décision.
    p = json.loads(public.read_text(encoding="utf-8"))
    assert p == {"restauree": False, "derniere_restauration": "2026-09-15T02:46:59+02:00"}
