#!/usr/bin/env python3
"""
YunoBox — tableau de bord local pour Raspberry Pi 5 + Waveshare UPS HAT (E)
sur YunoHost.

Batterie et autonomie, reseaux WiFi, services YunoHost (yunomdns en tete),
occupation des disques.

Aucune dependance hors python3-smbus. Sert d'API pour l'ecran tactile a venir.
"""

import http.server
import json
import os
import re
import secrets
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
STATIC = os.path.join(HERE, "static")
TOKEN_FILE = "/etc/yunobox/token"
STATE_DIR = "/var/lib/yunobox"
MDNS_LAST = os.path.join(STATE_DIR, "mdns-last")
DISPATCHER = "/etc/NetworkManager/dispatcher.d/99-yunobox-mdns"
# Porte en clair de la page de crise, servie par nginx (zz-arche-secours.conf).
PORT_CRISE = 8080


# --------------------------------------------------------------------------
#  Utilitaires
# --------------------------------------------------------------------------

def run(cmd, timeout=15):
    """Execute une commande. Renvoie (code, stdout, stderr) sans jamais lever."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError:
        return 127, "", "commande introuvable : %s" % cmd[0]
    except subprocess.TimeoutExpired:
        return 124, "", "delai depasse"
    except Exception as e:                                    # noqa: BLE001
        return 1, "", str(e)


def have(binary):
    return run(["which", binary], timeout=5)[0] == 0


def read_file(path, default=None):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return default


class Cache:
    """Cache a duree de vie, pour ne pas marteler l'I2C ni relancer un scan WiFi."""

    def __init__(self):
        self._d = {}
        self._lock = threading.Lock()

    def get(self, key, ttl, producer):
        now = time.monotonic()
        with self._lock:
            hit = self._d.get(key)
            if hit and now - hit[0] < ttl:
                return hit[1]
        value = producer()
        with self._lock:
            self._d[key] = (time.monotonic(), value)
        return value

    def drop(self, key):
        with self._lock:
            self._d.pop(key, None)


CACHE = Cache()


def nm_split(line):
    """Decoupe une ligne nmcli -t en tenant compte des ':' echappes."""
    out, cur, esc = [], "", False
    for ch in line:
        if esc:
            cur += ch
            esc = False
        elif ch == "\\":
            esc = True
        elif ch == ":":
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out


# --------------------------------------------------------------------------
#  UPS HAT (E)
# --------------------------------------------------------------------------

def i2c_pinmux():
    """Verifie que GPIO 2 et 3 sont bien en fonction I2C.

    Sur Raspberry Pi 5 (RP1), l'I2C1 correspond a la fonction alternative
    « a3 », et non « a0 » comme sur les generations precedentes. Si les broches
    derivent vers une autre fonction — un overlay SPI ou d'affichage peut
    revendiquer SPI0_CE2/CE3 sur ces memes broches — le bus devient totalement
    muet sans qu'aucun defaut materiel soit en cause. On le detecte donc, pour
    ne pas confondre ce cas avec un mauvais contact des pogo pins.
    """
    code, out, _ = run(["pinctrl", "get", "2,3"], timeout=5)
    if code != 0:
        return None
    lignes = [l.strip() for l in out.splitlines() if l.strip()]
    if len(lignes) < 2:
        return None
    ok = all(("SDA1" in l or "SCL1" in l) for l in lignes)
    return {"ok": ok, "detail": " / ".join(lignes)}


PHASES = {
    0: "veille",
    1: "charge lente",
    2: "courant constant",
    3: "tension constante",
    4: "charge en attente",
    5: "pleine",
    6: "timeout de charge",
}


class Ups:
    """Lecture des registres du UPS HAT (E).

    Deux precautions apprises a la dure :
      - les lectures octet par octet peuvent renvoyer un NACK quand le pin 5 V
        debite a cote des lignes SDA/SCL, d'ou les relances ;
      - les tensions de cellule passent par une lecture en bloc unique, bien
        plus fiable que huit acces successifs.
    """

    def __init__(self, bus=1, addr=0x2D):
        self.bus_no = bus
        self.addr = addr
        self._bus = None
        self._lock = threading.Lock()

    def _open(self):
        if self._bus is None:
            import smbus
            self._bus = smbus.SMBus(self.bus_no)
        return self._bus

    def _rd(self, reg, tries=6):
        for _ in range(tries):
            try:
                return self._open().read_byte_data(self.addr, reg)
            except OSError:
                time.sleep(0.02)
            except Exception:                                 # noqa: BLE001
                return None
        return None

    def _u16(self, reg):
        lo, hi = self._rd(reg), self._rd(reg + 1)
        if lo is None or hi is None:
            return None
        return lo | (hi << 8)

    def _s16(self, reg):
        v = self._u16(reg)
        if v is None:
            return None
        return v - 65536 if v > 32767 else v

    def _cells(self):
        try:
            d = self._open().read_i2c_block_data(self.addr, 0x30, 8)
            return [d[i] | (d[i + 1] << 8) for i in range(0, 8, 2)]
        except OSError:
            time.sleep(0.05)
            return [self._u16(0x30 + 2 * i) for i in range(4)]
        except Exception:                                     # noqa: BLE001
            return [None] * 4

    def read(self):
        with self._lock:
            return self._read()

    def _read(self):
        st = self._rd(0x02)
        if st is None:
            mux = i2c_pinmux()
            msg = "pas de reponse en 0x%02X sur le bus %d" % (self.addr, self.bus_no)
            if mux and not mux["ok"]:
                msg += (" — les broches GPIO 2/3 ne sont plus en fonction I2C, "
                        "le bus est donc muet sans defaut materiel : "
                        + mux["detail"])
            else:
                msg += ". I2C active ? contact des pogo pins ?"
            return {"ok": False, "erreur": msg, "pinmux": mux}

        comm = self._rd(0x03) or 0
        vbus_present = bool(st & 0x20)
        charging = bool(st & 0x80)
        fast = bool(st & 0x40)

        bat_mv = self._u16(0x20)
        bat_ma = self._s16(0x22)
        pct = self._u16(0x24)
        cap = self._u16(0x26)
        t_empty = self._u16(0x28)
        t_full = self._u16(0x2A)
        cells = self._cells()

        power_w = None
        if bat_mv is not None and bat_ma is not None:
            power_w = round(bat_mv * bat_ma / 1e6, 2)

        if bat_ma is None:
            etat = "inconnu"
        elif bat_ma > 20:
            etat = "charge"
        elif bat_ma < -20:
            etat = "decharge"
        else:
            etat = "repos"

        def minutes(v):
            return None if v in (None, 0xFFFF) else v

        known = [c for c in cells if c]
        # Le bit IP2368 tombe a 0 quand aucune entree USB-C n'est presente : la
        # puce est simplement endormie. Ce n'est PAS un defaut.
        if comm & 1:
            ip2368 = "ok"
        elif not vbus_present:
            ip2368 = "endormie (normal sans entree USB-C)"
        else:
            ip2368 = "ERREUR"

        return {
            "ok": True,
            "etat": etat,
            "phase": PHASES.get(st & 7, "inconnue"),
            "en_charge": charging,
            "charge_rapide": fast,
            "vbus_present": vbus_present,
            "vbus_mv": self._u16(0x10),
            "vbus_ma": self._s16(0x12),
            "vbus_mw": self._u16(0x14),
            "batterie_mv": bat_mv,
            "batterie_ma": bat_ma,
            "puissance_w": power_w,
            "pourcent": pct,
            "capacite_mah": cap,
            "energie_wh": round(cap * bat_mv / 1e6, 1)
                          if (cap and bat_mv) else None,
            "autonomie_min": minutes(t_empty) if etat == "decharge" else None,
            "charge_restante_min": minutes(t_full) if etat == "charge" else None,
            "cellules_mv": cells,
            "ecart_cellules_mv": (max(known) - min(known)) if len(known) == 4 else None,
            "liaison_bq4050": "ok" if comm & 2 else "ERREUR",
            "liaison_ip2368": ip2368,
            "registre_0x02": "0x%02X" % st,
            "registre_0x03": "0x%02X" % comm,
        }


UPS = Ups()


# --------------------------------------------------------------------------
#  Systeme
# --------------------------------------------------------------------------

# L'ÉTAT PRÉCÉDENT DU COMPTEUR CPU.
#
# /proc/stat donne des compteurs CUMULÉS depuis le démarrage : une lecture seule
# ne dit rien de la charge actuelle, seulement de la moyenne depuis l'allumage —
# qui, sur une machine allumée depuis des semaines, ne bouge plus jamais. Il faut
# deux lectures et la différence. On garde donc la précédente ici plutôt que de
# dormir une seconde à chaque appel : le service tourne en continu, et la page
# interroge toutes les trois secondes.
_CPU_PRECEDENT = {}


def cpu_pourcent():
    """Part du temps CPU passée hors inactivité depuis l'appel précédent."""
    ligne = read_file("/proc/stat", "")
    if not ligne.startswith("cpu "):
        return None
    try:
        champs = [int(x) for x in ligne.split("\n", 1)[0].split()[1:]]
    except ValueError:
        return None
    if len(champs) < 4:
        return None
    total = sum(champs)
    # idle + iowait : la machine attend, elle ne calcule pas.
    inactif = champs[3] + (champs[4] if len(champs) > 4 else 0)

    avant = _CPU_PRECEDENT.get("v")
    _CPU_PRECEDENT["v"] = (total, inactif)
    if not avant:
        return None                      # premier appel : rien à comparer
    d_total = total - avant[0]
    d_inactif = inactif - avant[1]
    if d_total <= 0:
        return None
    return round(100.0 * (d_total - d_inactif) / d_total, 1)


def memoire_info():
    """Mémoire vive et espace d'échange, en octets.

    On rapporte « disponible » et non « libre » : sur Linux la mémoire libre est
    proche de zéro en fonctionnement normal, parce que le noyau garde tout ce
    qu'il peut en cache. Afficher « 3 % libre » ferait croire à une machine
    saturée alors qu'elle est en bonne santé. MemAvailable est l'estimation que
    le noyau fait lui-même de ce qu'une application pourrait obtenir.
    """
    champs = {}
    texte = read_file("/proc/meminfo", "")
    for ligne in texte.splitlines():
        cle, _, reste = ligne.partition(":")
        valeur = reste.strip().split(" ")[0]
        if valeur.isdigit():
            champs[cle] = int(valeur) * 1024        # les kO du noyau

    total = champs.get("MemTotal")
    dispo = champs.get("MemAvailable")
    if not total:
        return None
    utilisee = total - dispo if dispo is not None else None
    swap_total = champs.get("SwapTotal", 0)
    swap_libre = champs.get("SwapFree", 0)

    return {
        "total_o": total,
        "disponible_o": dispo,
        "utilisee_o": utilisee,
        "pourcent": round(100.0 * utilisee / total, 1) if utilisee is not None else None,
        "cache_o": champs.get("Cached"),
        "echange_total_o": swap_total,
        "echange_utilise_o": swap_total - swap_libre if swap_total else 0,
    }


def frequence_mhz():
    """Fréquence du premier cœur. Lue à côté du bridage : c'est elle qui montre
    que la machine a réduit sa cadence, là où « bridage » dit seulement que
    c'est arrivé."""
    raw = read_file("/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq")
    if raw and raw.isdigit():
        return round(int(raw) / 1000.0)
    if have("vcgencmd"):
        code, out, _ = run(["vcgencmd", "measure_clock", "arm"], timeout=5)
        if code == 0 and "=" in out:
            try:
                return round(int(out.strip().split("=")[1]) / 1_000_000)
            except (ValueError, IndexError):
                pass
    return None


def system_info():
    temp = None
    raw = read_file("/sys/class/thermal/thermal_zone0/temp")
    if raw and raw.lstrip("-").isdigit():
        temp = round(int(raw) / 1000.0, 1)

    up = read_file("/proc/uptime", "0").split()[0]
    try:
        uptime_s = int(float(up))
    except ValueError:
        uptime_s = 0

    throttled = None
    if have("vcgencmd"):
        code, out, _ = run(["vcgencmd", "get_throttled"], timeout=5)
        if code == 0 and "=" in out:
            try:
                bits = int(out.strip().split("=")[1], 16)
                throttled = {
                    "sous_tension_maintenant": bool(bits & 0x1),
                    "bridage_maintenant": bool(bits & 0x4),
                    "sous_tension_depuis_boot": bool(bits & 0x10000),
                    "bridage_depuis_boot": bool(bits & 0x40000),
                }
            except (ValueError, IndexError):
                pass

    try:
        load = [round(x, 2) for x in os.getloadavg()]
    except OSError:
        load = None

    return {
        "hote": read_file("/etc/hostname", "?"),
        "temperature_c": temp,
        "uptime_s": uptime_s,
        "charge_moyenne": load,
        "coeurs": os.cpu_count(),
        "bridage": throttled,
        "cpu_pourcent": cpu_pourcent(),
        "frequence_mhz": frequence_mhz(),
        "memoire": memoire_info(),
    }


# --------------------------------------------------------------------------
#  Disques
# --------------------------------------------------------------------------

def nvme_temperatures():
    out = {}
    base = "/sys/class/hwmon"
    try:
        for entry in os.listdir(base):
            name = read_file(os.path.join(base, entry, "name"), "")
            if name and "nvme" in name.lower():
                raw = read_file(os.path.join(base, entry, "temp1_input"))
                if raw and raw.lstrip("-").isdigit():
                    out[name] = round(int(raw) / 1000.0, 1)
    except OSError:
        pass
    return out


def disks_info():
    code, out, err = run([
        "df", "-B1", "--output=source,target,fstype,size,used,avail,pcent",
        "-x", "tmpfs", "-x", "devtmpfs", "-x", "squashfs", "-x", "overlay",
    ])
    volumes = []
    if code == 0:
        for line in out.splitlines()[1:]:
            f = line.split()
            if len(f) < 7:
                continue
            try:
                size, used, avail = int(f[3]), int(f[4]), int(f[5])
            except ValueError:
                continue
            volumes.append({
                "peripherique": f[0],
                "montage": f[1],
                "type": f[2],
                "taille_o": size,
                "utilise_o": used,
                "libre_o": avail,
                "pourcent": int(f[6].rstrip("%")) if f[6].rstrip("%").isdigit() else None,
            })
    return {"volumes": volumes,
            "temperatures_nvme": nvme_temperatures(),
            "erreur": err.strip() or None if code != 0 else None}


# --------------------------------------------------------------------------
#  WiFi (NetworkManager)
# --------------------------------------------------------------------------

def wifi_state():
    if not have("nmcli"):
        return {"ok": False,
                "erreur": "nmcli absent. Ce module suppose NetworkManager."}

    # LA RADIO D'ABORD : coupée, tout le reste est une liste vide sans cause.
    #
    # Sur un Raspberry Pi OS frais, rfkill bloque le Wi-Fi tant que le pays
    # n'est pas défini — la radio est alors « disabled », le scan rend zéro
    # réseau, et le bouton paraît en panne alors qu'il fait exactement son
    # travail — et une liste vide sans explication fait accuser l'interface,
    # jamais la radio.
    radio = None
    code, out, _ = run(["nmcli", "radio", "wifi"])
    if code == 0:
        radio = out.strip().lower()          # « enabled » ou « disabled »

    actives = []
    code, out, _ = run(["nmcli", "-t", "-f",
                        "NAME,TYPE,DEVICE", "connection", "show", "--active"])
    if code == 0:
        for line in out.splitlines():
            f = nm_split(line)
            if len(f) >= 3:
                actives.append({"nom": f[0], "type": f[1], "interface": f[2]})

    devices = []
    code, out, _ = run(["nmcli", "-t", "-f",
                        "DEVICE,TYPE,STATE,CONNECTION", "device", "status"])
    if code == 0:
        for line in out.splitlines():
            f = nm_split(line)
            if len(f) >= 4 and f[1] != "loopback":
                devices.append({"interface": f[0], "type": f[1],
                                "etat": f[2], "connexion": f[3]})

    saved = []
    code, out, _ = run(["nmcli", "-t", "-f", "NAME,TYPE", "connection", "show"])
    if code == 0:
        for line in out.splitlines():
            f = nm_split(line)
            if len(f) >= 2 and "wireless" in f[1]:
                saved.append(f[0])

    return {"ok": True, "radio": radio, "actives": actives,
            "interfaces": devices, "enregistres": saved}


def wifi_scan(rescan=False):
    if not have("nmcli"):
        return {"ok": False, "erreur": "nmcli absent."}
    cmd = ["nmcli", "-t", "-f", "IN-USE,SSID,SIGNAL,SECURITY,FREQ",
           "device", "wifi", "list"]
    if rescan:
        cmd += ["--rescan", "yes"]
    code, out, err = run(cmd, timeout=45)
    if code != 0:
        return {"ok": False, "erreur": err.strip() or "echec du scan"}

    seen, reseaux = {}, []
    for line in out.splitlines():
        f = nm_split(line)
        if len(f) < 5 or not f[1]:
            continue
        try:
            signal = int(f[2])
        except ValueError:
            signal = 0
        ssid = f[1]
        entry = {"ssid": ssid, "actuel": f[0].strip() == "*", "signal": signal,
                 "securite": f[3] or "ouvert", "frequence": f[4]}
        # on ne garde que le meilleur signal par SSID
        if ssid in seen:
            if signal > seen[ssid]["signal"]:
                seen[ssid].update(entry)
            continue
        seen[ssid] = entry
        reseaux.append(entry)

    reseaux.sort(key=lambda r: (-r["actuel"], -r["signal"]))
    return {"ok": True, "reseaux": reseaux}


def wifi_connect(ssid, password=None, iface=None):
    if not have("nmcli"):
        return {"ok": False, "erreur": "nmcli absent."}
    if not ssid:
        return {"ok": False, "erreur": "ssid manquant"}

    cmd = ["nmcli", "device", "wifi", "connect", ssid]
    if password:
        cmd += ["password", password]
    if iface:
        cmd += ["ifname", iface]

    code, out, err = run(cmd, timeout=60)
    CACHE.drop("wifi_scan")
    CACHE.drop("wifi_state")
    message = (out or err).strip()
    return {"ok": code == 0, "message": message,
            "note": "yunomdns sera relance automatiquement par le hook "
                    "NetworkManager si celui-ci est installe."}


# --------------------------------------------------------------------------
#  Services YunoHost, yunomdns en tete
# --------------------------------------------------------------------------

MDNS_UNIT = "yunomdns"


def unit_detail(unit):
    code, out, _ = run([
        "systemctl", "show", unit,
        "-p", "ActiveState", "-p", "SubState", "-p", "UnitFileState",
        "-p", "ActiveEnterTimestamp", "-p", "ExecMainStartTimestamp",
    ], timeout=10)
    d = {}
    if code == 0:
        for line in out.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                d[k] = v
    return {
        "etat": d.get("ActiveState") or "inconnu",
        "sous_etat": d.get("SubState") or "",
        "au_demarrage": d.get("UnitFileState") or "",
        "actif_depuis": d.get("ActiveEnterTimestamp") or "",
    }


def local_domains():
    """Domaines .local que yunomdns doit publier."""
    domains = []
    raw = read_file("/etc/yunohost/mdns.yml")
    if raw:
        # mdns.yml liste les domaines sous forme de puces YAML
        domains = re.findall(r"^\s*-\s*([A-Za-z0-9._-]+)", raw, re.M)
    if not domains and have("yunohost"):
        code, out, _ = run(["yunohost", "domain", "list", "--output-as", "json"],
                           timeout=20)
        if code == 0:
            try:
                data = json.loads(out)
                domains = data.get("domains", data) if isinstance(data, dict) else data
            except (ValueError, AttributeError):
                domains = []
    return sorted({d for d in domains if isinstance(d, str) and d.endswith(".local")})


# ── Où joindre la page de crise ─────────────────────────────────────────────
#
# L'IP du réplica change — réseau de secours, partage de connexion, autre
# site : tout le dossier de crise le répète. Une adresse écrite en dur quelque
# part serait donc fausse le jour venu. On la relève à chaud, et on en fait un
# QR pour éviter la recopie à la main d'un « 10.0.0.1:8080 » sous stress.

# Docker crée un pont par réseau de pile, et TOUS se déclarent « scope global » :
# il y en a autant que de piles, et la liste brute donne alors une poignée
# d'adresses dont une seule est utile. Proposer « http://172.18.0.1:8080/ » à
# quelqu'un qui cherche la page de crise serait pire que de ne rien afficher.
_IFACES_IGNOREES = re.compile(r"^(lo|docker\d*|br-[0-9a-f]{12}|veth|virbr|tun|tap)")


def _ip_cmd(args):
    """« ip » vit dans /usr/sbin, pas toujours au PATH d'un service.

    On retente au chemin complet plutôt que de rendre une liste vide : « aucune
    adresse » se lirait comme un constat, alors que ce serait un échec.
    """
    code, out, _ = run(["ip"] + args, timeout=5)
    if code == 127:
        code, out, _ = run(["/usr/sbin/ip"] + args, timeout=5)
    return code, out


def _iface_par_defaut():
    """L'interface qui porte la route par défaut : la seule joignable d'ailleurs."""
    code, out = _ip_cmd(["-4", "route", "show", "default"])
    if code != 0:
        return None
    m = re.search(r"\bdev\s+(\S+)", out)
    return m.group(1) if m else None


def adresses_acces():
    """Adresses IPv4 où la page de crise répond, la principale en tête."""
    code, out = _ip_cmd(["-4", "-o", "addr", "show"])
    if code != 0:
        return []
    principale = _iface_par_defaut()
    trouvees = []
    for ligne in out.splitlines():
        if "scope global" not in ligne:
            continue
        m = re.match(r"^\d+:\s+(\S+)\s+inet\s+([\d.]+)/", ligne)
        if not m or _IFACES_IGNOREES.match(m.group(1)):
            continue
        trouvees.append({
            "interface": m.group(1),
            "ip": m.group(2),
            "url": "http://%s:%d/" % (m.group(2), PORT_CRISE),
            "principale": m.group(1) == principale,
        })
    trouvees.sort(key=lambda a: not a["principale"])
    return trouvees


def qr_svg(texte):
    """QR de « texte » en SVG à insérer tel quel, ou None si qrencode manque.

    ON NE CODE PAS LE QR NOUS-MÊMES. Un encodeur maison subtilement faux
    produirait une image qui RESSEMBLE à un QR et ne se scanne pas : l'échec
    serait indistinguable du succès à l'écran, et ne se découvrirait que le jour
    de la crise, téléphone en main. qrencode est un paquet Debian minuscule,
    posé par install.sh.

    Le QR reste noir sur blanc même en thème sombre : un QR inversé n'est pas lu
    par une bonne partie des téléphones.
    """
    if not have("qrencode"):
        return None
    # -m 2 : la marge blanche fait partie du code, sans elle beaucoup de
    # lecteurs échouent. -s 8 : la taille réelle est imposée plus bas par le
    # viewBox, mais un module trop petit dégrade le rendu à l'impression.
    code, out, _ = run(["qrencode", "-t", "SVG", "-o", "-", "-m", "2", "-s", "8",
                        texte], timeout=5)
    if code != 0 or "<svg" not in out:
        return None
    svg = out[out.index("<svg"):]
    # qrencode fige la taille en centimètres : on la retire pour que le viewBox
    # commande et que la feuille de style décide.
    return re.sub(r'\swidth="[^"]*"\s+height="[^"]*"',
                  ' width="100%" height="100%"', svg, count=1).strip()


def acces_info():
    """Ce qu'il faut pour joindre la page de crise depuis un téléphone."""
    adresses = adresses_acces()
    principale = adresses[0] if adresses else None
    return {
        "adresses": adresses,
        "principale": principale,
        "qr": qr_svg(principale["url"]) if principale else None,
        "qrencode_absent": not have("qrencode"),
        # La seconde porte, quand mDNS fonctionne. Elle ne dépend pas de l'IP.
        "url_nom": "https://%s/accueil/" % (read_file("/etc/hostname", "localhost")),
    }


def mdns_info():
    info = unit_detail(MDNS_UNIT)
    info["unite"] = MDNS_UNIT
    info["domaines_local"] = local_domains()
    info["hook_installe"] = os.path.exists(DISPATCHER)
    info["dernier_relancement_auto"] = read_file(MDNS_LAST)
    return info


def services_info():
    services = []
    if have("yunohost"):
        code, out, _ = run(["yunohost", "service", "status",
                            "--output-as", "json"], timeout=40)
        if code == 0:
            try:
                data = json.loads(out)
                for name, meta in sorted(data.items()):
                    if not isinstance(meta, dict):
                        continue
                    services.append({
                        "nom": name,
                        "etat": meta.get("status", "?"),
                        "au_demarrage": meta.get("start_on_boot", ""),
                        "configuration": meta.get("configuration", ""),
                        "change_le": meta.get("last_state_change", ""),
                    })
            except ValueError:
                pass

    if not services:                       # repli si la CLI YunoHost manque
        for unit in ("nginx", "php8.2-fpm", "mysql", "dovecot", "postfix",
                     "slapd", "ssh", "fail2ban", "yunomdns", "yunohost-api"):
            d = unit_detail(unit)
            if d["etat"] != "inconnu":
                services.append({"nom": unit, "etat": d["etat"],
                                 "au_demarrage": d["au_demarrage"],
                                 "configuration": "", "change_le": d["actif_depuis"]})

    return {"services": services, "mdns": mdns_info()}


SAFE_NAME = re.compile(r"^[A-Za-z0-9._@-]{1,64}$")


def service_restart(name):
    if not name or not SAFE_NAME.match(name):
        return {"ok": False, "erreur": "nom de service invalide"}

    if have("yunohost"):
        code, out, err = run(["yunohost", "service", "restart", name], timeout=90)
        if code == 0:
            if name == MDNS_UNIT:
                note_mdns_restart("manuel depuis l'interface")
            return {"ok": True, "message": (out or "redemarre").strip()}
        # certains services ne sont pas connus de YunoHost : on tente systemd
        fallback = err.strip()
    else:
        fallback = ""

    code, out, err = run(["systemctl", "restart", name], timeout=90)
    if code == 0 and name == MDNS_UNIT:
        note_mdns_restart("manuel depuis l'interface")
    return {"ok": code == 0,
            "message": (out or err or "redemarre").strip() or fallback}


def note_mdns_restart(raison):
    try:
        os.makedirs(STATE_DIR, exist_ok=True)
        with open(MDNS_LAST, "w") as f:
            f.write("%s — %s" % (time.strftime("%Y-%m-%d %H:%M:%S"), raison))
    except OSError:
        pass


# --------------------------------------------------------------------------
#  Serveur HTTP
# --------------------------------------------------------------------------

# --------------------------------------------------------------------------
#  Le PRA vu depuis la machine
#
#  YunoBox et le dispositif de reprise sont independants — c'est voulu, et c'est
#  ecrit dans la documentation. On fait ici DEUX exceptions, chacune payee par un
#  besoin concret constate :
#
#    - LIRE le verdict de la derniere nuit. Une arche qui n'a pas replique depuis
#      dix jours ressemble en tout point a une arche a jour. C'est l'information
#      qu'il faut avoir sous les yeux avant de s'appuyer sur cette copie, et
#      aucun autre ecran ne la montre a qui se tient devant la machine.
#
#    - ECRIRE la suspension. A 2 h du matin l'arche restaure par-dessus et
#      s'eteint : si quelqu'un travaille dessus en pleine crise, c'est le pire
#      moment possible. Il faut pouvoir suspendre sans passer par le SSO, donc
#      sans qu'un nom resolve.
#
#  La lecture se limite a un fichier JSON. L'ecriture ne touche qu'UNE cle, et
#  seulement apres validation par une expression stricte : pra.conf est « source »
#  par des scripts root, une valeur mal filtree y serait une execution de code.
#  Une date au format impose ne peut contenir aucun metacaractere de shell.
# --------------------------------------------------------------------------

PRA_STATUT = "/var/lib/pra/status.json"
PRA_CONF = "/etc/pra/pra.conf"
PRA_TIMER = "pra-nightly.timer"
RE_PAUSE = re.compile(r"^\d{4}-\d{2}-\d{2}( \d{2}:\d{2})?$")
PAUSE_MAX_JOURS = 7


def pra_pause_lue():
    """La suspension en vigueur, lue dans pra.conf. Chaine vide si aucune."""
    try:
        with open(PRA_CONF, encoding="utf-8", errors="replace") as f:
            for ligne in f:
                m = re.match(r'^\s*PRA_PAUSE_JUSQUA=["\']?([^"\'#\n]*)', ligne)
                if m:
                    return m.group(1).strip()
    except OSError:
        pass
    return ""


def pra_info():
    """Verdict de la derniere nuit, suspension en cours, etat de la minuterie."""
    info = {"verdict": None, "horodatage": None, "archive": None,
            "age_heures": None, "pause": pra_pause_lue(), "minuterie": None}
    try:
        with open(PRA_STATUT, encoding="utf-8") as f:
            d = json.load(f)
        info["verdict"] = d.get("verdict")
        info["archive"] = d.get("archive")
        info["horodatage"] = d.get("horodatage")
        try:
            t = datetime.fromisoformat(str(d.get("horodatage", "")))
            if t.tzinfo is None:
                t = t.replace(tzinfo=timezone.utc)
            info["age_heures"] = round(
                (datetime.now(timezone.utc) - t).total_seconds() / 3600, 1)
        except ValueError:
            pass
    except (OSError, ValueError) as e:
        info["erreur"] = str(e)
    _, sortie, _ = run(["systemctl", "is-enabled", PRA_TIMER])
    info["minuterie"] = sortie.strip() or "inconnue"
    return info


def pra_pause_ecrire(jusqua):
    """Pose ou leve la suspension, en ne touchant qu'une seule cle de pra.conf.

    Une chaine vide leve la suspension. Toute autre valeur doit satisfaire
    RE_PAUSE — refus sinon, sans ecriture.
    """
    jusqua = (jusqua or "").strip()
    if jusqua:
        if not RE_PAUSE.match(jusqua):
            return {"ok": False,
                    "erreur": "format attendu AAAA-MM-JJ ou AAAA-MM-JJ HH:MM"}
        try:
            fin = datetime.strptime(jusqua[:16].ljust(16, " ").strip(),
                                    "%Y-%m-%d %H:%M" if len(jusqua) > 10
                                    else "%Y-%m-%d")
        except ValueError:
            return {"ok": False, "erreur": "date invalide"}
        # Plafond : une suspension sans limite serait un dispositif eteint qui se
        # croit actif. Le script nocturne la ramenerait de toute façon au
        # plafond ; autant refuser ici, ou l'utilisateur peut corriger.
        if (fin - datetime.now()).days > PAUSE_MAX_JOURS:
            return {"ok": False,
                    "erreur": "au-dela de %d jours" % PAUSE_MAX_JOURS}

    try:
        with open(PRA_CONF, encoding="utf-8", errors="replace") as f:
            lignes = f.read().splitlines(True)
    except OSError as e:
        return {"ok": False, "erreur": "pra.conf illisible : %s" % e}

    sortie, vue = [], False
    for ligne in lignes:
        if re.match(r"^\s*PRA_PAUSE_JUSQUA=", ligne):
            if not vue:
                sortie.append('PRA_PAUSE_JUSQUA="%s"\n' % jusqua)
                vue = True
            continue          # les doublons eventuels disparaissent
        sortie.append(ligne)
    if not vue:
        if sortie and not sortie[-1].endswith("\n"):
            sortie.append("\n")
        sortie.append('PRA_PAUSE_JUSQUA="%s"\n' % jusqua)

    # Ecriture atomique : un pra.conf tronque serait « source » tel quel par le
    # prochain script et produirait une configuration partielle silencieuse.
    try:
        d = os.path.dirname(PRA_CONF)
        fd, tmp = tempfile.mkstemp(dir=d, prefix=".pra.conf.")
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("".join(sortie))
        os.chmod(tmp, 0o600)
        os.chown(tmp, 0, 0)
        os.replace(tmp, PRA_CONF)
    except OSError as e:
        return {"ok": False, "erreur": "ecriture refusee : %s" % e}
    return {"ok": True, "pause": jusqua}


def systeme_halt():
    """Extinction propre. Le disque est monte en ecriture : une coupure seche
    corrompt les bases, c'est-a-dire la copie meme qu'on est venu chercher."""
    run(["sync"], timeout=30)
    code, _, err = run(["systemctl", "halt"], timeout=20)
    if code != 0:
        return {"ok": False, "erreur": err.strip() or "code %d" % code}
    return {"ok": True, "message": "extinction demandee"}


def load_token():
    tok = read_file(TOKEN_FILE)
    if tok:
        return tok
    tok = secrets.token_urlsafe(24)
    try:
        os.makedirs(os.path.dirname(TOKEN_FILE), exist_ok=True)
        with open(TOKEN_FILE, "w") as f:
            f.write(tok)
        os.chmod(TOKEN_FILE, 0o600)
    except OSError:
        pass
    return tok


TOKEN = None


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "YunoBox"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    # -- helpers ----------------------------------------------------------
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self):
        given = self.headers.get("X-Auth-Token", "")
        if not given:
            from urllib.parse import urlparse, parse_qs
            given = (parse_qs(urlparse(self.path).query).get("token") or [""])[0]
        return secrets.compare_digest(given, TOKEN)

    def _body(self):
        try:
            n = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            return {}
        if n <= 0 or n > 64_000:
            return {}
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return {}

    def _static(self, path):
        name = "index.html" if path in ("/", "") else path.lstrip("/")
        if "/" in name or ".." in name:
            return self._send(404, {"erreur": "introuvable"})
        full = os.path.join(STATIC, name)
        if not os.path.isfile(full):
            return self._send(404, {"erreur": "introuvable"})
        ctype = ("text/html; charset=utf-8" if name.endswith(".html")
                 else "text/plain; charset=utf-8")
        with open(full, "rb") as f:
            self._send(200, f.read(), ctype)

    # -- routes -----------------------------------------------------------
    def do_GET(self):                                        # noqa: N802
        route = self.path.split("?")[0]

        if not route.startswith("/api/"):
            return self._static(route)
        if not self._authorised():
            return self._send(401, {"erreur": "jeton invalide ou absent"})

        if route == "/api/etat":
            return self._send(200, {
                "batterie": CACHE.get("bat", 2.0, UPS.read),
                "systeme": CACHE.get("sys", 3.0, system_info),
            })
        if route == "/api/disques":
            return self._send(200, CACHE.get("disks", 20.0, disks_info))
        if route == "/api/wifi":
            return self._send(200, {
                "etat": CACHE.get("wifi_state", 5.0, wifi_state),
                "scan": CACHE.get("wifi_scan", 30.0, lambda: wifi_scan(False)),
            })
        if route == "/api/wifi/scan":
            CACHE.drop("wifi_scan")
            return self._send(200, CACHE.get("wifi_scan", 30.0,
                                             lambda: wifi_scan(True)))
        if route == "/api/services":
            return self._send(200, CACHE.get("svc", 8.0, services_info))
        if route == "/api/mdns":
            return self._send(200, mdns_info())
        if route == "/api/acces":
            # 30 s : l'adresse ne bouge pas souvent, mais elle DOIT bouger vite
            # à l'écran le jour où l'on rebranche l'arche ailleurs.
            return self._send(200, CACHE.get("acces", 30.0, acces_info))
        if route == "/api/pra":
            return self._send(200, CACHE.get("pra", 10.0, pra_info))
        return self._send(404, {"erreur": "route inconnue"})

    def do_POST(self):                                       # noqa: N802
        route = self.path.split("?")[0]
        if not self._authorised():
            return self._send(401, {"erreur": "jeton invalide ou absent"})
        body = self._body()

        if route == "/api/wifi/connect":
            return self._send(200, wifi_connect(body.get("ssid"),
                                                body.get("password"),
                                                body.get("interface")))
        if route == "/api/services/restart":
            CACHE.drop("svc")
            return self._send(200, service_restart(body.get("nom")))
        if route == "/api/mdns/restart":
            CACHE.drop("svc")
            return self._send(200, service_restart(MDNS_UNIT))
        if route == "/api/pra/pause":
            CACHE.drop("pra")
            return self._send(200, pra_pause_ecrire(body.get("jusqua")))
        if route == "/api/systeme/halt":
            # Confirmation explicite exigee : une requete accidentelle ne doit
            # pas eteindre la machine que l'on est venu consulter.
            if body.get("confirme") is not True:
                return self._send(400, {"ok": False,
                                        "erreur": "confirmation requise"})
            return self._send(200, systeme_halt())
        return self._send(404, {"erreur": "route inconnue"})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# --------------------------------------------------------------------------
#  Autotest — je ne peux pas executer ceci a ta place, alors autant que le
#  programme sache se diagnostiquer lui-meme.
# --------------------------------------------------------------------------

def selftest():
    print("== YunoBox : autotest ==\n")
    ok = True

    print("-- multiplexage des broches I2C --")
    mux = i2c_pinmux()
    if mux is None:
        print("  pinctrl indisponible, verification impossible")
    else:
        print("  %s  ->  %s" % (mux["detail"], "ok" if mux["ok"]
                                else "PAS EN FONCTION I2C"))
        if not mux["ok"]:
            ok = False
            print("  sur Pi 5 l'I2C1 est la fonction a3, pas a0. Un redemarrage")
            print("  restaure le multiplexage depuis l'arbre de peripheriques.")

    print("\n-- UPS HAT (E) --")
    bat = UPS.read()
    if bat.get("ok"):
        print("  batterie %s mV, %s mA, %s %%, ecart cellules %s mV"
              % (bat["batterie_mv"], bat["batterie_ma"],
                 bat["pourcent"], bat["ecart_cellules_mv"]))
        print("  phase : %s | BQ4050 : %s | IP2368 : %s"
              % (bat["phase"], bat["liaison_bq4050"], bat["liaison_ip2368"]))
    else:
        ok = False
        print("  ECHEC : %s" % bat.get("erreur"))

    print("\n-- systeme --")
    s = system_info()
    print("  %s, %s degres, uptime %d s, charge %s"
          % (s["hote"], s["temperature_c"], s["uptime_s"], s["charge_moyenne"]))

    print("\n-- disques --")
    d = disks_info()
    for v in d["volumes"]:
        print("  %-24s %-16s %3s%%" % (v["montage"], v["peripherique"], v["pourcent"]))
    print("  temperatures NVMe : %s" % (d["temperatures_nvme"] or "non exposees"))

    print("\n-- WiFi --")
    w = wifi_state()
    if w.get("ok"):
        for i in w["interfaces"]:
            print("  %-10s %-12s %-14s %s"
                  % (i["interface"], i["type"], i["etat"], i["connexion"]))
        print("  profils enregistres : %s" % (", ".join(w["enregistres"]) or "aucun"))
    else:
        ok = False
        print("  ECHEC : %s" % w.get("erreur"))

    print("\n-- services et yunomdns --")
    sv = services_info()
    m = sv["mdns"]
    print("  yunomdns : %s (%s), au demarrage : %s"
          % (m["etat"], m["sous_etat"], m["au_demarrage"]))
    print("  domaines .local : %s" % (", ".join(m["domaines_local"]) or "aucun trouve"))
    print("  hook NetworkManager installe : %s" % ("oui" if m["hook_installe"] else "NON"))
    print("  dernier relancement auto : %s" % (m["dernier_relancement_auto"] or "jamais"))
    print("  %d services remontes" % len(sv["services"]))
    if not m["hook_installe"]:
        print("\n  -> lance install.sh pour poser le hook de relance automatique")

    print("\n%s" % ("Autotest complet." if ok else "Autotest : voir les ECHEC ci-dessus."))
    return 0 if ok else 1


def main():
    global TOKEN
    if "--selftest" in sys.argv:
        return selftest()

    host = os.environ.get("YUNOBOX_HOST", "0.0.0.0")
    port = int(os.environ.get("YUNOBOX_PORT", "8723"))
    TOKEN = load_token()

    srv = Server((host, port), Handler)
    print("YunoBox sur http://%s:%d/?token=%s" % (host, port, TOKEN), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
