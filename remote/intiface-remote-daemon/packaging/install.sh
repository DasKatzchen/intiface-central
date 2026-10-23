#!/usr/bin/env bash
# Install intiface-remote-daemon on a Raspberry Pi. Run as root from a
# directory containing the daemon binary and this packaging folder:
#
#   sudo ./install.sh ./intiface-remote-daemon
#
# Creates the `intiface` service user, an access token, and the systemd unit.
set -euo pipefail

bin="${1:-./intiface-remote-daemon}"
here="$(cd "$(dirname "$0")" && pwd)"
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
[ -x "$bin" ] || { echo "Daemon binary not found at $bin"; exit 1; }

id intiface >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin intiface
# bluetooth: BlueZ D-Bus policy; dialout: serial toys/dongles; plugdev: HID dongles.
for g in bluetooth dialout plugdev; do
  getent group "$g" >/dev/null && usermod -aG "$g" intiface
done

install -m 0755 "$bin" /usr/local/bin/intiface-remote-daemon

install -d -m 0750 -o root -g intiface /etc/intiface-remote
if [ ! -s /etc/intiface-remote/token ]; then
  head -c 24 /dev/urandom | base64 | tr -d '/+=' > /etc/intiface-remote/token
  chmod 0640 /etc/intiface-remote/token
  chgrp intiface /etc/intiface-remote/token
fi

# Lovense HID dongle access for the service user.
cat > /etc/udev/rules.d/60-intiface-remote.rules <<'EOF'
SUBSYSTEM=="hidraw", ATTRS{idVendor}=="1915", ATTRS{idProduct}=="520a", MODE="0660", GROUP="plugdev"
EOF
udevadm control --reload-rules || true

install -m 0644 "$here/intiface-remote.service" /etc/systemd/system/intiface-remote.service
systemctl daemon-reload
systemctl enable --now intiface-remote.service

ip="$(hostname -I | awk '{print $1}')"
echo
echo "intiface-remote is running. In Intiface Central > Settings > Remote Engine enter:"
echo "  Address: ws://$ip:12346"
echo "  Token:   $(cat /etc/intiface-remote/token)"
