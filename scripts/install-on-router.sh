#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# install-on-router.sh — SCP .ipk files to the router and install them.
#
# The packages are built for arch "aarch64_cortex-a53" but the router's
# DISTRIB_ARCH is "aarch64_cortex-a53_neon-vfpv4". Underlying CPU is
# identical (IPQ5332 uses Cortex-A53), so we either:
#   (a) add an opkg architecture rule accepting "aarch64_cortex-a53", or
#   (b) install with --force-arch on every call.
# We go with (a) — set once, then all future installs Just Work.
set -euo pipefail

ROUTER="${ROUTER:-root@192.168.8.1}"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/output"

if ! ls "$OUTPUT_DIR"/*.ipk >/dev/null 2>&1; then
  echo "[install] No .ipk files in $OUTPUT_DIR — run build-stack.sh first" >&2
  exit 1
fi

echo "[install] Found $(ls "$OUTPUT_DIR"/*.ipk | wc -l | tr -d ' ') .ipk files"

# 1) Add arch acceptance on router (idempotent)
echo "[install] Configuring opkg to accept aarch64_cortex-a53 packages…"
ssh -o BatchMode=yes "$ROUTER" '
  if ! grep -q "^arch aarch64_cortex-a53 " /etc/opkg.conf 2>/dev/null; then
    echo "arch aarch64_cortex-a53 200" >> /etc/opkg.conf
  fi
  mkdir -p /tmp/printing-ipk
  rm -f /tmp/printing-ipk/*.ipk
'

# 2) Copy .ipk files
echo "[install] Copying .ipk files…"
# -O forces legacy SCP protocol — OpenWrt's dropbear lacks sftp-server.
scp -O -q "$OUTPUT_DIR"/*.ipk "$ROUTER":/tmp/printing-ipk/

# 3) Install everything in /tmp/printing-ipk. opkg resolves internal deps.
#
# Poppler/libcairo are intentionally NOT installed:
#   - We removed all poppler-dependent filters from openprinting-cups-filters
#     (pdftoraster/pdftopdf/bannertopdf/pdftoopvp/pdftoijs/pdftops) since
#     cups-filters 1.0.37 is incompatible with poppler 23.x.
#   - With those filters gone, libpoppler.so is never loaded at runtime, and
#     libcairo (a poppler dep) is not in the router's repos either.
# Our pipeline is AirPrint → cups → gstoraster → ghostscript → foo2zjs, no poppler.
echo "[install] Running opkg install…"
ssh "$ROUTER" '
  # Pull libtiff6 + glib2 from standard repos first (not built locally — available upstream).
  opkg update 2>&1 | tail -3
  opkg install libtiff6 glib2 libusb-1.0-0 2>&1 | tail -5 || true

  cd /tmp/printing-ipk
  # Install all .ipks except poppler (unused — see above).
  # BusyBox xargs lacks -a; feed filenames via stdin instead.
  ls *.ipk | grep -v "^poppler_" | xargs opkg install 2>&1 | tail -50
'

echo "[install] Done."
