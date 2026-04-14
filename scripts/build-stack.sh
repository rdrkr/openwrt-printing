#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# build-stack.sh — compile the printing stack with inter-package parallelism.
#
# Strategy: issue a single `make` invocation listing all four top-level
# targets. OpenWrt's build system resolves the dep graph and schedules
# sibling packages (poppler, cups, ghostscript) concurrently on one shared
# GNU-make jobserver — much faster than serial per-package make calls.
# cups-filters depends on the other three, so it naturally runs last.
#
# Resume-friendly: OpenWrt's SDK caches everything — already-built packages
# are skipped instantly. Safe to re-run after a kill/crash.
#
# nspr LTO jobserver bug: at -jN, nspr occasionally dies with "write
# jobserver: Bad file descriptor" inside lto-wrapper. If the combined
# make fails, we fall back to a serial -j1 retry of each package.
#
# Ghostscript: aarch64 cross-compile is fragile. We request it but treat
# its failure as non-fatal (cups-filters works with poppler alone).
#
# Output: bin/packages/aarch64_cortex-a53/*.ipk → /host/output/
set -euo pipefail

CONTAINER=openwrt-build
LOG=/workspace/build.log

PKGS=(
  package/feeds/printing/poppler
  package/feeds/printing/cups
  package/feeds/printing/ghostscript
  package/feeds/printing/openprinting-cups-filters
)

# Space-joined list of "<pkg>/compile" targets for a single make call.
TARGETS=""
for p in "${PKGS[@]}"; do TARGETS+=" $p/compile"; done

docker exec -u builder "$CONTAINER" bash -c '
  set -uo pipefail
  cd /workspace/sdk
  : > '"$LOG"'

  JOBS=$(nproc)
  echo "[build] Parallel jobs: $JOBS" | tee -a '"$LOG"'
  echo "[build] Targets:'"$TARGETS"'" | tee -a '"$LOG"'

  # Attempt 1: all packages in parallel under one jobserver.
  if make V=s -j$JOBS'"$TARGETS"' >> '"$LOG"' 2>&1; then
    echo "[build] Parallel build succeeded." | tee -a '"$LOG"'
  else
    echo "[build] Parallel build failed — retrying each package at -j1…" | tee -a '"$LOG"'
    FAIL=""
    for pkg in '"${PKGS[*]}"'; do
      echo "[build] >>> -j1 $pkg" | tee -a '"$LOG"'
      if ! make "$pkg/compile" V=s -j1 >> '"$LOG"' 2>&1; then
        # ghostscript is allowed to fail (Plan A uses poppler).
        if [[ "$pkg" == *ghostscript* ]]; then
          echo "[build] ghostscript FAILED — continuing (poppler handles PDF)." | tee -a '"$LOG"'
        else
          echo "[build] FAILED: $pkg" | tee -a '"$LOG"'
          FAIL="$FAIL $pkg"
        fi
      fi
    done
    [ -z "$FAIL" ] || { echo "[build] FATAL: $FAIL" | tee -a '"$LOG"'; exit 1; }
  fi

  echo "[build] All done." | tee -a '"$LOG"'

  mkdir -p /host/output
  find bin/packages -name "*.ipk" -exec cp -v {} /host/output/ \; 2>&1 | tee -a '"$LOG"'
  echo "[build] Produced .ipk files:" | tee -a '"$LOG"'
  ls -la /host/output/*.ipk | tee -a '"$LOG"'
'
