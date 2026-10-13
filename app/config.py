"""Configuration de la webapp Arche.

Surchargeable par variables d'environnement préfixées `ARCHE_` ou par un `.env`.
À ne pas confondre avec /etc/pra/pra.conf, qui est la configuration du PRA
lui-même — celle que la webapp édite (voir app/praconf.py).
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="ARCHE_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # --- Rôle de cette installation ---
    # "arche"      : le réplica — réplication, contrôles, restauration.
    # "production" : le serveur source — contenu de la sauvegarde.
    # Un seul code pour les deux : deux applications séparées divergeraient.
    role: str = "arche"

    # --- Réseau ---
    host: str = "127.0.0.1"
    port: int = 8770
    # Préfixe d'URL derrière le reverse-proxy (ex. "/arche"). Vide = racine.
    root_path: str = ""

    # --- Authentification ---
    # "password" : mot de passe applicatif (tunnel SSH, usage autonome).
    # "proxy"    : accès déjà filtré en amont par SSOwat.
    # "oidc"     : délégué à dex.
    auth_mode: str = "password"
    admin_password_hash: str = ""
    session_secret: str = "change-me-in-production"
    session_max_age: int = 60 * 60 * 8

    # --- OIDC (dex) ---
    # ATTENTION : sur le réplica, le fournisseur d'identité est une COPIE
    # RESTAURÉE de celui de la production. Il peut donc être cassé par le
    # sinistre même — un binaire x86 restauré sur une machine arm64 le laisse
    # hors service des heures. Une console de reprise qui n'aurait que cette voie
    # d'accès serait inutilisable précisément le jour où elle sert. D'où
    # /login-secours, toujours actif, quel que soit auth_mode.
    oidc_discovery_url: str = ""
    oidc_client_id: str = "arche"
    oidc_client_secret: str = ""
    # Restriction facultative sur une revendication de groupe de l'identité.
    oidc_groupe_requis: str = ""
    # La CA interne signe les domaines .local : sans elle, la découverte échoue.
    oidc_cacert: str = ""
    # URL PUBLIQUE de l'application, préfixe compris (ex.
    # « https://exemple.org/arche »). Sert à construire l'URI de
    # redirection OIDC, qui doit correspondre AU CARACTÈRE PRÈS à celle déclarée
    # dans dex. Laissée vide, elle est déduite de la requête — ce qui marche,
    # mais dépend des en-têtes du reverse-proxy. Pour une valeur qui doit
    # concorder exactement, l'explicite vaut mieux que le déduit.
    public_url: str = ""

    # --- Accès de secours ---
    # Le chemin /login-secours contourne OIDC par conception. On le borne donc :
    # tentatives limitées, et chaque usage tracé.
    secours_max_essais: int = 5
    secours_fenetre_s: int = 300

    # --- Chemins ---
    # Helper privilégié : seul composant autorisé à écrire la configuration du
    # PRA et à lancer une restauration.
    helper: Path = Path("/opt/arche/helper/arche-helper")
    sudo: str = "sudo"

    # Délai maximal d'un appel au helper. Une restauration dure ~11 min et n'est
    # PAS lancée en synchrone (voir arche-helper « restaurer ») : ce délai ne
    # couvre que les opérations courtes.
    helper_timeout: int = 120

    base_dir: Path = Field(default_factory=lambda: Path(__file__).resolve().parent)


@lru_cache
def get_settings() -> Settings:
    return Settings()
