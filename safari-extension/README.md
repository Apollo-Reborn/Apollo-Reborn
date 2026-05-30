# Safari extension overlay

These files repair Apollo's bundled "Open in Apollo" Safari Web Extension
(`Apollofari.appex`). They are copied **over** the originals inside the appex at
IPA-package time by [`scripts/fix-safari-extension.sh`](../scripts/fix-safari-extension.sh),
which is invoked from [`scripts/build_release_variants.sh`](../scripts/build_release_variants.sh)
for the extension-bearing variants. (The Apollo-Reborn tweak dylib can't touch
the extension at runtime — it runs in Safari's separate process — so the fix
ships as a static asset overlay.)

## What was broken

The stock `content.js` defaulted to "Automatic" mode, which redirected to
`https://openinapollo.com` instead of `apollo://`. That page's auto-open relies
on an iOS Smart App Banner bound to the **App Store** Apollo (app id
`979274575`); a sideloaded build is not that app, so the banner never fired and
users were stranded on the interstitial. The stock `manifest.json` also
referenced a `background.js` that doesn't exist in the bundle, and `content.js`
used the deprecated `DOMNodeInserted` event and mishandled `/s/` share links.

## What these files change

- **`content.js`** — redirects directly to `apollo://reddit.com<path><query>`
  (the JS mirror of `ApolloURLByConvertingResolvedURLToApolloScheme` in
  `src/ApolloCommon.m`), so all link shapes including `/s/` share links work.
  Replaces `DOMNodeInserted` with a `MutationObserver` + `popstate` listener.
  Still honors the popup's `automaticObj.isAutomatic` preference.
- **`manifest.json`** — drops the dangling `background.js` reference. Stays on
  Manifest V2 (Safari supports it).

`popup.html`, `popup.js`, `popup.css`, icons, and `_locales` are left untouched
(the overlay script doesn't replace them).
