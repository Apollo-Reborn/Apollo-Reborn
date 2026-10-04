#!/bin/sh
# Renders Pal Home rooms + the full catalogue to PNGs for visual review.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${1:-"${TMPDIR:-/tmp}/pal-home-render"}
bin=$(mktemp -d "${TMPDIR:-/tmp}/pal-home-render-bin.XXXXXX")
trap 'rm -rf -- "$bin"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Wno-unused-parameter -Werror \
    -framework Foundation -framework CoreGraphics -framework CoreText -framework ImageIO \
    -I "$repo/src" \
    "$repo/src/palhome/ApolloPixelCanvas.m" "$repo/src/palhome/ApolloPalHomeCatalog.m" \
    "$repo/src/palhome/ApolloPalHomeSurfaces.m" "$repo/src/palhome/ApolloPalHomeFurniture.m" \
    "$repo/src/palhome/ApolloPalHomeWallItems.m" "$repo/src/palhome/ApolloPalHomeRenderer.m" \
    "$repo/src/palhome/ApolloPalHomeThemedItems.m" "$repo/src/palhome/ApolloPalHomeHalloween.m" "$repo/src/palhome/ApolloPalHomeStyles.m" \
    "$repo/src/palhome/ApolloPalHomeChrome.m" "$repo/src/palhome/ApolloPixelPalCoats.m" \
    "$repo/src/palhome/ApolloPalHomeWidgetRenderer.m" "$repo/src/palhome/ApolloPalHomeStore.m" "$repo/src/palhome/ApolloPalHomeShelter.m" "$repo/src/palhome/ApolloPalSpecies.m" "$repo/src/palhome/ApolloRebornPalSprites.m" \
    "$repo/tests/pal_home_render.m" -o "$bin/render"
"$bin/render" "$out"
