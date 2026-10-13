"""Analyse statique des scripts shell.

Deux pannes en une nuit, même famille, toutes deux triviales à détecter :

  - `yunohost_backup_daily.sh` : « local also_info="$2" » avec des appelants à un
    seul argument. Sous « set -u », le script mourait APRÈS avoir créé une
    archive de 12 Go correcte, en rapportant « FIN (code 1) ». La rétention ne
    tournait plus et le volet Docker n'était jamais enchaîné.

  - `pra_docker_restore.sh` : « ca_pub » déclarée « local » dans une fonction et
    utilisée dans une autre. Le volet Docker mourait net — « line 480: ca_pub:
    unbound variable » — juste après wiki, en laissant croire que wiki
    était en cause.

Les deux ne se manifestent qu'à l'exécution, sur la machine, au pire moment, et
sur un chemin qu'aucun test fonctionnel ne parcourt sans YunoHost ni Docker.
shellcheck les voit en une seconde. C'est le filet le moins cher du dépôt.

Ignoré proprement si shellcheck n'est pas installé, pour ne pas transformer un
outil manquant en échec de la suite — mais alors le test le DIT, sinon on croit
que le contrôle a eu lieu.
"""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

RACINE = Path(__file__).resolve().parent.parent
SCRIPTS = sorted(
    [*(RACINE / "pra").glob("*.sh"), *(RACINE / "scripts").glob("*.sh")]
)

besoin_shellcheck = pytest.mark.skipif(
    shutil.which("shellcheck") is None,
    reason="shellcheck absent — installer avec « brew install shellcheck » "
    "ou « apt install shellcheck » pour activer ce contrôle",
)


def test_il_y_a_bien_des_scripts_a_analyser():
    """Garde-fou : si le motif de recherche casse, la suite passerait en
    n'analysant rien — le pire des faux verts."""
    assert len(SCRIPTS) >= 5, f"seulement {len(SCRIPTS)} script(s) trouvé(s)"


@besoin_shellcheck
@pytest.mark.parametrize("script", SCRIPTS, ids=lambda p: p.name)
def test_aucun_avertissement_shellcheck(script: Path):
    """Niveau « warning » : on veut les variables non liées, les guillemets
    manquants et les redirections douteuses, pas les remarques de style."""
    r = subprocess.run(
        ["shellcheck", "-S", "warning", "--format=gcc", str(script)],
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        lignes = [l for l in r.stdout.splitlines() if l.strip()]
        pytest.fail(
            f"{script.name} — {len(lignes)} avertissement(s) :\n"
            + "\n".join("  " + l.replace(str(RACINE) + "/", "") for l in lignes[:20])
        )


def _est_bibliotheque(script: Path) -> bool:
    """Une bibliothèque est SOURCÉE, pas exécutée : y poser « set -u » l'imposerait
    au script appelant, ce qui n'est pas à elle d'en décider."""
    tete = script.read_text(encoding="utf-8")[:2000]
    return "destinée à être SOURCÉE" in tete or "à être sourcée" in tete.lower()


@pytest.mark.parametrize("script", SCRIPTS, ids=lambda p: p.name)
def test_les_scripts_sont_sous_set_u(script: Path):
    """« set -u » est ce qui transforme une faute de frappe en arrêt franc plutôt
    qu'en comportement silencieusement faux. Le contrôle shellcheck ci-dessus
    n'a de valeur que si les scripts s'exécutent effectivement ainsi."""
    if _est_bibliotheque(script):
        pytest.skip(f"{script.name} est une bibliothèque sourcée")
    tete = script.read_text(encoding="utf-8")[:4000]
    assert any(
        m in tete for m in ("set -euo pipefail", "set -eu", "set -u")
    ), f"{script.name} ne pose pas « set -u »"
