"""Bancs d'essai : la webapp est montée avec un FAUX helper.

Le vrai helper exige root et touche /etc/pra : inutilisable en test. On le
remplace par un script qui rend du JSON canné, ce qui permet d'éprouver toute la
chaîne — formulaire, validation, appel, rendu — sans privilège.
"""
from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path

import pytest

RACINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RACINE))

FAUX_HELPER = r'''#!/usr/bin/env python3
import json, sys, pathlib
memoire = pathlib.Path(__import__("os").environ["FAUX_MEMOIRE"])
cmd = sys.argv[1] if len(sys.argv) > 1 else ""
if cmd == "depot-etat":
    print(json.dumps({
        "parties": [
            {"libelle": "Images d'amorçage", "chemin": "iso", "octets": 24_100_000_000, "fichiers": 14},
            {"libelle": "Documentation hors ligne", "chemin": "documentation", "octets": 900_000_000, "fichiers": 812},
            {"libelle": "Archives Kiwix", "chemin": "iso/kiwix", "octets": 2_100_000_000, "fichiers": 7},
            {"libelle": "Outils", "chemin": "outils", "octets": 300_000_000, "fichiers": 11},
        ],
        "manuels_url": "http://192.0.2.10:8080/manuels/",
        "total_octets": 27_400_000_000,
        "libre_octets": 598_000_000_000,
        "manifeste": "2026-07-29T16:52:00",
        "en_cours": False,
        "journal": ["Debian 13 amd64 DVD-1 — vérifié", "Terminé : 28 réussis, 0 en échec"],
    }))
elif cmd == "depot-verifier":
    print(json.dumps({"ok": True, "a_jour": ["Debian 13 amd64 netinst", "Kali Linux Live"],
                      "a_renouveler": ["Ubuntu Server 24.04 LTS"], "absents": ["Fedora Server"]}))
elif cmd == "depot-majour":
    print(json.dumps({"ok": True, "pid": 4242}))
elif cmd == "depot-nettoyer":
    print(json.dumps({"ok": True, "sortie": ["2 fichier(s) supprimé(s)"]}))
elif cmd == "depot-etat":
    print(json.dumps({
        "parties": [
            {"libelle": "Images d'amorcage", "chemin": "iso", "octets": 24_100_000_000, "fichiers": 14},
            {"libelle": "Documentation hors ligne", "chemin": "documentation", "octets": 900_000_000, "fichiers": 812},
            {"libelle": "Archives Kiwix", "chemin": "iso/kiwix", "octets": 2_100_000_000, "fichiers": 7},
            {"libelle": "Outils", "chemin": "outils", "octets": 300_000_000, "fichiers": 11},
        ],
        "total_octets": 27_400_000_000,
        "libre_octets": 598_000_000_000,
        "manifeste": "2026-07-29T16:52:00",
        "en_cours": False,
        "journal": ["Debian 13 amd64 DVD-1 verifie", "Termine : 28 reussis, 0 en echec"],
    }))
elif cmd == "depot-verifier":
    print(json.dumps({"ok": True, "a_jour": ["Debian 13 amd64 netinst", "Kali Linux Live"],
                      "a_renouveler": ["Ubuntu Server 24.04 LTS"], "absents": ["Fedora Server"]}))
elif cmd == "depot-majour":
    print(json.dumps({"ok": True, "pid": 4242}))
elif cmd == "depot-nettoyer":
    print(json.dumps({"ok": True, "sortie": ["2 fichier(s) supprime(s)"]}))
elif cmd == "etat":
    print(json.dumps({"yunohost": {"verdict": "succès", "horodatage": "2026-07-27T02:15:00",
                                   # Le nom porte l'horodatage des DONNEES, qui
                                   # n'est pas celui de la restauration : c'est
                                   # tout l'objet de la tuile « age des donnees ».
                                   "archive": "20260727-000001",
                                   "applications": {"nextcloud": "restaurée"}},
                      "docker": {"verdict": "partiel", "horodatage": "2026-07-27T03:01:00",
                                 "piles": {"wiki": "ÉCHEC de construction"}},
                      "archives": [{"nom": "20260727-000001.tar", "taille": 12884901888,
                                    "date": "2026-07-27 02:10", "jour": "20260727"}],
                      # Liste SEPAREE : meler les deux familles faisait proposer un
                      # instantane Docker dans le selecteur d'archive YunoHost, ou
                      # la validation le rejette toujours.
                      "instantanes": [{"nom": "20260727-docker.tar", "taille": 27262976,
                                       "date": "2026-07-27 01:00", "jour": "20260727"}],
                      "services_morts": [], "restauration_en_cours": False,
                      "canaris_configures": False, "timer": "active",
                      # ACTIVE mais DÉSACTIVÉE : le piège classique. Le faux
                      # helper le reproduit pour que le test constate que
                      # l'alerte sort — l'ancienne version ne regardait que
                      # « active » et se taisait sur ce cas.
                      "timer_enable": "disabled",
                      "prochain_reveil": "2026-07-28 02:00"}))
elif cmd == "sante":
    # Le vrai helper ECRIT sur disque et ne renvoie qu'un accuse : une charge de
    # 3,9 ko ne tient pas dans un cookie de session. On imite l'ETAT, sinon le
    # test ne peut pas distinguer « pas encore sonde » de « sonde ».
    memoire.with_suffix(".sante").write_text("fait")
    print(json.dumps({"ok": True, "horodatage": "2026-07-30 16:42:11",
                      "applications": 4, "piles": 3}))
elif cmd == "sante-lire":
    if not memoire.with_suffix(".sante").exists():
        print(json.dumps({})); sys.exit(0)   # aucune mesure : le fichier n'existe pas
    print(json.dumps({
        "horodatage": "2026-07-30 16:42:11",
        "applications": [
            {"id": "wiki-proxy", "nom": "Incidents", "url": "https://wiki.local/",
             "code": "502", "verdict": "passerelle"},
            {"id": "kiwix", "nom": "Kiwix", "url": "https://kiwix.local/",
             "code": "000", "verdict": "injoignable"},
            {"id": "nextcloud", "nom": "Nextcloud", "url": "https://replica.local/nextcloud/",
             "code": "302", "verdict": "ok"},
            {"id": "vaultwarden", "nom": "Vaultwarden", "url": "https://replica.local/vaultwarden/",
             "code": "200", "verdict": "ok"},
            # dex sondé AILLEURS qu'à sa racine : nginx sert des fichiers
            # statiques devant lui, donc « / » rend 200 même service arrêté.
            {"id": "dex", "nom": "dex", "url": "https://replica.local/dex/",
             "sonde": "https://replica.local/dex/.well-known/openid-configuration",
             "code": "502", "verdict": "passerelle"},
        ],
        "piles": [
            {"nom": "wiki", "port": "8076", "mandataire": "reverse",
             "code": "502", "verdict": "passerelle"},
            {"nom": "annuaire", "port": "8077", "mandataire": "reverse",
             "code": "404", "verdict": "anomalie"},
            {"nom": "uptime-kuma", "port": None, "mandataire": None,
             "code": None, "verdict": "non sondable"},
        ],
    }))
elif cmd == "conf-lire":
    d = json.loads(memoire.read_text()) if memoire.exists() else {}
    # Le VRAI helper MASQUE les secrets et annonce lesquels sont renseignés. Un
    # faux qui renvoie les valeurs en clair et une liste vide ne peut pas révéler
    # les bogues du chemin « secret masqué » — c'est ce trou qui a laissé passer
    # le refus « les alertes Talk exigent les trois valeurs ».
    sys.path.insert(0, __import__("os").environ["FAUX_RACINE"])
    from app.praconf import SECRETS
    masquees = {c: ("●●●●●●●●" if c in SECRETS and v else v) for c, v in d.items()}
    print(json.dumps({"valeurs": masquees,
                      "secrets_definis": sorted(c for c in SECRETS if d.get(c))}))
elif cmd == "conf-ecrire":
    charge = json.load(sys.stdin)
    # Le VRAI helper revalide ici. On imite ce contrat : on refuse ce que la
    # validation refuserait, pour que le test prouve la défense en profondeur.
    sys.path.insert(0, __import__("os").environ["FAUX_RACINE"])
    from app.praconf import valider, rendre, ValeurInvalide
    try:
        propre = valider(charge["valeurs"])
        # On appelle RENDRE aussi, comme le vrai helper : sans cela le chemin
        # d'écriture n'est jamais éprouvé. C'est précisément ce trou qui a laissé
        # passer une erreur de dépaquetage de GROUPES.
        rendre(propre)
    except ValeurInvalide as e:
        print(json.dumps({"erreur": str(e)})); sys.exit(1)
    memoire.write_text(json.dumps(propre))
    print(json.dumps({"ok": True, "reglages": len(propre)}))
elif cmd == "journal":
    print(json.dumps({"lignes": ["[2026-07-27 02:10] ATTENTION  essai",
                                 "[2026-07-27 02:11] ÉCHEC  essai"],
                      "fichier": "/var/log/pra_nightly.log", "absent": False}))
elif cmd == "apps":
    print(json.dumps({"apps": [{"id": "nextcloud", "nom": "Nextcloud"},
                               {"id": "vaultwarden", "nom": "Vaultwarden"},
                               {"id": "cyberchef", "nom": "CyberChef"}]}))
elif cmd == "cibles":
    print(json.dumps({
        "applications": [{"id": "nextcloud", "vue_hier": True},
                         {"id": "vaultwarden", "vue_hier": True},
                         {"id": "moodle", "vue_hier": False}],
        "piles": [{"id": "notes"}, {"id": "wiki"}],
        "horodatage_yunohost": "2026-07-28T02:15:00",
        "horodatage_docker": "2026-07-28T03:01:00"}))
elif cmd == "tracer":
    # Le VRAI helper filtre : il écarte tout caractère de contrôle — sauts de
    # ligne et tabulations, qui falsifieraient la mise en forme du journal — mais
    # CONSERVE les accents. Un faux qui écrit la trace brute ne peut prouver ni
    # l'un ni l'autre : c'est ainsi que « rglages enregistrs » a pu passer.
    def _propre(valeur, maxi, espaces):
        gardés = [c for c in (valeur or "") if c.isprintable() and (espaces or not c.isspace())]
        texte = "".join(gardés)
        return texte[: maxi - 12] + " …(tronqué)" if len(texte) > maxi else texte
    trace = memoire.with_suffix(".audit")
    with open(trace, "a", encoding="utf-8") as f:
        f.write(_propre(sys.argv[2], 64, False) + "\t" + _propre(sys.argv[3], 1024, True) + "\n")
    print(json.dumps({"ok": True}))
elif cmd == "canaris":
    print(json.dumps({"ok": True, "sortie": "3 canari(s) intact(s), 0 en défaut"}))
elif cmd == "tester-alerte":
    print(json.dumps({"ok": True, "detail": "notification transmise (HTTP 201)"}))
elif cmd == "sauvegarder":
    print(json.dumps({"ok": True, "pid": 4243,
                      "avec_docker": "--sans-docker" not in sys.argv}))
elif cmd == "restaurer":
    # Le faux helper doit RENVOYER les options reçues : c'est ce que l'interface
    # affiche, et un faux helper qui les avale rendrait le test aveugle au bogue
    # qu'il est censé attraper.
    print(json.dumps({
        "ok": True, "pid": 4242,
        "mode": "validation" if "--valider" in sys.argv else "réelle",
        "halt": "--halt" in sys.argv,
        "sans_controles": "--sans-controles" in sys.argv,
        "sans_transfert": "--sans-transfert" in sys.argv,
        "avec_docker": "--valider" not in sys.argv and "--sans-docker" not in sys.argv,
    }))
else:
    print(json.dumps({"erreur": "commande inconnue"})); sys.exit(1)
'''


@pytest.fixture()
def client(tmp_path, monkeypatch):
    helper = tmp_path / "faux-helper"
    helper.write_text(FAUX_HELPER)
    helper.chmod(helper.stat().st_mode | stat.S_IEXEC)
    memoire = tmp_path / "conf.json"

    monkeypatch.setenv("ARCHE_HELPER", str(helper))
    monkeypatch.setenv("ARCHE_SUDO", "")          # pas de sudo en test
    monkeypatch.setenv("ARCHE_AUTH_MODE", "proxy")  # accès direct, pas de login
    monkeypatch.setenv("ARCHE_SESSION_SECRET", "essai")
    monkeypatch.setenv("FAUX_MEMOIRE", str(memoire))
    monkeypatch.setenv("FAUX_RACINE", str(RACINE))

    for module in [m for m in list(sys.modules) if m.startswith("app")]:
        del sys.modules[module]
    from app.config import get_settings
    get_settings.cache_clear()

    from fastapi.testclient import TestClient
    from app.main import app

    c = TestClient(app)
    c.audit = memoire.with_suffix(".audit")
    return c


@pytest.fixture()
def client_password(tmp_path, monkeypatch):
    """Instance en mode « password » : éprouve l'accès de secours et la
    redirection des pages protégées, que le mode « proxy » court-circuite."""
    helper = tmp_path / "faux-helper"
    helper.write_text(FAUX_HELPER)
    helper.chmod(helper.stat().st_mode | stat.S_IEXEC)

    monkeypatch.setenv("ARCHE_HELPER", str(helper))
    monkeypatch.setenv("ARCHE_SUDO", "")
    monkeypatch.setenv("ARCHE_AUTH_MODE", "password")
    monkeypatch.setenv("ARCHE_SESSION_SECRET", "essai")
    monkeypatch.setenv("FAUX_MEMOIRE", str(tmp_path / "conf.json"))
    monkeypatch.setenv("FAUX_RACINE", str(RACINE))

    for module in [m for m in list(sys.modules) if m.startswith("app")]:
        del sys.modules[module]
    from app.security import hash_password
    monkeypatch.setenv("ARCHE_ADMIN_PASSWORD_HASH", hash_password("sesame-de-test"))

    for module in [m for m in list(sys.modules) if m.startswith("app")]:
        del sys.modules[module]
    from app.config import get_settings
    get_settings.cache_clear()

    from fastapi.testclient import TestClient
    from app.main import app

    return TestClient(app)


@pytest.fixture()
def client_production(tmp_path, monkeypatch):
    """Instance en rôle « production » : mêmes code et helper, autre périmètre."""
    helper = tmp_path / "faux-helper"
    helper.write_text(FAUX_HELPER)
    helper.chmod(helper.stat().st_mode | stat.S_IEXEC)

    monkeypatch.setenv("ARCHE_HELPER", str(helper))
    monkeypatch.setenv("ARCHE_SUDO", "")
    monkeypatch.setenv("ARCHE_AUTH_MODE", "proxy")
    monkeypatch.setenv("ARCHE_ROLE", "production")
    monkeypatch.setenv("ARCHE_SESSION_SECRET", "essai")
    monkeypatch.setenv("FAUX_MEMOIRE", str(tmp_path / "conf.json"))
    monkeypatch.setenv("FAUX_RACINE", str(RACINE))

    for module in [m for m in list(sys.modules) if m.startswith("app")]:
        del sys.modules[module]
    from app.config import get_settings
    get_settings.cache_clear()

    from fastapi.testclient import TestClient
    from app.main import app

    c = TestClient(app)
    # Même contrat que la fixture « client » : les tests d'audit doivent pouvoir
    # relire ce que le helper a consigné, dans les deux rôles.
    c.audit = (tmp_path / "conf.json").with_suffix(".audit")
    return c
