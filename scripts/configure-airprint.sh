#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# configure-airprint.sh — publish an AirPrint mDNS record via avahi so that
# iOS/macOS discover the printer. Assumes CUPS is running and a printer
# named 'LaserJet1022' has been added.
#
# The TXT records here are the minimum set AirPrint requires. The `pdl`
# field declares what document types the printer accepts — we list PDF,
# URF (Apple Universal Raster), JPEG, and PNG so most iOS print paths work.
set -euo pipefail

ROUTER="${ROUTER:-root@192.168.8.1}"
PRINTER_NAME="${PRINTER_NAME:-LaserJet1022}"

ssh "$ROUTER" bash -s <<REMOTE
set -euo pipefail

# avahi-daemon should already be present on the router via opkg
opkg list-installed | grep -q avahi-daemon || opkg install avahi-nodbus-daemon

mkdir -p /etc/avahi/services
cat > /etc/avahi/services/airprint.service <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">AirPrint HP LaserJet 1022 @ %h</name>
  <service>
    <type>_ipp._tcp</type>
    <subtype>_universal._sub._ipp._tcp</subtype>
    <port>631</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rp=printers/${PRINTER_NAME}</txt-record>
    <txt-record>ty=HP LaserJet 1022</txt-record>
    <txt-record>note=HP LaserJet 1022 on GL-BE9300</txt-record>
    <txt-record>product=(GPL Ghostscript)</txt-record>
    <txt-record>printer-state=3</txt-record>
    <txt-record>printer-type=0x3006</txt-record>
    <txt-record>Binary=T</txt-record>
    <txt-record>Transparent=T</txt-record>
    <txt-record>URF=DM3</txt-record>
    <txt-record>pdl=application/octet-stream,application/pdf,application/postscript,application/vnd.cups-raster,image/jpeg,image/png,image/urf</txt-record>
  </service>
</service-group>
EOF

/etc/init.d/avahi-daemon enable
/etc/init.d/avahi-daemon restart
sleep 1
/etc/init.d/avahi-daemon status || true

echo "[configure-airprint] Published AirPrint service for printer '${PRINTER_NAME}'."
REMOTE
