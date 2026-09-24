#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
s=Path('src/ApolloInlineLinkPreviews.xm').read_text()
pieces=[]
for a,b in [('static BOOL ApolloLPScrollViewIsInteracting(', 'static void ApolloLPInvokeContainerRelayoutIfPossible('), ('static CGFloat ApolloLPFeedFooterOverlap(', 'static ASDisplayNode *ApolloLPNodeForViewIfPossible(')]:
 pieces.append(s[s.index(a):s.index(b)])
Path(sys.argv[1],'Overflow.inc').write_text('\n'.join(pieces))
PY
xcrun clang++ -std=c++17 -fobjc-arc -fblocks -framework Foundation -framework CoreGraphics -I"$work" -x objective-c++ tests/link_preview_overflow_tests.mm -o "$work/tests"
"$work/tests"
