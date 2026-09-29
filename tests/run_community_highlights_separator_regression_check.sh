#!/bin/sh
set -eu

test_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

python3 - "$test_root" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
source = (root / "src/ApolloSubredditHighlights.xm").read_text()

def require(fragment: str, message: str) -> None:
    if fragment not in source:
        raise SystemExit(f"missing Community Highlights separator guard: {message}")

require("static char kApolloHLDeDupSubKey;", "table-local subreddit identity")
require("ApolloHLHideSubsContains(subreddit)", "exact subreddit membership check")
require("if (hostVC) ApolloHLPrepareDeDupForSubreddit(hostVC, sub);",
        "Headers-on early-entry lifecycle preparation")
require("ApolloHLPrepareDeDupForSubreddit(vc, subreddit);",
        "normal install lifecycle preparation")
require("objc_setAssociatedObject(tableNode, &kApolloHLDeDupSubKey, nil",
        "table-local identity teardown")
require("objc_setAssociatedObject(tableNode, &kApolloHLStickyCountKey, nil",
        "sticky-count teardown")
require("objc_setAssociatedObject(tableNode, &kApolloHLFeedOwnedMaskKey, nil",
        "feed-owned-mask teardown")

function_start = source.index("static BOOL ApolloHLSeparatorShouldCollapse(")
function = source[function_start:
                  source.index("static void ApolloHLCollapseOrphanSeparators(", function_start)]
eligibility = function.index("if (!eligible) return NO;")
reactive_flag = function.index("kApolloHLSepCollapseKey")
if eligibility > reactive_flag:
    raise SystemExit("table eligibility must be checked before a stale reactive collapse flag")

install = source[source.index("static void ApolloHLInstall(UIViewController *vc) {"):
                 source.index("// Opt-in: harvest the full highlights set", source.index("static void ApolloHLInstall(UIViewController *vc) {"))]
prepare = install.index("ApolloHLPrepareDeDupForSubreddit(vc, subreddit)")
count_publish = install.index("ApolloHLApplyStickyCountToTable(vc, subreddit)")
if not prepare < count_publish:
    raise SystemExit("separator identity and membership must precede sticky-count reloads")

print("community_highlights_separator_regression_check passed")
PY
