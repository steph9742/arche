"""La page « Santé » et l'alerte du minuteur.

Ces deux écrans existent à cause d'une même leçon :
**l'état d'un service ne dit rien de son accessibilité**. Une pile peut être
« running » et rendre 502 depuis des heures ; le tableau de bord la déclare
saine parce que ses conteneurs tournent.

Un écran qui rassure à tort est pire qu'un écran absent, d'où ces tests : ils
vérifient non pas que la page s'affiche, mais qu'elle **dit ce qui ne va pas**.
"""

from __future__ import annotations

import re


def _jeton(client, chemin):
    m = re.search(r'name="_csrf" value="([^"]+)"', client.get(chemin).text)
    assert m, f"aucun jeton dans {chemin}"
    return m.group(1)


def test_page_accessible_et_sans_mesure_au_depart(client):
    """Pas de sonde au chargement : elle prend une dizaine de secondes, et une page
    lente est une page qu'on évite."""
    r = client.get("/sante")
    assert r.status_code == 200
    assert "Aucune mesure" in r.text
    assert "Sonder maintenant" in r.text


def test_la_sonde_remonte_les_anomalies_en_premier(client):
    r = client.post("/sante", data={"_csrf": _jeton(client, "/sante")},
                    follow_redirects=True)
    assert r.status_code == 200
    # Le bloc « À regarder » doit exister et citer les deux services fautifs.
    assert "À regarder" in r.text
    for attendu in ("wiki.local", "kiwix.local", "502", "000"):
        assert attendu in r.text, f"« {attendu} » absent de la page"


def test_le_diagnostic_est_explicite_et_pas_un_simple_code(client):
    """Un code HTTP seul n'aide personne en crise. La page doit dire quoi en
    conclure — c'est toute la différence avec un tableau de valeurs."""
    r = client.post("/sante", data={"_csrf": _jeton(client, "/sante")},
                    follow_redirects=True)
    assert "adresse de conteneur périmée" in r.text or "mandataire ne joint pas" in r.text
    assert "rien n" in r.text  # « rien n'écoute »
    # Et la commande de remède, pour la pile en 502.
    assert "restart reverse" in r.text


def test_un_401_ou_une_redirection_ne_sont_pas_des_pannes(client):
    """Le piège inverse : crier au loup sur un service qui va bien. Un 302 de
    SSOwat et un 200 doivent rester hors du bloc « À regarder »."""
    r = client.post("/sante", data={"_csrf": _jeton(client, "/sante")},
                    follow_redirects=True)
    avant = r.text.split("Applications")[0]      # le bloc « À regarder » seul
    assert "nextcloud" not in avant.lower()
    assert "vaultwarden" not in avant.lower()
    # Et la page explique pourquoi, sinon quelqu'un « corrigera » un 401.
    assert "est un succès" in r.text


def test_les_piles_sans_port_publie_sont_nommees_pas_omises(client):
    """uptime-kuma est en réseau host : il n'y a rien à sonder. Une ligne vide
    serait lue comme une panne — la page doit dire « réseau host »."""
    r = client.post("/sante", data={"_csrf": _jeton(client, "/sante")},
                    follow_redirects=True)
    assert "uptime-kuma" in r.text
    assert "réseau host" in r.text


def test_la_mesure_porte_son_horodatage(client):
    """Une mesure sans heure est un piège : on prend l'état d'il y a une heure pour
    celui du moment."""
    r = client.post("/sante", data={"_csrf": _jeton(client, "/sante")},
                    follow_redirects=True)
    assert "16:42:11" in r.text


def test_la_sonde_exige_un_jeton_csrf(client):
    """Elle déclenche une trentaine de requêtes sortantes : c'est une action, pas
    une lecture.

    L'app refuse par une REDIRECTION avec message, et non par un 403 nu — choix
    délibéré, documenté dans csrf.py : la cause la plus fréquente est une session
    expirée dans un onglet resté ouvert. Ce qu'on vérifie ici n'est donc pas le
    code de retour mais le fait que **la sonde n'a pas eu lieu**.
    """
    r = client.post("/sante", data={"_csrf": "faux"}, follow_redirects=False)
    assert r.status_code == 303, r.status_code
    suite = client.get("/sante")
    assert "Aucune mesure" in suite.text, "la sonde a tourné malgré un jeton invalide"


def test_un_minuteur_actif_mais_desactive_declenche_une_alerte(client):
    """LE PIÈGE CLASSIQUE. « enabled » et « active » sont indépendants, et
    c'est le second qu'on regarde d'instinct. Un minuteur actif mais désactivé
    paraît sain et ne redémarrera pas après un reboot : la réplication meurt à la
    prochaine coupure de courant, sans que rien ne l'ait signalé."""
    r = client.get("/")
    assert r.status_code == 200
    assert "disabled" in r.text, "l'état « enabled » n'est pas affiché"
    assert "ne redémarrera PAS" in r.text
    assert "systemctl enable --now pra-nightly.timer" in r.text


# ── sonder là où l'application répond vraiment ──────────────────────────────


def test_dex_est_sonde_sur_sa_decouverte_oidc_pas_sur_sa_racine():
    """dex arrêté rend quand même 200 sur « /dex/ » : nginx y sert des fichiers
    statiques devant l'application. Une sonde posée sur la racine déclarerait
    donc « ok » un fournisseur d'identité mort. On nomme le chemin qui, lui, ne
    mente pas.
    """
    from pathlib import Path

    src = (Path(__file__).resolve().parent.parent / "helper" / "arche-helper").read_text(
        encoding="utf-8"
    )
    assert "CHEMINS_SONDE" in src, "la table des chemins de sonde a disparu"
    assert ".well-known/openid-configuration" in src, "dex resonde sa racine"
    # Définir la table ne suffit pas : c'est de l'avoir OUBLIÉE dans la boucle
    # qui laisserait le trou intact.
    assert "CHEMINS_SONDE.get(" in src, "la table est définie mais jamais consultée"


def test_l_adresse_affichee_reste_celle_de_l_application(client):
    """Deux adresses, deux rôles. Le lien doit mener à l'application ; l'adresse
    sondée n'apparaît que là où le code HTTP doit être vérifiable."""
    r = client.post("/sante", data={"_csrf": _jeton(client, "/sante")},
                    follow_redirects=True)
    bloc_regarder = r.text.split("À regarder")[1].split("</table>")[0]
    assert ".well-known/openid-configuration" in bloc_regarder, \
        "le code est attribué à une adresse qui n'est pas celle qu'on a sondée"
    # Le tableau complet, lui, garde le lien cliquable vers l'application.
    complet = r.text.split("</table>", 1)[1]
    assert 'href="https://replica.local/dex/"' in complet, \
        "le lien mène au document de découverte au lieu de l'application"


# ── lancer un travail détaché, et savoir qu'il tourne ───────────────────────


def test_la_reponse_de_restauration_ne_reference_pas_une_variable_absente():
    """« proc.pid » ne existe QUE dans la branche de repli de
    _lancer_hors_cgroup. Avec systemd-run — le chemin normal — la fonction rend
    un entier, et la construction de la réponse levait NameError.

    Le travail était DÉJÀ LANCÉ à ce moment : l'interface affichait « Échec »
    sur une restauration qui tournait, ce qui est pire qu'un échec franc — on
    relance, et deux restaurations se disputent la machine.
    """
    from pathlib import Path

    src = (Path(__file__).resolve().parent.parent / "helper" / "arche-helper"
           ).read_text(encoding="utf-8")
    bloc = src.split("def cmd_restaurer")[1].split("def ")[0]
    assert '"pid": proc.pid' not in bloc, "la variable absente est revenue"
    assert '"pid": pid' in bloc


def test_un_travail_lance_par_systemd_est_reconnu_comme_tel():
    """systemd-run rend 0 — l'unité vit sa vie, il n'y a pas de PID à rendre.
    Or « os.kill(0, 0) » vise LE GROUPE DE PROCESSUS COURANT et réussit
    toujours : le tableau de bord affichait « restauration en cours »
    indéfiniment, boutons désactivés compris.
    """
    from pathlib import Path

    src = (Path(__file__).resolve().parent.parent / "helper" / "arche-helper"
           ).read_text(encoding="utf-8")
    bloc = src.split("def _travail_en_cours")[1].split("\ndef ")[0]
    assert "systemctl" in bloc, "systemd n'est plus interrogé"
    assert "if pid <= 0:" in bloc, "un PID nul serait de nouveau pris pour vivant"
    # Les deux travaux détachés doivent passer par là.
    assert "_travail_en_cours(PIDFILE, " in src
    assert "_travail_en_cours(PIDFILE_BACKUP, " in src
