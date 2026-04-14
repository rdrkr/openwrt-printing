#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# install-foomatic-rip.sh — unpack the cross-compiled foomatic-rip tarball
# on the router. CUPS needs /usr/lib/cups/filter/foomatic-rip to honor
# Foomatic-generated PPDs (which embed *FoomaticRIPCommandLine).
set -euo pipefail

ROUTER="${ROUTER:-root@192.168.8.1}"
TARBALL="$(cd "$(dirname "$0")/.." && pwd)/output/foomatic-rip-aarch64.tar.gz"

[ -f "$TARBALL" ] || { echo "Tarball not found: $TARBALL — run build-foomatic-rip.sh first" >&2; exit 1; }

echo "[install-foomatic-rip] Copying $(basename "$TARBALL")…"
scp -O -q "$TARBALL" "$ROUTER":/tmp/

ssh "$ROUTER" sh -s <<'REMOTE'
set -euo pipefail
cd /
tar -xzf /tmp/foomatic-rip-aarch64.tar.gz
# CUPS refuses filters in non-root-owned dirs. The tarball preserves
# container uid 1000 on filesystem entries; chown the whole tree — not
# just the individual files — because tar also resets the PARENT dir's
# ownership to 1000 if that dir was in the archive.
chown -R root:root /usr/lib/cups /etc/cups
chmod 755 /usr/lib/cups/filter/foomatic-rip
ls -la /usr/lib/cups/filter/foomatic-rip
file /usr/lib/cups/filter/foomatic-rip 2>/dev/null || head -c 4 /usr/lib/cups/filter/foomatic-rip | xxd | head -1
echo "[install-foomatic-rip] Done. Restart cupsd to pick it up."
REMOTE
