"""Appel du helper privilégié `arche-helper` depuis la webapp.

La webapp ne réalise AUCUNE opération privilégiée : elle ne sait ni écrire
/etc/pra/pra.conf, ni lancer une restauration, ni lire les journaux du PRA. Elle
délègue au helper via `sudo`, qui revalide tout ce qu'il reçoit.

Les arguments sont transmis en LISTE à subprocess, jamais via un shell : aucune
interpolation possible. Les charges utiles structurées passent par l'entrée
standard en JSON, pas par la ligne de commande — évite les limites de longueur
et l'exposition des secrets dans la table des processus.
"""

from __future__ import annotations

import json
import subprocess

from app.config import get_settings


class HelperError(RuntimeError):
    """Erreur remontée par le helper — message destiné à l'utilisateur."""


def _commande() -> list[str]:
    s = get_settings()
    cmd: list[str] = []
    if s.sudo:  # vide en développement : appel direct sans sudo
        cmd += s.sudo.split()
    cmd.append(str(s.helper))
    return cmd


def _appeler(args: list[str], charge: dict | None = None,
             timeout: float | None = None) -> dict:
    """Appelle le helper. « timeout » n'est renseigné que pour les commandes
    dont on sait qu'elles dépassent le délai courant — la vérification du dépôt
    interroge une vingtaine de sites, le nettoyage recalcule des empreintes."""
    s = get_settings()
    entree = json.dumps(charge).encode() if charge is not None else None
    delai = timeout or s.helper_timeout
    try:
        proc = subprocess.run(
            _commande() + args,
            input=entree,
            capture_output=True,
            timeout=delai,
        )
    except FileNotFoundError:
        raise HelperError(
            f"Helper introuvable ({s.helper}). L'installation est-elle complète ?"
        ) from None
    except subprocess.TimeoutExpired:
        raise HelperError(
            f"Le helper n'a pas répondu en {delai:.0f} s. "
            "La production est peut-être injoignable."
        ) from None

    sortie = proc.stdout.decode("utf-8", "replace").strip()
    erreur = proc.stderr.decode("utf-8", "replace").strip()

    if proc.returncode != 0:
        # Le helper renvoie ses erreurs en JSON quand il le peut ; sinon on
        # remonte stderr tel quel plutôt qu'un « échec » opaque.
        try:
            return_json = json.loads(sortie)
            raise HelperError(return_json.get("erreur") or erreur or "échec du helper")
        except json.JSONDecodeError:
            raise HelperError(erreur or sortie or "échec du helper") from None

    if not sortie:
        return {}
    try:
        return json.loads(sortie)
    except json.JSONDecodeError:
        raise HelperError("Réponse illisible du helper (JSON attendu).") from None


# ── Opérations ──────────────────────────────────────────────────────────────


def etat() -> dict:
    """État des deux volets : YunoHost, Docker, services, archives."""
    return _appeler(["etat"])


def conf_lire() -> dict:
    """Configuration courante du PRA. Les secrets sont masqués par le helper."""
    return _appeler(["conf-lire"])


def conf_ecrire(valeurs: dict[str, str]) -> dict:
    """Écrit /etc/pra/pra.conf. Le helper revalide intégralement."""
    return _appeler(["conf-ecrire"], charge={"valeurs": valeurs})


def journal(quoi: str, lignes: int = 200) -> dict:
    return _appeler(["journal", quoi, str(lignes)])


def canaris(action: str) -> dict:
    """action ∈ {deployer, rebaser, verifier}"""
    return _appeler(["canaris", action])


def restaurer(valider_seulement: bool = True, *, halt: bool = False,
              sans_controles: bool = False, sans_transfert: bool = False,
              sans_docker: bool = False, archive: str = "",
              instantane: str = "") -> dict:
    """Lance une restauration, en validation ou réelle.

    Les options sont des drapeaux : aucune valeur fournie par l'appelant n'entre
    dans la commande du helper, seulement le choix de les ajouter ou non.

    SAUF « archive », qui est une valeur — c'est le nom d'une archive antérieure,
    le geste dont on a besoin le jour où la plus récente est suspecte. Elle passe
    en argument de LISTE, jamais par un shell, et le helper la revalide
    intégralement : nommage exact, existence, appartenance au magasin après
    résolution des liens.
    """
    args = ["restaurer", "--valider" if valider_seulement else "--reel"]
    if halt:
        args.append("--halt")
    if sans_controles:
        args.append("--sans-controles")
    if sans_transfert:
        args.append("--sans-transfert")
    if archive:
        args += ["--archive", archive]
    if instantane:
        args += ["--docker-snapshot", instantane]
    if sans_docker:
        args.append("--sans-docker")
    return _appeler(args)

def apps() -> dict:
    """Applications YunoHost installées, pour les cases à cocher."""
    return _appeler(["apps"])


def cibles() -> dict:
    """Applications et piles sélectionnables, d'après l'inventaire de la veille."""
    return _appeler(["cibles"])


def sante() -> dict:
    """Lance la sonde. Le résultat est écrit sur DISQUE par le helper, pas renvoyé.

    Le stocker en session le mettait dans un cookie : 3,9 ko brut pour 29
    applications, davantage une fois signé, donc au-delà des 4096 octets qu'un
    navigateur accepte — le cookie était jeté en silence et la page restait vide.
    Le helper sonde en parallèle, ce qui tient dans une dizaine de secondes.
    """
    return _appeler(["sante"], timeout=90)


def sante_lire() -> dict:
    """La dernière mesure, sans resonder. Instantané."""
    return _appeler(["sante-lire"])


def depot_etat() -> dict:
    """Composition du dépôt de secours, place occupée et libre."""
    return _appeler(["depot-etat"])


def depot_verifier() -> dict:
    """Compare le dépôt à ce que les projets publient, sans rien télécharger."""
    return _appeler(["depot-verifier"], timeout=660)


def depot_majour() -> dict:
    """Lance le complément du dépôt. Détaché : plusieurs heures."""
    return _appeler(["depot-majour"])


def depot_nettoyer() -> dict:
    """Retire les versions périmées et les fichiers écartés."""
    return _appeler(["depot-nettoyer"], timeout=360)


def tracer(qui: str, quoi: str) -> dict:
    """Consigne une action dans le journal d'audit, tenu par le helper."""
    return _appeler(["tracer", qui, quoi])


def sauvegarder(*, sans_docker: bool = False) -> dict:
    """Lance la sauvegarde de production, instantané Docker compris par défaut."""
    args = ["sauvegarder"]
    if sans_docker:
        args.append("--sans-docker")
    return _appeler(args)

def tester_alerte() -> dict:
    return _appeler(["tester-alerte"])
