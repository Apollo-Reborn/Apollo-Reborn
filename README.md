# Apollo-ImprovedCustomApi (v2)
[![Build and release](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/actions/workflows/buildapp.yml/badge.svg)](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/actions/workflows/buildapp.yml) ![GitHub Release](https://img.shields.io/github/v/release/JeffreyCA/Apollo-ImprovedCustomApi)

iOS tweak for [Apollo for Reddit app](https://apolloapp.io/) that lets you continue using Apollo with your own API keys after its shutdown in June 2023. The tweak also unlocks several Ultra features and includes several enhancements and fixes.

| | | |
|:--:|:--:|:--:|
| <img src="img/settings.jpg" alt="Settings" width="250"> | <img src="img/custom.jpg" alt="Custom API Settings" width="250"> | <img src="img/recents.jpg" alt="Recently Read" width="250"> |

## Features

### General

- Use Apollo with your own Reddit and Imgur API keys ([don't have one?](#dont-have-an-api-key))
- Fully working Imgur integration
- Native Reddit media upload support (images, albums, and videos)
- Liquid Glass icons and UI enhancements for iOS 26+
- Reddit `/s/` share links support
- Pixel Pals support on newer iPhone models
- Image viewer and video playback fixes and enhancements
- Proxy Imgur images through DuckDuckGo for regional blocks
- Deep linking support for Steam, YouTube Shorts
- Auto-collapse pinned comments

### Unlocked Ultra Features and Easter Eggs

- New Comments Highlightifier
- Saved Categories
- App Icons + Wallpapers (Community Icon Pack, SPCA Animals, Ultra Icons, "sekrit" app icons)
- Pixel Pals (including hidden "Artificial Superintelligence")
- Themes (including hidden "Chumbus" theme)

### New Features

- **Backup & Restore**: Export and import Apollo and tweak settings as a .zip
- **Custom Subreddit Sources**: Use external URLs for random and trending subreddits
- **Recently Read Posts**: View all recently read posts from the Profile tab
- **Editable Saved Categories**: Add, rename, and delete saved post categories (Settings > Saved Categories)
- **Bulk in-place translation**: Translate posts and comments in-place with configurable provider and target language (Settings > Translation)
- **Tap timestamp for creation date**: Tap a comment or post's relative-time label to see the absolute creation date and time
- **Tag Filters**: Blur NSFW and/or Spoiler posts (including titles) in feeds, with per-subreddit overrides (Settings > Tag Filters)
- **Inline Media Previews**: Render images, GIFs, videos, and Imgur albums inline within posts and comments (Settings > Custom API > Media > Inline Media Previews)
- **User Profile Pictures**: Show Reddit user avatars next to usernames in feeds, comments, and user profiles (Settings > Custom API > Media > Show User Profile Pictures)

## Known Issues

- Long-tapping share links open in the in-app browser

## Safari integration

I recommend using the [Open-In-Apollo](https://github.com/AnthonyGress/Open-In-Apollo) userscript to automatically open Reddit links in Apollo.

## Looking for IPA?

One source where you can get the fully tweaked IPA is [Balackburn/Apollo](https://github.com/Balackburn/Apollo).

## Don't have an API key?

> [!IMPORTANT]
> Reddit and Imgur no longer allow new API key creation so you'll need to share or use existing keys.

See [this guide](https://github.com/wchill/patcheddit?tab=readme-ov-file#what-if-i-dont-have-a-client-id) for workarounds (proceed at your own risk).

When using credentials from another app, set the **Reddit API Key** (OAuth client ID), **Redirect URI**, and **User Agent** in the tweak settings to match the app's values. You'll also need to register the redirect URI scheme in the IPA (see [below](#custom-redirect-uri)).

More discussion in [#82](https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/issues/82).

## Custom Redirect URI

The redirect URI scheme (the part before `://`) must be registered in the Apollo IPA's `Info.plist` under `CFBundleURLTypes`, otherwise the OAuth callback won't return to Apollo. Add your scheme with [`patch.sh`](#patching-ipa) or the **Patch IPA** GitHub Action:

```bash
./patch.sh Apollo.ipa --url-schemes custom
```

Resulting `Info.plist` entry:

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array>
      <string>twitterkit-xyz</string>
      <string>apollo</string>
      <string>custom</string> <!-- enables custom://reddit-oauth -->
    </array>
  </dict>
</array>
```

## Patching IPA

`patch.sh` and the **Patch IPA** GitHub Action apply optional patches to a stock Apollo IPA. They do **not** inject the tweak - use [Sideloadly](#sideloadly) or [`build-ipa.sh`](#build-injected-ipa-locally) for that.

```bash
./patch.sh <path_to_ipa> [--liquid-glass] [--url-schemes <schemes>] [--remove-code-signature] [-o <output>]
```

Available patches:

- **`--liquid-glass`** - enables the iOS 26 Liquid Glass UI and installs a pack of Liquid Glass icons that can be switched between in the tweak's in-app icon picker.
- **`--url-schemes <list>`** - adds comma-separated URL schemes to `CFBundleURLTypes` (see [Custom Redirect URI](#custom-redirect-uri)).
- **`--remove-code-signature`** - strips the existing code signature.

To run via GitHub Actions, fork this repo and trigger **Actions** > **Patch IPA**. The IPA source can be a direct URL or a release artifact from your fork.

## Sideloadly

Recommended configuration:

- **Use automatic bundle ID**: unchecked (e.g. `com.foo.Apollo`)
- **Signing Mode**: Apple ID Sideload
- **Inject dylibs/frameworks**: checked - add the `.deb` via **+dylib/deb/bundle**
  - **Cydia Substrate**: checked
  - **Substitute** / **Sideload Spoofer**: unchecked

## Build Injected IPA Locally

`build-ipa.sh` builds the tweak `.deb` and injects it into a stock Apollo IPA. Requires `azule` or `cyan` installed locally; signing/sideloading is still handled by your preferred signer.

```bash
make package
./build-ipa.sh --ipa ./Apollo.ipa [--deb ./packages/<tweak>.deb] [-o ./packages/Apollo-Tweaked.ipa]
```

## Build

**Requirements:**
- [Theos](https://github.com/theos/theos)

**Instructions:**
1. `git clone https://github.com/JeffreyCA/Apollo-ImprovedCustomApi`
2. `cd Apollo-ImprovedCustomApi`
3. `git submodule update --init --recursive`
4. `make package` or `make package THEOS_PACKAGE_SCHEME=rootless` for rootless variant

## Contributors ✨

Thank you to these wonderful people:

<!-- CONTRIBUTORS-LIST:START - Generated by .github/skills/update-contributors/generate-readme-contributors.py -->

### Code Contributors

<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/JeffreyCA"><img src="https://avatars.githubusercontent.com/u/9157833?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="JeffreyCA"/><br /><sub><b>JeffreyCA</b></sub></a><br /><a href="#maintainer-JeffreyCA" title="Maintainer">Maintainer</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/EthanArbuckle"><img src="https://avatars.githubusercontent.com/u/4250718?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="EthanArbuckle"/><br /><sub><b>EthanArbuckle</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=EthanArbuckle" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/icpryde"><img src="https://avatars.githubusercontent.com/u/29389746?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="icpryde"/><br /><sub><b>icpryde</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=icpryde" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/jordanearle"><img src="https://avatars.githubusercontent.com/u/1413231?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="jordanearle"/><br /><sub><b>jordanearle</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=jordanearle" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/iCrazeiOS"><img src="https://avatars.githubusercontent.com/u/39101269?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="iCrazeiOS"/><br /><sub><b>iCrazeiOS</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=iCrazeiOS" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/hllvc"><img src="https://avatars.githubusercontent.com/u/10849058?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="hllvc"/><br /><sub><b>hllvc</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=hllvc" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/DeltAndy123"><img src="https://avatars.githubusercontent.com/u/105518328?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="DeltAndy123"/><br /><sub><b>DeltAndy123</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=DeltAndy123" title="Code">Code</a></td>
    </tr>
    <tr>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/yodaluca23"><img src="https://avatars.githubusercontent.com/u/67206487?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="yodaluca23"/><br /><sub><b>yodaluca23</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=yodaluca23" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/ep0chzero"><img src="https://avatars.githubusercontent.com/u/79633135?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="ep0chzero"/><br /><sub><b>ep0chzero</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=ep0chzero" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/mmshivesh"><img src="https://avatars.githubusercontent.com/u/23611514?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="mmshivesh"/><br /><sub><b>mmshivesh</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=mmshivesh" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/Uranosphaerite"><img src="https://avatars.githubusercontent.com/u/258388038?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="Uranosphaerite"/><br /><sub><b>Uranosphaerite</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=Uranosphaerite" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/wdeezy"><img src="https://avatars.githubusercontent.com/u/188708293?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="wdeezy"/><br /><sub><b>wdeezy</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=wdeezy" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/ryannair05"><img src="https://avatars.githubusercontent.com/u/23365226?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="ryannair05"/><br /><sub><b>ryannair05</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=ryannair05" title="Code">Code</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/ichitaso"><img src="https://avatars.githubusercontent.com/u/980215?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="ichitaso"/><br /><sub><b>ichitaso</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-CustomApiCredentialsPlus/commits?author=ichitaso" title="Code">Code</a></td>
    </tr>
  </tbody>
</table>

### Icon & Design Contributors

<table>
  <tbody>
    <tr>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/iGerman00"><img src="https://avatars.githubusercontent.com/u/36676880?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="iGerman00"/><br /><sub><b>iGerman00</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/jryng"><img src="https://avatars.githubusercontent.com/u/16271550?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="jryng"/><br /><sub><b>jryng</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://github.com/metalnakls"><img src="https://avatars.githubusercontent.com/u/15786688?v=4&amp;s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="metalnakls"/><br /><sub><b>metalnakls</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
      <td align="center" valign="top" width="14.29%"><a href="https://www.reddit.com/user/harunatsu91202024/"><img src="https://i.redd.it/snoovatar/avatars/ef90ed21-4a24-4a78-b535-848d4efc6378.png?s=100" width="100px;" height="100px;" style="object-fit: cover;" alt="harumatsu"/><br /><sub><b>harumatsu</b></sub></a><br /><a href="https://github.com/JeffreyCA/Apollo-ImprovedCustomApi/tree/main/liquid-glass#bundled-icons" title="Icon and design">Design</a></td>
    </tr>
  </tbody>
</table>

<!-- CONTRIBUTORS-LIST:END -->
