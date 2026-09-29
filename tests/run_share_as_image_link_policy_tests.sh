#!/bin/sh
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

python3 - "$repo" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
source = (root / "src/ApolloShareAsImageLink.xm").read_text()
video = (root / "src/ApolloShareAsVideo.xm").read_text()
makefile = (root / "Makefile").read_text()

required = {
    "the Link menu uses the Apollo theme accent helper": "button.tintColor = ApolloThemeAccentColor() ?: [(UIViewController *)vc view].tintColor;",
    "comment availability gates the third menu choice": "BOOL hasComment = ApolloShareLinkHasComment(vc);",
    "comment choice is exposed": "@(ApolloShareLinkModeComment)",
    "the selected mode is captured at the share boundary": "sActiveShareLinkMode = ApolloShareLinkModeRead",
    "the activity sheet resolves the selected target": "ApolloShareLinkURLForVC(vc, sActiveShareLinkMode)",
    "share-host rewriting still wraps the selected URL": "ApolloShareLinkRewriteURLForCurrentHost(url)",
}
for behavior, marker in required.items():
    if marker not in source:
        raise SystemExit(f"missing policy: {behavior}")

video_required = {
    "video reads the shared mode": "ApolloShareLinkModeRead(NSUserDefaults.standardUserDefaults",
    "video resolves comment and post targets through the shared policy": "ApolloShareLinkURLForMode(linkMode, comment, ApolloSVPostURL(vc))",
}
for behavior, marker in video_required.items():
    if marker not in video:
        raise SystemExit(f"missing policy: {behavior}")
if 'boolForKey:@"ApolloShareAsImageIncludeLink"' in video:
    raise SystemExit("video export still bypasses the shared link-mode policy")

helper = "$(SRC_DIR)/ApolloShareAsImageLinkMode.m"
hook = "$(SRC_DIR)/ApolloShareAsImageLink.xm"
if helper not in makefile or makefile.index(helper) > makefile.index(hook):
    raise SystemExit("link-mode helper must be compiled before its Logos consumer")

print(f"share-as-image link policy checks passed ({len(required) + len(video_required) + 2})")
PY
