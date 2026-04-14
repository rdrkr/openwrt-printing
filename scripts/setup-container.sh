#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# setup-container.sh — create a long-lived x86_64 Ubuntu build container
# with OpenWrt SDK build deps installed.
#
# Layout:
#   Named volume 'openwrt-sdk-vol' mounted at /workspace inside container.
#     Holds the SDK source tree and build artifacts. Kept off the macOS
#     virtiofs bind mount to avoid extraction-time permission issues with
#     symlinks and restricted files in the SDK tarball.
#   Host dir mounted at /host (read-only for scripts, writable for output):
#     /host/scripts  — helper scripts
#     /host/output   — built .ipk files (copied out after compile)
#
# Idempotent: re-running just re-starts the container.
set -euo pipefail

CONTAINER=openwrt-build
IMAGE=ubuntu:22.04
VOLUME=openwrt-sdk-vol
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "[setup] Container '$CONTAINER' already exists."
  docker start "$CONTAINER" >/dev/null
  exit 0
fi

docker volume inspect "$VOLUME" >/dev/null 2>&1 || docker volume create "$VOLUME" >/dev/null

echo "[setup] Creating '$CONTAINER' (linux/amd64 via qemu)…"
docker run -d \
  --name "$CONTAINER" \
  --platform linux/amd64 \
  -v "$VOLUME":/workspace \
  -v "$PROJECT_DIR":/host \
  -w /workspace \
  "$IMAGE" \
  sleep infinity

echo "[setup] Installing build dependencies (this takes a few minutes under qemu)…"
docker exec "$CONTAINER" bash -c '
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get install -y --no-install-recommends \
    build-essential ccache clang flex bison g++ gawk gettext \
    git libncurses-dev libssl-dev python3 python3-dev python3-setuptools \
    python3-distutils rsync swig unzip zlib1g-dev file wget curl \
    xsltproc libxml-parser-perl time ca-certificates \
    libelf-dev subversion
  apt-get clean
  rm -rf /var/lib/apt/lists/*
  # SDK expects a non-root user to build; create one that owns /workspace.
  id -u builder >/dev/null 2>&1 || useradd -m -s /bin/bash builder
  chown -R builder:builder /workspace
'

echo "[setup] Done. Container '$CONTAINER' is ready."
docker exec "$CONTAINER" bash -c 'gcc --version | head -1; uname -m'
