"""Protection anti-CSRF.

──────────────────────────────────────────────────────────────────────────────
POURQUOI UN JETON, ALORS QUE SAME_SITE=LAX EXISTE
──────────────────────────────────────────────────────────────────────────────
`same_site="lax"` empêche l'envoi du cookie de session sur un POST venu d'un
autre site, ce qui couvre le cas courant sur les navigateurs actuels. Ce n'est
pas suffisant ici :

 - « Restaurer maintenant » DÉSINSTALLE les applications de l'arche avant de les
   restaurer. Une requête forgée qui aboutit laisse l'arche incomplète jusqu'à
   la nuit suivante — c'est-à-dire sans filet.
 - `lax` dépend du navigateur et de sa version ; un vieux client, un client non
   standard ou une extension suffisent à retomber sur le comportement permissif.
 - Le `confirm()` JavaScript du tableau de bord n'est PAS une protection : il ne
   s'exécute que dans le navigateur de la victime légitime, jamais chez
   l'attaquant.

Le jeton est donc la vraie barrière ; `lax` en devient la ceinture.

MISE EN ŒUVRE — dépendance explicite, pas middleware. Lire le corps de la
requête dans un middleware Starlette consomme le flux : le handler en aval
reçoit alors un corps vide, sauf à rejouer `receive`, ce qui est fragile.
Déclarer la dépendance sur chaque route POST est plus verbeux mais sans piège.

Le revers du verbeux est l'oubli. `tests/test_csrf.py` ÉNUMÈRE donc toutes les
routes POST de l'application et échoue si l'une d'elles n'est pas protégée :
c'est ce test, et non la vigilance, qui garantit la couverture.
"""

from __future__ import annotations

import hmac
import secrets
from urllib.parse import urlsplit

from fastapi import Request
from fastapi.responses import RedirectResponse

CHAMP = "_csrf"
_CLE_SESSION = "_csrf"


class CsrfInvalide(Exception):
    """Jeton absent ou incorrect."""


def jeton(request: Request) -> str:
    """Renvoie le jeton de la session, en le créant au besoin.

    Lié à la session, donc renouvelé à chaque connexion — `request.session.clear()`
    à la déconnexion suffit à l'invalider.
    """
    valeur = request.session.get(_CLE_SESSION)
    if not valeur:
        valeur = secrets.token_urlsafe(32)
        request.session[_CLE_SESSION] = valeur
    return valeur


async def verifier(request: Request) -> None:
    """Dépendance FastAPI : à déclarer sur TOUTE route POST.

    Le formulaire est relu ici puis par le handler : Starlette met en cache le
    résultat sur l'objet Request, que FastAPI partage entre dépendances et
    endpoint. Aucune double lecture du flux.
    """
    attendu = request.session.get(_CLE_SESSION)
    formulaire = await request.form()
    fourni = str(formulaire.get(CHAMP) or "")
    # compare_digest : comparaison à temps constant. Le gain est théorique sur un
    # jeton de session, mais c'est le réflexe à garder pour tout secret.
    if not attendu or not fourni or not hmac.compare_digest(attendu, fourni):
        raise CsrfInvalide()


def reponse_refus(request: Request, prefixe: str) -> RedirectResponse:
    """Refus lisible plutôt qu'un 403 nu : la cause la plus fréquente est une
    session expirée dans un onglet resté ouvert, pas une attaque.

    Surtout, on NE redirige PAS vers le chemin courant : les routes d'action
    n'acceptent que POST, et une redirection 303 se suit en GET — le visiteur
    récoltait un 405 sans jamais voir le message. On revient donc sur la page
    d'origine, en ne conservant que son CHEMIN : réutiliser l'en-tête Referer tel
    quel ouvrirait une redirection arbitraire vers un site externe.
    """
    request.session.setdefault("_flashes", []).append(
        ["error", "Formulaire expiré ou invalide. Rechargez la page et réessayez."]
    )
    cible = "/"
    referent = request.headers.get("referer") or ""
    if referent:
        chemin = urlsplit(referent).path or "/"
        if prefixe and chemin.startswith(prefixe):
            chemin = chemin[len(prefixe):] or "/"
        # Une seule barre en tête, pas de « // » ni de schéma : sinon le
        # navigateur interpréterait « //hote » comme une URL absolue.
        if chemin.startswith("/") and not chemin.startswith("//"):
            cible = chemin
    return RedirectResponse(prefixe + cible, status_code=303)
