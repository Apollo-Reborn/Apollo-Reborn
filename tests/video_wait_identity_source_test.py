#!/usr/bin/env python3
"""Regression guard for the feed-video wait-log holder identity."""

from pathlib import Path
import re


repo = Path(__file__).resolve().parents[1]
source = (repo / "src" / "ApolloVideoUnmute.xm").read_text()
match = re.search(
    r"static void NoteFeedVideoWaiting\([^)]*\)\s*\{(?P<body>.*?)\n\}",
    source,
    re.DOTALL,
)
if not match:
    raise SystemExit("NoteFeedVideoWaiting function not found")

body = match.group("body")
required = {
    "raw address capture": "(__bridge const void *)holder",
    "raw pointer comparison": "[loggedFor pointerValue]",
    "raw pointer storage": "[NSValue valueWithPointer:holderAddress]",
}
for description, needle in required.items():
    if needle not in body:
        raise SystemExit(f"missing {description}: {needle}")

for forbidden in ("nonretainedObjectValue", "valueWithNonretainedObject"):
    if forbidden in body:
        raise SystemExit(f"unsafe Objective-C reconstruction returned: {forbidden}")

print("video wait identity source test passed")
