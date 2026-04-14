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
# Patch 6: Ghostscript host aux binary persistence.
#   Ghostscript's cross-compile needs host-built aux binaries (genarch,
#   genconf, echogs, etc.) to generate arch.h and similar files. The
#   feed's upstream patch symlinks them from HOST_BUILD_DIR, but OpenWrt
#   auto-cleans HOST_BUILD_DIR after host-compile, leaving the symlinks
#   dangling and the target build failing with "No such file" (Error 127).
#   Fix: install aux binaries into STAGING_DIR_HOSTPKG/share/ghostscript-aux
#   during Host/Install, then point OPENWRT_BASE_BUILD_PATH there and
#   switch symlinks → copies so the target build has its own independent
#   copies. Also ensure /workspace/sdk/host exists and is builder-owned —
#   the SDK is missing this dir that Ghostscript's host-build expects.
#
# Patch 7: install libcups2-dev on host.
#   Ghostscript's host build configure checks for <cups/cups.h> via
#   cups-config. Without host CUPS dev headers, the check falls back to
#   the target's cups-config (from the SDK) which points at cross-compiled
#   headers and fails. Fix: apt-install libcups2-dev so host configure
#   finds /usr/include/cups/cups.h.
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
  #   d) Remove all poppler-dependent filters from build targets — they use
  #      poppler private C++ API which is completely incompatible between
  #      poppler 23.x and cups-filters 1.0.37.  Removed: pdftoopvp,
  #      pdftoraster, pdftopdf, bannertopdf, pdftoijs, pdftops.
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
    # Remove ALL poppler-dependent filters from pkgfilter_PROGRAMS.
    # cups-filters 1.0.37 uses poppler private C++ API that is completely
    # incompatible with poppler 23.x. These filters are not needed — our
    # pipeline uses Ghostscript for PDF rasterization via gstoraster.
    # Removed: pdftoopvp, pdftoraster, pdftopdf, bannertopdf, pdftoijs, pdftops.
    for mk in /workspace/sdk/build_dir/target-aarch64_cortex-a53_musl/cups-filters-*/Makefile.in \
              /workspace/sdk/build_dir/target-aarch64_cortex-a53_musl/cups-filters-*/Makefile; do
      if [ -f "$mk" ]; then
        changed=false
        for prog in pdftoopvp pdftoraster pdftopdf bannertopdf pdftoijs pdftops; do
          if grep -q "$prog" "$mk"; then
            sed -i "s/ *${prog}\\\$(EXEEXT) *//g" "$mk"
            sed -i "s/ *${prog}\\\$(EXEEXT)//g" "$mk"
            changed=true
          fi
        done
        if $changed; then
          echo "[patch] Removed poppler-dependent filters from $(basename "$mk")"
        fi
      fi
    done

    # Also replace -std=c++0x with -std=c++17 (qpdf 11.6.3 needs C++17).
    for mk in /workspace/sdk/build_dir/target-aarch64_cortex-a53_musl/cups-filters-*/Makefile.in \
              /workspace/sdk/build_dir/target-aarch64_cortex-a53_musl/cups-filters-*/Makefile; do
      if [ -f "$mk" ] && grep -q "\-std=c++0x" "$mk"; then
        sed -i "s/-std=c++0x/-std=c++17/g" "$mk"
        echo "[patch] Updated C++ standard to c++17 in $(basename "$mk")"
      fi
    done

    # Ensure poppler-config.h is findable without path prefix (splash headers need it).
    STAGING=/workspace/sdk/staging_dir/target-aarch64_cortex-a53_musl
    if [ -f "$STAGING/usr/include/poppler/poppler-config.h" ] && \
       [ ! -f "$STAGING/usr/include/poppler-config.h" ]; then
      cp "$STAGING/usr/include/poppler/poppler-config.h" "$STAGING/usr/include/poppler-config.h"
      echo "[patch] Copied poppler-config.h to top-level include"
    fi

    # Create CMake-generated export headers that poppler private headers need.
    if [ ! -f "$STAGING/usr/include/poppler/poppler_private_export.h" ]; then
      cat > "$STAGING/usr/include/poppler/poppler_private_export.h" <<'PEOF'
#ifndef POPPLER_PRIVATE_EXPORT_H
#define POPPLER_PRIVATE_EXPORT_H
#define POPPLER_PRIVATE_EXPORT
#endif
PEOF
      echo "[patch] Created poppler_private_export.h"
    fi
    if [ ! -f "$STAGING/usr/include/poppler/poppler-export.h" ]; then
      cat > "$STAGING/usr/include/poppler/poppler-export.h" <<'PEOF'
#ifndef POPPLER_EXPORT_H
#define POPPLER_EXPORT_H
#define POPPLER_API
#endif
PEOF
      echo "[patch] Created poppler-export.h"
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

  # --- Patch 6: Ghostscript host aux binary persistence ---
  GS_MK=/workspace/sdk/feeds/printing/net/ghostscript/Makefile
  GS_PATCH=/workspace/sdk/feeds/printing/net/ghostscript/patches/003-ln-several-aux-binaries.patch
  if [ -f "$GS_MK" ] && [ -f "$GS_PATCH" ]; then
    # Ensure /workspace/sdk/host exists (SDK ships without it).
    if [ ! -d /workspace/sdk/host ]; then
      echo "[patch] Creating missing /workspace/sdk/host directory…"
      mkdir -p /workspace/sdk/host
      chown builder:builder /workspace/sdk/host
    fi

    # Swap ln -fs → cp -f in the aux-binary patch (one-shot).
    if grep -q "ln -fs OPENWRT_BASE_BUILD_PATH" "$GS_PATCH"; then
      echo "[patch] Swapping symlinks for copies in ghostscript aux-binary patch…"
      sed -i "s|ln -fs OPENWRT_BASE_BUILD_PATH|cp -f OPENWRT_BASE_BUILD_PATH|g" "$GS_PATCH"
    fi

    # Install aux binaries to a persistent path during Host/Install (empty
    # by default in the feed).
    if ! grep -q "ghostscript-aux" "$GS_MK"; then
      echo "[patch] Adding Host/Install for ghostscript aux binaries…"
      # Replace the empty Host/Install body with our copy step.
      awk '\''
        /^define Host\/Install$/ { print; in_host_install=1; next }
        in_host_install && /^endef$/ {
          print "\t$(INSTALL_DIR) $(STAGING_DIR_HOSTPKG)/share/ghostscript-aux/obj/aux"
          print "\t$(CP) $(HOST_BUILD_DIR)/obj/aux/* $(STAGING_DIR_HOSTPKG)/share/ghostscript-aux/obj/aux/"
          print
          in_host_install=0; next
        }
        in_host_install { next }
        { print }
      '\'' "$GS_MK" > "$GS_MK.new" && mv "$GS_MK.new" "$GS_MK"

      # Repoint OPENWRT_BASE_BUILD_PATH from HOST_BUILD_DIR → staging aux dir.
      sed -i "s|OPENWRT_BASE_BUILD_PATH,\$(HOST_BUILD_DIR)|OPENWRT_BASE_BUILD_PATH,\$(STAGING_DIR_HOSTPKG)/share/ghostscript-aux|" "$GS_MK"
    fi
  fi

  # --- Patch 7: install host libcups2-dev for Ghostscript host configure ---
  if ! dpkg -l libcups2-dev >/dev/null 2>&1; then
    echo "[patch] Installing host libcups2-dev for Ghostscript host build…"
    apt-get install -y --no-install-recommends libcups2-dev
  fi

  echo "[patch] Done."
'
