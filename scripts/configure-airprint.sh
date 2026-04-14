#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# configure-airprint.sh — publish an AirPrint mDNS record via avahi so that
# iOS/macOS discover the printer. Assumes CUPS is running and a print
# queue whose name matches $PRINTER_NAME has already been added with
# lpadmin (the Avahi record only advertises; it does not create the queue).
#
# All printer-facing strings (model, description, color, duplex, queue
# name) come from environment variables, so a single invocation re-targets
# the advertisement at any printer CUPS has been configured for. Defaults
# describe the reference HP LaserJet 1022 this repo was validated against.
#
# The TXT records here are the minimum set AirPrint requires. The `pdl`
# field declares what document types the printer accepts — we list PDF,
# URF (Apple Universal Raster), JPEG, and PNG so most iOS print paths work.
set -euo pipefail

ROUTER="${ROUTER:-root@192.168.8.1}"
PRINTER_NAME="${PRINTER_NAME:-HP_LaserJet_1022}"
# Human-readable strings that land in the Avahi TXT record. Override these
# to re-target the advertisement at a different printer without editing
# the script (the CUPS queue, driver, and PPD are what make a printer
# actually work — this only affects how iOS/macOS label it in the picker).
PRINTER_MODEL="${PRINTER_MODEL:-HP LaserJet 1022}"
PRINTER_DESCRIPTION="${PRINTER_DESCRIPTION:-${PRINTER_MODEL} on GL-BE9300}"
PRINTER_COLOR="${PRINTER_COLOR:-F}"          # F = mono, T = color
PRINTER_DUPLEX="${PRINTER_DUPLEX:-F}"        # F = simplex only, T = duplex
# Stable UUID seed. Derived from a slug of the model + router hostname so
# re-running the script against the same printer produces the same UUID
# (AirPrint on iOS 12+ rejects printers whose Bonjour record omits UUID,
# and a UUID that changes on every run causes iOS to re-add the printer
# as a new device on each advertisement).
UUID_SEED="${UUID_SEED:-$(echo "$PRINTER_MODEL" | tr '[:upper:] ' '[:lower:]-').gl-be9300.local}"
UUID="$(python3 -c "import uuid,sys; print(uuid.uuid5(uuid.NAMESPACE_DNS, sys.argv[1]))" "$UUID_SEED")"

ssh "$ROUTER" \
  PRINTER_NAME="$PRINTER_NAME" \
  PRINTER_MODEL="$PRINTER_MODEL" \
  PRINTER_DESCRIPTION="$PRINTER_DESCRIPTION" \
  PRINTER_COLOR="$PRINTER_COLOR" \
  PRINTER_DUPLEX="$PRINTER_DUPLEX" \
  UUID="$UUID" \
  sh -s <<'REMOTE'
set -euo pipefail

# Use whichever avahi variant is present. The router typically ships with
# avahi-dbus-daemon already installed; if neither is present, install the
# nodbus one (lighter, no dbus dep). Do NOT try to install avahi-nodbus-*
# when the dbus variant is present — libavahi-nodbus-support conflicts
# with libavahi-dbus-support on /usr/lib/libavahi-*.so.
# grep -c (not -q): -q closes stdin on first match and SIGPIPEs opkg,
# which under `set -o pipefail` propagates exit 141 and misfires the `!`.
have_avahi=$(opkg list-installed | grep -cE '^avahi-(dbus|nodbus)-daemon ' || true)
if [ "$have_avahi" -eq 0 ]; then
  opkg install avahi-nodbus-daemon
fi

# CUPS queues default to non-shared; iOS AirPrint treats a non-shared
# queue as offline even though IPP Get-Printer-Attributes responds.
# Also force shared=true on policy so advertised queue is truly reachable.
lpadmin -p "$PRINTER_NAME" -o printer-is-shared=true

mkdir -p /etc/avahi/services
# Use an unquoted heredoc so ${PRINTER_NAME}/${UUID} from the outer env
# get substituted. The nested EOF marker on the file is fine because
# avahi reads it literally.
cat > /etc/avahi/services/airprint.service <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">AirPrint ${PRINTER_MODEL} @ %h</name>
  <service>
    <type>_ipp._tcp</type>
    <subtype>_universal._sub._ipp._tcp</subtype>
    <port>631</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rp=printers/${PRINTER_NAME}</txt-record>
    <txt-record>ty=${PRINTER_MODEL}</txt-record>
    <txt-record>note=${PRINTER_DESCRIPTION}</txt-record>
    <txt-record>adminurl=http://GL-BE9300.local:631/printers/${PRINTER_NAME}</txt-record>
    <txt-record>product=(${PRINTER_MODEL})</txt-record>
    <txt-record>printer-state=3</txt-record>
    <txt-record>printer-type=0x801046</txt-record>
    <txt-record>Color=${PRINTER_COLOR}</txt-record>
    <txt-record>Duplex=${PRINTER_DUPLEX}</txt-record>
    <txt-record>Binary=T</txt-record>
    <txt-record>Transparent=T</txt-record>
    <txt-record>TBCP=F</txt-record>
    <txt-record>Fax=F</txt-record>
    <txt-record>Scan=F</txt-record>
    <txt-record>PaperMax=legal-A4</txt-record>
    <txt-record>kind=document</txt-record>
    <txt-record>UUID=${UUID}</txt-record>
    <txt-record>air=none</txt-record>
    <!--
      iOS AirPrint filters out printers that don't declare URF, even when
      the server can accept plain PDF. Claim a minimal-but-valid URF
      profile (W8 = 8-bit grayscale, SRGB24 = 24-bit sRGB, CP1 = one
      copies-feature group, RS600 = 600 dpi, DM1 = duplex mode off). iOS
      probes the printer's IPP attrs before sending URF; when our
      Get-Printer-Attributes response doesn't advertise image/urf as an
      accepted document-format, iOS falls back to PDF, which our filter
      chain (pstops → foomatic-rip → foo2zjs) handles natively.
    -->
    <txt-record>URF=W8,SRGB24,CP1,RS600,DM1</txt-record>
    <txt-record>pdl=application/pdf,application/postscript,image/jpeg,image/png,image/urf</txt-record>
  </service>
</service-group>
EOF

/etc/init.d/avahi-daemon enable
/etc/init.d/avahi-daemon restart
sleep 1
/etc/init.d/avahi-daemon status || true

echo "[configure-airprint] Published AirPrint service for printer '${PRINTER_NAME}' (UUID ${UUID})."
REMOTE
