"""La réécriture de pra.conf ne détruit plus ce que le schéma ignore.

Le fichier est régénéré en entier à chaque enregistrement depuis la webapp.
Sans précaution, toute ligne hors schéma disparaît silencieusement : un jeton
posé à la main s'efface et ne se signale que par plusieurs nuits d'« absent ».
Les clés connues sont déclarées au schéma ; ces tests verrouillent en plus la
CLASSE : une affectation inconnue est reconduite telle quelle, indéfiniment.
"""

import sys
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RACINE))

from app.praconf import (  # noqa: E402
    PAR_CLE, SECRETS, ValeurInvalide, lire, lire_hors_schema, rendre, valider,
)


def _conf(tmp_path, contenu: str) -> Path:
    chemin = tmp_path / "pra.conf"
    chemin.write_text(contenu, encoding="utf-8")
    return chemin


def test_les_affectations_inconnues_sont_relues(tmp_path):
    chemin = _conf(tmp_path, "\n".join([
        "# commentaire",
        ': "${PRA_GFS_JOURS:=4}"',            # clé du schéma : pas hors schéma
        "PRA_CLE_POSEE_A_LA_MAIN=valeur",     # les trois formes d'affectation
        'AUTRE_CLE="entre guillemets"',
        ': "${TROISIEME:=idiome}"',
        "",
        "echo je ne suis pas une affectation",   # jamais reconduit tel quel
    ]))
    assert lire_hors_schema(chemin) == [
        "PRA_CLE_POSEE_A_LA_MAIN=valeur",
        'AUTRE_CLE="entre guillemets"',
        ': "${TROISIEME:=idiome}"',
    ]


def test_rendre_reconduit_et_reste_idempotent(tmp_path):
    hors = ["PRA_CLE_POSEE_A_LA_MAIN=valeur"]
    contenu = rendre({"PRA_GFS_JOURS": "4"}, hors)
    chemin = _conf(tmp_path, contenu)
    # La ligne survit, le schéma se relit, et une seconde réécriture
    # reconduirait la même chose : rien ne s'érode d'un enregistrement à l'autre.
    assert lire(chemin)["PRA_GFS_JOURS"] == "4"
    assert lire_hors_schema(chemin) == hors
    assert lire_hors_schema(_conf(tmp_path, rendre(lire(chemin), hors))) == hors


def test_sans_hors_schema_rien_ne_change(tmp_path):
    contenu = rendre({"PRA_GFS_JOURS": "4"})
    assert "Hors schéma" not in contenu
    assert lire_hors_schema(_conf(tmp_path, contenu)) == []


def test_lire_accepte_les_trois_formes(tmp_path):
    # La forme sans guillemets est celle d'un ajout manuel pressé, un
    # « echo CLE=valeur >> … » en pleine nuit.
    chemin = _conf(tmp_path, "\n".join([
        "PRA_WAKE_AT=09:00",
        'PRA_GFS_LUNDIS="2"',
        ': "${PRA_GFS_JOURS:=4}"',
    ]))
    valeurs = lire(chemin)
    assert valeurs["PRA_WAKE_AT"] == "09:00"
    assert valeurs["PRA_GFS_LUNDIS"] == "2"
    assert valeurs["PRA_GFS_JOURS"] == "4"


def test_wake_at_et_jeton_sont_au_schema():
    # Les clés qui vivaient hors schéma sont déclarées : visibles dans
    # l'interface, validées, et écrites comme n'importe quel réglage.
    assert "PRA_WAKE_AT" in PAR_CLE
    assert "PRA_FORGEJO_TOKEN" in PAR_CLE
    assert "PRA_FORGEJO_TOKEN" in SECRETS       # jamais réaffiché en clair
    assert valider({"PRA_WAKE_AT": "09:00"})["PRA_WAKE_AT"] == "09:00"
    for invalide in ("25:00", "9h", "09:60", "bientôt"):
        try:
            valider({"PRA_WAKE_AT": invalide})
        except ValeurInvalide:
            continue
        raise AssertionError(f"« {invalide} » aurait dû être refusé")
