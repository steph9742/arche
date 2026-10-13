"""L'API d'état est publique, et RIEN d'autre ne l'est devenu avec elle.

Sans précaution, cette route rend 302 vers /yunohost/sso : SSOwat, branché au
niveau du bloc server de chaque domaine, s'applique aussi à elle. On le
contourne en redéfinissant le gestionnaire d'accès dans la route elle-même.

Contourner l'authentification est le genre de geste qui s'élargit en silence :
un « location = » devenu « location », une redéfinition recopiée ailleurs, un
alias vers un répertoire. Ces tests verrouillent la portée.
"""

import re
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
CONF = (RACINE / "pra" / "nginx" / "pra-etat.conf").read_text(encoding="utf-8")
ACTIF = "\n".join(l for l in CONF.splitlines() if not l.lstrip().startswith("#"))


def _blocs():
    """{en-tête du location: corps}, sur la configuration active seulement."""
    return {m.group(1).strip(): m.group(2)
            for m in re.finditer(r"location\s+([^{]+)\{(.*?)\n\}", ACTIF, re.S)}


def test_deux_locations_et_pas_une_de_plus():
    assert set(_blocs()) == {"= /pra/etat.json", "@pra_etat_absent"}


def test_la_route_publique_est_une_correspondance_exacte():
    # « location /pra/etat.json » (préfixe) laisserait passer /pra/etat.json.bak,
    # /pra/etat.jsonX… — tout ce qui commence pareil échapperait au SSO.
    assert re.search(r"location\s*=\s*/pra/etat\.json\s*\{", ACTIF)
    assert not re.search(r"location\s+/pra", ACTIF)


def test_le_contournement_du_sso_est_confine_aux_deux_locations():
    blocs = _blocs()
    for entete, corps in blocs.items():
        assert "access_by_lua_block { return }" in corps, f"SSO non contourné dans {entete}"
    # Et nulle part en dehors d'elles.
    hors_blocs = re.sub(r"location\s+[^{]+\{.*?\n\}", "", ACTIF, flags=re.S)
    assert "access_by_lua" not in hors_blocs


def test_on_sert_un_fichier_jamais_un_repertoire():
    corps = _blocs()["= /pra/etat.json"]
    alias = re.search(r"alias\s+(\S+);", corps).group(1)
    assert alias == "/var/www/pra-etat/etat.json"
    assert "autoindex" not in ACTIF
    assert "root " not in ACTIF


def test_le_404_de_secours_ne_publie_que_les_deux_champs():
    corps = _blocs()["@pra_etat_absent"]
    reponse = re.search(r"return\s+404\s+'([^']*)'", corps).group(1)
    import json
    assert set(json.loads(reponse)) == {"restauree", "derniere_restauration"}


def test_aucune_mise_en_cache():
    for entete, corps in _blocs().items():
        assert 'Cache-Control "no-store" always' in corps, entete


# ── L'installation attend que le rechargement ait pris avant de juger ────────

INSTALL = (RACINE / "scripts" / "install.sh").read_text(encoding="utf-8")


def _boucle_d_attente():
    api = INSTALL[INSTALL.index("L'API D'ÉTAT DE L'ARCHE"):]
    debut = api.index("      _code=000\n")
    fin = api.index("      done\n", debut) + len("      done\n")
    return api[debut:fin]


def test_l_installation_redemande_avant_de_conclure():
    """« systemctl reload nginx » est asynchrone : interrogée aussitôt, l'URL
    rend la réponse de l'ancienne configuration — l'installation annonce alors
    « 302 : SSOwat s'interpose » alors que l'API répond 200."""
    boucle = _boucle_d_attente()
    api = INSTALL[INSTALL.index("L'API D'ÉTAT DE L'ARCHE"):]
    assert api.index("systemctl reload nginx") < api.index(boucle)
    assert api.index(boucle) < api.index('case "$_code" in')


def _executer_boucle(reponses):
    import subprocess, tempfile, os
    with tempfile.NamedTemporaryFile("w", delete=False) as f:
        f.write("\n".join(reponses) + "\n")
        suite = f.name
    script = f'''set -uo pipefail
sleep() {{ :; }}
curl() {{
  local c; c="$(head -1 "{suite}")"; tail -n +2 "{suite}" > "{suite}.n"; mv "{suite}.n" "{suite}"
  printf "%s" "${{c:-302}}"
}}
_dom=exemple.org
{_boucle_d_attente()}
echo "FINAL $_code $_essai"
'''
    r = subprocess.run(["bash", "-c", script], capture_output=True, text=True)
    os.unlink(suite)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def test_un_302_transitoire_ne_fait_pas_conclure_a_tort():
    assert _executer_boucle(["302", "302", "200"]) == "FINAL 200 3"


def test_un_302_qui_dure_reste_signale():
    # Au bout du temps imparti, la réponse est réelle : SSOwat s'interpose bien.
    assert _executer_boucle(["302"] * 20) == "FINAL 302 10"
