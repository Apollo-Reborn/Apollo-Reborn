# Liquid Glass

Everything related to the iOS 26 Liquid Glass patch lives here:

```
liquid-glass/
├── icons.json                 # single source of truth — add new icons here
├── icons/<id>/
│   ├── <id>.icon/             # Icon Composer package, input to actool
│   ├── default.png            # in-app picker preview — light mode
│   ├── dark.png               #                          dark mode
│   ├── clear-light.png        #                          clear light
│   └── clear-dark.png         #                          clear dark
├── prebuilt/
│   ├── Assets.car             # pre-built asset catalog injected by patch.sh
│   └── asset-info.plist       # reference metadata for the catalog
├── scripts/
│   ├── rebuild_assets.py      # rebuilds prebuilt/Assets.car from a fresh Apollo Assets.car
│   └── generate_previews_header.py
└── generated/
    └── LiquidGlassIconPreviews.gen.h   # base64 PNG blob + LGIconRows + primary icon
```

The Liquid Glass runtime patches live in `ApolloLiquidGlass.xm` and
`ApolloLiquidGlassIconPicker.xm` at the repo root, alongside the other
`Apollo*.xm` modules.

## Bundled icons

| Icon | Default | Dark | Clear Light | Clear Dark |
|---|---|---|---|---|
| **iGerman00**  | ![](icons/igerman00/default.png)  | ![](icons/igerman00/dark.png)  | ![](icons/igerman00/clear-light.png)  | ![](icons/igerman00/clear-dark.png)  |
| **jryng**      | ![](icons/jryng/default.png)      | ![](icons/jryng/dark.png)      | ![](icons/jryng/clear-light.png)      | ![](icons/jryng/clear-dark.png)      |
| **jryng (alt)**| ![](icons/jryng-alt/default.png)  | ![](icons/jryng-alt/dark.png)  | ![](icons/jryng-alt/clear-light.png)  | ![](icons/jryng-alt/clear-dark.png)  |
| **metalnakls** | ![](icons/metalnakls/default.png) | ![](icons/metalnakls/dark.png) | ![](icons/metalnakls/clear-light.png) | ![](icons/metalnakls/clear-dark.png) |

## Adding a new icon

1. Design it in **[Icon Composer](https://developer.apple.com/icon-composer/)** and export the `.icon` package.
2. Create the per-icon directory and drop in the package and four preview PNGs:
   ```
   liquid-glass/icons/<id>/<id>.icon/        # paste the .icon package here
   liquid-glass/icons/<id>/default.png       # 300×300 light-mode preview
   liquid-glass/icons/<id>/dark.png          # dark mode
   liquid-glass/icons/<id>/clear-light.png   # clear light
   liquid-glass/icons/<id>/clear-dark.png    # clear dark
   ```
3. Append the icon to **`liquid-glass/icons.json`** (this is the only registration step — the generated header, the icon picker, and `patch.sh` all read from this file).
4. Regenerate the preview header and rebuild the asset catalog:
   ```bash
   # From the repo root
   make lg-previews

   # Rebuild prebuilt/Assets.car (requires a decrypted Apollo Assets.car — see below)
   python3 liquid-glass/scripts/rebuild_assets.py
   ```
5. Commit the new `.icon` package, preview PNGs, regenerated
   `generated/LiquidGlassIconPreviews.gen.h`, and updated
   `prebuilt/Assets.car`.

## Rebuilding `prebuilt/Assets.car`

The pre-built catalog is what `patch.sh --liquid-glass` injects into the
final IPA. It bundles Apollo's original assets plus the Liquid Glass
`.icon` packages registered above.

### Prerequisites

- **Xcode Command Line Tools** — provides `assetutil` and `xcrun actool`
- **[cartool](https://github.com/showxu/cartools)** — must be on your `PATH` ([binary release](https://github.com/showxu/cartools/releases/download/1.0.0-alpha/cartool-1.0.0-alpha.bigsur.bottle.tar.gz))
- **[Asset Catalog Tinkerer](https://github.com/insidegui/AssetCatalogTinkerer)** — installed at `/Applications/Asset Catalog Tinkerer.app`
- **Python 3**

### Run

```bash
# Extract Assets.car from a decrypted Apollo IPA
unzip Apollo.ipa -d Apollo-extracted
cp Apollo-extracted/Payload/Apollo.app/Assets.car liquid-glass/Assets.car

# Rebuild — output goes to liquid-glass/prebuilt/Assets.car
python3 liquid-glass/scripts/rebuild_assets.py
```

The script:

1. Reads metadata from `liquid-glass/Assets.car` via `assetutil -I`.
2. Extracts vector PDFs with `cartool` and symbol SVGs with `act`.
3. Synthesises an `.xcassets` bundle preserving every original asset.
4. Invokes `actool` with each `.icon` package listed in `icons.json` and
   writes the result to `liquid-glass/prebuilt/Assets.car`.
