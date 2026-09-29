#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

python3 - "$test_root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
search = (root / "src/ApolloSearchInPlace.xm").read_text()
theme = (root / "src/ApolloThemeRuntime.xm").read_text()

def require(source: str, fragment: str, message: str) -> None:
    if fragment not in source:
        raise SystemExit(f"missing classic feed toolbar theme guard: {message}")

require(search, "!IsLiquidGlass() && ApolloThemeRuntimeIsActive()",
        "classic custom-theme scope")
require(search, "ApolloFeedControllerForSearchToolbar(toolbar)",
        "feed-owner scope")
require(search, 'ApolloReadBoolIvar(controller, "searchBarShouldStickToKeyboard"',
        "comments find-bar exclusion")
require(search, "ApolloThemeTokenBarBackground", "Bars-role toolbar surface")
require(search, "[surface removeFromSuperview]", "live disable/reuse teardown")
require(search, "insertSubview:surface aboveSubview:systemBackground",
        "surface above UIKit toolbar background")
require(search, "ApolloApplyClassicFeedToolbarSurface((UIView *)self);",
        "idempotent layout refresh")
require(search, "- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection",
        "live theme edit/disable refresh")

field_start = theme.index("%hook _TtC6Apollo24ApolloSearchBarTextField")
field_end = theme.index("%end", field_start)
field_hook = theme[field_start:field_end]
require(field_hook, "ApolloThemeTokenTertiaryBackground", "Raised-role search field retained")

helper_start = search.index("static void ApolloApplyClassicFeedToolbarSurface(")
helper_end = search.index("%hook _TtC6Apollo19ApolloSearchToolbar", helper_start)
helper = search[helper_start:helper_end]
if helper.index("if (!wantsSurface)") > helper.index("ApolloThemeRuntimeColor(ApolloThemeTokenBarBackground)"):
    raise SystemExit("teardown gate must run before resolving/applying the custom Bars role")

print("classic_feed_toolbar_theme_regression_check passed")
PY
