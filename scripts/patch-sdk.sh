#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# patch-sdk.sh — apply post-extract patches to the OpenWrt SDK.
#
# Patch 1: gnulib overlay for gettext-0.21.1 host build.
#   gettext-0.21.1's autogen.sh runs gnulib-tool --import, which reads
#   modules from staging_dir/host/share/gnulib/. The SDK ships a curated
#   gnulib snapshot that omits a handful of modules gettext references
#   (notably `root-uid`). Missing-module failures are fatal and happen
#   on the first dependant build (poppler → glib2 → gettext-full/host).
#
#   Fix: overlay Ubuntu's gnulib package (apt-installed in the container)
#   onto the SDK's gnulib tree with rsync --ignore-existing, so missing
#   module descriptors and their sources are added without disturbing
#   the SDK's existing files. Also clear any stale gettext hostpkg
#   build_dir so it reimports with the patched tree on next build.
#
# Patch 2: poppler ENABLE_BOOST=OFF.
#   Vladdrako's poppler 23.11.0 Makefile does not pass ENABLE_BOOST=OFF,
#   so CMake fails at configure with "Boost recommended for Splash"
#   because Boost >= 1.71 is not in our feeds selection. We don't need
#   the Splash backend — cups-filters uses poppler's core API — so the
#   switch is safe and small.
#
# Patch 3: cups --with-tls conditional is inverted.
#   The upstream Vladdrako Makefile line reads
#     --with-tls=$(if $(LIBCUPS_OPENSSL),gnutls,openssl)
#   which evaluates to `openssl` when the user selects GnuTLS (our case)
#   and to `gnutls` when they pick OpenSSL. We swap the branches so the
#   selected backend is actually passed to cups' configure.
#
# Patch 4: cups-filters 1.0.37 driver.h missing #include <cups/ppd.h>.
#   CUPS 2.4.x no longer transitively includes ppd.h from cups.h.
#   cups-filters' cupsfilters/driver.h uses ppd_attr_t / ppd_file_t
#   without including <cups/ppd.h>, causing a compile failure.
#   Fix: inject the include after #include <cups/raster.h>.
#
# Patch 5: fix hardcoded /usr in .pc files.
#   poppler and qpdf install pkg-config .pc files with prefix=/usr.
#   When cups-filters' configure resolves LIBQPDF_CFLAGS / POPPLER_CFLAGS
#   via pkg-config, this injects -I/usr/include into the cross-compiler
#   invocation, pulling host glibc headers (bits/libc-header-start.h) and
#   fatally breaking the build. Fix: rewrite prefix to point at the SDK
#   staging directory.  Must run after poppler/qpdf are built.
#
# Idempotent: re-running is safe and quick.
set -euo pipefail

CONTAINER=openwrt-build

docker exec "$CONTAINER" bash -c '
  set -euo pipefail

  # Install Ubuntu gnulib if missing — provides /usr/share/gnulib/ with
  # the full upstream module set (incl. root-uid).
  if [ ! -d /usr/share/gnulib/modules ]; then
    echo "[patch] Installing ubuntu gnulib package…"
    apt-get update -q
    apt-get install -y --no-install-recommends gnulib
  fi

  SRC=/usr/share/gnulib
  DST=/workspace/sdk/staging_dir/host/share/gnulib
  [ -d "$DST" ] || { echo "[patch] SDK not extracted yet — run fetch-sdk.sh first"; exit 1; }

  BEFORE=$(ls "$DST/modules" | wc -l)
  rsync -a --ignore-existing "$SRC/" "$DST/"
  AFTER=$(ls "$DST/modules" | wc -l)
  echo "[patch] gnulib modules: $BEFORE → $AFTER ($(( AFTER - BEFORE )) added)"

  # Clear stale gettext host build_dir so it reimports with patched gnulib.
  if [ -d /workspace/sdk/build_dir/hostpkg/gettext-0.21.1 ]; then
    echo "[patch] Clearing stale gettext hostpkg build_dir…"
    rm -rf /workspace/sdk/build_dir/hostpkg/gettext-0.21.1
  fi

  # Ownership fix — apt-installed files are root-owned; builder needs read+exec.
  chown -R builder:builder "$DST"

  # --- Patch 2: poppler ENABLE_BOOST=OFF ---
  POPPLER_MK=/workspace/sdk/feeds/printing/utils/poppler/Makefile
  if [ -f "$POPPLER_MK" ] && ! grep -q "ENABLE_BOOST=OFF" "$POPPLER_MK"; then
    echo "[patch] Adding -DENABLE_BOOST=OFF to poppler CMake options…"
    sed -i "s|-DFONT_CONFIGURATION=fontconfig|-DFONT_CONFIGURATION=fontconfig \\\\\n\t-DENABLE_BOOST=OFF|" "$POPPLER_MK"
    # Clear stale configure stamp so CMake re-runs with the new flag.
    rm -f /workspace/sdk/build_dir/target-aarch64_cortex-a53_musl/poppler-*/.configured*
  else
    echo "[patch] poppler already has ENABLE_BOOST=OFF (or feed not installed)"
  fi

  # --- Patch 3: cups --with-tls inverted conditional ---
  CUPS_MK=/workspace/sdk/feeds/printing/net/cups/Makefile
  if [ -f "$CUPS_MK" ] && grep -q -- "--with-tls=\$(if \$(LIBCUPS_OPENSSL),gnutls,openssl)" "$CUPS_MK"; then
    echo "[patch] Swapping cups --with-tls branches (upstream inverted)…"
    sed -i "s|--with-tls=\$(if \$(LIBCUPS_OPENSSL),gnutls,openssl)|--with-tls=\$(if \$(LIBCUPS_OPENSSL),openssl,gnutls)|" "$CUPS_MK"
    rm -f /workspace/sdk/build_dir/target-aarch64_cortex-a53_musl/cups-*/.configured*
  else
    echo "[patch] cups --with-tls already patched (or feed not installed)"
  fi

  # --- Patch 4: cups-filters CUPS 2.4.x compat ---
  #   a) Add -include cups/ppd.h — CUPS 2.4.x no longer includes ppd.h from cups.h.
  #   b) Remove -DHAVE_CPP_POPPLER_VERSION_H — prevents including poppler C++ headers.
  #   c) Add -std=c++17 — qpdf 11.6.3 headers use std::string_view (C++17).
  #   d) Remove pdftoopvp and pdftoraster from build targets — they use
  #      poppler private C++ API (GooString.h, SplashOutputDev.h, etc.)
  #      which is incompatible between poppler 23.x and cups-filters 1.0.37.
  #      Not needed: our pipeline uses Ghostscript for rasterization.
  CF_MK=/workspace/sdk/feeds/printing/net/openprinting-cups-filters/Makefile
  if [ -f "$CF_MK" ]; then
    if ! grep -q "cups/ppd.h" "$CF_MK"; then
      echo "[patch] Patching cups-filters Makefile (ppd.h + drop HAVE_CPP_POPPLER_VERSION_H)…"
      sed -i "s|EXTRA_CFLAGS+=-DHAVE_CPP_POPPLER_VERSION_H|EXTRA_CFLAGS+=-include cups/ppd.h|" "$CF_MK"
      if ! grep -q "EXTRA_CXXFLAGS" "$CF_MK"; then
        sed -i "/EXTRA_CFLAGS/a EXTRA_CXXFLAGS+=-include cups/ppd.h -std=c++17" "$CF_MK"
      fi
      rm -f /workspace/sdk/build_dir/target-aarch64_cortex-a53_musl/cups-filters-*/.configured*
      rm -f /workspace/sdk/build_dir/target-aarch64_cortex-a53_musl/cups-filters-*/.built
    fi
    # Remove pdftoopvp + pdftoraster from pkgfilter_PROGRAMS in both
    # Makefile.in (survives configure regeneration) and Makefile (immediate).
    for mk in /workspace/sdk/build_dir/target-aarch64_cortex-a53_musl/cups-filters-*/Makefile.in \
              /workspace/sdk/build_dir/target-aarch64_cortex-a53_musl/cups-filters-*/Makefile; do
      if [ -f "$mk" ] && grep -q "pdftoopvp" "$mk"; then
        echo "[patch] Removing pdftoopvp + pdftoraster from $(basename "$mk")…"
        sed -i "s/pdftoopvp\$(EXEEXT) //g" "$mk"
        sed -i "s/ pdftoraster\$(EXEEXT)//g" "$mk"
        sed -i "s/pdftoraster\$(EXEEXT) //g" "$mk"
      fi
    done

    # Ensure poppler-config.h is findable without path prefix (splash headers need it).
    STAGING=/workspace/sdk/staging_dir/target-aarch64_cortex-a53_musl
    if [ -f "$STAGING/usr/include/poppler/poppler-config.h" ] && \
       [ ! -f "$STAGING/usr/include/poppler-config.h" ]; then
      cp "$STAGING/usr/include/poppler/poppler-config.h" "$STAGING/usr/include/poppler-config.h"
      echo "[patch] Copied poppler-config.h to top-level include"
    fi
  else
    echo "[patch] cups-filters not installed yet"
  fi

  # --- Patch 5: fix pkg-config .pc files with hardcoded /usr paths ---
  #   poppler and qpdf install .pc files with prefix=/usr, which causes
  #   -I/usr/include to leak into cross-compilation, pulling host glibc
  #   headers and fatally breaking the build (bits/libc-header-start.h).
  #   Fix: rewrite prefix to point at the SDK staging directory.
  STAGING=/workspace/sdk/staging_dir/target-aarch64_cortex-a53_musl
  for pc in "$STAGING/usr/lib/pkgconfig/poppler.pc" "$STAGING/usr/lib/pkgconfig/libqpdf.pc"; do
    if [ -f "$pc" ] && grep -q "^prefix=/usr$" "$pc"; then
      echo "[patch] Fixing hardcoded /usr in $(basename "$pc")…"
      sed -i "s|^prefix=/usr$|prefix=$STAGING/usr|" "$pc"
      sed -i "s|^exec_prefix=/usr$|exec_prefix=\${prefix}|" "$pc"
      sed -i "s|^libdir=/usr/lib$|libdir=\${prefix}/lib|" "$pc"
      sed -i "s|^includedir=/usr/include$|includedir=\${prefix}/include|" "$pc"
    fi
  done

  echo "[patch] Done."
'
