#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-fullscreen-menu.XXXXXX")
trap 'rm "$build/FullscreenMenu.inc" "$build/test"; rmdir "$build"' EXIT
python3 - "$root/src/ApolloSaveAllMediaMenus.xm" "$build/FullscreenMenu.inc" <<'PY'
import pathlib, sys
s = pathlib.Path(sys.argv[1]).read_text()
def between(a, b):
    return s[s.index(a):s.index(b, s.index(a))]
pathlib.Path(sys.argv[2]).write_text(
    between('@interface ApolloFullScreenImageMenu', 'static UIViewController *ApolloFullScreenCurrentViewer') +
    between('static UIAction *ApolloFullScreenImageAction', 'static void ApolloFullScreenShowShareMenu(ApolloFullScreenImageMenu *context) {') +
    between('static UIMenu *ApolloFullScreenWithoutSharing', '%hook _TtC6Apollo23MediaPageViewController'))
PY
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    -I "$build" "$root/tests/fullscreen_media_menu_tests.m" -framework Foundation -o "$build/test"
"$build/test"
