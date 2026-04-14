<!-- Copyright (c) 2026 Ronen Druker. -->

<!-- markdownlint-disable-next-line MD041 MD033 -->
<h1 align="center">AirPrint for GL.iNet Flint 3 (GL-BE9300)</h1>

<!-- markdownlint-disable-next-line MD033 -->
<div align="center">

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![OpenWrt 23.05](https://img.shields.io/badge/openwrt-23.05-00b5e2)](https://openwrt.org/releases/23.05/start)
[![Target: aarch64](https://img.shields.io/badge/target-aarch64__cortex--a53-F37626)](https://openwrt.org/docs/techref/targets/ipq807x)
[![Toolchain: GCC 12.3](https://img.shields.io/badge/toolchain-gcc%2012.3.0%20%2B%20musl%201.2.4-7952B3)](https://openwrt.org/docs/guide-developer/toolchain/start)
[![Platform: Docker](https://img.shields.io/badge/platform-docker-2496ED)](https://www.docker.com/)

**Cross-compile CUPS + cups-filters + Poppler/Ghostscript + foo2zjs for a GL.iNet Flint 3 router,
turning a USB-connected printer into an AirPrint-discoverable network printer for iOS and macOS.**

<!-- prettier-ignore-start -->
<!-- markdownlint-disable-next-line MD013 -->
[Pipeline](#-print-pipeline) • [Quick Start](#-quick-start) • [Build](#-build) • [Install](#-install-on-router) • [Configure](#-configure) • [Troubleshooting](#-troubleshooting)
<!-- prettier-ignore-end -->

</div>

---

## ✨ What This Is

OpenWrt's official feeds don't ship CUPS, cups-filters, Ghostscript, Poppler, or foo2zjs for the
`aarch64_cortex-a53` target used by the Flint 3. This project provides a reproducible Docker-based
cross-compile pipeline that produces installable `.ipk` packages plus a foo2zjs tarball, then installs
and configures them on the router for AirPrint.

The target router is a **GL.iNet GL-BE9300 (Flint 3)** running GL.iNet firmware v4.8.4 (OpenWrt 23.05-SNAPSHOT,
QSDK v12.5) on a Qualcomm IPQ5332 (4× Cortex-A53, 1 GB RAM). The target printer is an **HP LaserJet 1022**
connected over USB and using the proprietary ZjStream protocol.

---

## 🖨️ Print Pipeline

<!-- prettier-ignore -->
```markdown
iOS / macOS device
  → AirPrint (IPP + mDNS discovery via Avahi)
    → CUPS (print server, port 631)
      → cups-filters (PDF → raster conversion)
        → Poppler or Ghostscript (PDF → PBM rasterizer)
          → foo2zjs (PBM → ZjStream encoder)
            → USB (/dev/usb/lp0)
              → HP LaserJet 1022
```

Poppler is the primary PDF backend ("Plan A"). Ghostscript is attempted but treated as optional —
its aarch64 cross-compile is historically fragile, and cups-filters works with Poppler alone.

---

## 🚀 Quick Start

### Prerequisites

- **Docker** — works with Docker Desktop, Colima, or any Docker daemon.
- **An x86_64 Linux host** is _strongly_ recommended. The OpenWrt SDK ships only x86_64 binaries;
  on Apple Silicon they run under Rosetta, and shell-heavy host-tool builds (especially
  `gettext`/`gnulib-tool`) become the bottleneck — expect hours instead of minutes.
- **SSH key access to the router** — `ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.8.1`.

### Router Specs

| Detail          | Value                                              |
| --------------- | -------------------------------------------------- |
| Model           | GL.iNet GL-BE9300 (Flint 3)                        |
| SoC             | Qualcomm IPQ5332                                   |
| Architecture    | `aarch64_cortex-a53_neon-vfpv4` (runtime)          |
| CPU / RAM       | 4× Cortex-A53 / 1 GB                               |
| Firmware        | GL.iNet v4.8.4 (OpenWrt 23.05-SNAPSHOT, QSDK 12.5) |
| Toolchain match | GCC 12.3.0, musl 1.2.4                             |

---

## 🏗️ Architecture

The build runs inside a long-lived Docker container (`openwrt-build`, `ubuntu:22.04`, `--platform linux/amd64`).
All SDK state lives in a named Docker volume (`openwrt-sdk-vol`) rather than a bind mount — this avoids
macOS virtiofs permission issues with the SDK's symlinks and restricted files. The project directory
is bind-mounted at `/host` for the scripts directory and for writing output artifacts.

<!-- prettier-ignore -->
```markdown
Host (Mac or Linux)
  scripts/*.sh       ─┐
  output/*.ipk       ◄│──  /host   ┐
                     │              │
                     │              │  openwrt-build  (ubuntu:22.04 linux/amd64)
                     │              │
  openwrt-sdk-vol  ──┴──  /workspace ┴─►  OpenWrt SDK 23.05.6 ipq807x
                                          + feeds (base, packages, printing, luci)
                                          + build_dir/, staging_dir/, bin/
```

### Project Layout

<!-- prettier-ignore -->
```markdown
openwrt-printing/
├── scripts/
│   ├── setup-container.sh        # Create openwrt-build container + named volume
│   ├── fetch-sdk.sh              # Download + extract OpenWrt 23.05.6 ipq807x SDK
│   ├── patch-sdk.sh              # Overlay full gnulib tree onto SDK snapshot (gettext fix)
│   ├── prepare-feeds.sh          # Wire Vladdrako printing feed, update + install
│   ├── configure-sdk.sh          # Write SDK .config for cups/filters/poppler/gs
│   ├── build-stack.sh            # Cross-compile poppler + cups + gs + cups-filters
│   ├── build-foo2zjs.sh          # Cross-compile foo2zjs binary + wrapper + PPD
│   ├── install-on-router.sh      # scp *.ipk → opkg install on router
│   ├── install-foo2zjs.sh        # scp tarball → extract on router
│   ├── configure-cups.sh         # Write cupsd.conf, open firewall ports
│   └── configure-airprint.sh     # Write Avahi service file for _ipp._tcp
├── output/                       # Produced .ipk + foo2zjs tarball (gitignored)
├── build/                        # Cached SDK tarball (gitignored)
├── CLAUDE.md                     # Agent context: plan, URLs, troubleshooting
├── LICENSE                       # MIT
└── README.md                     # This file
```

---

## 📦 Build

All scripts are idempotent and resume-friendly. Re-running after a failure is safe.

```bash
# First-time environment bootstrap (~5 min on Linux amd64, ~15 min under Rosetta)
./scripts/setup-container.sh
./scripts/fetch-sdk.sh
./scripts/patch-sdk.sh        # gnulib overlay — see Troubleshooting
./scripts/prepare-feeds.sh
./scripts/configure-sdk.sh

# Cross-compile the stack (single `make -jN` invocation with all four targets —
# poppler, cups, ghostscript, cups-filters — so sibling packages run in parallel
# under one jobserver).
./scripts/build-stack.sh

# Cross-compile foo2zjs (direct toolchain invocation — not wrapped as .ipk;
# produces a tarball that unpacks straight into /usr/lib/cups/filter/ and
# /usr/share/cups/model/ on the router).
./scripts/build-foo2zjs.sh
```

### Watching the Build

The build logs to `/workspace/build.log` inside the container. Stream it from a second terminal:

```bash
docker exec openwrt-build tail -F /workspace/build.log
```

### Expected Output

```bash
output/
├── cups_*.ipk
├── cups-client_*.ipk
├── libcups_*.ipk
├── openprinting-cups-filters_*.ipk
├── libpoppler_*.ipk
├── ghostscript_*.ipk            # if the GS build succeeded
├── liblcms2_*.ipk, libpng_*.ipk, libtiff_*.ipk, ...
└── foo2zjs-hp-lj1022.tar.gz
```

---

## 🔌 Install on Router

The router's DISTRIB_ARCH is `aarch64_cortex-a53_neon-vfpv4` (note the `_neon-vfpv4` suffix), but the
upstream OpenWrt SDK emits packages tagged `aarch64_cortex-a53`. `install-on-router.sh` handles this
by adding an extra `arch aarch64_cortex-a53 200` line to `/etc/opkg.conf` so opkg accepts both arch
tags. ABI-wise this is safe — NEON + VFPv4 are mandatory parts of ARMv8-A, so the cortex-a53 build
runs identically on the Flint 3.

```bash
# SSH key must be in place first:
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@192.168.8.1

# Install the .ipk stack + foo2zjs:
./scripts/install-on-router.sh
./scripts/install-foo2zjs.sh
```

---

## ⚙️ Configure

```bash
# CUPS: bind to 0.0.0.0:631, allow LAN, open firewall
./scripts/configure-cups.sh

# AirPrint: Avahi _ipp._tcp._universal service record for HP LJ 1022
./scripts/configure-airprint.sh
```

Then add the printer through the CUPS admin UI at `http://192.168.8.1:631/admin`, or:

```bash
ssh root@192.168.8.1 \
  lpadmin -p LaserJet1022 -E \
  -v usb://HP/LaserJet%201022 \
  -P /usr/share/cups/model/HP-LaserJet_1022.ppd
```

The printer should then appear on iOS and macOS as an AirPrint destination named
**"AirPrint HP LaserJet 1022 @ \<hostname\>"**.

---

## 🔧 Troubleshooting

### Build is slow / looks stuck

If you're building on Apple Silicon via Rosetta, `gettext-full`'s host build runs `gnulib-tool` —
a shell script that spawns thousands of short-lived processes. Each fork roundtrips through Rosetta,
so a single gnulib import can take over an hour. The build _isn't_ stuck; it's emulation-bound.
Move the build to a native x86_64 Linux host and it finishes in under an hour.

Verify it's still progressing:

```bash
docker exec openwrt-build bash -c '
  L1=$(wc -c < /workspace/build.log); sleep 10
  L2=$(wc -c < /workspace/build.log)
  echo "bytes added in 10s: $((L2 - L1))"'
```

### `gnulib-tool: module root-uid doesn't exist`

The SDK's bundled `staging_dir/host/share/gnulib/` is a curated 2017 snapshot and omits a handful of
modules that `gettext-0.21.1`'s `autogen.sh` imports (notably `root-uid`). `scripts/patch-sdk.sh`
fixes this by overlaying Ubuntu's `gnulib` package (apt-installed inside the container) with
`rsync --ignore-existing`, adding the missing module descriptors without touching the SDK's own
files. It also clears `build_dir/hostpkg/gettext-0.21.1` so gettext reimports with the patched tree.
Idempotent — re-running is a no-op after the first pass.

### poppler CMake: `Boost recommended for Splash. Use ENABLE_BOOST=OFF to skip.`

Vladdrako's poppler 23.11.0 Makefile does not pass `ENABLE_BOOST=OFF`, so CMake hard-fails when
Boost ≥ 1.71 is not installed. The Splash backend isn't needed — cups-filters uses poppler's core
API — so `scripts/patch-sdk.sh` appends `-DENABLE_BOOST=OFF` to the CMake options and clears the
stale `.configured` stamp. Idempotent.

### cups configure: `--with-tls=openssl was specified but neither OpenSSL nor LibreSSL were found`

The Vladdrako cups Makefile has its `--with-tls` conditional inverted:
`--with-tls=$(if $(LIBCUPS_OPENSSL),gnutls,openssl)` — so selecting GnuTLS in menuconfig
actually passes `openssl` to configure. `scripts/patch-sdk.sh` swaps the two branches so the
selected TLS backend is respected. We default to GnuTLS because `libgnutls` is pre-staged by the
SDK; OpenSSL requires also selecting `libopenssl`.

### `nspr` fails with "write jobserver: Bad file descriptor"

This is a known GCC 12 LTO/jobserver fd bug triggered at high parallelism. `build-stack.sh`
automatically retries failed packages at `-j1` when the parallel build fails.

### Ghostscript fails to cross-compile

Known-fragile. The pipeline uses Poppler as the primary PDF backend; Ghostscript failure is treated
as non-fatal (cups-filters works with Poppler alone).

### Printer not discovered by iOS / macOS

1. Check Avahi is running: `ssh root@192.168.8.1 pgrep avahi-daemon`
2. Verify mDNS traffic is allowed on the LAN side: `ssh root@192.168.8.1 nft list chain inet fw4 input_lan`
3. Confirm the service advertises: `dns-sd -B _ipp._tcp local` (from macOS)

### `opkg install` refuses packages — architecture mismatch

Confirm `/etc/opkg.conf` on the router contains `arch aarch64_cortex-a53 200`. `install-on-router.sh`
adds this line idempotently on every run.

---

## 🛡️ Notes on ABI and Source Compatibility

- **SDK target `ipq807x`** is used as the closest upstream match for the router's `ipq53xx`. Both
  use Cortex-A53 with identical ABI (NEON + VFPv4 + crypto extensions); packages compiled for
  ipq807x run unchanged on ipq53xx.
- **Runtime linker mismatch risk**: the router uses `ld-musl-aarch64.so.1` from its shipped musl
  1.2.4 build; the SDK produces binaries linked against the same. Confirmed compatible.
- **Kernel version** on the router (5.4.213) affects only kernel modules. This project ships
  userspace only — no kmods — so kernel skew is irrelevant.

---

## 📚 Key References

- **Vladdrako printing feed**: <https://github.com/Vladdrako/openwrt-printing-packages>
- **OpenWrt SDK (23.05.6, ipq807x)**: <https://downloads.openwrt.org/releases/23.05.6/targets/ipq807x/generic/>
- **OpenPrinting / foo2zjs**: <https://github.com/OpenPrinting/foo2zjs>
- **HP LaserJet 1022 on OpenPrinting**: <https://www.openprinting.org/printer/HP/HP-LaserJet_1022>
- **TheMMcOfficial — CUPS for OpenWrt**: <https://themmcofficial.github.io/cups-for-openwrt/>

---

## 📄 License

[MIT](LICENSE) — see `LICENSE` for full text.
