"""Application FastAPI — Arche.

Pilotage et suivi du plan de reprise d'activité, hébergée SUR L'ARCHE et non sur
la production : une console installée sur la production disparaîtrait au moment
précis où elle servirait. L'arche, elle, est sur batterie, en armoire, sur un
réseau isolé — c'est la machine conçue pour survivre.

L'application ne porte aucune logique du PRA : elle édite /etc/pra/pra.conf, que
les scripts lisent seuls. Si elle est arrêtée ou cassée, la réplication nocturne
se déroule exactement pareil.
"""

from __future__ import annotations

import re
from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import Depends, FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from starlette.middleware.sessions import SessionMiddleware

from app.config import get_settings
from app.helper import client
from app.helper.client import HelperError
from app import csrf, oidc
from app import annuaire as annuaire_mod
from app.praconf import (
    PAR_CLE, SECRETS, ValeurInvalide, groupes_du_role, reglages_du_role, valider,
)
from pathlib import Path

from app.security import AuthMiddleware, RootPathMiddleware, verify_password

settings = get_settings()


@asynccontextmanager
async def lifespan(_app: FastAPI):
    yield


app = FastAPI(title="Arche", lifespan=lifespan)

# Ordre (du plus interne au plus externe) : routes < Auth < Session < RootPath.
app.add_middleware(AuthMiddleware)
app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret,
    max_age=settings.session_max_age,
    same_site="lax",
    https_only=False,
)
app.add_middleware(RootPathMiddleware, prefix=settings.root_path)

@app.exception_handler(csrf.CsrfInvalide)
async def csrf_refuse(request: Request, _exc: csrf.CsrfInvalide):
    return csrf.reponse_refus(request, settings.root_path)


templates = Jinja2Templates(directory=str(settings.base_dir / "templates"))


def capitaliser(valeur) -> str:
    """Première lettre en majuscule, le reste intact.

    Les verdicts et états viennent des scripts en minuscules (« succès »,
    « démarrée », « ÉCHEC de construction »). `capitalize` de Python abaisserait
    la suite et détruirait les majuscules porteuses de sens — on ne touche donc
    qu'au premier caractère.
    """
    texte = "" if valeur is None else str(valeur)
    return texte[:1].upper() + texte[1:] if texte else texte


templates.env.filters["capitaliser"] = capitaliser
app.mount(
    "/static",
    StaticFiles(directory=str(settings.base_dir / "static")),
    name="static",
)


# --------------------------------------------------------------------------- #
# Utilitaires
# --------------------------------------------------------------------------- #


def flash(request: Request, message: str, categorie: str = "info") -> None:
    request.session.setdefault("_flashes", []).append([categorie, message])


def _version_style() -> str:
    """Empreinte de la feuille de style, pour forcer son rechargement.

    Sans elle, le navigateur applique une fraîcheur heuristique — il ne
    revalide pas — et sert l'ancienne feuille après un déploiement. Une mise en
    page cassée fait alors croire à un défaut du code, alors que le serveur rend
    déjà le bon fichier : une case à cocher ajoutée la veille s'affiche sans sa
    mise en forme, et l'on cherche le défaut dans le gabarit.

    La date de modification suffit : elle change à chaque installation, et
    calculer une empreinte du contenu à chaque page coûterait sans rien
    apporter.
    """
    try:
        return str(int((Path(__file__).parent / "static" / "style.css").stat().st_mtime))
    except OSError:
        return "0"


def render(request: Request, nom: str, **ctx) -> HTMLResponse:
    flashes = request.session.pop("_flashes", [])
    contexte = {
        "request": request,
        "flashes": flashes,
        "settings": settings,
        "base": settings.root_path,
        "version_style": _version_style(),
        "auth_mode": settings.auth_mode,
        "authed": settings.auth_mode == "proxy" or request.session.get("auth"),
        "role": settings.role,
        # Chemin courant, préfixe retiré : sert à marquer l'onglet actif. Sans
        # repère visuel, on ne sait pas où l'on se trouve dans la console.
        "chemin": request.url.path[len(settings.root_path):] or "/",
        "csrf": csrf.jeton(request),
        "csrf_champ": csrf.CHAMP,
        **ctx,
    }
    return templates.TemplateResponse(request=request, name=nom, context=contexte)


def redirect(chemin: str) -> RedirectResponse:
    return RedirectResponse(settings.root_path + chemin, status_code=303)


# --------------------------------------------------------------------------- #
# Authentification
# --------------------------------------------------------------------------- #


def _uri_retour(request: Request) -> str:
    """URI de redirection OIDC, préfixe de sous-chemin INCLUS.

    On n'emploie PAS request.url_for() : RootPathMiddleware retire le préfixe du
    chemin sans poser scope["root_path"] (à dessein, sinon le service des
    fichiers statiques casse), donc url_for produirait « /auth/retour » au lieu
    de « /arche/auth/retour ». dex refuse alors la demande :
    « unregistered redirect_uri ».
    """
    if settings.public_url:
        return settings.public_url.rstrip("/") + "/auth/retour"
    return str(request.base_url).rstrip("/") + settings.root_path + "/auth/retour"


@app.get("/login", response_class=HTMLResponse)
async def login_form(request: Request):
    # En mode OIDC on part directement chez dex : afficher un formulaire local
    # inutile ne ferait qu'égarer. Si la découverte échoue — dex hors service,
    # ce qui est un scénario RÉEL sur l'arche — on le dit et on oriente vers
    # l'accès de secours au lieu d'afficher une erreur opaque.
    if settings.auth_mode == "oidc" and oidc.disponible():
        try:
            return await oidc.client().authorize_redirect(request, _uri_retour(request))
        except Exception as exc:  # dex injoignable, découverte illisible, TLS…
            flash(
                request,
                f"Le fournisseur d'identité ne répond pas ({exc.__class__.__name__}). "
                "Utilisez l'accès de secours.",
                "error",
            )
            return redirect("/login-secours")
    return render(request, "login.html", secours=False)


@app.get("/auth/retour", name="auth_retour")
async def auth_retour(request: Request):
    try:
        jeton = await oidc.client().authorize_access_token(request)
    except Exception as exc:
        # Un diagnostic UTILE, c'est-à-dire adapté à l'erreur reçue. Ma première
        # version citait l'URI de redirection quelle que soit la cause, ce qui
        # envoyait sur une fausse piste quand le secret était en défaut.
        detail = str(exc)
        bas = detail.lower()
        if "redirect" in bas:
            aide = (
                f"L'URI envoyée était « {_uri_retour(request)} » : elle doit "
                "figurer à l'identique dans les redirectURIs du client dex."
            )
        elif "client" in bas:
            aide = (
                "L'identifiant ou le secret du client ne concordent pas. "
                "Comparez « secret » dans /var/www/dex/config.yaml.d/ et "
                "ARCHE_OIDC_CLIENT_SECRET dans /etc/arche/arche.env, puis "
                "redémarrez dex et arche."
            )
        elif "certificate" in bas or "ssl" in bas or "verify" in bas:
            aide = (
                "Le certificat du fournisseur n'est pas vérifiable : renseignez "
                "ARCHE_OIDC_CACERT avec l'autorité interne."
            )
        else:
            aide = "Consultez « journalctl -u dex » pour la cause côté fournisseur."
        flash(request, f"Authentification refusée : {detail} — {aide}", "error")
        return redirect("/login-secours")

    identite = jeton.get("userinfo") or {}
    if not oidc.groupe_autorise(identite):
        flash(request, "Votre compte n'appartient pas au groupe autorisé.", "error")
        return redirect("/login-secours")

    request.session["auth"] = True
    request.session["utilisateur"] = identite.get("email") or identite.get("sub") or "?"
    return redirect("/")


# ── Accès de secours ────────────────────────────────────────────────────────
# Toujours actif, quel que soit le mode d'authentification : sur l'arche, dex est
# une copie restaurée et peut être cassé par le sinistre même. Voir app/oidc.py.


@app.get("/login-secours", response_class=HTMLResponse)
def secours_form(request: Request):
    return render(request, "login.html", secours=True)


@app.post("/login-secours", dependencies=[Depends(csrf.verifier)])
def secours(request: Request, password: str = Form("")):
    attente = oidc.secours_bloque(request)
    if attente:
        flash(request, f"Trop de tentatives. Réessayez dans {attente} secondes.",
              "error")
        return redirect("/login-secours")
    if verify_password(password):
        oidc.secours_reussi(request)
        request.session["auth"] = True
        request.session["utilisateur"] = "secours"
        return redirect("/")
    oidc.secours_echec(request)
    flash(request, "Mot de passe incorrect.", "error")
    return redirect("/login-secours")


# Conservé pour le mode « password » : même traitement que l'accès de secours,
# limitation comprise — un formulaire local mérite le même frein, qu'il
# s'appelle secours ou non.
@app.post("/login", dependencies=[Depends(csrf.verifier)])
def login(request: Request, password: str = Form("")):
    return secours(request, password)


@app.get("/logout")
def logout(request: Request):
    request.session.clear()
    return redirect("/login")


@app.get("/healthz")
def healthz():
    return {"ok": True}


# --------------------------------------------------------------------------- #
# Tableau de bord
# --------------------------------------------------------------------------- #


def _age_donnees(etat: dict) -> dict | None:
    """L'âge des DONNÉES, qui n'est pas l'heure de la restauration.

    `20260730-022349` restaurée à 15 h 34 signifie que les données datent de
    02 h 23 — treize heures plus tôt. Le tableau de bord n'affichait que l'heure
    de restauration, et la nuance est invisible en temps normal et décisive en
    crise : la première question qu'on se pose devant l'arche est « ce que je
    regarde, ça date de quand ? ».

    Le nom de l'archive porte l'horodatage de la SAUVEGARDE, donc de l'état réel
    des données. C'est la seule source honnête.
    """
    nom = (etat.get("yunohost") or {}).get("archive") or ""
    m = re.fullmatch(r"(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})", nom.replace(".tar", ""))
    if not m:
        return None
    try:
        quand = datetime(*(int(x) for x in m.groups()))
    except ValueError:
        return None
    heures = (datetime.now() - quand).total_seconds() / 3600
    return {
        "quand": quand.strftime("%d/%m/%Y à %H:%M"),
        "heures": round(heures),
        # 48 h : au-delà, deux nuits ont été manquées — ce n'est plus un retard,
        # c'est une réplication qui ne se fait plus.
        "vieux": heures > 48,
    }


@app.get("/", response_class=HTMLResponse)
def dashboard(request: Request):
    try:
        etat = client.etat()
    except HelperError as exc:
        flash(request, f"État indisponible : {exc}", "error")
        etat = {}
    return render(request, "dashboard.html", etat=etat, age=_age_donnees(etat))


# --------------------------------------------------------------------------- #
# Réglages
# --------------------------------------------------------------------------- #


def _auteur(request: Request) -> str:
    """Qui agit. En mode « proxy », SSOwat transmet l'identité dans un en-tête ;
    sinon on tient ce qu'on sait — et « inconnu » est une réponse honnête."""
    return (
        request.session.get("utilisateur")
        or request.headers.get("remote-user")
        or request.headers.get("x-forwarded-user")
        or ("proxy" if settings.auth_mode == "proxy" else "inconnu")
    )


def _tracer(request: Request, quoi: str) -> None:
    """Journalise l'action. Best effort : une trace qui échoue ne doit pas
    empêcher l'action, mais l'échec est visible dans les journaux du service."""
    try:
        client.tracer(_auteur(request), quoi)
    except HelperError:
        pass


def _valeurs_courantes(request: Request) -> dict[str, str]:
    try:
        reponse = client.conf_lire()
    except HelperError as exc:
        flash(request, f"Configuration illisible : {exc}", "error")
        return {}
    return reponse.get("valeurs", {})


@app.get("/reglages", response_class=HTMLResponse)
def reglages_form(request: Request):
    valeurs = _valeurs_courantes(request)
    mes_reglages = reglages_du_role(settings.role)
    # Un réglage jamais défini s'affiche avec son défaut : l'utilisateur voit ce
    # qui s'applique réellement, pas un champ vide trompeur.
    affichees = {
        r.cle: valeurs.get(r.cle, "") or (r.defaut if r.cle not in valeurs else "")
        for r in mes_reglages
    }
    # Une liste saisie à la main se périme en silence : on interroge la machine.
    apps_installees: list[dict] = []
    if any(r.type == "apps" for r in mes_reglages):
        try:
            apps_installees = client.apps().get("apps", [])
        except HelperError as exc:
            flash(request, f"Liste des applications indisponible : {exc}", "error")

    cibles: dict = {}
    if any(r.type in ("cibles", "piles") for r in mes_reglages):
        try:
            cibles = client.cibles()
        except HelperError as exc:
            flash(request, f"Cibles de restauration indisponibles : {exc}", "error")

    return render(
        request, "reglages.html",
        groupes=groupes_du_role(settings.role),
        reglages=mes_reglages, valeurs=affichees,
        apps_installees=apps_installees, cibles=cibles,
    )


@app.post("/reglages", dependencies=[Depends(csrf.verifier)])
async def reglages_save(request: Request):
    form = await request.form()
    soumis: dict[str, str] = {}
    for reglage in reglages_du_role(settings.role):
        if reglage.type in ("liste", "parties", "apps", "cibles", "piles"):
            # Cases à cocher multiples ou zone de texte multiligne.
            valeurs = form.getlist(reglage.cle)
            soumis[reglage.cle] = " ".join(str(v) for v in valeurs if str(v).strip())
        elif reglage.type == "booleen":
            soumis[reglage.cle] = "1" if form.get(reglage.cle) else "0"
        else:
            soumis[reglage.cle] = str(form.get(reglage.cle, ""))

    # Validation côté application d'abord, pour un message immédiat et précis.
    # Le helper revalidera de toute façon : c'est lui la véritable barrière.
    #
    # On valide la configuration EFFECTIVE — l'existante, recouverte par ce qui
    # vient d'être soumis — et non la seule soumission. Le helper procède ainsi
    # (il fusionne avant de valider) ; ne pas l'imiter rendait cette pré-vérif
    # PLUS stricte que l'autorité, donc refusait des saisies qui auraient été
    # écrites sans problème. Sur le rôle « production », par exemple, le champ
    # des témoins n'est pas affiché, donc absent de la soumission, donc lu comme
    # vide — « au moins une machine témoin est nécessaire » interdirait alors
    # toute modification des canaris, témoins pourtant bien réglés.
    try:
        _lu = client.conf_lire()
        actuelles = _lu.get("valeurs", {})
        secrets_definis = set(_lu.get("secrets_definis", []))
    except HelperError:
        actuelles, secrets_definis = {}, set()
    effectives = {**actuelles, **soumis}

    # Un secret laissé masqué signifie « ne pas changer » : le helper y remet
    # l'ancienne valeur avant d'écrire. La v1 se contentait de RETIRER toute
    # valeur masquée, ce qui la faisait passer pour VIDE ici — d'où « les alertes
    # Talk exigent les trois valeurs ensemble » alors qu'elles sont bien
    # réglées, le secret existant simplement sans être réaffiché.
    # On lui substitue donc un jeton de forme valide,
    # et seulement s'il est effectivement enregistré côté helper.
    for cle in [c for c, v in effectives.items() if str(v).startswith("●")]:
        if cle in secrets_definis:
            effectives[cle] = "inchange"
        else:
            del effectives[cle]
    try:
        valider(effectives)
    except ValeurInvalide as exc:
        flash(request, str(exc), "error")
        return redirect("/reglages")

    try:
        client.conf_ecrire(soumis)
    except HelperError as exc:
        flash(request, f"Enregistrement refusé : {exc}", "error")
        return redirect("/reglages")

    # « réglages enregistrés » seul ne dit pas CE QUI a changé : le journal ne
    # permettait donc pas de répondre à la question qu'il est censé servir.
    # On consigne le détail — en nommant les secrets sans jamais les écrire.
    modifs: list[str] = []
    for cle, val in soumis.items():
        avant, apres = str(actuelles.get(cle, "")), str(val)
        if apres.startswith("●"):
            continue                            # secret laissé inchangé
        if cle in SECRETS:
            if apres != avant:
                modifs.append(f"{cle} : nouvelle valeur (secret non journalisé)")
            continue
        if apres != avant:
            modifs.append(f"{cle} : « {avant or '(vide)'} » → « {apres or '(vide)'} »")
    _tracer(request, "réglages enregistrés — " +
            ("; ".join(modifs) if modifs else "aucun changement effectif"))
    flash(request, "Configuration enregistrée. Elle s'appliquera dès la prochaine "
                   "exécution — aucun redémarrage n'est nécessaire.", "success")
    return redirect("/reglages")


# --------------------------------------------------------------------------- #
# Actions
# --------------------------------------------------------------------------- #


# --------------------------------------------------------------------------- #
# Annuaire de crise
#
# Les numéros à composer quand la production est tombée. S'ils ne vivent que dans
# le Nextcloud de la production, ils disparaissent avec elle — et personne
# n'appelle personne.
#
# La séparation des rôles est le tout du dispositif : on SAISIT ici, derrière le
# SSO et avec la trace de qui a changé quoi ; on LIT sur la page de secours, qui
# n'exige rien. Saisir demande du calme, lire demande l'urgence.
# --------------------------------------------------------------------------- #


@app.get("/annuaire", response_class=HTMLResponse)
def annuaire_form(request: Request):
    donnees = annuaire_mod.lire()
    return render(request, "annuaire.html",
                  entrees=donnees["entrees"],
                  modifie=donnees["modifie"], par=donnees["par"])


@app.post("/annuaire", dependencies=[Depends(csrf.verifier)])
async def annuaire_save(request: Request):
    form = await request.form()
    # Les champs arrivent en colonnes parallèles : nom[], role[]… La ligne i est
    # reconstituée en reprenant le i-ième de chaque colonne.
    colonnes = {c: form.getlist(c) for c in annuaire_mod.CHAMPS}
    hauteur = max((len(v) for v in colonnes.values()), default=0)
    soumises = [
        {c: (colonnes[c][i] if i < len(colonnes[c]) else "")
         for c in annuaire_mod.CHAMPS}
        for i in range(hauteur)
    ]

    avant = annuaire_mod.lire()["entrees"]
    try:
        apres = annuaire_mod.ecrire(soumises, _auteur(request))
    except OSError as exc:
        flash(request, f"Annuaire non enregistré : {exc}", "error")
        return redirect("/annuaire")

    _tracer(request, annuaire_mod.resume(avant, apres["entrees"]))
    flash(request, f"Annuaire enregistré — {len(apres['entrees'])} entrées. "
                   "Il apparaîtra sur la page de secours dans les dix minutes.",
          "success")
    return redirect("/annuaire")


# --------------------------------------------------------------------------- #
# Dépôt de secours
#
# On PILOTE le dépôt d'ici — voir ce qu'il contient, vérifier, compléter,
# nettoyer — mais on n'y téléverse rien et on ne le parcourt pas : le dépôt de
# fichiers le fait déjà, et le refaire ici coûterait cher pour rien.
# --------------------------------------------------------------------------- #


def _octets(n: int | None) -> str:
    """Une taille lisible. Les gigaoctets à une décimale : « 31,4 Go » se lit,
    « 31356842102 octets » non."""
    if not n:
        return "0"
    for unite, seuil in (("To", 1e12), ("Go", 1e9), ("Mo", 1e6), ("ko", 1e3)):
        if n >= seuil:
            return f"{n / seuil:.1f} {unite}".replace(".", ",")
    return f"{n} o"


@app.get("/sante", response_class=HTMLResponse)
def sante_page(request: Request):
    """L'accessibilité réelle. La MESURE vit sur disque, pas en session.

    La stocker en session la mettrait dans un cookie : près de 4 ko pour une
    trentaine d'applications, davantage une fois signée, donc au-delà de la
    limite de 4096 octets. Le navigateur jette alors le cookie sans rien dire et
    la page reste vide : on appuie sur « sonder maintenant » et il ne vient aucun
    résultat. Le fichier n'a pas cette limite, survit à un rafraîchissement, et
    son horodatage reste vrai.

    Pas de sonde au chargement : elle interroge une trentaine d'URL. Une page qui
    se sonde d'elle-même devient lente, donc évitée — et une page évitée ne sert
    à rien.
    """
    mesure = None
    try:
        mesure = client.sante_lire() or None
    except HelperError as exc:
        flash(request, f"Dernière mesure illisible : {exc}", "error")
    return render(request, "sante.html", sante=mesure)


@app.post("/sante", dependencies=[Depends(csrf.verifier)])
def sante_sonder(request: Request):
    try:
        r = client.sante()
        flash(request, "Sonde terminée : %s application(s) et %s pile(s)."
              % (r.get("applications", "?"), r.get("piles", "?")), "success")
    except HelperError as exc:
        flash(request, f"Sonde impossible : {exc}", "error")
    return redirect("/sante")


@app.get("/depot", response_class=HTMLResponse)
def depot_page(request: Request):
    etat, verif = {}, request.session.pop("_depot_verif", None)
    try:
        etat = client.depot_etat()
    except HelperError as exc:
        flash(request, f"Dépôt illisible : {exc}", "error")
    return render(request, "depot.html", depot=etat, verif=verif,
                  octets=_octets)


@app.post("/depot/{action}", dependencies=[Depends(csrf.verifier)])
def depot_action(request: Request, action: str):
    # Liste blanche : la valeur vient de l'URL, elle n'est jamais utilisée
    # telle quelle pour construire une commande.
    permises = {"verifier": client.depot_verifier,
                "majour": client.depot_majour,
                "nettoyer": client.depot_nettoyer}
    if action not in permises:
        flash(request, "Action inconnue.", "error")
        return redirect("/depot")

    try:
        reponse = permises[action]()
    except HelperError as exc:
        flash(request, f"Échec : {exc}", "error")
        return redirect("/depot")

    if action == "verifier":
        # Le résultat est gardé le temps d'une redirection : l'afficher évite de
        # relancer une vérification d'une minute à chaque rafraîchissement.
        request.session["_depot_verif"] = reponse
        n = len(reponse.get("a_renouveler", [])) + len(reponse.get("absents", []))
        flash(request, f"Vérification terminée — {n} élément(s) à récupérer."
              if n else "Vérification terminée — le dépôt est à jour.", "success")
    elif action == "majour":
        flash(request, "Complément du dépôt lancé. Il dure plusieurs heures ; "
                       "l'avancement s'affiche sur cette page.", "success")
    else:
        flash(request, "Nettoyage effectué.", "success")

    _tracer(request, f"dépôt de secours : {action}")
    return redirect("/depot")


@app.post("/actions/canaris/{action}", dependencies=[Depends(csrf.verifier)])
def action_canaris(request: Request, action: str):
    _tracer(request, f"canaris:{action}")
    try:
        r = client.canaris(action)
    except HelperError as exc:
        flash(request, f"Échec : {exc}", "error")
        return redirect("/reglages")
    flash(
        request,
        r.get("sortie") or "Opération effectuée.",
        "success" if r.get("ok") else "error",
    )
    return redirect("/reglages")


@app.post("/actions/tester-alerte", dependencies=[Depends(csrf.verifier)])
def action_tester_alerte(request: Request):
    _tracer(request, "alerte d'essai")
    try:
        r = client.tester_alerte()
    except HelperError as exc:
        flash(request, f"Échec : {exc}", "error")
        return redirect("/reglages")
    if r.get("ok"):
        flash(request, "Alerte transmise — vérifiez la conversation Talk.", "success")
    else:
        flash(request, f"L'alerte n'est pas partie : {r.get('detail') or 'cause inconnue'}",
              "error")
    return redirect("/reglages")


@app.post("/actions/sauvegarder", dependencies=[Depends(csrf.verifier)])
def action_sauvegarder(request: Request, sans_docker: str = Form("")):
    if settings.role != "production":
        flash(request, "La sauvegarde n'existe que sur la production.", "error")
        return redirect("/")
    _tracer(request, "sauvegarde lancée%s" % (
        " (sans instantané Docker)" if sans_docker else ""))
    try:
        r = client.sauvegarder(sans_docker=bool(sans_docker))
    except HelperError as exc:
        flash(request, f"Échec : {exc}", "error")
        return redirect("/")
    flash(request, "Sauvegarde lancée — %s. Suivez le journal." % (
        "instantané Docker compris" if r.get("avec_docker")
        else "SANS instantané Docker"), "success")
    # « sauvegarde » et non « sauvegarde-manuelle » : les deux clés désignent le
    # même fichier, mais seule la première a un onglet, donc seule la première
    # apparaît comme active en arrivant sur la page.
    return redirect("/journal/sauvegarde")


@app.post("/actions/restaurer", dependencies=[Depends(csrf.verifier)])
def action_restaurer(
    request: Request,
    mode: str = Form("valider"),
    halt: str = Form(""),
    sans_controles: str = Form(""),
    sans_transfert: str = Form(""),
    sans_docker: str = Form(""),
    archive: str = Form(""),
    instantane: str = Form(""),
):
    # Restaurer n'a de sens que sur l'arche : sur la production, ce serait
    # écraser les données vivantes par une sauvegarde.
    if settings.role != "arche":
        flash(request, "La restauration n'est possible que depuis l'arche.", "error")
        return redirect("/")

    reelle = mode == "reel"
    options = {
        "halt": bool(halt) and reelle,
        "sans_controles": bool(sans_controles),
        "sans_transfert": bool(sans_transfert),
        "sans_docker": bool(sans_docker),
    }
    choisies = [n for n, v in options.items() if v]
    # L'ARCHIVE CHOISIE EST TRACÉE À PART, et nommée. C'est la décision la plus
    # lourde qu'on prenne ici — remonter à une nuit antérieure parce qu'on
    # soupçonne la plus récente — et l'audit doit dire LAQUELLE a été retenue,
    # pas seulement qu'une restauration a eu lieu.
    _tracer(request, "restauration lancée (mode=%s%s%s)" % (
        "réelle" if reelle else "validation",
        ", " + ", ".join(choisies) if choisies else "",
        (f", archive {archive}" if archive else ", archive du jour")
        + (f", instantané Docker {instantane}" if instantane else "")))

    try:
        r = client.restaurer(valider_seulement=not reelle, archive=archive.strip(),
                             instantane=instantane.strip(), **options)
    except HelperError as exc:
        flash(request, f"Échec : {exc}", "error")
        return redirect("/")

    detail = []
    if r.get("halt"):
        detail.append("la machine s'éteindra à la fin")
    if r.get("sans_controles"):
        detail.append("contrôles de santé ignorés")
    if r.get("sans_transfert"):
        detail.append("archive locale, sans transfert")
    detail.append("piles Docker comprises" if r.get("avec_docker")
                  else "SANS les piles Docker")
    flash(request, "Restauration %s lancée%s. Suivez le journal." % (
        "réelle" if reelle else "en validation",
        " — " + ", ".join(detail) if detail else ""), "success")
    return redirect("/journal/restauration")


@app.get("/journal/{quoi}", response_class=HTMLResponse)
def journal(request: Request, quoi: str, lignes: int = 300):
    try:
        r = client.journal(quoi, lignes)
    except HelperError as exc:
        flash(request, f"Journal indisponible : {exc}", "error")
        r = {"lignes": [], "fichier": "", "absent": True}
    return render(request, "journal.html", quoi=quoi, journal=r)
