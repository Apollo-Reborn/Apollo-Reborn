#!/usr/bin/env python3
"""
Rebuild Assets.car from an existing Assets.car.

Strategy:
  1. assetutil -I  → full metadata: maps Name + Appearance → RenditionName
  2. cartool       → extract vector PDFs (preserves original vector format)
  3. act extract   → SVG symbol weight/size variants + PNG fallbacks
  4. Group files by asset Name, preferring PDFs from cartool over act's rasters
  5. For symbol assets: use the correctly-sized SVG variant from act
  6. Compile with actool, including every .icon package registered in icons.json
"""

import json
import os
import re
import shutil
import subprocess
import sys
from collections import defaultdict

# Layout (resolved relative to this script so the rebuild can run from anywhere):
#
#   liquid-glass/
#   ├── icons.json                          (registry: which icons to include)
#   ├── Assets.car                          (user-supplied original — input)
#   ├── icons/<id>/<id>.icon/               (Icon Composer packages)
#   ├── prebuilt/Assets.car                 (rebuilt output destination)
#   └── scripts/
#       ├── rebuild_assets.py               (this file)
#       ├── cartool-extracted/              (intermediate, gitignored)
#       ├── act-extracted/                  (intermediate, gitignored)
#       └── rebuilt/{Assets.xcassets,compiled}/  (intermediate, gitignored)

SCRIPTS_DIR     = os.path.dirname(os.path.abspath(__file__))
LG_DIR          = os.path.abspath(os.path.join(SCRIPTS_DIR, ".."))
REGISTRY_PATH   = os.path.join(LG_DIR, "icons.json")
ICONS_ROOT      = os.path.join(LG_DIR, "icons")
ORIGINAL_CAR    = os.path.join(LG_DIR, "Assets.car")
PREBUILT_CAR    = os.path.join(LG_DIR, "prebuilt", "Assets.car")

CARTOOL_DIR     = os.path.join(SCRIPTS_DIR, "cartool-extracted")
EXTRACTED_DIR   = os.path.join(SCRIPTS_DIR, "act-extracted")
REBUILT_ROOT    = os.path.join(SCRIPTS_DIR, "rebuilt")
XCASSETS_DIR    = os.path.join(REBUILT_ROOT, "Assets.xcassets")
OUTPUT_DIR      = os.path.join(REBUILT_ROOT, "compiled")

ACT             = "/Applications/Asset Catalog Tinkerer.app/Contents/MacOS/act"
CARTOOL         = shutil.which("cartool") or "/usr/local/bin/cartool"

# Appearance string → Contents.json appearances array entry
APPEARANCE_MAP = {
    "UIAppearanceDark":  [{"appearance": "luminosity", "value": "dark"}],
    "UIAppearanceLight": [{"appearance": "luminosity", "value": "light"}],
}

# act names symbol SVGs as: {name}_{weight}_{size}_automatic.svg  (weight may be camelCase)
SYMBOL_SVG_RE = re.compile(
    r'^(.+)_(ultralight|thin|light|regular|medium|semibold|bold|heavy|black)'
    r'_(small|medium|large)_automatic\.svg$',
    re.IGNORECASE,
)

# act names raster PNGs as: {rendition-stem}_Normal[@2x|@3x][_N].png
# We only care about the base scale files (no numbered suffix = appearance 0 / universal-any)
RASTER_PNG_RE = re.compile(r'^(.+)_Normal(@2x|@3x)?\.png$')

RENDERING_INTENTS = {}      # asset name -> original/template/automatic
TEMPLATE_ASSETS   = set()   # asset names that need template-rendering-intent
SYMBOL_ASSETS     = set()   # asset names that have SVG glyph variants


# ---------------------------------------------------------------------------
# Step 1 – load metadata from original Assets.car
# ---------------------------------------------------------------------------

def load_metadata():
    """
    Returns:
      rendition_to_assets: dict[rendition_stem -> list[(asset_name, appearance_str_or_None)]]
      rendering_intents:   dict of asset names to template-rendering-intent values
      symbol_assets:       set of asset names that have Glyph Size entries (SF Symbol-style)
    """
    global RENDERING_INTENTS, TEMPLATE_ASSETS, SYMBOL_ASSETS

    print(f"Reading metadata from {ORIGINAL_CAR}...")
    result = subprocess.run(
        ["assetutil", "-I", ORIGINAL_CAR],
        capture_output=True, text=True, check=True,
    )
    entries = json.loads(result.stdout)

    rendition_to_assets = defaultdict(list)

    for e in entries:
        if not isinstance(e, dict) or "Name" not in e or "RenditionName" not in e:
            continue

        name         = e["Name"]
        rendition    = e["RenditionName"]               # e.g. "launch-dark-bg.pdf"
        appearance   = e.get("Appearance")              # "UIAppearanceDark" | "UIAppearanceLight" | None
        stem         = os.path.splitext(rendition)[0]   # strip .pdf / .svg

        rendition_to_assets[stem].append((name, appearance))

        template_mode = e.get("Template Mode")
        if template_mode == "template":
            RENDERING_INTENTS[name] = "template"
            TEMPLATE_ASSETS.add(name)
        elif template_mode == "automatic":
            RENDERING_INTENTS.setdefault(name, "automatic")
        elif name not in RENDERING_INTENTS:
            RENDERING_INTENTS[name] = "original"

        if e.get("Glyph Size"):
            SYMBOL_ASSETS.add(name)

    print(f"  {len(rendition_to_assets)} unique rendition stems")
    print(f"  {len(TEMPLATE_ASSETS)} template assets, {len(SYMBOL_ASSETS)} symbol assets")
    return rendition_to_assets


# ---------------------------------------------------------------------------
# Step 2 – extract files with cartool (PDFs) and act (SVGs + PNG fallbacks)
# ---------------------------------------------------------------------------

def run_cartool_extraction():
    if os.path.exists(CARTOOL_DIR):
        shutil.rmtree(CARTOOL_DIR)
    os.makedirs(CARTOOL_DIR)
    print(f"Extracting vectors with cartool...")
    r = subprocess.run(
        [CARTOOL, ORIGINAL_CAR, CARTOOL_DIR],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"✗ cartool failed:\n{r.stderr}")
        return False
    count = sum(len(files) for _, _, files in os.walk(CARTOOL_DIR))
    print(f"  Extracted {count} files into {len(os.listdir(CARTOOL_DIR))} asset directories")
    return True


def run_act_extraction():
    if os.path.exists(EXTRACTED_DIR):
        shutil.rmtree(EXTRACTED_DIR)
    print(f"Extracting symbol SVGs with act...")
    r = subprocess.run(
        [ACT, "-i", ORIGINAL_CAR, "extract", "-o", EXTRACTED_DIR],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"✗ act failed:\n{r.stderr}")
        return False
    print(f"  Extracted {len(os.listdir(EXTRACTED_DIR))} files")
    return True


# ---------------------------------------------------------------------------
# Step 3 – group files by asset name
#   - PDFs from cartool (vector, preferred for non-symbol assets)
#   - SVGs from act (weight/size variants for SF Symbols)
#   - PNGs from act (fallback for assets with no PDF in the catalog)
# ---------------------------------------------------------------------------

def group_by_asset(rendition_to_assets):
    """
    Returns two dicts keyed by asset name:
      symbol_variants: name -> {(weight, size): filepath}   (SVG files from act)
      raster_groups:   name -> [(filepath, scale, appearance_str_or_None)]
                       scale is "1x" for PDFs (vector), "1x"/"2x"/"3x" for PNGs
    """
    symbol_variants = defaultdict(dict)   # name -> {(weight,size): abs_path}
    raster_groups   = defaultdict(list)   # name -> [(path, scale, appearance)]
    pdf_assets      = set()               # asset names covered by a PDF

    # --- A: Collect PDFs from cartool output ---
    # cartool extracts to: {CARTOOL_DIR}/{asset_name}/{rendition-name}.pdf
    # It also writes .pdf.png rasters alongside each PDF — skip those.
    if os.path.isdir(CARTOOL_DIR):
        for dirname in sorted(os.listdir(CARTOOL_DIR)):
            dirpath = os.path.join(CARTOOL_DIR, dirname)
            if not os.path.isdir(dirpath):
                continue
            for fname in sorted(os.listdir(dirpath)):
                if not fname.endswith(".pdf") or fname.endswith(".pdf.png"):
                    continue
                filepath = os.path.join(dirpath, fname)
                stem = fname[:-4]  # strip .pdf
                if stem in rendition_to_assets:
                    for (asset_name, appearance) in rendition_to_assets[stem]:
                        raster_groups[asset_name].append((filepath, "1x", appearance))
                        pdf_assets.add(asset_name)
                else:
                    # Rendition stem == asset name (simple case)
                    raster_groups[dirname].append((filepath, "1x", None))
                    pdf_assets.add(dirname)

    # --- B: Collect SVG symbol variants + PNG fallbacks from act output ---
    for filename in os.listdir(EXTRACTED_DIR):
        filepath = os.path.join(EXTRACTED_DIR, filename)

        # SVG symbol variant (act outputs one file per weight×size combination)
        m = SYMBOL_SVG_RE.match(filename)
        if m:
            rendition_stem = m.group(1)
            weight, size   = m.group(2).lower(), m.group(3).lower()
            if rendition_stem in rendition_to_assets:
                name = rendition_to_assets[rendition_stem][0][0]
            else:
                name = rendition_stem
            symbol_variants[name][(weight, size)] = filepath
            continue

        # Raster PNG — only use if cartool didn't provide a PDF for this asset
        m = RASTER_PNG_RE.match(filename)
        if m:
            rendition_stem = m.group(1)
            scale_suffix   = m.group(2)
            scale = {None: "1x", "@2x": "2x", "@3x": "3x"}[scale_suffix]

            if rendition_stem in rendition_to_assets:
                for (asset_name, appearance) in rendition_to_assets[rendition_stem]:
                    if asset_name not in pdf_assets:
                        raster_groups[asset_name].append((filepath, scale, appearance))
            else:
                if rendition_stem not in pdf_assets:
                    raster_groups[rendition_stem].append((filepath, scale, None))

    return symbol_variants, raster_groups


# ---------------------------------------------------------------------------
# Step 4 – write .xcassets
# ---------------------------------------------------------------------------

def is_template(name):
    return name in TEMPLATE_ASSETS or name in SYMBOL_ASSETS


def rendering_intent(name):
    if is_template(name):
        return "template"
    return RENDERING_INTENTS.get(name, "original")


def write_symbol_imageset(name, variants, xcassets_path):
    imageset_path = os.path.join(xcassets_path, f"{name}.imageset")
    os.makedirs(imageset_path, exist_ok=True)

    # Context menus use medium glyph size; prefer regular weight
    preferred = [
        ("regular", "medium"), ("regular", "large"), ("regular", "small"),
        ("semibold", "medium"), ("semibold", "large"), ("semibold", "small"),
    ]
    key = next((k for k in preferred if k in variants), next(iter(variants)))
    src = variants[key]
    dst_name = os.path.basename(src)
    shutil.copy2(src, os.path.join(imageset_path, dst_name))

    contents = {
        "images": [{"filename": dst_name, "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {
            "preserves-vector-representation": True,
            "template-rendering-intent": "template",
        },
    }
    with open(os.path.join(imageset_path, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)


def write_raster_imageset(name, entries, xcassets_path):
    """
    entries: [(filepath, scale, appearance_str_or_None)]
    """
    imageset_path = os.path.join(xcassets_path, f"{name}.imageset")
    os.makedirs(imageset_path, exist_ok=True)

    images = []
    # Use a set to avoid copying the same file twice (same rendition, multiple appearances)
    copied = set()

    for (filepath, scale, appearance) in entries:
        dst_name = os.path.basename(filepath)
        if dst_name not in copied:
            shutil.copy2(filepath, os.path.join(imageset_path, dst_name))
            copied.add(dst_name)

        entry = {"filename": dst_name, "idiom": "universal", "scale": scale}
        if appearance and appearance in APPEARANCE_MAP:
            entry["appearances"] = APPEARANCE_MAP[appearance]
        images.append(entry)

    has_pdf = any(fp.endswith(".pdf") for (fp, _, _) in entries)
    properties = {"template-rendering-intent": rendering_intent(name)}
    if has_pdf:
        properties["preserves-vector-representation"] = True

    contents = {"images": images, "info": {"author": "xcode", "version": 1}, "properties": properties}

    with open(os.path.join(imageset_path, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)


def build_xcassets(symbol_variants, raster_groups):
    print(f"Building {XCASSETS_DIR}...")
    if os.path.exists(REBUILT_ROOT):
        shutil.rmtree(REBUILT_ROOT)
    os.makedirs(XCASSETS_DIR, exist_ok=True)
    with open(os.path.join(XCASSETS_DIR, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)

    count = 0
    for name, variants in symbol_variants.items():
        write_symbol_imageset(name, variants, XCASSETS_DIR)
        count += 1

    for name, entries in raster_groups.items():
        if name not in symbol_variants:
            write_raster_imageset(name, entries, XCASSETS_DIR)
            count += 1

    sym = len(symbol_variants)
    pdf_count = sum(
        1 for name, entries in raster_groups.items()
        if name not in symbol_variants and any(fp.endswith(".pdf") for (fp, _, _) in entries)
    )
    png_count = count - sym - pdf_count
    print(f"  Created {count} imagesets ({sym} symbol SVG, {pdf_count} vector PDF, {png_count} raster PNG)")
    return count


# ---------------------------------------------------------------------------
# Step 5 – compile
# ---------------------------------------------------------------------------

def load_icon_packages():
    """Resolve every `.icon` package listed in icons.json.

    Each entry maps to liquid-glass/icons/<id>/<id>.icon. Missing
    packages are a hard error since the registry is the source of truth.
    """
    with open(REGISTRY_PATH, "r") as fp:
        registry = json.load(fp)

    packages = []
    for entry in registry.get("icons", []):
        icon_id = entry["id"]
        pkg = os.path.join(ICONS_ROOT, icon_id, f"{icon_id}.icon")
        if not os.path.isdir(pkg):
            print(f"✗ missing .icon package: {pkg}", file=sys.stderr)
            return None
        packages.append(pkg)
    return packages


def compile_assets():
    print("\nCompiling Assets.car...")
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    icon_packages = load_icon_packages()
    if icon_packages is None:
        return False
    if icon_packages:
        names = [os.path.splitext(os.path.basename(p))[0] for p in icon_packages]
        print(f"  Including {len(icon_packages)} icon packages: {', '.join(names)}")

    cmd = ["xcrun", "actool", XCASSETS_DIR]

    # Add each .icon package as an additional input
    cmd.extend(icon_packages)

    cmd.extend([
        "--compile", OUTPUT_DIR,
        "--platform", "iphoneos",
        "--minimum-deployment-target", "13.0",
        "--output-format", "human-readable-text",
    ])

    # Register every icon as an alternate app icon
    cmd.extend(["--include-all-app-icons"])

    # --output-partial-info-plist is required when alternate icons are present
    if icon_packages:
        cmd.extend(["--output-partial-info-plist", os.path.join(OUTPUT_DIR, "partial-info.plist")])

    try:
        print(f"Running: {' '.join(cmd)}")
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        print(result.stdout)
        compiled_car = os.path.join(OUTPUT_DIR, "Assets.car")
        if not os.path.exists(compiled_car):
            print("⚠ Assets.car not found in output")
            return False
        print(f"✓ Assets.car ({os.path.getsize(compiled_car):,} bytes) → {compiled_car}")

        # Copy into prebuilt/ for the patcher to pick up.
        os.makedirs(os.path.dirname(PREBUILT_CAR), exist_ok=True)
        shutil.copy2(compiled_car, PREBUILT_CAR)
        print(f"✓ Copied to {PREBUILT_CAR}")
        return True
    except subprocess.CalledProcessError as e:
        print(f"✗ actool:\n{e.stderr}")
        return False


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    print("=" * 60)
    print("Assets.car Rebuild")
    print("=" * 60)

    if not os.path.exists(ORIGINAL_CAR):
        print(f"✗ {ORIGINAL_CAR} not found")
        print(f"  Copy a decrypted Apollo Assets.car to {ORIGINAL_CAR} and rerun.")
        return 1

    rendition_to_assets = load_metadata()

    if not run_cartool_extraction():
        return 1

    if not run_act_extraction():
        return 1

    symbol_variants, raster_groups = group_by_asset(rendition_to_assets)
    print(f"  Grouped into {len(symbol_variants)} symbol, {len(raster_groups)} raster assets")

    if build_xcassets(symbol_variants, raster_groups) == 0:
        print("✗ No assets found")
        return 1

    # Verify coverage against original
    original_names = set(rendition_to_assets[s][0][0]
                         for s in rendition_to_assets
                         for _ in rendition_to_assets[s])
    rebuilt_names  = set(
        d.replace(".imageset", "")
        for d in os.listdir(XCASSETS_DIR)
        if d.endswith(".imageset")
    )
    # ZZZZPackedAsset entries are internal actool packing atlases, not real named assets
    missing = {n for n in original_names - rebuilt_names if not n.startswith("ZZZZPackedAsset")}
    if missing:
        print(f"  ⚠ {len(missing)} assets still missing: {sorted(missing)}")

    if compile_assets():
        print("\n" + "=" * 60)
        print("✓ Rebuild complete!")
        print(f"  .xcassets : {XCASSETS_DIR}")
        print(f"  Assets.car: {OUTPUT_DIR}/Assets.car")
        print(f"  Installed : {PREBUILT_CAR}")
        print("=" * 60)
        return 0
    return 1


if __name__ == "__main__":
    exit(main())
