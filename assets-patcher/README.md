# Assets Patcher

Rebuilds Apollo's `Assets.car` (compiled asset catalog) to inject iOS 26 Liquid Glass alternate app icons while faithfully preserving all original assets.

The output replaces `patch-assets/liquid-glass/ApolloLiquidGlass/Assets.car`, which `patch.sh` copies into the IPA when the `--liquid-glass` flag is passed.

## Prerequisites

- **Xcode Command Line Tools** — provides `assetutil` and `xcrun actool`
- **[cartool](https://github.com/showxu/cartools)** — must be on your `PATH` (download binary [here](https://github.com/showxu/cartools/releases/download/1.0.0-alpha/cartool-1.0.0-alpha.bigsur.bottle.tar.gz))
- **[Asset Catalog Tinkerer](https://github.com/insidegui/AssetCatalogTinkerer)** — must be installed at `/Applications/Asset Catalog Tinkerer.app`
- **Python 3**

## Setup

Copy `Assets.car` from a decrypted Apollo IPA into this directory:

```bash
# Extract from a decrypted IPA
unzip Apollo.ipa -d Apollo-extracted
cp Apollo-extracted/Payload/Apollo.app/Assets.car assets-patcher/Assets.car
```

## Running

From this directory:

```bash
python3 rebuild_assets.py
```

This extracts the asset catalog, adds the icons, and rebuilds it into `rebuilt/compiled/Assets.car`. Copy the result into the patch directory:

```bash
cp rebuilt/compiled/Assets.car ../patch-assets/liquid-glass/ApolloLiquidGlass/Assets.car
```

## Adding a new icon

### 1. Create the `.icon` package

Design the icon in **[Icon Composer](https://developer.apple.com/icon-composer/)**, then export it as a `.icon` package. Place the exported package in the `icons/` directory.

### 2. Add preview images

Create `../Resources/LiquidGlassIconPreviews/<iconID>/` with four PNGs:

| Filename | Appearance |
|----------|-----------|
| `default.png` | Light mode |
| `dark.png` | Dark mode |
| `clear-light.png` | Clear light |
| `clear-dark.png` | Clear dark |

These are rendered at 300×300 and shown in the in-app icon picker row.

### 3. Register the icon ID in three places

**`../Resources/LiquidGlassIconPreviews/generate_header.py`** — add to the `ICONS` list:

```python
ICONS = ["jryng", "jryng-alt", "igerman00", "metalnakls", "<iconID>"]
```

**`../ApolloLiquidGlassIconPicker.xm`** — add a row to `LGIconRows`:

```objc
static const LGIconRow rows[] = {
    { @"igerman00",  @"iGerman00" },
    { @"jryng",      @"jryng" },
    { @"jryng-alt",  @"jryng (alt)" },
    { @"metalnakls", @"metalnakls" },
    { @"<iconID>",   @"Display Name" },
};
```

**`../patch.sh`** — add to `LIQUID_GLASS_ALTERNATE_ICONS`:

```bash
LIQUID_GLASS_ALTERNATE_ICONS=("jryng" "jryng-alt" "igerman00" "metalnakls" "<iconID>")
```

### 4. Regenerate the preview header and run the patcher

```bash
# From the repo root
make lg-previews

# From this directory
python3 rebuild_assets.py
cp rebuilt/compiled/Assets.car ../patch-assets/liquid-glass/ApolloLiquidGlass/Assets.car
```

Commit the updated `Assets.car`, `LiquidGlassIconPreviews.gen.h`, and the new `.icon` package.
