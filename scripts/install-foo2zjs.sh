#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# install-foo2zjs.sh — unpack the foo2zjs tarball on the router into the
# correct CUPS filter/model directories.
set -euo pipefail

ROUTER="${ROUTER:-root@192.168.8.1}"
TARBALL="$(cd "$(dirname "$0")/.." && pwd)/output/foo2zjs-hp-lj1022.tar.gz"

[ -f "$TARBALL" ] || { echo "Tarball not found: $TARBALL — run build-foo2zjs.sh first" >&2; exit 1; }

echo "[install-foo2zjs] Copying $(basename "$TARBALL")…"
scp -O -q "$TARBALL" "$ROUTER":/tmp/

ssh "$ROUTER" sh -s <<'REMOTE'
set -euo pipefail
cd /
tar -xzf /tmp/foo2zjs-hp-lj1022.tar.gz
# Tarball was created in the build container under uid 1000 — tar preserves
# that uid on extract when run as root. CUPS refuses to use filters in
# non-root-owned dirs ("cups-insecure-filter-warning"), so force ownership.
chown -R root:root /usr/lib/cups /usr/share/cups/model
chown root:root /usr/bin/foo2zjs-pstops
chmod 755 /usr/lib/cups/filter/foo2zjs /usr/lib/cups/filter/foo2zjs-wrapper /usr/bin/foo2zjs-pstops
ls -la /usr/lib/cups/filter/foo2zjs /usr/lib/cups/filter/foo2zjs-wrapper /usr/bin/foo2zjs-pstops
ls /usr/share/cups/model/ | grep -i laserjet || echo "WARNING: no LaserJet PPD installed"
echo "[install-foo2zjs] Done. Now restart cupsd and add the printer."
REMOTE
