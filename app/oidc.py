"""Authentification OIDC (dex) et accès de secours.

──────────────────────────────────────────────────────────────────────────────
POURQUOI UN ACCÈS DE SECOURS N'EST PAS OPTIONNEL ICI
──────────────────────────────────────────────────────────────────────────────
Sur le réplica, dex est une **copie restaurée** de celui de la production. Il
hérite donc des défauts de la restauration : un binaire x86 restauré sur une
machine arm64 le laisse hors service des heures (« Exec format error »). Une
console de reprise dont la seule voie d'accès serait dex serait inutilisable
exactement le jour où elle sert.

Règle générale, valable au-delà de ce projet : **ne jamais faire dépendre son
outil de secours d'un service que le sinistre peut avoir emporté.**

D'où `/login-secours`, actif quel que soit le mode d'authentification. Comme il
contourne l'OIDC par conception, il est borné :

 - nombre de tentatives limité par adresse, sur une fenêtre glissante ;
 - chaque usage — réussi ou non — est tracé dans le journal du service, pour
   qu'un contournement ne puisse pas passer inaperçu.

Le compteur est en mémoire : il retombe à zéro au redémarrage du service, et ne
serait pas partagé entre plusieurs processus uvicorn. C'est un frein contre le
tâtonnement, pas une protection cryptographique — celle-ci vient de bcrypt et de
la longueur du mot de passe.
"""

from __future__ import annotations

import logging
import ssl
import time
from typing import Any

import httpx
from authlib.integrations.starlette_client import OAuth, OAuthError

from app.config import get_settings

journal = logging.getLogger("arche.auth")

_oauth: OAuth | None = None
# adresse -> [horodatages des échecs]
_echecs: dict[str, list[float]] = {}


def disponible() -> bool:
    s = get_settings()
    return bool(s.oidc_discovery_url and s.oidc_client_secret)


def client() -> Any:
    """Client OIDC paresseux : la découverte n'est faite qu'au premier usage.

    Volontairement paresseux — si dex est hors service, la webapp doit tout de
    même démarrer et servir /login-secours.
    """
    global _oauth
    s = get_settings()
    if _oauth is None:
        contexte = None
        if s.oidc_cacert:
            contexte = ssl.create_default_context(cafile=s.oidc_cacert)
        _oauth = OAuth()
        _oauth.register(
            name="dex",
            server_metadata_url=s.oidc_discovery_url,
            client_id=s.oidc_client_id,
            client_secret=s.oidc_client_secret,
            # MÉTHODE D'AUTHENTIFICATION DU CLIENT — « client_secret_post »
            # et non le « client_secret_basic » par défaut d'authlib.
            #
            # Le point de terminaison du jeton est atteint à travers nginx, qui
            # ne transmet pas forcément l'en-tête « Authorization » vers le
            # service en amont. Dex ne voit alors aucun identifiant et répond
            # « invalid_client » — pour N'IMPORTE QUEL client, même valide.
            # Les clients qui fonctionnent dans ce montage envoient leurs
            # identifiants dans le CORPS de la requête. On fait donc pareil :
            # le corps traverse tous les mandataires.
            token_endpoint_auth_method="client_secret_post",
            client_kwargs={
                "scope": "openid profile email groups",
                # Les domaines internes sont signés par la CA de
                # l'établissement : sans elle, la découverte échoue en TLS.
                "verify": contexte if contexte is not None else True,
                "timeout": httpx.Timeout(15.0),
            },
        )
    return _oauth.dex


def groupe_autorise(identite: dict) -> bool:
    """Vérifie la revendication de groupe, si une restriction est configurée."""
    requis = get_settings().oidc_groupe_requis
    if not requis:
        return True
    groupes = identite.get("groups") or []
    if isinstance(groupes, str):
        groupes = [groupes]
    return requis in groupes


# ── Accès de secours : limitation et traçabilité ─────────────────────────────


def _adresse(request) -> str:
    return (request.client.host if request.client else "inconnue") or "inconnue"


def secours_bloque(request) -> int:
    """Renvoie le nombre de secondes d'attente restantes, 0 si l'accès est ouvert."""
    s = get_settings()
    ip = _adresse(request)
    maintenant = time.time()
    recents = [t for t in _echecs.get(ip, []) if maintenant - t < s.secours_fenetre_s]
    _echecs[ip] = recents
    if len(recents) < s.secours_max_essais:
        return 0
    return int(s.secours_fenetre_s - (maintenant - recents[0])) + 1


def secours_echec(request) -> None:
    ip = _adresse(request)
    _echecs.setdefault(ip, []).append(time.time())
    journal.warning(
        "ACCÈS DE SECOURS — tentative refusée depuis %s (%d échec(s) récent(s))",
        ip, len(_echecs[ip]),
    )


def secours_reussi(request) -> None:
    ip = _adresse(request)
    _echecs.pop(ip, None)
    # Journalisé en avertissement, pas en information : l'usage du contournement
    # doit sauter aux yeux dans « journalctl -u arche », même en usage légitime.
    journal.warning("ACCÈS DE SECOURS — connexion réussie depuis %s", ip)


__all__ = [
    "OAuthError",
    "client",
    "disponible",
    "groupe_autorise",
    "secours_bloque",
    "secours_echec",
    "secours_reussi",
]
