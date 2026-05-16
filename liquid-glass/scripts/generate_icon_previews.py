#!/usr/bin/env python3
"""Generate 300×300 PNG preview images for each icon variant using ictool.

For each icon registered in icons.json, finds <id>/<id>.icon and exports
four variants (default, dark, clear-light, clear-dark) via ictool into
icons/<id>/<variant>.png at 300×300 px.

Usage:
    python3 scripts/generate_icon_previews.py [--icons <id1,id2,...>]

    --icons  Comma-separated list of icon IDs to (re)generate.
             Omit to regenerate all icons in icons.json.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

_ICTOOL_CANDIDATES = [
    # Standalone Icon Composer from developer.apple.com/icon-composer/
    "/Applications/Icon Composer.app/Contents/Executables/ictool",
    # Bundled inside Xcode
    "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool",
]
ICTOOL = next((p for p in _ICTOOL_CANDIDATES if os.path.isfile(p)), _ICTOOL_CANDIDATES[0])

# Maps preview filename stem → ictool rendition name
VARIANTS: dict[str, str] = {
    "default":     "Default",
    "dark":        "Dark",
    "clear-light": "ClearLight",
    "clear-dark":  "ClearDark",
}

# Output size in logical points; scale=1 → pixel dimensions equal these values
PREVIEW_WIDTH  = 300
PREVIEW_HEIGHT = 300
PREVIEW_SCALE  = 1


def export_variant(icon_file: str, rendition: str, out_path: str) -> bool:
    cmd = [
        ICTOOL, icon_file,
        "--export-image",
        "--output-file", out_path,
        "--platform", "iOS",
        "--rendition", rendition,
        "--width",  str(PREVIEW_WIDTH),
        "--height", str(PREVIEW_HEIGHT),
        "--scale",  str(PREVIEW_SCALE),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0 or not os.path.isfile(out_path):
        print(f"  ERROR: ictool failed for rendition={rendition}", file=sys.stderr)
        if result.stderr.strip():
            print(f"  stderr: {result.stderr.strip()}", file=sys.stderr)
        return False

    # ictool may export 16-bit (rgba64be) PNGs; normalise to 8-bit so file
    # sizes are consistent with the other icons.
    convert = subprocess.run(
        ["magick", out_path, "-depth", "8", out_path],
        capture_output=True, text=True,
    )
    if convert.returncode != 0:
        print(f"  WARNING: magick depth conversion failed for {out_path}", file=sys.stderr)
        if convert.stderr.strip():
            print(f"  stderr: {convert.stderr.strip()}", file=sys.stderr)

    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--icons", help="Comma-separated icon IDs to regenerate")
    args = parser.parse_args()

    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    lg_dir = os.path.abspath(os.path.join(scripts_dir, ".."))

    if not os.path.isfile(ICTOOL):
        print(f"ictool not found at:\n  {ICTOOL}", file=sys.stderr)
        return 1

    registry_path = os.path.join(lg_dir, "icons.json")
    with open(registry_path) as fp:
        registry = json.load(fp)

    all_ids = [entry["id"] for entry in registry["icons"]]
    if args.icons:
        selected = [s.strip() for s in args.icons.split(",")]
        unknown = [i for i in selected if i not in all_ids]
        if unknown:
            print(f"Unknown icon IDs: {', '.join(unknown)}", file=sys.stderr)
            print(f"Known: {', '.join(all_ids)}", file=sys.stderr)
            return 1
        target_ids = selected
    else:
        target_ids = all_ids

    errors = 0
    for icon_id in target_ids:
        icon_dir  = os.path.join(lg_dir, "icons", icon_id)
        icon_file = os.path.join(icon_dir, f"{icon_id}.icon")

        if not os.path.exists(icon_file):
            print(f"[{icon_id}] SKIP — .icon file not found: {icon_file}", file=sys.stderr)
            errors += 1
            continue

        print(f"[{icon_id}] Exporting from {os.path.basename(icon_file)} ...")
        ok = True
        for stem, rendition in VARIANTS.items():
            out_path = os.path.join(icon_dir, f"{stem}.png")
            success  = export_variant(icon_file, rendition, out_path)
            status   = "OK" if success else "FAIL"
            print(f"  {stem:<12} ({rendition:<12}) → {status}")
            if not success:
                ok = False
                errors += 1

        if ok:
            print(f"  All variants written to {icon_dir}")

    if errors:
        print(f"\n{errors} error(s). Check stderr above.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
