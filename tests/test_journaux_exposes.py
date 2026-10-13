"""Les journaux que l'interface propose doivent être ceux que les scripts écrivent.

Ce test existe à cause d'une panne silencieuse : un onglet de journal qui
reste désespérément vide après une opération parfaitement réussie, parce que la
liste blanche du helper pointe vers un fichier qu'aucun script n'écrit —
`pra_backup.log` au lieu de `yunohost_backup_daily.log`, par exemple.

Rien ne signalait l'écart : l'interface affichait sagement « ce journal n'existe
pas encore », ce qui est le message d'un onglet jamais utilisé, pas d'un chemin
faux. Les deux se ressemblent, et c'est précisément ce qui rend la faute durable.

On confronte donc les deux sources : les `LOG=` des scripts d'un côté, la liste
blanche du helper de l'autre.
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

RACINE = Path(__file__).resolve().parent.parent
HELPER = RACINE / "helper" / "arche-helper"
PRA = RACINE / "pra"

# Journaux qui ne viennent pas d'un script de pra/ : le helper écrit lui-même
# l'audit, et journalctl fournit le reste.
HORS_SCRIPTS = {"/var/log/arche-audit.log"}


def liste_blanche() -> dict[str, str]:
    """Les chemins que le helper accepte d'exposer."""
    texte = HELPER.read_text(encoding="utf-8")
    bloc = re.search(r"JOURNAUX\s*=\s*\{(.*?)\n\}", texte, re.S)
    assert bloc, "le bloc JOURNAUX est introuvable dans le helper"
    return dict(re.findall(r'"([a-z0-9-]+)":\s*Path\("([^"]+)"\)', bloc.group(1)))


def chemins_ecrits() -> set[str]:
    """Les fichiers que les scripts écrivent réellement, d'après leur `LOG=`."""
    ecrits = set()
    for s in PRA.glob("*.sh"):
        for m in re.finditer(r'^(?:LOG|JOURNAL)="([^"]+)"', s.read_text(encoding="utf-8"), re.M):
            # Certains chemins passent par une variable d'environnement :
            # LOG="${PRA_X_LOG:-/var/log/x.log}". On garde la valeur par défaut.
            val = m.group(1)
            defaut = re.match(r"\$\{[A-Z_]+:-([^}]+)\}$", val)
            ecrits.add(defaut.group(1) if defaut else val)
    assert ecrits, "aucun LOG= trouvé dans pra/ — le motif a dû changer"
    return ecrits


def test_tout_journal_expose_est_ecrit_par_quelque_chose():
    """La faute du 30/07 : exposer un chemin que rien n'écrit. L'onglet reste
    vide et l'on croit que l'opération n'a jamais tourné."""
    ecrits = chemins_ecrits() | HORS_SCRIPTS
    fantomes = {
        cle: chemin
        for cle, chemin in liste_blanche().items()
        if chemin not in ecrits
    }
    assert not fantomes, (
        "journaux exposés que RIEN n'écrit — l'onglet restera vide : "
        + ", ".join(f"{k} → {v}" for k, v in sorted(fantomes.items()))
    )


def test_les_journaux_importants_sont_consultables():
    """Symétrique : un script qui journalise sans que l'interface l'expose oblige
    à ouvrir un terminal, ce qui est exactement ce que l'interface évite."""
    attendus = {
        "/var/log/pra_nightly.log",
        "/var/log/pra_restore.log",
        "/var/log/yunohost_backup_daily.log",
        "/var/log/pra_docker_snapshot.log",
        "/var/log/pra_docker_restore.log",
        "/var/log/pra_notify.log",
    }
    exposes = set(liste_blanche().values())
    manquants = attendus - exposes
    assert not manquants, "journaux écrits mais inaccessibles depuis l'interface : " + ", ".join(
        sorted(manquants)
    )


def test_les_onglets_designent_des_cles_valides():
    """Un onglet vers une clé absente de la liste blanche donne un refus du
    helper — un message d'erreur là où l'on attendait un journal."""
    gabarit = (RACINE / "app" / "templates" / "journal.html").read_text(encoding="utf-8")
    bloc = re.search(r"set onglets = (.*?)%\}", gabarit, re.S)
    assert bloc, "la liste des onglets est introuvable"
    cles = set(re.findall(r'\("([a-z0-9-]+)"\s*,', bloc.group(1)))
    assert cles, "aucun onglet détecté — le gabarit a dû changer de forme"
    inconnues = cles - set(liste_blanche())
    assert not inconnues, "onglets sans entrée dans la liste blanche : " + ", ".join(
        sorted(inconnues)
    )


def test_les_redirections_du_code_designent_des_cles_valides():
    """Après une action, l'interface renvoie vers un journal. Une clé fausse
    mènerait à une erreur juste après une opération réussie."""
    code = (RACINE / "app" / "main.py").read_text(encoding="utf-8")
    cles = set(re.findall(r'redirect\("/journal/([a-z0-9-]+)"\)', code))
    inconnues = cles - set(liste_blanche())
    assert not inconnues, "redirections vers des journaux inconnus : " + ", ".join(
        sorted(inconnues)
    )
