#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# fetch-sdk.sh — download and extract the OpenWrt 23.05.6 ipq807x SDK
# inside the build container's /workspace volume.
#
# Why ipq807x: the router's target (ipq53xx) is not in upstream OpenWrt 23.05,
# but ipq807x is the closest aarch64 Cortex-A53 target and ships the matching
# toolchain (GCC 12.3.0 + musl 1.2.4). Packages are arch-tagged
# "aarch64_cortex-a53"; the router reports "aarch64_cortex-a53_neon-vfpv4",
# so we'll install with --force-arch (underlying ABI is identical).
set -euo pipefail

CONTAINER=openwrt-build
SDK_URL="https://downloads.openwrt.org/releases/23.05.6/targets/ipq807x/generic/openwrt-sdk-23.05.6-ipq807x-generic_gcc-12.3.0_musl.Linux-x86_64.tar.xz"
SDK_SHA256="d253f579fd0d199656831fdcca62d76c44ca52999f1d80d966401a2545b09ad1"
SDK_TARBALL="openwrt-sdk-23.05.6-ipq807x.tar.xz"
SDK_DIR_NAME="openwrt-sdk-23.05.6-ipq807x-generic_gcc-12.3.0_musl.Linux-x86_64"

docker exec -u builder "$CONTAINER" bash -c "
  set -euo pipefail
  cd /workspace
  if [ ! -f '$SDK_TARBALL' ]; then
    echo '[fetch] Downloading SDK (~250 MB)…'
    curl -fL --retry 3 -o '$SDK_TARBALL' '$SDK_URL'
  fi
  echo '[fetch] Verifying checksum…'
  echo '$SDK_SHA256  $SDK_TARBALL' | sha256sum -c -
  if [ ! -d sdk ]; then
    echo '[fetch] Extracting (a few minutes)…'
    tar -xf '$SDK_TARBALL'
    mv '$SDK_DIR_NAME' sdk
  fi
  echo '[fetch] Done. SDK at /workspace/sdk'
  ls /workspace/sdk | head -20
"
