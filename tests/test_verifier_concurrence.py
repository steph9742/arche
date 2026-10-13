"""Deux passages du vérificateur en même temps ne se marchent plus dessus.

La production journalise « publication impossible » et « état détaillé
impossible » dès que deux passages se croisent : la planification lance
« --publier » tous les quarts d'heure ET le passage complet à heure fixe. Ils
démarrent alors à la même seconde et écrivent les MÊMES fichiers temporaires —
le second trouve le sien renommé par l'autre.

Ces tests rejouent la collision avec le VRAI script : un verrou sérialise les
passages, les temporaires ont des noms uniques, et quand une écriture échoue
vraiment, sa cause est écrite au lieu d'être avalée par « 2>/dev/null ».
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
SOURCE = VERIFIER.read_text(encoding="utf-8")

besoin_gnu = pytest.mark.skipif(sys.platform == "darwin",
                                reason="« find -printf », « stat -c » et flock sont des outils GNU")


def test_le_verrou_precede_toute_ecriture():
    assert "flock -w 60 9" in SOURCE
    assert SOURCE.index("flock -w 60 9") < SOURCE.index("publier() {")


def test_plus_aucun_temporaire_a_nom_fixe():
    assert '.tmp"' not in SOURCE
    assert SOURCE.count('mktemp "$ETAT_JSON.XXXXXX"') == 1
    assert SOURCE.count('mktemp "$ETAT_PRIVE.XXXXXX"') == 1


def _environnement(tmp_path):
    recus = tmp_path / "recus"
    recus.mkdir()
    recu = recus / "20260915-025017.json"
    recu.write_text(json.dumps({
        "schema": 2, "verdict": "succès", "mode": "nocturne",
        "horodatage": "2026-09-15T02:46:59+02:00", "archive": "20260915-000001",
        "applications": {"reussies": 21, "echouees": [], "ignorees": []},
        "piles_docker": {"reussies": 6, "echouees": [], "ignorees": []},
    }), encoding="utf-8")
    quand = time.time() - 5 * 3600
    os.utime(recu, (quand, quand))
    notify = tmp_path / "notify.sh"
    notify.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
    notify.chmod(0o755)
    return dict(os.environ,
                PRA_RECU_DIR=str(recus),
                PRA_ETAT_JSON=str(tmp_path / "public" / "etat.json"),
                PRA_RECU_ETAT_PRIVE=str(tmp_path / "prive" / "recu-etat.json"),
                PRA_RECU_VERROU=str(tmp_path / "verrou"),
                PRA_NOTIFY_BIN=str(notify),
                PRA_RECU_LOG=str(tmp_path / "v.log"))


@besoin_gnu
def test_la_collision_de_08h00_ne_produit_plus_d_echec(tmp_path):
    """Vingt paires lancées ensemble — le passage des quinze minutes et celui de
    08:00 — sur les mêmes fichiers. Aucune écriture ne doit échouer, et ce qui
    reste publié doit être du JSON entier."""
    env = _environnement(tmp_path)
    processus = []
    for _ in range(20):
        processus.append(subprocess.Popen(["bash", str(VERIFIER), "--publier"], env=env,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        processus.append(subprocess.Popen(["bash", str(VERIFIER)], env=env,
                                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
    for p in processus:
        p.wait(timeout=120)

    journal = Path(env["PRA_RECU_LOG"]).read_text(encoding="utf-8")
    assert "impossible" not in journal, journal
    assert json.loads(Path(env["PRA_ETAT_JSON"]).read_text()) == {
        "restauree": True, "derniere_restauration": "2026-09-15T02:46:59+02:00"}
    assert json.loads(Path(env["PRA_RECU_ETAT_PRIVE"]).read_text())["etat"] == "vivante"
    # Aucun temporaire abandonné à côté des fichiers publiés.
    for d in (Path(env["PRA_ETAT_JSON"]).parent, Path(env["PRA_RECU_ETAT_PRIVE"]).parent):
        restes = [p.name for p in d.iterdir() if p.name not in ("etat.json", "recu-etat.json")]
        assert restes == [], restes


@besoin_gnu
def test_une_ecriture_impossible_dit_pourquoi(tmp_path):
    """Un répertoire de publication qui est en réalité un FICHIER : même root ne
    peut pas y créer etat.json. Le journal doit porter la cause, pas seulement
    le mot « impossible »."""
    env = _environnement(tmp_path)
    obstacle = tmp_path / "obstacle"
    obstacle.write_text("je suis un fichier", encoding="utf-8")
    env["PRA_ETAT_JSON"] = str(obstacle / "etat.json")
    subprocess.run(["bash", str(VERIFIER), "--publier"], env=env, capture_output=True, text=True)
    journal = Path(env["PRA_RECU_LOG"]).read_text(encoding="utf-8")
    ligne = next(l for l in journal.splitlines() if "publication impossible" in l)
    assert " : " in ligne.split("etat.json", 1)[1], f"cause absente : {ligne}"
    assert "mkdir" in ligne or "Not a directory" in ligne or "n'est pas un répertoire" in ligne
