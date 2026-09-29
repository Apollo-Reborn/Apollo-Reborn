#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
build=$(mktemp -d "${TMPDIR:-/tmp}/apollo-classic-bar-tests.XXXXXX")
trap 'rm -rf "$build"' EXIT HUP INT TERM

python3 - "$test_root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
search = (root / "src/ApolloSearchInPlace.xm").read_text()
theme = (root / "src/ApolloThemeRuntime.xm").read_text()

def require(source: str, fragment: str, message: str) -> None:
    if fragment not in source:
        raise SystemExit(f"missing classic bar theme guard: {message}")

def reject(source: str, fragment: str, message: str) -> None:
    if fragment in source:
        raise SystemExit(f"stale classic toolbar overlay remains: {message}")

for stale in (
    "kApolloClassicFeedToolbarSurfaceKey",
    "ApolloReadBoolIvar",
    "ApolloFeedControllerForSearchToolbar",
    "ApolloApplyClassicFeedToolbarSurface",
):
    reject(search, stale, stale)

helper_start = theme.index("static UIColor *ApolloThemeClassicBarFill(")
helper_end = theme.index("%hook UIBarAppearance", helper_start)
helper = theme[helper_start:helper_end]
require(theme, '#import "ApolloClassicBarTheme.h"', "portable policy import")
require(helper, "ApolloClassicBarShouldRouteRaisedToBars(", "portable policy invocation")
require(helper, "snapshot->enabled, liquidGlass, hasComponents, a, rgb,",
        "decoded runtime state forwarded to policy")
require(helper, "snapshot->tokens[ApolloThemeModeLight][ApolloThemeTokenTertiaryBackground]",
        "active light Raised token forwarded to policy")
require(helper, "snapshot->tokens[ApolloThemeModeDark][ApolloThemeTokenTertiaryBackground]",
        "active dark Raised token forwarded to policy")
require(helper, "return ApolloThemeRuntimeColor(ApolloThemeTokenBarBackground) ?: color;",
        "Raised-to-Bars routing with fail-closed fallback")

appearance_start = theme.index("%hook UIBarAppearance", helper_end)
appearance_end = theme.index("%end", appearance_start)
appearance_hook = theme[appearance_start:appearance_end]
require(appearance_hook, "[self isKindOfClass:[UINavigationBarAppearance class]]",
        "navigation-bar appearance scope")
require(appearance_hook, "[self isKindOfClass:[UITabBarAppearance class]]",
        "tab-bar appearance scope")
require(appearance_hook, "color = ApolloThemeClassicBarFill(color);",
        "appearance fill routing")
require(appearance_hook, "%orig(color);", "modified appearance colour forwarding")
reject(appearance_hook, "UIToolbarAppearance", "generic toolbar appearance interception")

tab_start = theme.index("%hook UITabBar", appearance_end)
tab_end = theme.index("%end", tab_start)
tab_hook = theme[tab_start:tab_end]
require(tab_hook, "- (void)setBarTintColor:(UIColor *)color",
        "legacy tab-bar fill sink")
require(tab_hook, "%orig(ApolloThemeClassicBarFill(color));",
        "legacy tab-bar Raised-to-Bars routing")

field_start = theme.index("%hook _TtC6Apollo24ApolloSearchBarTextField")
field_end = theme.index("%end", field_start)
field_hook = theme[field_start:field_end]
require(field_hook, "ApolloThemeTokenTertiaryBackground", "Raised-role search field retained")

print("classic_bar_theme_regression_check passed")
PY

xcrun --sdk macosx clang \
    -std=c11 -Wall -Wextra -Werror -pedantic \
    -fsanitize=address,undefined \
    -I"$test_root/src" \
    "$test_root/tests/classic_bar_theme_policy_tests.c" \
    -o "$build/classic_bar_theme_policy_tests"

"$build/classic_bar_theme_policy_tests"
