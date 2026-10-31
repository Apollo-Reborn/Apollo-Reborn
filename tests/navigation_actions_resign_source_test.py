#!/usr/bin/env python3
"""Regression guard for lifecycle-safe navigation-action settlement."""

from pathlib import Path
import re


repo = Path(__file__).resolve().parents[1]
source = (repo / "src" / "ApolloNavigationActions.xm").read_text()

observer = re.search(
    r"UIApplicationWillResignActiveNotification.*?usingBlock:\^\([^)]*\)\s*\{(?P<body>.*?)\n\s*\}\];",
    source,
    re.DOTALL,
)
if not observer:
    raise SystemExit("will-resign-active observer not found")
if "collapseForResignActive" not in observer.group("body"):
    raise SystemExit("will-resign-active observer bypasses lifecycle-safe settlement")

method = re.search(
    r"- \(void\)collapseForResignActive\s*\{(?P<body>.*?)\n\}",
    source,
    re.DOTALL,
)
if not method:
    raise SystemExit("collapseForResignActive method not found")

body = method.group("body")
required = {
    "detach animator before interruption": "self.animator = nil;",
    "discard presentation animation without completion": "[running stopAnimation:YES];",
    "force cleanup after interruption": "self.needsAnimationSettlement = YES;",
    "collapse without starting another animation": "[self setExpanded:NO animated:NO];",
}
for description, needle in required.items():
    if needle not in body:
        raise SystemExit(f"missing {description}: {needle}")

if "finishAnimationAtPosition" in body or "stopAnimation:NO" in body:
    raise SystemExit("resign-active path must not finish an animator inside the scene transaction")
if body.index("self.animator = nil;") > body.index("[running stopAnimation:YES];"):
    raise SystemExit("animator must be detached before UIKit interruption callbacks can run")

print("navigation actions resign source test passed")
