#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# configure-cups.sh — post-install CUPS configuration on the router.
#
# Writes /etc/cups/cupsd.conf to listen on LAN, sets up the avahi AirPrint
# service file, opens firewall ports 631/tcp and 5353/udp, and starts
# daemons. Does NOT add the printer itself (see add-printer.sh) because
# the printer add depends on having the foo2zjs PPD installed.
set -euo pipefail

ROUTER="${ROUTER:-root@192.168.8.1}"
LAN_CIDR="${LAN_CIDR:-192.168.8.0/24}"

ssh "$ROUTER" LAN_CIDR="$LAN_CIDR" sh -s <<'REMOTE'
set -euo pipefail

# 1) cupsd.conf — listen on all interfaces, allow LAN
cat > /etc/cups/cupsd.conf <<EOF
LogLevel warn
MaxLogSize 0
Listen 0.0.0.0:631
Listen /var/run/cups/cups.sock
# Accept any Host: header. CUPS 2.4 validates Host: against the bound
# hostnames by default; macOS/iOS AirPrint clients send Host set to the
# Bonjour hostname (e.g. GL-BE9300.local), which CUPS otherwise rejects
# with HTTP 400, and the dnssd:// backend reports "Unable to get printer
# status" (jobs park forever on the client).
ServerAlias *
Browsing On
BrowseLocalProtocols dnssd
DefaultAuthType Basic
WebInterface Yes
IdleExitTimeout 60

<Location />
  Order allow,deny
  Allow localhost
  Allow $LAN_CIDR
</Location>
<Location /admin>
  Order allow,deny
  Allow localhost
  Allow $LAN_CIDR
</Location>
<Location /admin/conf>
  AuthType Default
  Require user @SYSTEM
  Order allow,deny
  Allow localhost
  Allow $LAN_CIDR
</Location>

<Policy default>
  JobPrivateAccess default
  JobPrivateValues default
  SubscriptionPrivateAccess default
  SubscriptionPrivateValues default
  <Limit Create-Job Print-Job Print-URI Validate-Job>
    Order deny,allow
  </Limit>
  <Limit Send-Document Send-URI Hold-Job Release-Job Restart-Job Purge-Jobs Set-Job-Attributes Create-Job-Subscription Renew-Subscription Cancel-Subscription Get-Notifications Reprocess-Job Cancel-Current-Job Suspend-Current-Job Resume-Job Cancel-My-Jobs Close-Job CUPS-Move-Job CUPS-Get-Document>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>
  <Limit CUPS-Add-Modify-Printer CUPS-Delete-Printer CUPS-Add-Modify-Class CUPS-Delete-Class CUPS-Set-Default CUPS-Get-Devices>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>
  <Limit Pause-Printer Resume-Printer Enable-Printer Disable-Printer Pause-Printer-After-Current-Job Hold-New-Jobs Release-Held-New-Jobs Deactivate-Printer Activate-Printer Restart-Printer Shutdown-Printer Startup-Printer Promote-Job Schedule-Job-After CUPS-Accept-Jobs CUPS-Reject-Jobs>
    AuthType Default
    Require user @SYSTEM
    Order deny,allow
  </Limit>
  <Limit Cancel-Job CUPS-Authenticate-Job>
    Require user @OWNER @SYSTEM
    Order deny,allow
  </Limit>
  <Limit All>
    Order deny,allow
  </Limit>
</Policy>
EOF

# 2) Make sure /dev/usb/lp0 is readable by CUPS (runs as root by default on OpenWrt)
ls -la /dev/usb/lp0 || echo "WARNING: /dev/usb/lp0 not present"

# 3) PDF ingress shim. cups-filters 1.0.37 does not build its PDF filters
# (pdftopdf / pdftops / pdftoraster) against poppler 23.x — the upstream
# headers moved and the 1.0.37 sources fail to compile. Without pdftops,
# CUPS has no chain from application/pdf to application/vnd.cups-postscript
# (which every foomatic-rip-based PPD declares as its input). Consequence:
# application/pdf and image/urf are omitted from document-format-supported
# in IPP Get-Printer-Attributes, and iOS AirPrint silently refuses to send
# the job — the printer looks online but no Create-Job ever arrives.
# Fix: ship a gs-based pdftops shim and register it in /etc/cups/mime.convs.
cat > /usr/lib/cups/filter/pdftops <<'SHIM'
#!/bin/sh
# CUPS filter: application/pdf -> application/vnd.cups-postscript via ghostscript.
# Shim installed by configure-cups.sh because cups-filters 1.0.37 cannot
# build its own pdftops against poppler 23.x on this target. Ghostscript
# 10.x handles the conversion natively via -sDEVICE=ps2write.
# CUPS filter ABI: job-id user title copies options [filename]. Read stdin
# when no filename is given; write PostScript on stdout; log to stderr.
set -eu
GS_ARGS='-q -dNOPAUSE -dBATCH -dSAFER -sDEVICE=ps2write -sOutputFile=-'
if [ $# -ge 6 ] && [ -n "${6:-}" ]; then
  exec /usr/bin/gs $GS_ARGS -f "$6"
else
  exec /usr/bin/gs $GS_ARGS -
fi
SHIM
chown root:root /usr/lib/cups/filter/pdftops
chmod 755 /usr/lib/cups/filter/pdftops

# /etc/cups/mime.convs overlay. CUPS merges every *.convs under
# /usr/share/cups/mime/ and /etc/cups/; this file is the project-owned
# extension that registers the shim as a 50-cost converter from
# application/pdf to application/vnd.cups-postscript. The cost (50) is
# intentionally lower than the 100-cost entry pdftopdf→cups-pdf→pdftops
# would have imposed, so CUPS selects this one-hop chain whenever it
# exists. Cost-50 also sits below the default 100 for pdftopdf, so the
# shim wins against any future package that ships pdftopdf+pdftops.
cat > /etc/cups/mime.convs <<'EOF'
# Project-owned overlay installed by configure-cups.sh.
# Wires the local pdftops shim into CUPS' filter graph.
application/pdf  application/vnd.cups-postscript  50  pdftops
EOF

# 4) Enable + start cupsd (picks up the new mime.convs on startup)
/etc/init.d/cupsd enable
/etc/init.d/cupsd restart
sleep 2
/etc/init.d/cupsd status || true

# 5) Firewall rules (LAN → CUPS and mDNS). Idempotent by name.
if ! uci show firewall | grep -q "Allow-CUPS"; then
  uci add firewall rule >/dev/null
  uci set firewall.@rule[-1].name='Allow-CUPS'
  uci set firewall.@rule[-1].src='lan'
  uci set firewall.@rule[-1].dest_port='631'
  uci set firewall.@rule[-1].proto='tcp'
  uci set firewall.@rule[-1].target='ACCEPT'
fi
if ! uci show firewall | grep -q "Allow-mDNS"; then
  uci add firewall rule >/dev/null
  uci set firewall.@rule[-1].name='Allow-mDNS'
  uci set firewall.@rule[-1].src='lan'
  uci set firewall.@rule[-1].dest_port='5353'
  uci set firewall.@rule[-1].proto='udp'
  uci set firewall.@rule[-1].target='ACCEPT'
fi
uci commit firewall
/etc/init.d/firewall reload

# 6) Test: is cupsd listening on 631?
netstat -lnt 2>/dev/null | grep ':631 ' || ss -lnt 2>/dev/null | grep ':631 '

echo "[configure-cups] Done. Web UI: http://192.168.8.1:631/"
REMOTE
