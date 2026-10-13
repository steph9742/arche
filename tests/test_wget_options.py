"""Les options passées aux outils externes doivent exister.

Ce test vient d'une panne durable et silencieuse : `--max-file-size=8000000`
ajouté à l'appel de wget qui copie les manuels, en croyant que l'option
existait. Elle n'existe pas. wget refuse toute option inconnue et sort
**aussitôt**, sans rien télécharger.

Rien ne le signale pendant des jours, pour trois raisons qui s'ajoutent :

  - la sortie de wget est jetée (`2>/dev/null`), donc le message « option non
    reconnue » n'apparaissait nulle part ;
  - le script juge le résultat en comptant les fichiers produits, donc l'échec se
    présentait comme « aucune page récupérée » — indistinguable d'un site muet ;
  - le dépôt contenait déjà 7 manuels, téléchargés AVANT cet ajout, ce qui donnait
    l'impression que le mécanisme fonctionnait.

Bilan : 11 manuels sur 18 manquants, dont ceux de YunoHost et du Raspberry Pi —
c'est-à-dire de quoi rebâtir l'arche elle-même.

Le test confronte donc chaque option longue des scripts à l'aide de l'outil.
"""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path

import pytest

RACINE = Path(__file__).resolve().parent.parent
SCRIPTS = sorted((RACINE / "pra").glob("*.sh"))

# Options que l'aide de l'outil ne liste pas mais qui existent, ou qui sont
# construites dynamiquement dans le script. Toute entrée ici doit être justifiée.
TOLEREES: dict[str, set[str]] = {}


def _aide(outil: str) -> str:
    """L'aide COMPLÈTE, et non l'extrait.

    « curl --help » n'affiche qu'une sélection : --max-time et --data-urlencode,
    qui existent, n'y figurent pas. Il faut « --help all ». Sans cela le test
    signalait des options parfaitement valides — un test qui crie au loup est
    désactivé en une semaine.
    """
    for args in ([outil, "--help", "all"], [outil, "--help"]):
        try:
            r = subprocess.run(args, capture_output=True, text=True, timeout=20)
        except Exception:
            continue
        texte = r.stdout + r.stderr
        if len(texte) > 500:
            return texte
    return ""


def _options_longues(texte: str, outil: str) -> set[str]:
    """Les options longues passées à `outil` dans un script shell.

    La portée d'une commande shell, c'est sa ligne PLUS les continuations
    terminées par « \\ ». Une première version ratissait tout jusqu'à la ligne
    vide suivante : elle attrapait les options d'autres commandes et produisait
    des faux positifs. Suivre les continuations est à la fois plus simple et exact.

    Les lignes de commentaire sont écartées : elles PARLENT des options, souvent
    pour expliquer qu'il ne faut pas les employer — c'est le cas ici même.
    """
    trouvees: set[str] = set()
    lignes = texte.splitlines()
    i = 0
    while i < len(lignes):
        nue = lignes[i].lstrip()
        if not nue.startswith("#") and re.search(rf"(?<![\w/-]){outil}(?=\s)", lignes[i]):
            bloc = [lignes[i]]
            while bloc[-1].rstrip().endswith("\\") and i + 1 < len(lignes):
                i += 1
                bloc.append(lignes[i])
            for ligne in bloc:
                # Une continuation peut elle-même être commentée.
                if ligne.lstrip().startswith("#"):
                    continue
                trouvees.update(re.findall(r"(?<![\w-])--([a-z][a-z0-9-]+)", ligne))
        i += 1
    return trouvees


@pytest.mark.skipif(shutil.which("wget") is None, reason="wget absent")
@pytest.mark.parametrize("script", SCRIPTS, ids=lambda p: p.name)
def test_les_options_wget_existent(script: Path):
    texte = script.read_text(encoding="utf-8")
    if "wget " not in texte:
        pytest.skip("ce script n'appelle pas wget")
    aide = _aide("wget")
    inconnues = sorted(
        o for o in _options_longues(texte, "wget") - TOLEREES.get("wget", set())
        if f"--{o}" not in aide
    )
    assert not inconnues, (
        f"{script.name} passe à wget des options qu'il ne connaît pas : "
        + ", ".join(f"--{o}" for o in inconnues)
        + " — wget refuse toute option inconnue et sort sans rien faire"
    )


@pytest.mark.skipif(shutil.which("curl") is None, reason="curl absent")
@pytest.mark.parametrize("script", SCRIPTS, ids=lambda p: p.name)
def test_les_options_curl_existent(script: Path):
    texte = script.read_text(encoding="utf-8")
    if "curl " not in texte:
        pytest.skip("ce script n'appelle pas curl")
    aide = _aide("curl")
    inconnues = sorted(
        o for o in _options_longues(texte, "curl") - TOLEREES.get("curl", set())
        if f"--{o}" not in aide
    )
    assert not inconnues, (
        f"{script.name} passe à curl des options qu'il ne connaît pas : "
        + ", ".join(f"--{o}" for o in inconnues)
    )


@pytest.mark.skipif(shutil.which("wget") is None, reason="wget absent")
def test_le_test_attrape_bien_une_option_inventee():
    """Un test qui ne peut pas échouer ne protège de rien. On vérifie qu'il
    détecte l'option exacte qui a causé la panne."""
    aide = _aide("wget")
    assert "--max-file-size" not in aide, (
        "wget aurait acquis cette option : revoir le commentaire de "
        "pra_depot_isos.sh, qui explique qu'elle n'existe pas"
    )
    faux = "wget -q -r --max-file-size=8000000 --quota=40m https://exemple.test\n"
    inconnues = [o for o in _options_longues(faux, "wget") if f"--{o}" not in aide]
    assert "max-file-size" in inconnues, "le détecteur ne voit pas l'option inventée"
