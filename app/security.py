"""Authentification : mot de passe admin unique + session signée.

Repris de Cert_yuno, même modèle et mêmes compromis. En mode « proxy »,
l'authentification est déléguée à SSOwat en amont et ce module s'efface.

Le pré-hachage SHA-256 avant bcrypt contourne la limite de 72 octets de bcrypt
sans troncature silencieuse — un mot de passe long ne doit pas être accepté sur
ses 72 premiers octets seulement.
"""

from __future__ import annotations

import base64
import hashlib

import bcrypt
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import RedirectResponse

from app.config import get_settings

# Chemins accessibles sans authentification.
# /login-secours et /auth doivent rester accessibles sans session : le premier
# est le repli quand l'OIDC est hors service, le second reçoit la redirection du
# fournisseur d'identité. « /login » couvre déjà « /login-secours » par préfixe,
# mais on l'écrit explicitement pour que la liste se lise sans piège.
_PUBLIC_PREFIXES = ("/login", "/login-secours", "/auth", "/static", "/healthz")


def _prepare(password: str) -> bytes:
    """Pré-hache le mot de passe (SHA-256 + base64) pour contourner la limite bcrypt
    de 72 octets sans troncature silencieuse."""
    digest = hashlib.sha256(password.encode("utf-8")).digest()
    return base64.b64encode(digest)


def verify_password(password: str) -> bool:
    settings = get_settings()
    if not settings.admin_password_hash:
        return False
    try:
        return bcrypt.checkpw(_prepare(password), settings.admin_password_hash.encode())
    except Exception:
        return False


def hash_password(password: str) -> str:
    return bcrypt.hashpw(_prepare(password), bcrypt.gensalt()).decode()


class RootPathMiddleware:
    """Middleware ASGI qui retire le préfixe de sous-chemin du `path` entrant.

    Nécessaire derrière un reverse-proxy qui transmet l'URL **telle quelle** (ex. l'app
    Reverse Proxy de YunoHost) : le backend reçoit `/arche/login` et doit router
    comme `/login`. On pose aussi `root_path` dans le scope. La génération des URLs
    sortantes, elle, préfixe déjà via `settings.root_path` (variable `base`)."""

    def __init__(self, app, prefix: str = ""):
        self.app = app
        self.prefix = prefix.rstrip("/")

    async def __call__(self, scope, receive, send):
        if self.prefix and scope["type"] in ("http", "websocket"):
            path = scope.get("path", "")
            if path == self.prefix or path.startswith(self.prefix + "/"):
                scope = dict(scope)
                scope["path"] = path[len(self.prefix) :] or "/"
                raw = scope.get("raw_path")
                if raw is not None:
                    pref_b = self.prefix.encode()
                    if raw.startswith(pref_b):
                        scope["raw_path"] = raw[len(pref_b) :] or b"/"
                # On ne pose PAS scope["root_path"] : Starlette re-dériverait le chemin
                # des Mount (StaticFiles) et casserait le service des assets. La
                # génération des URLs sortantes utilise settings.root_path (`base`).
        await self.app(scope, receive, send)


class AuthMiddleware(BaseHTTPMiddleware):
    """Redirige toute requête non authentifiée vers /login (hors chemins publics)."""

    async def dispatch(self, request: Request, call_next):
        # Mode "proxy" : l'accès est déjà filtré par SSOwat en amont -> on laisse passer.
        if get_settings().auth_mode == "proxy":
            return await call_next(request)
        # Le préfixe root_path est déjà retiré par RootPathMiddleware : le chemin vu
        # ici est à la racine (/login, /static, …).
        path = request.url.path
        if path.startswith(_PUBLIC_PREFIXES) or request.session.get("auth"):
            return await call_next(request)
        return RedirectResponse(
            url=get_settings().root_path + "/login", status_code=303
        )
