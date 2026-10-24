"""Regression expectation for the real native visibility-method probe.

Original behavior must fail; the isolated 49pt tab-height control must pass.
The control is a diagnostic experiment, not a proposed 49pt hardcoded fix.
"""
import json
from pathlib import Path
import sys

data = json.loads(Path(sys.argv[1]).read_text())
key = 'controlWith49ptTabBar' if '--control' in sys.argv else 'nativeAllowsAutoplay'
full_rows = [r for r in data['rows'] if r['visibleFraction'] == 1]
assert full_rows, 'Probe did not contain a fully visible video position'
# The navigation bar changes height between Duo poses. Select the same semantic
# case, a midpoint behind that measured bar, rather than a front-only y constant.
behind_bar = max((r for r in data['rows'] if r['midY'] < data['nativeRegionTop'] and
                  r['visibleFraction'] > 0), key=lambda r: r['midY'])
full = full_rows[0]
print(f"{key}: fully visible={full[key]}, only {behind_bar['visibleFraction']:.1%} visible={behind_bar[key]}")
assert all(r[key] for r in full_rows), 'A fully visible video is rejected by the native visibility gate'
assert not behind_bar[key], 'A video whose midpoint is behind the navigation bar is accepted'
print('PASS')
