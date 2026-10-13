"""Le réveil de l'arche : la seule chose qui la ramène à la vie.

L'arche passe sa journée éteinte. Rien ne la rallume qu'une alarme inscrite dans
son horloge matérielle — et une machine éteinte n'alerte personne. C'est donc le
point du dispositif où une erreur est à la fois la plus silencieuse et la plus
totale : pas de réplication, pas de journal, pas de notification, rien.

Ces tests portent sur les deux façons de perdre le réveil, que l'ajout d'un
second réveil de mise au point fait aussitôt apparaître :

  - **armer une alarme déjà passée**. « 02:00 tomorrow » est toujours à venir, si
    bien que la question ne se posait pas. Viser une heure du jour même la pose :
    une restauration qui déborde au-delà de l'heure visée arme une alarme dans le
    passé, que le noyau accepte sans broncher et qui ne sonnera jamais.

  - **éteindre sans successeur**. Le nocturne arme l'alarme suivante en sortant.
    Un démarrage hors fenêtre ne fait rien, donc n'arme rien : éteindre après une
    intervention laissait l'arche sans aucun réveil.
"""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

import pytest

RACINE = Path(__file__).resolve().parent.parent
NIGHTLY = RACINE / "pra" / "pra_nightly.sh"
FILET = RACINE / "pra" / "pra_reveil_filet.sh"
UNITE = RACINE / "pra" / "pra-reveil-filet.service"


def _date_gnu() -> bool:
    """« date -d » n'existe pas sur BSD : sur un poste macOS ces tests
    mesureraient le poste, pas le script. L'arche est sous Debian, et
    l'intégration continue aussi — c'est là qu'ils comptent."""
    r = subprocess.run(["date", "-d", "@0", "+%s"], capture_output=True, text=True)
    return r.returncode == 0 and r.stdout.strip() == "0"


besoin_gnu = pytest.mark.skipif(not _date_gnu(), reason="« date -d » absent (BSD)")


def _bash(script: str, env: dict | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                          timeout=30, env={"PATH": "/usr/bin:/bin", **(env or {})})


# ── une alarme dans le passé ────────────────────────────────────────────────


def test_le_report_au_lendemain_est_ecrit_dans_le_nocturne():
    src = NIGHTLY.read_text(encoding="utf-8")
    bloc = src.split("arm_wakealarm()")[1][:1400]
    assert "target=$((target + 86400))" in bloc, "l'alarme passée n'est plus reportée"
    assert 'log "« $WAKE_AT » est déjà passé' in bloc, "le report se ferait en silence"


def test_le_reglage_non_standard_se_signale_a_chaque_nuit():
    """Un réglage temporaire qu'on ne se rappelle pas devient permanent."""
    src = NIGHTLY.read_text(encoding="utf-8")
    assert "RÉVEIL NON STANDARD" in src


# ── le filet d'extinction ───────────────────────────────────────────────────


@besoin_gnu
@pytest.mark.skipif(not FILET.exists(), reason="filet absent du dépôt")
def test_le_filet_n_ecrase_pas_une_alarme_deja_prevue():
    """Le nocturne vient peut-être d'armer le réveil : le filet ne doit jamais
    lui passer devant, sans quoi il déferait le réglage qu'on a choisi."""
    with_tmp = """
      d=$(mktemp -d); alarme="$d/wakealarm"; log="$d/log"
      # une alarme dans une heure : elle doit survivre intacte
      futur=$(( $(date +%s) + 3600 )); echo "$futur" > "$alarme"
      PRA_RTC_WAKEALARM="$alarme" PRA_LOG="$log" bash %s
      echo "RESTE=$(cat "$alarme")"; echo "ATTENDU=$futur"
      grep -q "laissée en place" "$log" && echo "DIT=oui"
      rm -rf "$d"
    """ % FILET
    r = _bash(with_tmp)
    valeurs = dict(re.findall(r"^(RESTE|ATTENDU)=(\d+)$", r.stdout, re.M))
    assert valeurs.get("RESTE") == valeurs.get("ATTENDU"), r.stdout + r.stderr
    assert "DIT=oui" in r.stdout, "le filet n'explique pas son abstention"


@besoin_gnu
@pytest.mark.skipif(not FILET.exists(), reason="filet absent du dépôt")
@pytest.mark.parametrize("etat,description", [
    ("", "aucune alarme — le cas d'une extinction manuelle"),
    ("0", "alarme remise à zéro"),
    ("1", "alarme de 1970, donc largement passée"),
])
def test_le_filet_arme_quand_rien_n_est_prevu(etat, description):
    r = _bash("""
      d=$(mktemp -d); alarme="$d/wakealarm"; log="$d/log"
      printf '%%s' "%s" > "$alarme"
      PRA_RTC_WAKEALARM="$alarme" PRA_LOG="$log" bash %s
      echo "POSE=$(cat "$alarme")"; echo "MAINTENANT=$(date +%%s)"
      rm -rf "$d"
    """ % (etat, FILET))
    v = dict(re.findall(r"^(POSE|MAINTENANT)=(\d+)$", r.stdout, re.M))
    assert "POSE" in v, f"rien n'a été armé ({description}) : {r.stdout}{r.stderr}"
    assert int(v["POSE"]) > int(v["MAINTENANT"]), "alarme armée dans le passé"


@besoin_gnu
@pytest.mark.skipif(not FILET.exists(), reason="filet absent du dépôt")
def test_l_heure_de_repli_est_toujours_dans_le_futur():
    """Même en demandant une heure déjà passée aujourd'hui, le filet vise demain
    — c'est exactement le piège qu'il est censé couvrir."""
    r = _bash("""
      d=$(mktemp -d); alarme="$d/wakealarm"
      : > "$alarme"
      PRA_RTC_WAKEALARM="$alarme" PRA_LOG="$d/log" PRA_FILET_WAKE_AT="00:01" bash %s
      echo "POSE=$(cat "$alarme")"; echo "MAINTENANT=$(date +%%s)"
      rm -rf "$d"
    """ % FILET)
    v = dict(re.findall(r"^(POSE|MAINTENANT)=(\d+)$", r.stdout, re.M))
    assert int(v["POSE"]) > int(v["MAINTENANT"]), r.stdout + r.stderr


def test_l_unite_agit_a_l_extinction_et_pas_au_demarrage():
    """Tout le sens du filet est dans ExecStop. Un ExecStart qui armerait au
    démarrage ne servirait à rien : c'est en s'éteignant qu'on perd le réveil."""
    u = UNITE.read_text(encoding="utf-8")
    assert "ExecStop=/usr/local/sbin/pra_reveil_filet.sh" in u
    assert "RemainAfterExit=yes" in u, "sans cela l'unité s'arrête aussitôt démarrée"
    assert "Before=shutdown.target" in u, "l'arrêt arriverait trop tard"
    assert "DefaultDependencies=no" in u
    assert "WantedBy=multi-user.target" in u, "l'unité ne serait jamais démarrée"
