"""La sélection des piles et des applications accepte espaces ET virgules.

Le cas est passé par là : /etc/pra/pra.conf déclare ses listes à l'ESPACE —
seule écriture que la webapp (v_liste) sache produire — tandis que wanted(),
dans pra_docker_restore.sh, comparait à la VIRGULE. Aucune pile ne correspond
alors jamais : « 0 pile(s) à traiter » chaque nuit, verdict « succès », et des
données Docker figées au dernier passage manuel. Ces tests exécutent le code
RÉEL des scripts (extrait, pas recopié) pour que la classe entière — un
séparateur figé face à une conf qui en produit un autre — ne revienne pas.

Même nuit, l'autre panne : la rétention GFS tranchait correctement mais en
« compte rendu seul » (PRA_PURGE_APPLIQUER=0 par défaut) — trois semaines sans
supprimer, 278 Go de copies préparées, disque plein, restauration du 15/08
arrêtée APRÈS la désinstallation des applications. Les tests vérifient que le
défaut est désormais l'application réelle, et que la bibliothèque décide juste.
"""

import re
import subprocess
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
DOCKER_RESTORE = RACINE / "pra" / "pra_docker_restore.sh"
REPLICA = RACINE / "pra" / "pra_restore_replica.sh"

ENV_MIN = {"PATH": "/usr/bin:/bin", "HOME": "/tmp"}


def _bloc(texte: str, debut: str, fin: str) -> str:
    m = re.search(re.escape(debut) + r".*?" + re.escape(fin), texte, re.S)
    assert m, f"bloc introuvable dans le script : {debut!r} … {fin!r}"
    return m.group(0)


def _wanted(stacks: str, pile: str, only: str = "") -> str:
    texte = DOCKER_RESTORE.read_text()
    bloc_only = _bloc(texte, 'ONLY="${PRA_ONLY', 'SKIP_BUILD=')
    bloc_only = bloc_only[: bloc_only.rindex("SKIP_BUILD=")]
    # « wanted() { » avec l'accolade : le nom seul apparaît aussi dans les
    # commentaires du script, et l'extraction s'y était fait piéger.
    bloc_wanted = _bloc(texte, "wanted() {", "\n}")
    code = (
        "set -u\n"
        f"{bloc_only}\n{bloc_wanted}\n"
        f'wanted "{pile}" && echo OUI || echo NON\n'
    )
    env = dict(ENV_MIN, PRA_DOCKER_STACKS=stacks, PRA_ONLY=only)
    r = subprocess.run(["bash", "-c", code], capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def test_liste_a_espaces_selectionne_chaque_pile():
    # L'écriture que produit réellement la webapp : c'est CE cas qui échouait.
    stacks = "notes annuaire recherche wiki uptime-kuma tableau"
    for pile in stacks.split():
        assert _wanted(stacks, pile) == "OUI", pile


def test_liste_a_virgules_selectionne_chaque_pile():
    stacks = "notes,annuaire,wiki"
    for pile in stacks.split(","):
        assert _wanted(stacks, pile) == "OUI", pile


def test_pile_hors_liste_rejetee():
    assert _wanted("notes annuaire", "wiki") == "NON"
    assert _wanted("notes,annuaire", "wiki") == "NON"


def test_liste_vide_prend_tout():
    assert _wanted("", "nimporte") == "OUI"


def test_pra_only_prioritaire():
    assert _wanted("notes", "annuaire", only="annuaire") == "OUI"


def test_le_nom_partiel_ne_matche_pas():
    # « redirect » ne doit pas sélectionner « redirect__2 », ni l'inverse.
    assert _wanted("redirect__2", "redirect") == "NON"


def _app_selectionnee(apps: str, app: str) -> str:
    texte = REPLICA.read_text()
    bloc = _bloc(texte, "app_selectionnee()", "\n}")
    code = (
        "set -u\n"
        f'RESTORE_APPS="{apps}"\n{bloc}\n'
        f'app_selectionnee "{app}" && echo OUI || echo NON\n'
    )
    r = subprocess.run(["bash", "-c", code], capture_output=True, text=True, env=ENV_MIN)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def test_apps_yunohost_espaces_et_virgules():
    assert _app_selectionnee("dex nextcloud", "dex") == "OUI"
    assert _app_selectionnee("dex,nextcloud", "nextcloud") == "OUI"
    assert _app_selectionnee("dex nextcloud", "moodle") == "NON"
    assert _app_selectionnee("", "moodle") == "OUI"
    assert _app_selectionnee(" , ", "moodle") == "OUI"


def test_purge_appliquee_par_defaut():
    # Le mode « compte rendu seul » ne doit plus être le défaut : c'est lui qui
    # a laissé le disque se remplir. Le réglage reste disponible en conf.
    for script in (REPLICA, RACINE / "pra" / "yunohost_backup_daily.sh"):
        assert 'PURGE_APPLIQUER="${PRA_PURGE_APPLIQUER:-1}"' in script.read_text(), script.name


def _decisions(tmp_path, noms):
    d = tmp_path / "magasin"
    d.mkdir()
    for nom in noms:
        (d / nom).write_text("x")
    lib = RACINE / "pra" / "pra_retention.sh"
    code = f'. "{lib}"\ndecisions_gfs "{d}" 2 1 1 2\n'   # 2 jours, 1 lundi, 1 mois, plancher 2
    r = subprocess.run(["bash", "-c", code], capture_output=True, text=True, env=ENV_MIN)
    assert r.returncode == 0, r.stderr
    return {
        Path(ligne.split()[1]).name: ligne.split()[0]
        for ligne in r.stdout.strip().splitlines()
    }


def test_retention_purge_les_vieilles_et_garde_les_jalons(tmp_path):
    verdicts = _decisions(tmp_path, [
        "20260701-000001.tar",     # mois révolu, hors quota (1 mois) -> purgé
        "20260801-000001.tar",     # première archive du mois courant -> jalon
        "20260803-000001.tar",     # lundi le plus récent -> jalon gardé
        "20260814-000001.tar",     # deux derniers jours présents -> gardés
        "20260815-000001.tar",
        "nextcloud-pre-upgrade1.tar",   # nom inconnu -> JAMAIS purgé
    ])
    assert verdicts["20260815-000001.tar"] == "GARDER"
    assert verdicts["20260814-000001.tar"] == "GARDER"
    assert verdicts["20260803-000001.tar"] == "GARDER"      # lundi
    assert verdicts["20260801-000001.tar"] == "GARDER"      # premier du mois
    assert verdicts["20260701-000001.tar"] == "PURGER"
    assert verdicts["nextcloud-pre-upgrade1.tar"] == "GARDER"


def test_retention_familles_separees(tmp_path):
    # Les instantanés Docker ne consomment pas le quota des archives YunoHost.
    verdicts = _decisions(tmp_path, [
        "20260814-000001.tar", "20260815-000001.tar",
        "20260814-010001-docker.tar", "20260815-010001-docker.tar",
    ])
    assert all(v == "GARDER" for v in verdicts.values()), verdicts
