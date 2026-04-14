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

ssh "$ROUTER" bash -s <<REMOTE
set -euo pipefail

# 1) cupsd.conf — listen on all interfaces, allow LAN
cat > /etc/cups/cupsd.conf <<'EOF'
LogLevel warn
MaxLogSize 0
Listen 0.0.0.0:631
Listen /var/run/cups/cups.sock
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

# 3) Enable + start cupsd
/etc/init.d/cupsd enable
/etc/init.d/cupsd restart
sleep 2
/etc/init.d/cupsd status || true

# 4) Firewall rules (LAN → CUPS and mDNS). Idempotent by name.
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

# 5) Test: is cupsd listening on 631?
netstat -lnt 2>/dev/null | grep ':631 ' || ss -lnt 2>/dev/null | grep ':631 '

echo "[configure-cups] Done. Web UI: http://192.168.8.1:631/"
REMOTE
