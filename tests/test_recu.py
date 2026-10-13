"""Le reçu déposé chez la production ne localise jamais l'arche.

L'arche s'éteint après sa nuit : son silence ne distingue pas « tout va bien »
de « elle ne s'est pas réveillée », et l'on peut l'ignorer des jours. Elle
dépose donc un reçu chez la production avant de s'éteindre, et c'est l'ABSENCE
de reçu qui devient le signal.

Ce que ces tests protègent, dans l'ordre d'importance :

1. le reçu ne nomme RIEN de l'arche — la production ne doit détenir ni adresse,
   ni nom, ni jeton la concernant ;
2. la construction est une LISTE BLANCHE : un champ ajouté demain à status.json
   ne doit pas partir tout seul ;
3. le garde-fou refuse l'envoi si une adresse ou un nom s'est glissé malgré
   tout — une fuite partirait sinon sans erreur, et personne ne relit un fichier
   déposé chez quelqu'un d'autre.
"""

import datetime
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

RACINE = Path(__file__).resolve().parent.parent
RECU = RACINE / "pra" / "pra_recu.sh"
VERIFIER = RACINE / "pra" / "pra_recu_verifier.sh"

# Une restauration d'il y a une heure : au-delà de 12 h, le reçu la déclare
# « non faite ». Des dates figées rendraient les tests faux dès le lendemain.
RECENT = (datetime.datetime.now().astimezone()
          - datetime.timedelta(hours=1)).isoformat(timespec="seconds")
ANCIEN = (datetime.datetime.now().astimezone()
          - datetime.timedelta(hours=30)).isoformat(timespec="seconds")

ETAT = {
    "horodatage": RECENT,
    "duree_s": 2460,
    "verdict": "succès",
    "etape": "terminé",
    "mode": "restauration",
    "archive": "20260910-000001",
    "applications": {"dex": "restaurée", "vaultwarden": "réparé", "moodle": "ÉCHEC"},
}
DOCKER = {
    "horodatage": RECENT,
    "verdict": "succès",
    "etape": "terminé",
    "piles": {"annuaire": "démarrée", "wiki": "démarrée", "notes": "ÉCHEC"},
}


def _etat(tmp_path, status=None, docker=None):
    d = tmp_path / "etat"
    d.mkdir(exist_ok=True)
    (d / "status.json").write_text(
        json.dumps(status if status is not None else ETAT, ensure_ascii=False),
        encoding="utf-8")
    (d / "docker-status.json").write_text(
        json.dumps(docker if docker is not None else DOCKER, ensure_ascii=False),
        encoding="utf-8")
    return d


def _montrer(tmp_path, mode="nocturne", code="0", status=None):
    """Exécute le VRAI script en mode inspection : le corps rendu est celui
    qui partirait sur le réseau, pas une reconstitution."""
    d = _etat(tmp_path, status=status)
    env = dict(os.environ,
               PRA_STATE_DIR=str(d),
               PRA_LOG=str(tmp_path / "journal.log"),
               PRA_RECU_MONTRER="1")
    r = subprocess.run(["bash", str(RECU), mode, code],
                       capture_output=True, text=True, env=env)
    return r


def test_le_recu_ne_nomme_rien_de_l_arche(tmp_path):
    r = _montrer(tmp_path)
    assert r.returncode == 0, r.stderr
    corps = r.stdout
    assert not re.search(r"\b(\d{1,3}\.){3}\d{1,3}\b", corps), "une adresse IP est partie"
    for interdit in (os.uname().nodename, "rssi", ".local", "/srv", "/var/lib", "token"):
        assert interdit.lower() not in corps.lower(), f"« {interdit} » est parti"


def test_la_liste_blanche_ne_laisse_pas_passer_un_champ_nouveau(tmp_path):
    # Le jour où quelqu'un ajoute un champ à status.json, il ne doit pas se
    # retrouver chez la production sans décision explicite. C'est la raison
    # d'être de la liste blanche, et sans ce test elle s'érode en silence.
    etat = dict(ETAT, chemin_local="/srv/pra/travail", adresse_arche="192.0.2.10")
    r = _montrer(tmp_path, status=etat)
    assert r.returncode == 0, r.stderr
    assert "chemin_local" not in r.stdout
    assert "adresse_arche" not in r.stdout
    assert "/srv/pra/travail" not in r.stdout


def test_le_recu_dit_ce_qui_a_echoue(tmp_path):
    d = json.loads(_montrer(tmp_path).stdout)
    assert d["applications"] == {"reussies": 2, "echouees": ["moodle"], "ignorees": []}
    assert d["piles_docker"] == {"reussies": 2, "echouees": ["notes"], "ignorees": []}
    assert d["archive"] == "20260910-000001"
    assert d["mode"] == "nocturne"


def test_un_echec_se_dit_aussi(tmp_path):
    # « J'ai échoué » vaut autant que « j'ai réussi » : dans les deux cas la
    # production apprend que l'arche s'est réveillée. Seule l'absence alerte.
    etat = dict(ETAT, verdict="échec", etape="vérification de l'empreinte")
    r = _montrer(tmp_path, mode="nocturne", code="1", status=etat)
    assert r.returncode == 0, r.stderr
    d = json.loads(r.stdout)
    assert d["verdict"] == "échec" and d["code"] == 1


def _refus(tmp_path, status):
    d = _etat(tmp_path, status=status)
    journal = tmp_path / "journal.log"
    env = dict(os.environ, PRA_STATE_DIR=str(d), PRA_LOG=str(journal),
               PRA_RECU_MONTRER="1")
    r = subprocess.run(["bash", str(RECU), "nocturne", "0"],
                       capture_output=True, text=True, env=env)
    return r, journal.read_text(encoding="utf-8") if journal.exists() else ""


def test_une_adresse_qui_se_glisse_bloque_l_envoi(tmp_path):
    r, journal = _refus(tmp_path, dict(ETAT, etape="échec du transfert depuis 192.0.2.20"))
    assert r.returncode != 0
    assert "REFUS" in journal and "adresse IP" in journal
    assert "192.0.2.20" not in r.stdout


def test_le_nom_de_la_machine_bloque_l_envoi(tmp_path):
    r, journal = _refus(tmp_path, dict(ETAT, etape="copie vers %s" % os.uname().nodename))
    assert r.returncode != 0
    assert "REFUS" in journal and "nom de la machine" in journal


def test_etat_absent_ne_fabrique_pas_un_faux_succes(tmp_path):
    # Aucun fichier d'état : le reçu doit dire « inconnu », jamais « succès ».
    vide = tmp_path / "vide"
    vide.mkdir()
    env = dict(os.environ, PRA_STATE_DIR=str(vide),
               PRA_LOG=str(tmp_path / "j.log"), PRA_RECU_MONTRER="1")
    r = subprocess.run(["bash", str(RECU), "nocturne", "0"],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout)["verdict"] == "inconnu"


# ── Côté production : c'est l'absence qui doit parler ────────────────────────

besoin_gnu = pytest.mark.skipif(
    sys.platform == "darwin" or not shutil.which("stat"),
    reason="« find -printf » et « stat -c » sont des outils GNU")


def _verifier(tmp_path, ages_heures):
    """Pose des reçus d'âges donnés et lance le VRAI vérificateur.
    Rend (code de retour, alertes reçues)."""
    recus = tmp_path / "recus"
    recus.mkdir(exist_ok=True)
    import time
    for i, (age_h, verdict) in enumerate(ages_heures):
        f = recus / ("2026091%d-020000.json" % i)
        f.write_text(json.dumps({
            "schema": 1, "verdict": verdict, "mode": "nocturne",
            "horodatage": "2026-09-10T02:51:14+02:00",
            "archive": "20260910-000001", "code": 0,
            "applications": {"reussies": 26, "echouees": []},
            "piles_docker": {"reussies": 6, "echouees": []},
        }, ensure_ascii=False), encoding="utf-8")
        quand = time.time() - age_h * 3600
        os.utime(f, (quand, quand))

    mouchard = tmp_path / "alertes.txt"
    faux_notify = tmp_path / "notify.sh"
    faux_notify.write_text(
        '#!/bin/bash\nprintf "%%s|%%s\\n" "$1" "$2" >> "%s"\n' % mouchard,
        encoding="utf-8")
    faux_notify.chmod(0o755)

    etat_json = tmp_path / "public" / "etat.json"
    env = dict(os.environ, PRA_RECU_DIR=str(recus),
               PRA_NOTIFY_BIN=str(faux_notify),
               PRA_ETAT_JSON=str(etat_json),
               PRA_RECU_LOG=str(tmp_path / "v.log"))
    r = subprocess.run(["bash", str(VERIFIER)], capture_output=True, text=True, env=env)
    alertes = mouchard.read_text(encoding="utf-8") if mouchard.exists() else ""
    publie = json.loads(etat_json.read_text(encoding="utf-8")) if etat_json.exists() else None
    return r.returncode, alertes, publie


@besoin_gnu
def test_un_recu_frais_et_reussi_ne_reveille_personne(tmp_path):
    code, alertes, _ = _verifier(tmp_path, [(2, "succès")])
    assert code == 0
    assert alertes == "", f"alerte injustifiée : {alertes}"


@besoin_gnu
def test_le_silence_alerte(tmp_path):
    # Le cas qui a manqué en août : l'arche muette depuis deux jours.
    code, alertes, _ = _verifier(tmp_path, [(50, "succès")])
    assert code != 0
    assert "silencieuse" in alertes


@besoin_gnu
def test_aucun_recu_du_tout_alerte(tmp_path):
    code, alertes, _ = _verifier(tmp_path, [])
    assert code != 0
    assert "aucun reçu" in alertes.lower()


@besoin_gnu
def test_un_echec_annonce_alerte(tmp_path):
    code, alertes, _ = _verifier(tmp_path, [(2, "échec")])
    assert code != 0
    assert "échec" in alertes


@besoin_gnu
def test_l_api_publique_ne_dit_que_deux_choses(tmp_path):
    """Sans jeton, chaque champ publié est un champ qu'on ne peut plus reprendre.
    L'API dit si l'arche est restaurée et depuis quand — rien d'autre."""
    code, _, publie = _verifier(tmp_path, [(2, "succès")])
    assert code == 0
    assert set(publie) == {"restauree", "derniere_restauration"}
    assert publie["restauree"] is True
    assert publie["derniere_restauration"] == "2026-09-10T02:51:14+02:00"


@besoin_gnu
def test_l_api_dit_non_quand_l_arche_est_muette(tmp_path):
    _, _, publie = _verifier(tmp_path, [(50, "succès")])
    assert publie["restauree"] is False


@besoin_gnu
def test_l_api_dit_non_sur_un_echec(tmp_path):
    _, _, publie = _verifier(tmp_path, [(2, "échec")])
    assert publie["restauree"] is False


@besoin_gnu
def test_publier_seul_n_alerte_pas(tmp_path):
    """Le passage des quinze minutes rafraîchit l'API sans réveiller personne :
    une alerte répétée tous les quarts d'heure cesse d'être lue."""
    recus = tmp_path / "recus"
    recus.mkdir()
    mouchard = tmp_path / "alertes.txt"
    notify = tmp_path / "notify.sh"
    notify.write_text('#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s"\n' % mouchard,
                      encoding="utf-8")
    notify.chmod(0o755)
    etat_json = tmp_path / "public" / "etat.json"
    env = dict(os.environ, PRA_RECU_DIR=str(recus), PRA_NOTIFY_BIN=str(notify),
               PRA_ETAT_JSON=str(etat_json), PRA_RECU_LOG=str(tmp_path / "v.log"))
    # Aucun reçu : le passage complet alerterait. Celui-ci ne doit pas.
    r = subprocess.run(["bash", str(VERIFIER), "--publier"],
                       capture_output=True, text=True, env=env)
    assert r.returncode == 0
    assert not mouchard.exists(), "le passage de publication a alerté"
    assert json.loads(etat_json.read_text())["restauree"] is False


# ── Le chemin de pra_notify.sh, et l'alerte qui ne part pas ──────────────────

def test_le_verificateur_cherche_pra_notify_la_ou_install_le_pose():
    """Il visait /usr/local/bin ; install.sh pose tout dans /usr/local/sbin. Sur
    la production, « [ -x ] » aurait été faux et CHAQUE alerte abandonnée."""
    install = (RACINE / "scripts" / "install.sh").read_text(encoding="utf-8")
    sbin = re.search(r'SBIN="\$\{ARCHE_SBIN:-([^}]+)\}"', install).group(1)
    verif = VERIFIER.read_text(encoding="utf-8")
    assert f'NOTIFY="${{PRA_NOTIFY_BIN:-{sbin}/pra_notify.sh}}"' in verif


@besoin_gnu
def test_une_alerte_impossible_a_envoyer_se_voit(tmp_path):
    """Aucun reçu → alerte due. pra_notify.sh absent → elle ne peut pas partir,
    et le journal doit le dire au lieu de se taire."""
    journal = tmp_path / "v.log"
    env = dict(os.environ, PRA_RECU_DIR=str(tmp_path / "rien"),
               PRA_NOTIFY_BIN=str(tmp_path / "absent.sh"),
               PRA_ETAT_JSON=str(tmp_path / "public" / "etat.json"),
               PRA_RECU_LOG=str(journal))
    r = subprocess.run(["bash", str(VERIFIER)], capture_output=True, text=True, env=env)
    assert r.returncode != 0
    assert "ALERTE NON ENVOYÉE" in journal.read_text(encoding="utf-8")


# ── Le classement sur les libellés RÉELS d'une nuit complète ───────────────

ETAT_REEL = {
    "horodatage": RECENT, "duree_s": 2071, "verdict": "succès", "etape": "terminé",
    "mode": "restauration", "archive": "20260914-000001",
    "applications": {
        "bookstack": "restaurée", "dex": "réparé (binaire arm64)",
        "dokuwiki": "absent de l'archive", "reverseproxy__8": "non couverte",
        "reverseproxy__9": "non couverte", "reverseproxy__10": "non couverte",
        "vaultwarden": "réparé (binaire arm64)", "moodle": "restaurée",
    },
}
DOCKER_REEL = {
    "horodatage": RECENT, "verdict": "succès", "etape": "terminé",
    "piles": {
        "notes": "démarrée", "notes-db": "restaurée (46 tables)",
        "annuaire": "démarrée", "annuaire-db": "restaurée (110 tables)",
        "wiki-db": "restaurée (38 tables)", "uptime-kuma": "démarrée",
    },
}


def _montrer_etats(tmp_path, status, docker, mode="nocturne", code="0"):
    d = tmp_path / "etat"
    d.mkdir(exist_ok=True)
    (d / "status.json").write_text(json.dumps(status, ensure_ascii=False), encoding="utf-8")
    (d / "docker-status.json").write_text(json.dumps(docker, ensure_ascii=False), encoding="utf-8")
    env = dict(os.environ, PRA_STATE_DIR=str(d), PRA_LOG=str(tmp_path / "j.log"),
               PRA_RECU_MONTRER="1")
    r = subprocess.run(["bash", str(RECU), mode, code], capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stderr
    return json.loads(r.stdout)


def test_la_nuit_reelle_du_14_septembre_n_a_aucun_echec(tmp_path):
    """La première version y voyait 4 applications et 3 piles en échec : la
    production aurait crié « incomplète » chaque matin."""
    d = _montrer_etats(tmp_path, ETAT_REEL, DOCKER_REEL)
    assert d["verdict"] == "succès"
    assert d["applications"]["echouees"] == []
    assert d["applications"]["ignorees"] == [
        "dokuwiki", "reverseproxy__10", "reverseproxy__8", "reverseproxy__9"]
    assert d["applications"]["reussies"] == 4
    assert d["piles_docker"]["echouees"] == []
    assert d["piles_docker"]["reussies"] == 6


def test_les_marques_d_echec_des_scripts_sont_reconnues(tmp_path):
    etat = dict(ETAT_REEL, applications={"moodle": "ÉCHEC", "dex": "restaurée"})
    dock = dict(DOCKER_REEL, piles={
        "wiki": "INJOIGNABLE (port 8076 : 502)",
        "annuaire": "DÉMARRAGE INCOMPLET : app",
        "notes-db": "conteneur absent",
        "annuaire-db": "ÉCHEC connexion",
        "tableau": "démarrée",
    })
    d = _montrer_etats(tmp_path, etat, dock)
    assert d["applications"]["echouees"] == ["moodle"]
    assert d["piles_docker"]["echouees"] == ["annuaire", "annuaire-db", "notes-db", "wiki"]
    assert d["piles_docker"]["reussies"] == 1


def test_un_etat_de_la_veille_n_est_pas_une_restauration_de_cette_nuit(tmp_path):
    """Nocturne arrêté avant de restaurer : status.json est celui de la veille.
    Le reçu disait « succès » — l'API aurait publié « restaurée »."""
    d = _montrer_etats(tmp_path, dict(ETAT_REEL, horodatage=ANCIEN),
                       dict(DOCKER_REEL, horodatage=ANCIEN))
    assert d["verdict"] == "non_faite"
    assert d["horodatage"] == ANCIEN, "la date doit rester celle de la dernière vraie restauration"
    assert d["applications"]["a_jour"] is False
    assert d["piles_docker"]["a_jour"] is False
    assert d["archive"] == ""


def test_la_date_est_celle_de_la_restauration_pas_du_depot(tmp_path):
    d = _montrer_etats(tmp_path, ETAT_REEL, DOCKER_REEL)
    assert d["horodatage"] == RECENT
    assert d["depose_le"] != RECENT


def test_un_volet_docker_perime_ne_prete_pas_ses_resultats(tmp_path):
    """YunoHost restauré cette nuit, Docker non : les piles de la veille ne
    doivent pas passer pour celles de cette nuit."""
    d = _montrer_etats(tmp_path, ETAT_REEL, dict(DOCKER_REEL, horodatage=ANCIEN))
    assert d["verdict"] == "succès"
    assert d["piles_docker"]["a_jour"] is False


@besoin_gnu
def test_partiel_n_est_ni_un_succes_ni_une_panne(tmp_path):
    code, alertes, publie = _verifier(tmp_path, [(2, "partiel")])
    assert code != 0
    assert publie["restauree"] is False
    assert alertes, "un verdict partiel doit prévenir"


@besoin_gnu
def test_non_faite_publie_non_restauree(tmp_path):
    code, _, publie = _verifier(tmp_path, [(2, "non_faite")])
    assert code != 0
    assert publie["restauree"] is False
