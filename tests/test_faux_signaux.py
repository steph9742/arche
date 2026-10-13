"""Les faux signaux de la nuit, et ce qui les distingue des vrais.

Deux faux signaux reviennent : une restauration qui rend « partiel » alors
qu'elle a tout restauré, parce que logrotate, rattrapé au réveil, est passé
avant fail2ban et a échoué sur sa rotation — la nuit suivante, même course
gagnée, « succès » ; et une application lente déclarée « mandataire sur une
adresse périmée », son mandataire relancé, alors qu'il suffisait d'attendre
l'amont.

Un signal faux répété apprend à ignorer le vrai. Ces tests verrouillent les
deux corrections SANS absoudre les vraies pannes : c'est la moitié qui compte.
"""

import os
import re
import subprocess
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
SURCHARGE = RACINE / "pra" / "logrotate-apres-fail2ban.conf"
INSTALL = (RACINE / "scripts" / "install.sh").read_text(encoding="utf-8")
DOCKER = (RACINE / "pra" / "pra_docker_restore.sh").read_text(encoding="utf-8")


# ── logrotate après fail2ban ────────────────────────────────────────────────

def test_logrotate_est_ordonne_apres_fail2ban():
    texte = SURCHARGE.read_text(encoding="utf-8")
    lignes = [l.strip() for l in texte.splitlines() if l.strip() and not l.startswith("#")]
    assert lignes[0] == "[Unit]"
    assert "After=fail2ban.service" in lignes


def test_l_ordre_ne_devient_pas_une_dependance():
    """« Requires= » ferait disparaître le signal : si fail2ban est vraiment en
    panne, logrotate DOIT encore échouer, et ce sera cette fois un vrai signal."""
    texte = SURCHARGE.read_text(encoding="utf-8")
    actives = [l for l in texte.splitlines() if not l.lstrip().startswith("#")]
    assert not any(re.match(r"\s*(Requires|BindsTo|Requisite)=", l) for l in actives)


def test_l_installation_pose_et_verifie_la_surcharge():
    assert "logrotate.service.d/arche-apres-fail2ban.conf" in INSTALL
    # Une surcharge mal placée est ignorée sans un mot : on contrôle qu'elle a pris.
    assert "systemctl show logrotate.service -p After" in INSTALL


# ── wiki : attendre l'amont avant de diagnostiquer ──────────────────────

def _patience(codes, patience="90"):
    """Exécute le VRAI bloc de patience de pra_docker_restore.sh, avec une sonde
    qui rend successivement « codes » et un sommeil instantané."""
    debut = DOCKER.index("      _injoignable() {")
    fin = DOCKER.index("rien à relancer\"\n      fi\n") + len("rien à relancer\"\n      fi\n")
    bloc = DOCKER[debut:fin]
    suite = Path(os.environ.get("TMPDIR", "/tmp")) / f"codes-{os.getpid()}-{len(codes)}"
    suite.write_text("\n".join(codes[1:]) + "\n", encoding="utf-8")
    script = f'''set -euo pipefail
sleep() {{ :; }}
log() {{ echo "LOG $*"; }}
_code_http() {{
  local c; c="$(head -1 "{suite}")"; tail -n +2 "{suite}" > "{suite}.n"; mv "{suite}.n" "{suite}"
  echo "${{c:-502}}"
}}
name=wiki; _sonde_port=8076; _c={codes[0]}
PRA_DOCKER_PATIENCE_S={patience}
{bloc}
echo "FINAL $_c $_attendu"
'''
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    suite.unlink(missing_ok=True)
    assert r.returncode == 0, r.stderr
    return r.stdout


def test_un_amont_lent_n_est_pas_une_adresse_perimee():
    sortie = _patience(["502", "502", "302"])
    assert "FINAL 302 20" in sortie
    assert "répond après 20 s" in sortie and "rien à relancer" in sortie


def test_un_502_qui_dure_garde_son_diagnostic():
    """La patience ne doit pas absoudre : un mandataire vraiment perdu reste 502,
    et le bloc laisse la main au remède (relance du seul mandataire)."""
    sortie = _patience(["502"] * 20, patience="30")
    assert "FINAL 502 30" in sortie
    assert "rien à relancer" not in sortie


def test_ce_qui_repond_tout_de_suite_n_attend_pas():
    sortie = _patience(["302"])
    assert "FINAL 302 0" in sortie
    assert "LOG" not in sortie


def test_la_patience_precede_le_diagnostic():
    assert DOCKER.index("_injoignable() {") < DOCKER.index("adresse périmée\"")
