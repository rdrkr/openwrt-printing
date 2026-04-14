#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# install-foo2zjs.sh — unpack the foo2zjs tarball on the router into the
# correct CUPS filter/model directories.
set -euo pipefail

ROUTER="${ROUTER:-root@192.168.8.1}"
TARBALL="$(cd "$(dirname "$0")/.." && pwd)/output/foo2zjs-hp-lj1022.tar.gz"

[ -f "$TARBALL" ] || { echo "Tarball not found: $TARBALL — run build-foo2zjs.sh first" >&2; exit 1; }

echo "[install-foo2zjs] Copying $(basename "$TARBALL")…"
scp -q "$TARBALL" "$ROUTER":/tmp/

ssh "$ROUTER" bash -s <<'REMOTE'
set -euo pipefail
cd /
tar -xzf /tmp/foo2zjs-hp-lj1022.tar.gz
chmod 755 /usr/lib/cups/filter/foo2zjs /usr/lib/cups/filter/foo2zjs-wrapper
ls -la /usr/lib/cups/filter/foo2zjs /usr/lib/cups/filter/foo2zjs-wrapper
ls /usr/share/cups/model/ | grep -i laserjet || echo "WARNING: no LaserJet PPD installed"
echo "[install-foo2zjs] Done. Now restart cupsd and add the printer."
REMOTE
