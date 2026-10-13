"""Le choix d'archive, l'âge des données, et la comparaison de santé.

Ces trois ajouts répondent à autant de manques constatés à l'usage :

  - **Choisir une archive antérieure** était impossible depuis l'interface. Or le
    jour d'un rançongiciel, l'archive la plus récente est justement celle dont on
    se méfie — le chiffrement a pu être répliqué la nuit passée. Le geste le plus
    critique du dispositif n'existait qu'en ligne de commande.

  - **L'âge des données** n'était affiché nulle part. Une archive
    « 20260730-022349 » restaurée à 15 h 34 porte l'état de 02 h 23 : treize
    heures d'écart, invisibles.

  - **La comparaison de santé** manquait : « 24 services joignables » ne dit rien,
    « hier 29, ce matin 24 » désigne le problème.

Le premier touche à la sécurité — un nom venu de l'interface sert à désigner un
fichier lu en root — d'où les tests d'injection en tête.
"""

from __future__ import annotations

import re
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pytest

RACINE = Path(__file__).resolve().parent.parent
HELPER = RACINE / "helper" / "arche-helper"


# ── validation du nom d'archive, côté helper ────────────────────────────────


def _valide(nom: str) -> bool:
    """Le filtre du helper, tel qu'il est écrit — on teste la règle réelle."""
    return bool(re.fullmatch(r"\d{8}-\d{6}(\.tar)?", nom))


@pytest.mark.parametrize("nom", [
    "20260730-022349",
    "20260730-022349.tar",
    "20260101-000000",
])
def test_les_noms_legitimes_passent(nom):
    assert _valide(nom), nom


@pytest.mark.parametrize("nom", [
    "../../etc/shadow",
    "/etc/shadow",
    "20260730-022349/../../../etc/passwd",
    "20260730-022349.tar; rm -rf /",
    "20260730-022349$(whoami)",
    "..%2f..%2fetc",
    "20260730-02234",          # un chiffre de moins
    "2026730-022349",          # date trop courte
    "",
    "nextcloud-pre-upgrade1",  # une vraie archive, mais pas au nommage attendu
])
def test_aucun_nom_dangereux_ne_passe(nom):
    """Le nom vient d'un compte NON PRIVILÉGIÉ et sert à désigner un fichier lu
    en root. Aucun caractère de chemin ne doit franchir ce filtre."""
    assert not _valide(nom), f"« {nom} » a été accepté"


def test_le_helper_refuse_de_tourner_hors_root():
    """Contrôle d'abord la garde qui rend les autres possibles : le helper est le
    seul composant privilégié, et il doit refuser toute invocation non root — y
    compris la nôtre."""
    r = subprocess.run(
        [sys.executable, str(HELPER), "restaurer", "--valider",
         "--archive", "20200101-000000"],
        capture_output=True, text=True, timeout=30,
        env={"PATH": "/usr/bin:/bin", "ARCHE_APP_DIR": str(RACINE)},
    )
    assert r.returncode != 0
    assert "root" in (r.stdout + r.stderr).lower(), r.stdout + r.stderr


def test_les_trois_couches_de_validation_sont_presentes():
    """Le nommage ne suffit pas. Un nom bien formé peut désigner un lien
    symbolique déposé entre-temps, ou un fichier hors du magasin. Les trois
    contrôles doivent coexister — et comme le helper exige root, on ne peut pas
    les éprouver en exécution ici : on vérifie qu'ils sont écrits.
    """
    src = HELPER.read_text(encoding="utf-8")
    bloc = src.split("ARCHIVE DÉSIGNÉE")[1][:2000]
    assert 're.fullmatch(r"\\d{8}-\\d{6}' in bloc, "le filtre de nommage a disparu"
    assert ".resolve()" in bloc, "la résolution des liens symboliques a disparu"
    assert "is_file()" in bloc, "le contrôle d'existence a disparu"
    assert "parent !=" in bloc, "le contrôle d'appartenance au magasin a disparu"


# ── âge des données ─────────────────────────────────────────────────────────


def _age(nom: str):
    sys.path.insert(0, str(RACINE))
    from app.main import _age_donnees

    return _age_donnees({"yunohost": {"archive": nom}})


def test_l_age_vient_du_nom_de_l_archive_pas_de_la_restauration():
    """C'est tout l'intérêt : l'heure de restauration n'est pas celle des
    données."""
    hier = datetime.now() - timedelta(hours=13)
    a = _age(hier.strftime("%Y%m%d-%H%M%S"))
    assert a is not None
    assert 12 <= a["heures"] <= 14, a
    assert not a["vieux"]


def test_au_dela_de_deux_nuits_c_est_signale():
    vieux = datetime.now() - timedelta(days=3)
    a = _age(vieux.strftime("%Y%m%d-%H%M%S"))
    assert a["vieux"], a
    assert a["heures"] >= 72


@pytest.mark.parametrize("nom", ["", "bookstack-pre-upgrade1", "pas-une-date", None])
def test_un_nom_non_horodate_ne_produit_pas_de_faux_age(nom):
    """Les archives « pre-upgrade » de YunoHost ne portent pas de date. Inventer
    un âge à partir d'elles serait pire que de n'en afficher aucun."""
    assert _age(nom or "") is None


def test_l_age_est_affiche_et_alerte_sur_le_tableau_de_bord(client):
    """Le faux helper rend une archive du 27/07 : à la date des tests elle a plus
    de deux nuits, donc l'alerte doit sortir."""
    r = client.get("/")
    assert r.status_code == 200
    assert "Âge des données" in r.text or "ge des donn" in r.text


# ── sélecteur d'archive dans l'interface ────────────────────────────────────


def test_le_selecteur_propose_les_archives(client):
    r = client.get("/")
    assert 'name="archive"' in r.text, "le sélecteur d'archive est absent"
    assert "20260727-000001" in r.text, "les archives connues ne sont pas proposées"
    assert "plus récente du jour" in r.text, "le défaut n'est pas explicite"


def test_le_selecteur_explique_le_cas_du_rancongiciel(client):
    """Un sélecteur sans explication serait dangereux : on choisirait la plus
    récente par réflexe, c'est-à-dire justement la suspecte."""
    r = client.get("/")
    assert "avant la contamination" in r.text


# ── comparaison de santé ────────────────────────────────────────────────────


def test_la_regression_se_calcule_dans_le_bon_sens():
    """On ne signale QUE ce qui répondait et ne répond plus. Une application qui
    se remet à répondre est une bonne nouvelle, pas une alerte — et noyer les
    régressions dans les améliorations ferait cesser de lire."""
    avant = {"nextcloud", "moodle", "n8n"}
    apres = {"nextcloud", "n8n", "freshrss"}
    regressions = sorted(avant - apres)
    assert regressions == ["moodle"]
    assert "freshrss" not in regressions


# ── instantané Docker : appariement et choix explicite ──────────────────────


def _valide_snap(nom: str) -> bool:
    """Le filtre du helper pour un instantané Docker — les DEUX nommages.

    L'heure fait partie du nom : sans elle, un instantané manuel porte le même
    nom que celui du cron, et le magasin en écriture unique
    (--ignore-existing) ne le transfère jamais. Une restauration lancée exprès
    derrière une sauvegarde manuelle repart alors, silencieusement, sur l'état
    de la nuit.
    """
    return bool(re.fullmatch(r"\d{8}(-\d{6})?-docker(\.tar)?", nom))


@pytest.mark.parametrize("nom", ["20260727-docker", "20260727-docker.tar",
                                 "20260808-172854-docker", "20260808-172854-docker.tar"])
def test_les_instantanes_legitimes_passent(nom):
    assert _valide_snap(nom)


@pytest.mark.parametrize("nom", [
    "../../etc/shadow", "/etc/shadow", "20260727-docker.tar; rm -rf /",
    "20260727-000001", "docker", "", "20260727-docker/../x",
])
def test_aucun_instantane_dangereux_ne_passe(nom):
    assert not _valide_snap(nom), f"« {nom} » accepté"


def test_les_deux_listes_sont_separees(client):
    """Mêler archives YunoHost et instantanés Docker faisait proposer, dans le
    sélecteur d'archive, un choix que la validation rejette toujours."""
    r = client.get("/")
    assert 'name="archive"' in r.text and 'name="instantane"' in r.text
    # L'instantané ne doit pas figurer parmi les archives, ni l'inverse.
    bloc_archive = r.text.split('name="archive"')[1].split("</select>")[0]
    assert "docker" not in bloc_archive, "un instantané Docker proposé comme archive"
    bloc_snap = r.text.split('name="instantane"')[1].split("</select>")[0]
    assert "20260727-000001" not in bloc_snap, "une archive proposée comme instantané"


def test_l_appariement_par_jour_est_le_defaut(client):
    """Sans appariement, choisir une archive antérieure pour fuir un chiffrement
    laissait les piles Docker ramener l'instantané du jour."""
    r = client.get("/")
    assert "Apparié au jour de l'archive" in r.text


def test_le_repli_ne_remonte_jamais_vers_un_instantane_posterieur():
    """La règle qui compte : à défaut du jour exact, on prend le plus récent qui
    ne soit PAS postérieur. Prendre un instantané plus récent que l'archive
    ramènerait précisément ce qu'on cherche à éviter."""
    dispo = ["20260727-docker.tar", "20260729-docker.tar", "20260731-docker.tar"]
    def choisir(jour):
        exact = f"{jour}-docker.tar"
        if exact in dispo:
            return exact
        anterieurs = [s for s in sorted(dispo) if s <= exact]
        return anterieurs[-1] if anterieurs else None
    assert choisir("20260729") == "20260729-docker.tar"
    assert choisir("20260730") == "20260729-docker.tar"   # repli, pas le 31
    assert choisir("20260726") is None                    # rien d'antérieur
    assert choisir("20260728") == "20260727-docker.tar"


def test_l_appariement_prend_l_instantane_le_plus_proche_dans_le_temps():
    """Deux instantanés le même jour — celui du cron à 01h00, un manuel à
    17h45. L'archive manuelle de 17h28 doit se marier avec le manuel qu'elle a
    déclenché, et l'archive nocturne de 00h00 avec celui du cron. C'est la
    règle du script de restauration, reproduite ici à l'identique."""
    import re as _re

    def h(n):
        m = _re.match(r"\d{8}-(\d{6})-docker\.tar$", n)
        return int(m.group(1)) if m else 0

    noms = ["20260808-docker.tar", "20260808-174500-docker.tar"]

    def plus_proche(heure):
        return sorted(noms, key=lambda n: abs(h(n) - int(heure)))[0]

    assert plus_proche("172854") == "20260808-174500-docker.tar"
    assert plus_proche("000001") == "20260808-docker.tar"
    # Et la validation du helper doit accepter le nouveau nommage, sinon le
    # sélecteur de l'interface refuserait ce que le magasin contient.
    src = HELPER.read_text(encoding="utf-8")
    assert r"\d{8}(-\d{6})?-docker" in src


# ── une construction qui rate ne doit pas coucher la pile ────────────────────


def test_la_construction_est_retentee_puis_repliee_sur_l_image_precedente():
    """Une construction peut échouer sur un incident de téléchargement —
    « Fail extracting tarball » — et non sur une erreur de code. La pile reste
    alors à terre toute la nuit, alors que ses images de la veille sont encore
    présentes, et ne revient qu'au réveil suivant, ramassée par le filet de
    démarrage : par chance, pas par conception.

    Deux parades, dans cet ordre : réessayer, puis démarrer sur l'image
    précédente en le disant. Un service dégradé qu'on sait dégradé vaut mieux
    qu'un service absent.
    """
    from pathlib import Path

    src = (Path(__file__).resolve().parent.parent / "pra" / "pra_docker_restore.sh"
           ).read_text(encoding="utf-8")
    assert "nouvelle tentative dans 15 s" in src, "la seconde tentative a disparu"
    assert "--no-build" in src, "le repli sur l'image précédente a disparu"
    # « --no-build » est essentiel : sans lui, « up » relance la construction et
    # reproduit exactement l'échec qu'on cherche à contourner.
    bloc = src.split("CONSTRUCTION EN ÉCHEC")[1][:1600]
    assert "docker compose up -d --no-build" in bloc
    assert "IMAGE PRÉCÉDENTE" in bloc, "le repli se ferait en silence"
    assert "aucune image utilisable" in bloc, "le cas sans image n'est plus distingué"


def test_une_tache_ponctuelle_deja_passee_ne_couche_pas_la_pile():
    """annuaire déclare « depends_on: migrate: service_completed_successfully ».
    Au démarrage, « up -d » relance la migration, qui échoue en
    « duplicate_object » puisque la base porte déjà son schéma — restauré la
    nuit. La condition n'étant pas remplie, app, server et reverse ne démarrent
    pas du tout : la pile reste à terre pour une tâche qui a fait son travail.

    Le repli reprend service par service, sans dépendances, en sautant
    précisément les travaux dont une CONDITION D'ACHÈVEMENT dépend. Mesuré sur
    une pile réelle : 0/6 conteneurs debout contre 5/6, et un port qui passe de
    muet à 404 — le 404 étant la bonne réponse d'un mandataire pour une
    application servie sous sous-chemin.
    """
    from pathlib import Path

    src = (Path(__file__).resolve().parent.parent / "pra" / "pra_piles_docker.sh"
           ).read_text(encoding="utf-8")
    assert "service_completed_successfully" in src, \
        "les tâches ponctuelles ne sont plus identifiées"
    assert "--no-deps" in src, "le repli service par service a disparu"
    # Sauter les tâches ponctuelles n'a de sens que si l'on redémarre TOUT LE
    # RESTE : filtrer sans reprendre les autres ne réparerait rien.
    assert "config --services" in src, "les autres services ne sont plus repris"


def test_l_historique_de_comparaison_se_construit_tout_seul():
    """« applications : 26 (historique insuffisant : 0 référence(s)) » à chaque
    nuit depuis l'origine : le contrôle cherchait des « <archive>.info.json »
    que personne n'écrivait. Une garde anti-rançongiciel inerte, qui annonçait
    poliment son abstention — et qu'on lisait comme un contrôle passé.

    L'arche constitue désormais l'historique depuis les archives qu'elle a
    déjà : dix secondes par archive de 12 Go, une fois, puis en cache.
    """
    from pathlib import Path

    src = (Path(__file__).resolve().parent.parent / "pra" / "pra_restore_replica.sh"
           ).read_text(encoding="utf-8")
    bloc = src.split("LE CONTRÔLE N'AVAIT JAMAIS TOURNÉ")[1][:2200]
    assert "tar xOf" in bloc, "l'indexation a disparu"
    assert "head -10" in bloc, "l'indexation n'est plus bornée"
    # Écrire à côté puis renommer : une extraction interrompue laisserait
    # sinon un fichier tronqué que la comparaison lirait comme une vérité.
    assert ".info.json.tmp" in bloc and "mv -f" in bloc, \
        "l'écriture n'est plus atomique"
    # Et l'archive du jour ne doit pas se comparer à elle-même.
    assert '! -name "$(basename "$ARCHIVE_FILE").info.json"' in src


def test_le_filet_de_demarrage_ne_se_croit_pas_bloque_en_permanence():
    """« kill -0 0 » vise le groupe de processus courant et réussit TOUJOURS.
    Or le fichier de PID contient précisément « 0 » depuis que la restauration
    part par systemd-run, qui n'en rend pas.

    Le garde-fou concluait donc « une restauration tourne » à chaque exécution,
    indéfiniment : le filet ne relançait plus rien, EN SILENCE, et l'on croyait
    qu'il faisait son travail. Cela se découvre en cherchant pourquoi une pile
    reste à terre après une restauration.
    """
    from pathlib import Path

    src = (Path(__file__).resolve().parent.parent / "pra" / "pra_piles_docker.sh"
           ).read_text(encoding="utf-8")
    assert "systemctl is-active --quiet arche-restauration.service" in src, \
        "systemd n'est plus interrogé"
    assert '[ "$pid" -gt 0 ] || return 1' in src, \
        "un PID nul serait de nouveau pris pour un processus vivant"


def test_le_rechargement_des_bases_ne_s_ancre_jamais_sur_la_base_effacee():
    """La purge avant rechargement a créé un piège en trois exemplaires : la
    sonde de connexion, le chargement et le comptage s'ancraient tous sur
    POSTGRES_DB — la base applicative, c'est-à-dire précisément celle qu'on
    vient d'effacer. Chacun tue ou dévoie un essai à sa manière :

      23:35  le chargement s'ancre sur la base effacée → dump jamais chargé,
             comptage qui meurt sous set -e
      23:40  la sonde attend deux minutes sur une base absente → wiki
             déclaré en échec sur un serveur parfaitement vivant

    « postgres » existe toujours et n'est jamais effacée : c'est le seul point
    d'accroche sûr. Le comptage, lui, reste sur la base applicative — c'est ce
    qu'on mesure — mais protégé pour rendre un échec honnête au lieu de tuer.
    """
    from pathlib import Path

    src = (Path(__file__).resolve().parent.parent / "pra" / "pra_docker_restore.sh"
           ).read_text(encoding="utf-8")
    bloc = src.split("restore_pg()")[1]
    assert "psql ${PG_ARGS} -d postgres -tAc 'select 1'" in bloc, \
        "la sonde s'ancre de nouveau sur la base applicative"
    assert "-d postgres -q -o /dev/null" in bloc, \
        "le chargement s'ancre de nouveau sur la base applicative"
    assert "DROP DATABASE IF EXISTS" in bloc, "la purge avant rechargement a disparu"
    assert "tr -dc '0-9' || true" in bloc, \
        "un comptage sur base absente tuerait de nouveau le script"


def test_un_instantane_tronque_est_mis_en_quarantaine_pas_promis_a_un_refetch():
    """« il sera retéléchargé » était une promesse fausse : le magasin est en
    écriture unique (--ignore-existing), un fichier présent n'est JAMAIS
    réécrit. Un instantané tronqué serait resté en place et aurait fait échouer
    chaque nuit avec le même message, indéfiniment.

    Même famille que le nommage au jour : une hypothèse de retéléchargement
    écrite avant la doctrine d'écriture unique, jamais réconciliée avec elle.
    La quarantaine renomme — sans supprimer : si la production envoie des
    fichiers corrompus, ces copies sont des indices — et libère le nom.
    """
    from pathlib import Path

    src = (Path(__file__).resolve().parent.parent / "pra" / "pra_docker_restore.sh"
           ).read_text(encoding="utf-8")
    assert "instantané tronqué, il sera retéléchargé" not in src, \
        "la promesse fausse est revenue"
    bloc = src.split("empreinte NON conforme")[0][-1800:] + src.split("empreinte NON conforme")[1][:600]
    assert ".corrompu-" in bloc, "la quarantaine a disparu"
    assert 'mv -f "$SNAP.sha256"' in bloc, \
        "le .sha256 resterait et re-signalerait un fichier absent"


def test_les_instantanes_de_la_veille_sont_transferes_aussi():
    """Un instantané manuel pris hier soir — après le passage du nocturne —
    n'était couvert par aucun motif de transfert : celui d'hier ne tournera
    plus, celui d'aujourd'hui ne regarde qu'aujourd'hui. Le fichier manquait
    définitivement au miroir. --ignore-existing rend l'élargissement sans
    risque : ce qui est là n'est jamais réécrit."""
    from pathlib import Path

    racine = Path(__file__).resolve().parent.parent
    for script in ("pra_nightly.sh", "pra_restore_replica.sh"):
        src = (racine / "pra" / script).read_text(encoding="utf-8")
        assert "date -d yesterday +%Y%m%d" in src, f"{script} : la veille a disparu"
        assert src.count("-docker.tar*") >= 1, f"{script} : le motif de transfert a disparu"


def test_les_logos_du_portail_sont_synchronises_depuis_la_production():
    """« yunohost backup » n'inclut pas /usr/share/yunohost/applogos/ : les
    logos téléversés à la main n'existent que sur la production. Les réglages
    restaurés les référencent par empreinte — la référence voyage dans
    l'archive, le fichier jamais — et le portail du réplica affiche alors
    « ? » à la place des vignettes.

    Sans --ignore-existing, délibérément : un logo est un fichier public
    remplaçable, pas une sauvegarde à protéger — un logo changé sur la
    production doit suivre.
    """
    from pathlib import Path

    src = (Path(__file__).resolve().parent.parent / "pra" / "pra_restore_replica.sh"
           ).read_text(encoding="utf-8")
    assert "/usr/share/yunohost/applogos/" in src, "la synchronisation a disparu"
    bloc = src.split("LES LOGOS DU PORTAIL")[1][:1400]
    assert "--ignore-existing" not in bloc.split("rsync")[1].split("||")[0], \
        "un logo changé sur la production ne suivrait plus"
