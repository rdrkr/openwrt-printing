#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# install-wan-notify.sh — install the WAN-switch ntfy notifier on the router.
#
# Copies files/usr/sbin/wan-notify and its kmwan hotplug hook, writes
# /etc/config/wan_notify, lists both files in /etc/sysupgrade.conf so they
# survive a firmware upgrade, and sends a test notification.
#
# The ntfy topic is the only secret: anyone who knows it can read and post to
# it. Resolution order: $NTFY_TOPIC, then the topic already on the router,
# then a freshly generated random one (printed at the end — subscribe to it
# in the ntfy iOS app).
#
# Env:
#   ROUTER       ssh target                (default root@192.168.8.1)
#   NTFY_TOPIC   ntfy topic                (default: keep existing / generate)
#   NTFY_SERVER  ntfy base URL             (default https://ntfy.sh)
#   NTFY_TOKEN   ntfy access token         (optional)
set -euo pipefail

ROUTER="${ROUTER:-root@192.168.8.1}"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
NTFY_TOKEN="${NTFY_TOKEN:-}"
FILES_DIR="$(cd "$(dirname "$0")/.." && pwd)/files"

if [ -z "${NTFY_TOPIC:-}" ]; then
  NTFY_TOPIC="$(ssh -o BatchMode=yes "$ROUTER" 'uci -q get wan_notify.main.topic' || true)"
fi
if [ -z "$NTFY_TOPIC" ]; then
  NTFY_TOPIC="wan-$(openssl rand -hex 12)"
  echo "[wan-notify] Generated ntfy topic"
fi

echo "[wan-notify] Copying files to $ROUTER…"
# -O forces legacy SCP protocol — OpenWrt's dropbear lacks sftp-server.
scp -O -q "$FILES_DIR/usr/sbin/wan-notify" "$ROUTER":/usr/sbin/wan-notify
scp -O -q "$FILES_DIR/etc/hotplug.d/kmwan/99-wan-notify" "$ROUTER":/etc/hotplug.d/kmwan/99-wan-notify

echo "[wan-notify] Configuring…"
ssh "$ROUTER" NTFY_TOPIC="$NTFY_TOPIC" NTFY_SERVER="$NTFY_SERVER" NTFY_TOKEN="$NTFY_TOKEN" sh -s <<'REMOTE'
set -eu
chmod 755 /usr/sbin/wan-notify /etc/hotplug.d/kmwan/99-wan-notify

touch /etc/config/wan_notify
uci -q get wan_notify.main >/dev/null || uci set wan_notify.main=notify
uci -q get wan_notify.main.enabled >/dev/null || uci set wan_notify.main.enabled=1
uci set wan_notify.main.server="$NTFY_SERVER"
uci set wan_notify.main.topic="$NTFY_TOPIC"
if [ -n "$NTFY_TOKEN" ]; then
  uci set wan_notify.main.token="$NTFY_TOKEN"
fi
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

echo "[wan-notify] Done. Subscribe in the ntfy iOS app to:"
echo "  server: $NTFY_SERVER"
echo "  topic:  $NTFY_TOPIC"
