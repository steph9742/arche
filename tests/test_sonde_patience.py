"""Un service lent à démarrer n'est pas un service en panne.

La sonde tourne juste après la restauration des piles. AFFiNE met plusieurs
dizaines de secondes à servir, et son mandataire (reverseproxy__2) rend 502
tant qu'il n'a pas d'amont : presque chaque nuit annonçait donc « notes et
reverseproxy__2 ne répondent plus », alors que les deux étaient debout deux
minutes plus tard. Une alerte qui se trompe régulièrement cesse d'être lue — et
le jour où elle aura raison, personne ne la croira.

D'où « --patienter », réservé à l'appel de la nuit : on redemande à CE QUI A
ÉCHOUÉ, et le temps qu'il a fallu est conservé pour que le journal le dise.
La page Santé de l'interface, elle, ne patiente pas : elle doit répondre tout
de suite, sinon elle expire derrière le mandataire.
"""

import importlib.util
import re
import subprocess
import sys
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
HELPER = (RACINE / "helper" / "arche-helper").read_text(encoding="utf-8")
NIGHTLY = (RACINE / "pra" / "pra_nightly.sh").read_text(encoding="utf-8")



def _charger_helper():
    """Charge arche-helper comme module : il n'a pas d'extension .py, mais c'est
    bien SON code qu'on veut exercer, pas une recopie."""
    sys.path.insert(0, str(RACINE))
    spec = importlib.util.spec_from_loader(
        "arche_helper",
        importlib.machinery.SourceFileLoader(
            "arche_helper", str(RACINE / "helper" / "arche-helper")))
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


H = _charger_helper()


def _app(ident, verdict):
    return {"id": ident, "nom": ident, "url": "https://x/", "code": "502",
            "verdict": verdict}


def _pile(nom, verdict, port="3010"):
    return {"nom": nom, "port": port, "mandataire": nom, "code": "502",
            "verdict": verdict}


def _cibles(*ids):
    # aFaire porte (ident, label, url, url_sonde, domaine)
    return {i: (i, i, "https://x/", "https://x/", "x.local") for i in ids}


def test_notes_lent_finit_par_repondre_et_n_alerte_pas():
    """Le cas réel : notes et son mandataire rendent 502, puis servent."""
    apps = [_app("notes", "erreur"), _app("dex", "ok")]
    piles = [_pile("notes", "erreur")]
    appels = []

    def sonder(url, hote=None):
        appels.append(url)
        # Rien au premier passage, tout au second.
        return "200" if len([a for a in appels if a == url]) > 1 else "502"

    attendu = H._seconde_chance(apps, piles, _cibles("notes", "dex"),
                                budget=120, pas=30, sonder=sonder,
                                dormir=lambda s: None)
    par_id = {a["id"]: a for a in apps}
    assert par_id["notes"]["verdict"] == "ok"
    assert par_id["notes"]["apparu_apres_s"] == 60
    assert piles[0]["verdict"] == "ok"
    assert attendu == 60


def test_on_ne_redemande_jamais_a_ce_qui_repond_deja():
    """Le coût n'est payé que dans le cas anormal : resonder les services sains
    allongerait chaque nuit de trois minutes pour rien."""
    apps = [_app("dex", "ok"), _app("moodle", "ok")]
    interroges = []

    def sonder(url, hote=None):
        interroges.append(url)
        return "200"

    H._seconde_chance(apps, [], _cibles("dex", "moodle"),
                      budget=120, pas=30, sonder=sonder, dormir=lambda s: None)
    assert interroges == [], "un service sain a été resondé"


def test_une_pile_non_sondable_n_est_pas_un_retard():
    """Il n'y a rien à interroger : attendre trois minutes pour elle allongerait
    la nuit sans rien apprendre."""
    piles = [_pile("uptime-kuma", "non sondable", port=None)]
    dormi = []
    attendu = H._seconde_chance([], piles, {}, budget=120, pas=30,
                                sonder=lambda *a, **k: "200",
                                dormir=lambda s: dormi.append(s))
    assert dormi == [] and attendu == 0


def test_une_vraie_panne_reste_une_panne():
    """La patience ne doit pas absoudre : ce qui ne répond jamais garde son
    verdict, et l'alerte part — c'est tout l'intérêt du dispositif."""
    apps = [_app("notes", "erreur")]
    attendu = H._seconde_chance(apps, [], _cibles("notes"), budget=90, pas=30,
                                sonder=lambda *a, **k: "502",
                                dormir=lambda s: None)
    assert apps[0]["verdict"] == "erreur"
    assert "apparu_apres_s" not in apps[0]
    assert attendu == 90, "le budget doit être consommé entièrement"


def test_la_patience_est_bornee():
    """Une attente non bornée ferait déborder la nuit sans qu'on s'en aperçoive."""
    dormi = []
    H._seconde_chance([_app("x", "erreur")], [], _cibles("x"),
                      budget=100, pas=30, sonder=lambda *a, **k: "000",
                      dormir=lambda s: dormi.append(s))
    assert sum(dormi) <= 100 and len(dormi) == 3


def test_un_401_compte_comme_une_reponse():
    """« Le service répond et demande à s'authentifier » est un succès : sans
    cela la patience s'épuiserait sur des services parfaitement sains."""
    apps = [_app("vaultwarden", "erreur")]
    H._seconde_chance(apps, [], _cibles("vaultwarden"), budget=60, pas=30,
                      sonder=lambda *a, **k: "401", dormir=lambda s: None)
    assert apps[0]["verdict"] == "ok" and apps[0]["apparu_apres_s"] == 30


def test_la_patience_est_reservee_a_la_nuit():
    # L'interface appelle « sante » sans option : elle ne doit jamais attendre.
    assert '"--patienter"' in HELPER
    assert 'sante --patienter' in NIGHTLY, "le nocturne doit demander la patience"


def test_le_helper_reste_syntaxiquement_valide():
    r = subprocess.run([sys.executable, "-c",
                        "import ast,sys; ast.parse(open(sys.argv[1]).read())",
                        str(RACINE / "helper" / "arche-helper")],
                       capture_output=True, text=True)
    assert r.returncode == 0, r.stderr

def test_le_journal_dit_ce_qui_a_demarre_lentement():
    """Taire le délai remplacerait une fausse alerte par un silence : un service
    qui met 90 s à répondre finira par dépasser la patience de la sonde."""
    assert "apparu_apres_s" in NIGHTLY
    assert "lent au démarrage" in NIGHTLY


def test_la_patience_par_defaut_reste_raisonnable():
    """Réglable, mais pas au point de faire déborder la nuit."""
    src = (RACINE / "helper" / "arche-helper").read_text(encoding="utf-8")
    d = re.search(r'PRA_SANTE_PATIENCE_S", "(\d+)"', src)
    p = re.search(r'PRA_SANTE_PAS_S", "(\d+)"', src)
    assert d and p
    assert 60 <= int(d.group(1)) <= 600
    assert 5 <= int(p.group(1)) <= 60
