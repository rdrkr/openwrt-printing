#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# bootstrap.sh — one-shot pipeline: build the printing stack inside the
# Docker build container, install the .ipk packages + helper tarballs on
# the router, add the CUPS print queue, and publish the AirPrint service.
# Wraps every stage script under scripts/ with a single CLI entry point.
#
# All printer-specific inputs are CLI flags with defaults describing the
# reference HP LaserJet 1022 build. Every stage script is already
# idempotent, so re-running this wrapper after a failure is safe.
#
# Typical usage (reference HP LaserJet 1022 config):
#   ./scripts/bootstrap.sh
#
# Targeting a different printer (Brother HL-L2350DW example):
#   ./scripts/bootstrap.sh \
#     --printer-name Brother_HLL2350DW \
#     --printer-model "Brother HL-L2350DW" \
#     --device-uri usb://Brother/HL-L2350DW \
#     --ppd /usr/share/cups/model/Brother-HL-L2350DW.ppd
#
# Skipping stages (build already done, just re-push configuration):
#   ./scripts/bootstrap.sh --skip-build --skip-install
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Defaults. CLI flags below override each of these.
ROUTER="root@192.168.8.1"
LAN_CIDR="192.168.8.0/24"
PRINTER_NAME="HP_LaserJet_1022"
PRINTER_MODEL="HP LaserJet 1022"
PRINTER_DESCRIPTION=""                                    # derived if empty
PRINTER_COLOR="F"
PRINTER_DUPLEX="F"
DEVICE_URI="usb://HP/LaserJet%201022"
PPD_PATH="/usr/share/cups/model/HP-LaserJet_1022.ppd"
SKIP_BUILD=0
SKIP_INSTALL=0
SKIP_CONFIGURE=0
SKIP_LPADMIN=0

usage() {
  cat <<'USAGE'
bootstrap.sh — build, install, and configure the AirPrint stack on a
GL.iNet Flint 3 (or compatible aarch64_cortex-a53 OpenWrt router).

Usage: ./scripts/bootstrap.sh [OPTIONS]

Connectivity:
  --router SSH_TARGET         Router SSH target. Default: root@192.168.8.1
  --lan-cidr CIDR             LAN subnet allowed to talk to CUPS.
                              Default: 192.168.8.0/24

Printer identity (defaults describe the reference HP LJ 1022):
  --printer-name NAME         CUPS queue name. Default: HP_LaserJet_1022
  --printer-model MODEL       Human-readable model; lands in the AirPrint
                              TXT record 'ty' field. Default: "HP LaserJet 1022"
  --printer-description TEXT  Description shown in the AirPrint picker.
                              Default: "<model> on <router-host>"
  --printer-color F|T         T if color, F if mono. Default: F
  --printer-duplex F|T        T if printer supports duplex. Default: F

Printer driver wiring (passed to lpadmin; printer-specific):
  --device-uri URI            CUPS device URI. Default: usb://HP/LaserJet%201022
                              (run 'lpinfo -v' on the router to discover
                              valid URIs for a connected printer).
  --ppd PATH                  Path to PPD on the router for lpadmin -P.
                              Default: /usr/share/cups/model/HP-LaserJet_1022.ppd

Pipeline control (skip stages already completed on a previous run):
  --skip-build                Skip Docker setup, SDK fetch, and cross-compile.
  --skip-install              Skip scp + opkg install on the router.
  --skip-configure            Skip cupsd.conf, pdftops shim, firewall,
                              lpadmin, and the Avahi advertisement.
  --skip-lpadmin              Still run configure-cups / configure-airprint,
                              but don't add the CUPS queue.
  -h, --help                  Show this message and exit.

Exits 0 on success, non-zero on first failure.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --router)              ROUTER="$2";              shift 2 ;;
    --lan-cidr)            LAN_CIDR="$2";            shift 2 ;;
    --printer-name)        PRINTER_NAME="$2";        shift 2 ;;
    --printer-model)       PRINTER_MODEL="$2";       shift 2 ;;
    --printer-description) PRINTER_DESCRIPTION="$2"; shift 2 ;;
    --printer-color)       PRINTER_COLOR="$2";       shift 2 ;;
    --printer-duplex)      PRINTER_DUPLEX="$2";      shift 2 ;;
    --device-uri)          DEVICE_URI="$2";          shift 2 ;;
    --ppd)                 PPD_PATH="$2";            shift 2 ;;
    --skip-build)          SKIP_BUILD=1;             shift ;;
    --skip-install)        SKIP_INSTALL=1;           shift ;;
    --skip-configure)      SKIP_CONFIGURE=1;         shift ;;
    --skip-lpadmin)        SKIP_LPADMIN=1;           shift ;;
    -h|--help)             usage; exit 0 ;;
    *) echo "bootstrap.sh: unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

ROUTER_HOST="${ROUTER##*@}"
[ -n "$PRINTER_DESCRIPTION" ] || PRINTER_DESCRIPTION="$PRINTER_MODEL on $ROUTER_HOST"

# Export env vars consumed by the stage scripts.
export ROUTER LAN_CIDR
export PRINTER_NAME PRINTER_MODEL PRINTER_DESCRIPTION PRINTER_COLOR PRINTER_DUPLEX

banner() {
  printf '\n\033[1;34m==> %s\033[0m\n' "$*"
}

run() {
  banner "$*"
  "$@"
}

banner "bootstrap plan"
cat <<SUMMARY
  router:          $ROUTER  (LAN $LAN_CIDR)
  queue name:      $PRINTER_NAME
  model:           $PRINTER_MODEL
  description:     $PRINTER_DESCRIPTION
  color / duplex:  $PRINTER_COLOR / $PRINTER_DUPLEX
  device URI:      $DEVICE_URI
  PPD:             $PPD_PATH
  stages:          build=$([ $SKIP_BUILD -eq 0 ] && echo yes || echo skip) install=$([ $SKIP_INSTALL -eq 0 ] && echo yes || echo skip) configure=$([ $SKIP_CONFIGURE -eq 0 ] && echo yes || echo skip) lpadmin=$([ $SKIP_LPADMIN -eq 0 ] && echo yes || echo skip)
SUMMARY

# ---------------------------------------------------------------------------
# 1) Build stage: cross-compile the printing stack inside the build container.
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" -eq 0 ]; then
  run "$SCRIPT_DIR/setup-container.sh"
  run "$SCRIPT_DIR/fetch-sdk.sh"
  run "$SCRIPT_DIR/patch-sdk.sh"
  run "$SCRIPT_DIR/prepare-feeds.sh"
  run "$SCRIPT_DIR/configure-sdk.sh"
  run "$SCRIPT_DIR/build-stack.sh"
  run "$SCRIPT_DIR/build-foomatic-rip.sh"
  run "$SCRIPT_DIR/build-foo2zjs.sh"
fi

# ---------------------------------------------------------------------------
# 2) Install stage: push packages + tarballs onto the router.
# ---------------------------------------------------------------------------
if [ "$SKIP_INSTALL" -eq 0 ]; then
  run "$SCRIPT_DIR/install-on-router.sh"
  run "$SCRIPT_DIR/install-foomatic-rip.sh"
  run "$SCRIPT_DIR/install-foo2zjs.sh"
fi

# ---------------------------------------------------------------------------
# 3) Configure stage: cupsd.conf, pdftops shim, firewall, CUPS queue, Avahi.
# ---------------------------------------------------------------------------
if [ "$SKIP_CONFIGURE" -eq 0 ]; then
  run "$SCRIPT_DIR/configure-cups.sh"

  if [ "$SKIP_LPADMIN" -eq 0 ]; then
    banner "add CUPS queue '$PRINTER_NAME' on $ROUTER"
    # The queue has to exist on the router (via lpadmin) before the Avahi
    # advertisement is meaningful — AirPrint clients that see the mDNS
    # record then issue IPP Get-Printer-Attributes for exactly this queue
    # name, and CUPS 404s the request if the queue is missing.
    ssh "$ROUTER" \
      PRINTER_NAME="$PRINTER_NAME" \
      DEVICE_URI="$DEVICE_URI" \
      PPD_PATH="$PPD_PATH" \
      sh -s <<'REMOTE'
set -euo pipefail
if [ ! -f "$PPD_PATH" ]; then
  echo "[lpadmin] PPD not found on router: $PPD_PATH" >&2
  echo "[lpadmin] expected install-foo2zjs.sh (or equivalent) to place it" >&2
  exit 1
fi
if lpstat -p "$PRINTER_NAME" >/dev/null 2>&1; then
  echo "[lpadmin] queue '$PRINTER_NAME' already exists — reapplying options"
else
  lpadmin -p "$PRINTER_NAME" -E -v "$DEVICE_URI" -P "$PPD_PATH"
  echo "[lpadmin] created queue '$PRINTER_NAME' with device '$DEVICE_URI'"
fi
# printer-is-shared=true is what AirPrint clients check before listing the
# queue as usable; without it iOS silently treats the printer as offline.
lpadmin -p "$PRINTER_NAME" -o printer-is-shared=true
cupsaccept "$PRINTER_NAME"
cupsenable "$PRINTER_NAME"
# Foomatic PPDs are installed 0640 by default; CUPS filters run as 'nobody'
# and can't read them, which produces a cryptic "Unable to open PPD file".
chmod 644 /etc/cups/ppd/"$PRINTER_NAME".ppd 2>/dev/null || true
lpstat -p "$PRINTER_NAME"
REMOTE
  fi

  run "$SCRIPT_DIR/configure-airprint.sh"
fi

banner "bootstrap complete"
cat <<DONE
  CUPS web UI:    http://$ROUTER_HOST:631/
  AirPrint name:  AirPrint $PRINTER_MODEL @ <router-hostname>
  test page:      ssh $ROUTER lp -d $PRINTER_NAME /etc/hostname
DONE
