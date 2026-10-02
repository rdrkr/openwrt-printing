#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# install-wan-notify.sh — install the WAN-switch Bark notifier on the router.
#
# Copies files/usr/sbin/wan-notify and its kmwan hotplug hook, writes
# /etc/config/wan_notify, lists both files in /etc/sysupgrade.conf so they
# survive a firmware upgrade, and sends a test notification.
#
# The Bark device key is the only secret: anyone who knows it can push to your
# phone. Get it from the Bark iOS app (the part after https://api.day.app/ in
# the example URLs). Resolution order: $BARK_KEY, then the key already on the
# router; the script fails if neither is set.
#
# Env:
#   ROUTER       ssh target                (default root@192.168.8.1)
#   BARK_KEY     Bark device key           (default: keep existing)
#   BARK_SERVER  Bark server URL           (default https://api.day.app)
set -euo pipefail

ROUTER="${ROUTER:-root@192.168.8.1}"
BARK_SERVER="${BARK_SERVER:-https://api.day.app}"
FILES_DIR="$(cd "$(dirname "$0")/.." && pwd)/files"

if [ -z "${BARK_KEY:-}" ]; then
  BARK_KEY="$(ssh -o BatchMode=yes "$ROUTER" 'uci -q get wan_notify.main.key' || true)"
fi
if [ -z "$BARK_KEY" ]; then
  echo "[wan-notify] BARK_KEY is not set and none is configured on $ROUTER." >&2
  echo "[wan-notify] Copy your device key from the Bark iOS app and re-run:" >&2
  echo "  BARK_KEY=<key> $0" >&2
  exit 1
fi

echo "[wan-notify] Copying files to $ROUTER…"
# -O forces legacy SCP protocol — OpenWrt's dropbear lacks sftp-server.
scp -O -q "$FILES_DIR/usr/sbin/wan-notify" "$ROUTER":/usr/sbin/wan-notify
scp -O -q "$FILES_DIR/etc/hotplug.d/kmwan/99-wan-notify" "$ROUTER":/etc/hotplug.d/kmwan/99-wan-notify

echo "[wan-notify] Configuring…"
ssh "$ROUTER" BARK_KEY="$BARK_KEY" BARK_SERVER="$BARK_SERVER" sh -s <<'REMOTE'
set -eu
chmod 755 /usr/sbin/wan-notify /etc/hotplug.d/kmwan/99-wan-notify

touch /etc/config/wan_notify
uci -q get wan_notify.main >/dev/null || uci set wan_notify.main=notify
uci -q get wan_notify.main.enabled >/dev/null || uci set wan_notify.main.enabled=1
uci set wan_notify.main.server="$BARK_SERVER"
uci set wan_notify.main.key="$BARK_KEY"
# Drop settings left over from the earlier ntfy backend.
uci -q delete wan_notify.main.topic || true
uci -q delete wan_notify.main.token || true
uci commit wan_notify

# Custom files outside /etc/config are dropped by a firmware upgrade unless
# listed here.
for f in /usr/sbin/wan-notify /etc/hotplug.d/kmwan/99-wan-notify; do
  grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >>/etc/sysupgrade.conf
done

# Seed the state file so the next real switch is reported against it.
/usr/sbin/wan-notify check
/usr/sbin/wan-notify status
/usr/sbin/wan-notify test
REMOTE

echo "[wan-notify] Done — a test notification should be on your phone."
