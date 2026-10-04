#!/bin/sh
# Pal Home placement rules, hostile room documents, every catalogue item,
# every style template, and Pal codes. Foundation/CoreGraphics only.
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
bin=$(mktemp -d "${TMPDIR:-/tmp}/pal-home-layout.XXXXXX")
trap 'rm -rf -- "$bin"' EXIT HUP INT TERM
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wno-unused-parameter -Werror -fsanitize=address,undefined \
    -framework Foundation -framework CoreGraphics -framework CoreText -I "$repo/src" \
    "$repo"/src/palhome/ApolloPixelCanvas.m "$repo"/src/palhome/ApolloPalHomeCatalog.m "$repo"/src/palhome/ApolloPalHomeSurfaces.m \
    "$repo"/src/palhome/ApolloPalHomeFurniture.m "$repo"/src/palhome/ApolloPalHomeWallItems.m "$repo"/src/palhome/ApolloPalHomeThemedItems.m "$repo"/src/palhome/ApolloPalHomeHalloween.m \
    "$repo"/src/palhome/ApolloPalHomeStyles.m "$repo"/src/palhome/ApolloPalHomeRenderer.m "$repo"/src/palhome/ApolloPalHomeChrome.m \
    "$repo"/src/palhome/ApolloPixelPalCoats.m "$repo"/src/palhome/ApolloPalHomeStore.m "$repo"/src/palhome/ApolloPalHomeShelter.m "$repo"/src/palhome/ApolloPalSpecies.m "$repo"/src/palhome/ApolloRebornPalSprites.m \
    "$repo"/src/palhome/ApolloPalHomeWidgetRenderer.m "$repo/tests/pal_home_layout_tests.m" -o "$bin/tests"
"$bin/tests"
