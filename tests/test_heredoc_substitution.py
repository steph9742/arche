"""Aucun heredoc ouvert à l'intérieur d'une substitution « $( … ) ».

bash 3.2 — celui de macOS, où ces tests tournent souvent — relit le contenu
d'un heredoc placé DANS une substitution de commande et s'y perd à la première
apostrophe : « bad substitution: no closing `)' ». Une douzaine de tests peuvent
ainsi échouer sur un Mac et passer sous Linux pour cette seule raison, dès qu'un
commentaire du code embarqué contient une apostrophe.

Le piège est sournois à trois titres : bash 5, sur la machine cible, n'a pas ce
défaut ;
« bash -n » ne le voit pas, puisque la substitution n'est analysée qu'à
l'exécution ; et il ne se déclenche qu'au jour où quelqu'un écrit une apostrophe
dans un commentaire. On verrouille donc la FORME : le heredoc vit dans une
fonction, et la substitution appelle la fonction.
"""

import re
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent

SCRIPTS = sorted(
    list((RACINE / "pra").glob("*.sh"))
    + list((RACINE / "scripts").glob("*.sh"))
    + list((RACINE / "yunobox").glob("*.sh"))
    + [p for p in (RACINE / "yunobox" / "dispatcher").glob("*") if p.is_file()]
)

MOTIF = re.compile(r"\$\([^)]*<<")


def test_il_y_a_bien_des_scripts_a_examiner():
    # Un glob qui ne trouve rien ferait passer ce test sans rien vérifier.
    noms = {p.name for p in SCRIPTS}
    assert {"pra_recu.sh", "pra_recu_verifier.sh", "pra_nightly.sh"} <= noms


def test_aucun_heredoc_dans_une_substitution():
    fautes = []
    for script in SCRIPTS:
        for n, ligne in enumerate(script.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if ligne.lstrip().startswith("#"):
                continue
            if MOTIF.search(ligne):
                fautes.append(f"{script.relative_to(RACINE)}:{n}: {ligne.strip()}")
    assert not fautes, (
        "heredoc ouvert dans « $( … ) » — le placer dans une fonction :\n  "
        + "\n  ".join(fautes))
