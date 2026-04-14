#!/usr/bin/env bash
# Copyright (c) 2026 Ronen Druker.
# prepare-feeds.sh — wire the Vladdrako printing feed into the SDK,
# update feeds, install required package metadata, and write an initial
# .config selecting just what we need as .ipk packages (not built-in).
#
# Produces: /workspace/sdk/.config with CUPS, cups-filters, ghostscript,
# foo2zjs all selected as modules (=m), plus their deps as modules where
# possible (so nothing is baked into a firmware image we're not building).
set -euo pipefail

CONTAINER=openwrt-build
PRINTING_FEED="src-git printing https://github.com/Vladdrako/openwrt-printing-packages.git"

docker exec -u builder "$CONTAINER" bash -c "
  set -euo pipefail
  cd /workspace/sdk

  # 1) Add printing feed if not present
  if ! grep -q 'Vladdrako/openwrt-printing-packages' feeds.conf.default; then
    echo '$PRINTING_FEED' >> feeds.conf.default
    echo '[feeds] Appended Vladdrako printing feed'
  fi

  # 2) Update all feeds (downloads feed metadata + printing package Makefiles)
  echo '[feeds] Updating feeds…'
  ./scripts/feeds update -a 2>&1 | tail -20

  # 3) Install package metadata (creates symlinks under package/feeds/…)
  echo '[feeds] Installing package metadata…'
  ./scripts/feeds install -a 2>&1 | tail -10

  # 4) Verify the printing packages we need are present
  echo '[feeds] Checking printing packages…'
  for pkg in cups cups-filters ghostscript foo2zjs; do
    if [ -d \"package/feeds/printing/\$pkg\" ]; then
      echo \"  ✓ \$pkg\"
    else
      echo \"  ✗ \$pkg MISSING\"
    fi
  done

  # 5) Seed .config with a minimal target config and our package selections.
  # NOTE package names must match the feed exactly:
  #   - cups-filters is actually called 'openprinting-cups-filters'
  #   - libcupscgi / libcupsmime / libcupsppdc are NOT built — upstream
  #     CUPS 2.4.x only produces .a statics for these and cupsd links
  #     them statically. Vladdrako correctly leaves those BuildPackage
  #     lines commented; do not try to emit .so packages for them.
  cat > .config <<'EOF'
CONFIG_TARGET_ipq807x=y
CONFIG_TARGET_ipq807x_generic=y
CONFIG_TARGET_MULTI_PROFILE=y
CONFIG_ALL_KMODS=n
CONFIG_ALL_NONSHARED=n
CONFIG_ALL=n
# Printing stack — selected as modules so we get .ipk artifacts
CONFIG_PACKAGE_cups=m
CONFIG_PACKAGE_cups-client=m
CONFIG_PACKAGE_cups-ppdc=m
CONFIG_PACKAGE_libcups=m
CONFIG_PACKAGE_libcupsimage=m
CONFIG_PACKAGE_openprinting-cups-filters=m
CONFIG_PACKAGE_poppler=m
CONFIG_PACKAGE_ghostscript=m
CONFIG_PACKAGE_foo2zjs=m
EOF

  echo '[feeds] Running make defconfig to resolve deps…'
  make defconfig 2>&1 | tail -5

  echo '[feeds] Final selection (printing-related):'
  grep -E 'cups|ghost|foo2zjs|poppler|freetype|fontconfig|lcms' .config | grep -v '^#' | head -30
"
