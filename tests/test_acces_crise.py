"""L'adresse de la page de crise affichée par YunoBox est la BONNE.

Le réplica change d'adresse — réseau de secours, partage de connexion, autre
site. YunoBox la relève donc à chaud. Mais Docker crée un pont par réseau de
pile et TOUS se déclarent « scope global » : il y en a autant que de piles,
contre une seule adresse joignable. Une liste brute proposerait donc une
poignée d'adresses dont presque toutes mènent nulle part — et rien à l'écran ne
distinguerait la bonne. Ces tests exécutent le CODE RÉEL de yunobox.py sur une
sortie « ip » relevée sur une machine réelle.
"""

import sys
from pathlib import Path

RACINE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RACINE / "yunobox"))

import yunobox  # noqa: E402

# Sortie réelle de « ip -4 -o addr show » sur l'arche, ponts Docker compris.
IP_ADDR = """1: lo    inet 127.0.0.1/8 scope host lo\\       valid_lft forever
2: eth0    inet 192.0.2.10/26 brd 192.0.2.255 scope global noprefixroute eth0\\       valid_lft forever
4: br-6ee9b0624a7a    inet 172.18.0.1/16 brd 172.18.255.255 scope global br-6ee9b0624a7a\\       valid_lft forever
5: br-9495ac62b06d    inet 172.19.0.1/16 brd 172.19.255.255 scope global br-9495ac62b06d\\       valid_lft forever
6: br-c36cff8a23f5    inet 172.22.0.1/16 brd 172.22.255.255 scope global br-c36cff8a23f5\\       valid_lft forever
7: br-cbf2bd58a5ef    inet 172.23.0.1/16 brd 172.23.255.255 scope global br-cbf2bd58a5ef\\       valid_lft forever
8: br-dd1be1eb218c    inet 172.21.0.1/16 brd 172.21.255.255 scope global br-dd1be1eb218c\\       valid_lft forever
9: docker0    inet 172.17.0.1/16 brd 172.17.255.255 scope global docker0\\       valid_lft forever
"""
ROUTE = "default via 192.0.2.254 dev eth0 proto static metric 100\n"


def _faux_ip(monkeypatch, addr=IP_ADDR, route=ROUTE, code=0):
    def run(cmd, timeout=15):
        if "route" in cmd:
            return code, route, ""
        return code, addr, ""
    monkeypatch.setattr(yunobox, "run", run)


def test_les_ponts_docker_sont_ecartes(monkeypatch):
    _faux_ip(monkeypatch)
    adresses = yunobox.adresses_acces()
    assert [a["ip"] for a in adresses] == ["192.0.2.10"]
    assert adresses[0]["url"] == "http://192.0.2.10:8080/"
    assert adresses[0]["principale"] is True


def test_la_principale_passe_en_tete(monkeypatch):
    # Wi-Fi en plus du filaire : les deux sont joignables, mais celle qui porte
    # la route par défaut doit être proposée la première — c'est elle qu'on lit.
    addr = IP_ADDR + (
        "3: wlan0    inet 198.51.100.46/24 brd 10.103.226.255 scope global wlan0\\"
        "       valid_lft forever\n"
    )
    _faux_ip(monkeypatch, addr=addr, route="default via 10.103.226.1 dev wlan0\n")
    adresses = yunobox.adresses_acces()
    assert [a["ip"] for a in adresses] == ["198.51.100.46", "192.0.2.10"]
    assert adresses[0]["principale"] and not adresses[1]["principale"]


def test_sans_reseau_on_ne_ment_pas(monkeypatch):
    _faux_ip(monkeypatch, addr="", route="")
    assert yunobox.adresses_acces() == []


def test_ip_introuvable_n_est_pas_une_absence_d_adresse(monkeypatch):
    """Code 127 = binaire absent. Le repli au chemin complet doit être tenté :
    rendre [] ferait passer un échec pour un constat « aucune adresse »."""
    tentes = []

    def run(cmd, timeout=15):
        tentes.append(cmd[0])
        if cmd[0] == "ip":
            return 127, "", "commande introuvable"
        return 0, (ROUTE if "route" in cmd else IP_ADDR), ""

    monkeypatch.setattr(yunobox, "run", run)
    adresses = yunobox.adresses_acces()
    assert "/usr/sbin/ip" in tentes
    assert [a["ip"] for a in adresses] == ["192.0.2.10"]


def test_qr_absent_se_declare_au_lieu_de_produire_une_image_fausse(monkeypatch):
    monkeypatch.setattr(yunobox, "have", lambda b: False)
    assert yunobox.qr_svg("http://exemple/") is None


def test_le_svg_rendu_est_inserable_tel_quel(monkeypatch):
    # qrencode fige la taille en centimètres et préfixe une déclaration XML :
    # inséré tel quel dans la page, le SVG ne s'adapterait pas à la carte.
    brut = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<!-- Created with qrencode -->\n'
            '<svg width="5.72cm" height="5.72cm" viewBox="0 0 27 27" '
            'xmlns="http://www.w3.org/2000/svg"><rect/></svg>')
    monkeypatch.setattr(yunobox, "have", lambda b: True)
    monkeypatch.setattr(yunobox, "run", lambda cmd, timeout=15: (0, brut, ""))
    svg = yunobox.qr_svg("http://exemple/")
    assert svg.startswith("<svg")
    assert "<?xml" not in svg and "cm" not in svg
    assert 'width="100%"' in svg and 'viewBox="0 0 27 27"' in svg
