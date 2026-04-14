# AirPrint Print Server for GL.iNet Flint 3 (GL-BE9300)

## Goal

Cross-compile and install CUPS + Ghostscript + foo2zjs on a GL.iNet Flint 3 router to enable AirPrint printing from iOS and macOS devices to an HP LaserJet 1022 connected via USB.

## Print Pipeline

```
iOS/macOS device
  → AirPrint (IPP/mDNS discovery)
    → CUPS (print server, port 631)
      → cups-filters (PDF → raster conversion)
        → Ghostscript (PDF → PBM rasterizer)
          → foo2zjs (PBM → ZjStream encoder)
            → USB (/dev/usb/lp0)
              → HP LaserJet 1022
```

## Router Specifications

| Detail | Value |
|--------|-------|
| Model | GL.iNet GL-BE9300 (Flint 3) |
| SoC | Qualcomm IPQ5332 |
| Architecture | ARMv8 / aarch64_cortex-a53_neon-vfpv4 |
| CPU | 4x Cortex-A53 |
| RAM | 1 GB |
| Storage | eMMC with 6.3 GB free on overlay |
| Kernel | 5.4.213 |
| GCC (build) | 12.3.0 (OpenWrt GCC 12.3.0) |
| libc | musl 1.2.4 |
| Firmware | GL.iNet v4.8.4 |
| OpenWrt | 23.05-SNAPSHOT |
| Target | ipq53xx/generic |
| DISTRIB_ARCH | aarch64_cortex-a53_neon-vfpv4 |
| SDK base | Qualcomm QSDK v12.5 |

## opkg Feed URLs

```
src/gz glinet_core https://fw.gl-inet.com/releases/qsdk_v12.5/kmod-4.7/be9300-ipq53xx
src/gz glinet_gli_pub https://fw.gl-inet.com/releases/qsdk_v12.5/packages-4.x/ipq53xx/be9300/glinet
src/gz opnwrt_packages https://fw.gl-inet.com/releases/qsdk_v12.5/packages-4.x/ipq53xx/be9300/packages
```

## What's Already Installed / Available via opkg

### Installed
- `kmod-usb-printer` (5.4.213-1) — printer detected at `/dev/usb/lp0`
- `libexpat` (2.5.0-1)
- `libjpeg-turbo` (2.1.4-2)

### Available in repos (do NOT need cross-compilation)
- `avahi-nodbus-daemon` (0.8-8) — mDNS daemon for AirPrint discovery
- `avahi-utils` (0.8-8)
- `libavahi-client`, `libavahi-compat-libdnssd`, etc.
- `p910nd` (0.97-13) — lightweight print daemon (fallback)
- `hplip-common` (3.21.6-2)
- `hplip-sane` (3.21.6-2)

### NOT available in repos (must be cross-compiled)
- **CUPS** — print server
- **cups-filters** — PDF/raster conversion filters  
- **Ghostscript** — PDF rendering engine
- **foo2zjs** — ZjStream driver for HP LaserJet 1022
- Various dependencies: libpng, libtiff, freetype, fontconfig, lcms2, poppler (if ghostscript fails)

## Printer Details

- **Model**: HP LaserJet 1022
- **Protocol**: ZjStream (Zenographics)
- **Driver**: foo2zjs-z1 (recommended by OpenPrinting)
- **Firmware**: Built-in (no firmware upload needed, unlike 1018/1020)
- **Connection**: USB, detected at `/dev/usb/lp0`
- **foo2zjs** converts PBM (produced by Ghostscript) to ZjStream format

## Build Environment

- **Host machine**: MacBook Pro M1 Pro (Apple Silicon)
- **Container runtime**: Colima (not Docker Desktop)
- **Build container**: Ubuntu 22.04 x86_64 via `--platform linux/amd64` (Rosetta)
- **Build system**: Qualcomm QSDK from CodeLinaro, or upstream OpenWrt 23.05 SDK

## Build Strategy

### Option 1: QSDK from CodeLinaro (preferred — exact toolchain match)

```bash
# Start colima with enough resources
colima start --cpu 4 --memory 8 --disk 60 --arch x86_64

# Create build container
docker run -it --name openwrt-build \
  --platform linux/amd64 \
  -v ~/openwrt-printing:/build \
  ubuntu:22.04 /bin/bash

# Inside container: install deps
apt update && apt install -y \
  build-essential clang flex bison g++ gawk gcc-multilib \
  g++-multilib gettext git libncurses5-dev libssl-dev \
  python3-distutils python3-setuptools rsync swig unzip \
  zlib1g-dev file wget curl xsltproc libxml-parser-perl \
  python3-dev time

# Clone QSDK
cd /build
mkdir -p ~/bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
export PATH=~/bin:$PATH

repo init -u https://git.codelinaro.org/clo/qsdk/releases/manifest/qstak \
  -b release -m AU_LINUX_QSDK_NHSS.QSDK.12.5.xml \
  --repo-url=https://git.codelinaro.org/clo/tools/repo \
  --repo-branch=qc-stable
repo sync -j$(nproc)

# Configure for ipq53xx 64-bit
cp qca/configs/ipq53xx/ipq53xx_64_defconfig .config
make defconfig
make tools/install -j$(nproc) V=s
make toolchain/install -j$(nproc) V=s

# Add printing feed
echo 'src-git printing https://github.com/Vladdrako/openwrt-printing-packages.git' >> feeds.conf.default
./scripts/feeds update printing
./scripts/feeds install cups ghostscript cups-filters foo2zjs

# Select packages in menuconfig: Network -> Printing
make menuconfig

# Build
make package/cups/compile V=s -j$(nproc)
make package/ghostscript/compile V=s -j$(nproc)
make package/cups-filters/compile V=s -j$(nproc)
make package/foo2zjs/compile V=s -j$(nproc)
```

### Option 2: Upstream OpenWrt 23.05 SDK (fallback if QSDK manifest unavailable)

Download the OpenWrt SDK for a compatible aarch64 target and use it to build packages. The key is matching GCC 12.3.0 + musl 1.2.4.

### Ghostscript Cross-Compilation Warning

Ghostscript has known cross-compilation issues. The openwrt-printing-packages README states:
> "Ghostscript lacks proper cross-compilation support. I used a patch taken from timesys.com. If your architecture is not there, compiling it just won't work for you. The alternative is to use Poppler as the PDF backend."

If Ghostscript fails for aarch64, use **Poppler** instead as the PDF rendering backend for cups-filters.

### Vladdrako Fork Note

The Vladdrako fork (https://github.com/Vladdrako/openwrt-printing-packages) reportedly works on `qcom/ipq60xx/linksys-mr7350`, which is a similar Qualcomm aarch64 platform. This is the most promising fork to try first.

## Installation on Router

After building .ipk files:

```bash
# Transfer to router
scp bin/packages/aarch64_cortex-a53_neon-vfpv4/printing/*.ipk \
  root@192.168.8.1:/tmp/

# Install on router
ssh root@192.168.8.1
opkg install /tmp/cups*.ipk /tmp/ghostscript*.ipk \
  /tmp/cups-filters*.ipk /tmp/foo2zjs*.ipk

# Install avahi from existing repos
opkg install avahi-nodbus-daemon
```

## Post-Install Configuration

### 1. CUPS Configuration

```bash
# Edit /etc/cups/cupsd.conf
# Key settings:
#   Listen 0.0.0.0:631 (allow network access)
#   Allow from 192.168.8.0/24 (local network)
#   DefaultAuthType None (or Basic)

# Remove kmod-usb-printer conflict (CUPS manages USB directly)
# May need: chmod 700 /usr/lib/cups/backend/usb
# May need: edit cupsd.conf to run as root

# Start CUPS
/etc/init.d/cupsd enable
/etc/init.d/cupsd start

# Add printer via web UI at http://192.168.8.1:631/admin
# Or via command line:
lpadmin -p LaserJet1022 -E \
  -v usb:///HP/LaserJet%201022 \
  -m foomatic:HP-LaserJet_1022-foo2zjs-z1.ppd
```

### 2. Avahi AirPrint Service

```bash
opkg install avahi-nodbus-daemon

cat > /etc/avahi/services/airprint.service << 'EOF'
<?xml version="1.0" encoding='UTF-8'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name replace-wildcards="yes">AirPrint HP LaserJet 1022 @ %h</name>
  <service>
    <type>_ipp._tcp</type>
    <subtype>_universal._sub._ipp._tcp</subtype>
    <port>631</port>
    <txt-record>txtvers=1</txt-record>
    <txt-record>qtotal=1</txt-record>
    <txt-record>rp=printers/LaserJet1022</txt-record>
    <txt-record>ty=HP LaserJet 1022</txt-record>
    <txt-record>note=HP LaserJet 1022 on GL-BE9300</txt-record>
    <txt-record>product=(GPL Ghostscript)</txt-record>
    <txt-record>printer-state=3</txt-record>
    <txt-record>printer-type=0x3006</txt-record>
    <txt-record>Binary=T</txt-record>
    <txt-record>Transparent=T</txt-record>
    <txt-record>URF=DM3</txt-record>
    <txt-record>pdl=application/octet-stream,application/pdf,application/postscript,application/vnd.cups-raster,image/gif,image/jpeg,image/png,image/urf</txt-record>
  </service>
</service-group>
EOF

/etc/init.d/avahi-daemon enable
/etc/init.d/avahi-daemon restart
```

### 3. Firewall

```bash
# Allow CUPS (port 631) and mDNS (port 5353) on LAN
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-CUPS'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_port='631'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].target='ACCEPT'

uci add firewall rule
uci set firewall.@rule[-1].name='Allow-mDNS'
uci set firewall.@rule[-1].src='lan'
uci set firewall.@rule[-1].dest_port='5353'
uci set firewall.@rule[-1].proto='udp'
uci set firewall.@rule[-1].target='ACCEPT'

uci commit firewall
/etc/init.d/firewall restart
```

## Key Resources

- **Vladdrako printing packages**: https://github.com/Vladdrako/openwrt-printing-packages
- **Original FranciscoBorges fork**: https://github.com/FranciscoBorges/openwrt-printing-packages
- **adlerweb CUPS for OpenWrt**: https://github.com/adlerweb/openwrt-cups
- **TheMMcOfficial guide**: https://themmcofficial.github.io/cups-for-openwrt/
- **QSDK wiki**: https://wiki.codelinaro.org/en/clo/qsdk/overview
- **QSDK manifests**: https://git.codelinaro.org/clo/qsdk/releases/manifest/qstak
- **foo2zjs source**: https://github.com/OpenPrinting/foo2zjs
- **OpenPrinting HP LJ 1022**: https://www.openprinting.org/printer/HP/HP-LaserJet_1022

## Troubleshooting Notes

- If CUPS conflicts with `kmod-usb-printer` for `/dev/usb/lp0` access, you may need to either unload the `usblp` kernel module (`rmmod usblp`) or configure CUPS to use `/dev/usb/lp0` directly.
- The CUPS web UI needs to be accessible from LAN — ensure `cupsd.conf` binds to `0.0.0.0:631` not just `localhost:631`.
- If Ghostscript cross-compilation fails, switch to Poppler as the PDF backend in cups-filters build config.
- The exact QSDK manifest tag may need discovery — list available tags at the CodeLinaro manifest repo.
- Router IP for SSH/SCP: `root@192.168.8.1`
