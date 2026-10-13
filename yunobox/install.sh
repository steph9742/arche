#!/bin/bash
# Installation de YunoBox. A lancer en root sur le Raspberry Pi.
#   sudo ./install.sh              installe tout
#   sudo ./install.sh --no-hook    sans le hook NetworkManager
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST=/opt/yunobox
UNIT=/etc/systemd/system/yunobox.service
WORKER=/usr/local/sbin/yunobox-mdns-refresh
HOOK=/etc/NetworkManager/dispatcher.d/99-yunobox-mdns
TOKEN_FILE=/etc/yunobox/token
WITH_HOOK=1

[ "${1:-}" = "--no-hook" ] && WITH_HOOK=0

if [ "$(id -u)" != "0" ]; then
    echo "A lancer en root : sudo $0" >&2
    exit 1
fi

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

# ---------------------------------------------------------------- prerequis
say "Verification des prerequis"

if ! python3 -c 'import smbus' 2>/dev/null; then
    echo "  python3-smbus manquant, installation…"
    apt-get install -y python3-smbus >/dev/null
fi
echo "  python3-smbus : ok"

if [ -e /dev/i2c-1 ]; then
    echo "  /dev/i2c-1 : ok"
else
    echo "  /dev/i2c-1 ABSENT — active l'I2C : raspi-config nonint do_i2c 0 puis reboot" >&2
fi

if command -v nmcli >/dev/null 2>&1; then
    echo "  nmcli : ok"
    HAVE_NM=1
else
    echo "  nmcli ABSENT — le module WiFi et le hook seront inertes."
    echo "  Ce projet suppose NetworkManager. Sous systemd-networkd, il faudrait"
    echo "  passer par networkd-dispatcher."
    HAVE_NM=0
fi

command -v yunohost >/dev/null 2>&1 \
    && echo "  CLI yunohost : ok" \
    || echo "  CLI yunohost absente — repli sur systemctl pour les services."

# ---------------------------------------------------------------- programme
say "Installation dans $DEST"
install -d -m 0755 "$DEST" "$DEST/static"
install -m 0755 "$SRC/yunobox.py"          "$DEST/yunobox.py"
install -m 0644 "$SRC/static/index.html"   "$DEST/static/index.html"
[ -f "$SRC/README.md" ] && install -m 0644 "$SRC/README.md" "$DEST/README.md"
install -d -m 0755 /var/lib/yunobox

# ---------------------------------------------------------------- jeton
if [ -s "$TOKEN_FILE" ]; then
    say "Jeton existant conserve"
else
    say "Generation du jeton"
    install -d -m 0700 "$(dirname "$TOKEN_FILE")"
    python3 -c 'import secrets; print(secrets.token_urlsafe(24))' > "$TOKEN_FILE"
    chmod 0600 "$TOKEN_FILE"
fi
TOKEN="$(cat "$TOKEN_FILE")"

# ---------------------------------------------------------------- hook mDNS
if [ "$WITH_HOOK" = "1" ]; then
    say "Hook de relance de yunomdns"
    install -m 0755 "$SRC/dispatcher/yunobox-mdns-refresh" "$WORKER"
    echo "  worker : $WORKER"
    if [ "$HAVE_NM" = "1" ] && [ -d /etc/NetworkManager/dispatcher.d ]; then
        install -o root -g root -m 0755 "$SRC/dispatcher/99-yunobox-mdns" "$HOOK"
        echo "  dispatcher : $HOOK"
    else
        echo "  dispatcher NON installe (NetworkManager absent)."
        echo "  Le worker reste appelable a la main : $WORKER wlan0 manuel"
    fi
else
    say "Hook non installe (--no-hook)"
fi

# ---------------------------------------------------------------- service
say "Service systemd"
install -m 0644 "$SRC/yunobox.service" "$UNIT"
systemctl daemon-reload
systemctl enable yunobox >/dev/null 2>&1 || true
systemctl restart yunobox
sleep 1
systemctl is-active --quiet yunobox \
    && echo "  yunobox : actif" \
    || { echo "  yunobox : ECHEC — journalctl -u yunobox -n 40" >&2; exit 1; }

# ---------------------------------------------------------------- autotest
say "Autotest"
python3 "$DEST/yunobox.py" --selftest || true

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
say "Termine"
echo "  http://${IP:-<ip-du-pi>}:8723/?token=$TOKEN"
echo
echo "  Le jeton est aussi dans $TOKEN_FILE."
echo "  Journal du service   : journalctl -u yunobox -f"
echo "  Journal du hook mDNS : journalctl -t yunobox-mdns -f"
