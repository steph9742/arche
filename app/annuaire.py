"""L'annuaire de crise.

Les numéros à composer quand la production est tombée : équipe, CERT, hébergeur,
assurance, juridique. S'ils ne vivent que dans le Nextcloud de la production, ils
disparaissent avec elle — et personne n'appelle personne.

Ils sont donc saisis ici, dans l'interface de l'arche, et repris tels quels dans
la **page de secours**, qui s'affiche sans authentification. La séparation des
rôles est nette et voulue :

  - on SAISIT l'annuaire en temps calme, derrière le SSO, avec la trace de qui a
    changé quoi ;
  - on le LIT en crise, sur une page qui n'exige rien.

Le fichier appartient au compte de service de l'application, non à root : la
webapp n'a pas besoin de privilège pour ses propres données, et le générateur de
la page de secours, lui, se contente de le lire.
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from datetime import datetime
from pathlib import Path

FICHIER = Path(os.environ.get("ARCHE_ANNUAIRE", "/var/lib/arche/annuaire.json"))

CHAMPS = ("nom", "role", "telephone", "courriel", "remarque")
LONGUEUR_MAX = 200
ENTREES_MAX = 100

# Les caractères de contrôle n'ont rien à faire dans un annuaire, et une nouvelle
# ligne injectée dans une valeur casserait la mise en page de la page de secours.
# On ne filtre QUE cela : les numéros s'écrivent avec des espaces, des points,
# des parenthèses et des signes plus, et les rôles avec des accents.
CONTROLE = re.compile(r"[\x00-\x1f\x7f]")


def _propre(valeur: str) -> str:
    return CONTROLE.sub(" ", str(valeur or "")).strip()[:LONGUEUR_MAX]


def lire() -> dict:
    """L'annuaire enregistré. Jamais d'exception : un annuaire illisible ne doit
    pas empêcher d'ouvrir la page pour le corriger."""
    try:
        with FICHIER.open(encoding="utf-8") as f:
            donnees = json.load(f)
    except (OSError, ValueError):
        return {"entrees": [], "modifie": None, "par": None}

    entrees = []
    for brut in donnees.get("entrees", [])[:ENTREES_MAX]:
        if not isinstance(brut, dict):
            continue
        entree = {c: _propre(brut.get(c, "")) for c in CHAMPS}
        if any(entree.values()):
            entrees.append(entree)
    return {"entrees": entrees,
            "modifie": donnees.get("modifie"),
            "par": donnees.get("par")}


def ecrire(entrees: list[dict], auteur: str) -> dict:
    """Remplace l'annuaire. Retourne ce qui a été enregistré.

    Les lignes entièrement vides sont écartées : le formulaire en propose
    toujours quelques-unes en réserve, et les enregistrer produirait un annuaire
    truffé de trous.
    """
    propres = []
    for brut in entrees[:ENTREES_MAX]:
        entree = {c: _propre(brut.get(c, "")) for c in CHAMPS}
        if entree["nom"] or entree["telephone"] or entree["courriel"]:
            propres.append(entree)

    charge = {
        "entrees": propres,
        "modifie": datetime.now().isoformat(timespec="seconds"),
        "par": _propre(auteur),
    }

    # Écriture atomique : un annuaire tronqué serait repris tel quel dans la page
    # de secours, et on ne s'en apercevrait qu'en cherchant un numéro.
    FICHIER.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=FICHIER.parent, prefix=".annuaire-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(charge, f, ensure_ascii=False, indent=2)
    os.chmod(tmp, 0o644)
    os.replace(tmp, FICHIER)
    return charge


def resume(avant: list[dict], apres: list[dict]) -> str:
    """Une ligne pour le journal d'audit.

    On ne détaille pas les valeurs : un annuaire est une donnée personnelle, et
    le journal d'audit est lisible par tous les administrateurs. Savoir QUE la
    liste a changé, et de combien, suffit à reconstituer une histoire.
    """
    n_avant, n_apres = len(avant), len(apres)
    noms_avant = {e.get("nom", "") for e in avant}
    noms_apres = {e.get("nom", "") for e in apres}
    ajouts = sorted(noms_apres - noms_avant)
    retraits = sorted(noms_avant - noms_apres)

    morceaux = [f"{n_avant} → {n_apres} entrées"]
    if ajouts:
        morceaux.append("ajout : " + ", ".join(ajouts[:5]))
    if retraits:
        morceaux.append("retrait : " + ", ".join(retraits[:5]))
    if not ajouts and not retraits and n_avant == n_apres:
        morceaux.append("modification sans ajout ni retrait")
    return "annuaire de crise — " + " ; ".join(morceaux)
