#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output="$(mktemp "${TMPDIR:-/tmp}/swipe-comments-media-policy.XXXXXX")"
trap 'rm -f "$output"' EXIT

clang -std=c11 -Wall -Wextra -Werror \
    -I"$repo_root/src" \
    "$repo_root/tests/swipe_comments_media_policy_tests.c" \
    -o "$output"
"$output"

swipe_source="$repo_root/src/ApolloSwipeUpComments.xm"
pip_source="$repo_root/src/ApolloPictureInPicture.xm"
swipe_fix_source="$repo_root/src/ApolloVideoSwipeFix.xm"

grep -q 'ApolloSwipeCommentsCaptureMediaSession(mediaController)' "$swipe_source"
grep -q 'ApolloSwipeCommentsProtectsFullscreenPlayer' "$pip_source"
grep -q 'ApolloSwipeCommentsSharedPlayerLayerMoved' "$swipe_fix_source"
grep -q 'pane settled' "$swipe_source"
grep -q 'videoPlaybackSpeed' "$swipe_source"
grep -q 'player.defaultRate' "$swipe_source"
grep -q '\[player setRate:restoreRate\]' "$swipe_source"

python3 - "$swipe_source" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
for selector, next_selector in (
    ("- (void)closePane:", "- (void)openFullPost:"),
    ("- (void)openFullPost:", "- (void)presentationControllerDidDismiss:"),
):
    body = source[source.index(selector):source.index(next_selector)]
    dismiss = body.index("dismissViewControllerAnimated:")
    finish = body.index("ApolloSwipeCommentsFinishMediaSessionAfterDismissal")
    if finish < dismiss:
        raise SystemExit(f"{selector} drops media protection before dismissal")
print("dismissal lifecycle source checks passed")
PY

echo "swipe comments media source checks passed"
