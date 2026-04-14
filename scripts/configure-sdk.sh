#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# configure-sdk.sh — write the final .config for the SDK and run defconfig
# so all dependencies get resolved as modules (.ipk) rather than builtins.
#
# Package name note: the Vladdrako feed calls cups-filters
# "openprinting-cups-filters" (upstream project name), not "cups-filters".
# foo2zjs is not in this feed — we build it out-of-tree in a separate step.
set -euo pipefail

CONTAINER=openwrt-build

docker exec -u builder "$CONTAINER" bash -c "
  set -euo pipefail
  cd /workspace/sdk

  cat > .config <<'EOF'
CONFIG_TARGET_ipq807x=y
CONFIG_TARGET_ipq807x_generic=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_ALL_KMODS=n
CONFIG_ALL_NONSHARED=n
CONFIG_ALL=n
# Printing stack — all as modules (.ipk)
CONFIG_PACKAGE_cups=m
CONFIG_PACKAGE_cups-client=m
CONFIG_PACKAGE_openprinting-cups-filters=m
CONFIG_PACKAGE_ghostscript=m
CONFIG_PACKAGE_ghostscript-fonts-std=m
CONFIG_PACKAGE_poppler=m
CONFIG_PACKAGE_lcms2=m
CONFIG_PACKAGE_libjpeg-turbo=m
CONFIG_PACKAGE_libpng=m
CONFIG_PACKAGE_libtiff=m
CONFIG_PACKAGE_freetype=m
CONFIG_PACKAGE_fontconfig=m
# Avahi client is on the router's repos already — still useful to have headers
CONFIG_PACKAGE_libavahi-client=m
EOF

  echo '[configure] Running make defconfig…'
  make defconfig 2>&1 | tail -5

  echo '[configure] Printing-related packages selected:'
  grep -E '^CONFIG_PACKAGE_.*(cups|ghost|poppler|lcms|jpeg|png|tiff|freetype|fontconfig|avahi)' .config | grep -v '^#' | sort

  echo '[configure] Target arch:'
  grep CONFIG_TARGET_ARCH_PACKAGES .config
"
