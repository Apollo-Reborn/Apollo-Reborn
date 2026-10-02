# Pal Home

Pal Home is an opt-in replacement for Apollo's Pixel Pals: a full-screen,
Animal Crossing-style pixel-art home for every Pal, with Apollo's care
(feeding, playing, hearts, stats) on the same data.

**Opt-in** (Apollo Reborn → Features → Pal Home → Use Pal Home, default off).
Off ("Classic"), Apollo's own care sheet and chooser are untouched apart from
an occasional "Try Pal Home" card (`ApolloPalHomePrompt`; at most daily, never
after ×). On, tapping the Pal on the Dynamic Island and Settings → Pixel Pals
open Pal Home. Turning it off runs `-returnToClassic`: a Reborn Pal on the
island goes home with its progress, the borrowed slot is returned, and one of
Apollo's own Pals takes the island; homes and adopted Pals are kept.

Everything on screen is procedural pixel art drawn at runtime at true art
resolution (one unit = one art pixel) and shown with nearest-neighbour scaling.
Nothing is bundled: art, chiptunes and ambience are all generated. Titles,
names and buttons use a built-in pixel font; longer body copy uses a small
rounded system font (`ApolloPixelLabel.smooth`) so it stays easy to read.

## Files

| File | Purpose |
|------|---------|
| `ApolloPixelCanvas` | Tiny RGBA painter (rects, ellipses, Bayer dithering, outlines), pixel font, PRNG, CGImage export |
| `ApolloPalHomeCatalog` | Item/surface specs, room geometry, the moving-in starter room |
| `ApolloPalHomeFurniture` / `WallItems` / `Surfaces` | The catalogue's draw blocks |
| `ApolloPalHomeStyles` / `ThemedItems` | Home styles (shell trim, outside backdrop, ambient tint, template room) and their pieces |
| `ApolloPalHomeRenderer` | Placement/validation (`APRoomLayout`), room shell, baked dithered lightmap, fire frames, thumbnails, icons |
| `ApolloPalHomeChrome` | UI materials per style (wood, stone, metal, bark, driftwood), signs, hearts |
| `ApolloPalHomeScene` | SpriteKit room: animations, Pal behaviour/pathfinding, furniture reactions, moving-in day, drag editing |
| `ApolloPalHomePixelUI` / `Drawer` / `Wardrobe` | Pixel buttons/labels/panels, the decorating drawer, the Pal card |
| `ApolloPalHomeShelter` / `ShelterView` | The daily adoption roster and its screens |
| `ApolloPalHomeViewController` | Full-screen host: hides nav/tab bars, toolbar, care, toasts |
| `ApolloPalHomeStore` | Persistence, residents, care rules, the island channel, Apollo's native data |
| `ApolloPalSpecies` | Reborn's species table (Apollo's 16 + Reborn species) |
| `ApolloRebornPalSprites` | Sprite sheets for Reborn species (the capybara), in Apollo's sheet format |
| `ApolloPixelPalCoats` | Coat colours (palette-role sprite recolouring) |
| `ApolloPalHomeAmbience` / `Chiptune` | Live room sound and chiptune stings |
| `ApolloPalHomeHaptics` | One haptic vocabulary for every interaction |
| `ApolloPalHomeWidgetRenderer` | The Pal Home widget's code and renderer (see `widgets/WIDGETS.md`) |

Everything except the scene, UI, view controller, ambience and haptics is
Foundation/CoreGraphics only, so the host-side tests and the render harness run
on a Mac.

## The room

- 8 × 7 floor grid of 16px tiles, a back wall of 8 × 3 hanging slots, and a
  trim rail for garlands. Some floor pieces need the back wall (fireplace,
  bookshelf). Rugs sit under furniture; nothing else overlaps within a layer.
- Items declare lights; the renderer bakes them with the time-of-day ambient
  light into an ordered-dithered lightmap. Emissive layers (flames, lit
  shades, sky, neon) aren't darkened. Windows follow the local hour.
- Items declare animations (`APAnim`): fire, embers, candles, fairy bulbs,
  steam, window weather, pendulums, neon, music notes, bubbles, fireflies.
- Adding a piece means registering one `APSpec` with a draw block. Variants
  are palette swaps. Everything in the catalogue is available from the start.

**Styles**: Cosy Cottage, Castle Keep, Grand Library, Space Station, Wild West
Saloon, Treehouse, Under the Sea. A style repaints the shell, the world outside
and the UI material. Picking one (Decorate → Styles) asks how: **Furnished**
(its template room), **Bare room** (its walls and floor only) or **Keep my
things** (its walls and floor around your furniture); all with Undo. **Fresh**
resets to moving-in day. The drawer keeps your place in a list as you pick.

**Outside decorate mode** tapping furniture does things: lamps and fires
toggle, the cottage window's curtains open and close (closed blocks the
daylight), seats call the Pal up, pet beds send it for a nap, the bowls feed it
and the yarn basket starts a game (same rules as the toolbar), the moving boxes
unpack, and everything else wobbles. Tapping the floor calls the Pal over;
tapping the Pal pets it.

## A home for every Pal, and moving-in day

- `document.rooms[residentID]` is each Pal's own room; `store.room` is the
  active Pal's. Switching Pals switches homes.
- Migration: the single room older versions saved (`document.room`) becomes the
  home of whoever is active the first time this version runs (`roomOwner`).
  `document.room` keeps mirroring the last-saved room for older builds.
- A Pal with no room yet gets moving-in day (`-playMovingInDay:`): bare walls,
  one window and moving boxes; the boxes thump down in dust, a "Moving Day!"
  sign swings in to a chiptune, and the Pal hops in. Tap to skip.
  `document.movedIn` remembers who has seen it.

## Residents and species

Apollo's species are a closed Swift enum (`Apollo.PixelPal`: 16 no-payload
cases in one byte; Optional's `nil` is tag 16 and the switch jump tables have
no bounds check), so it is never extended. Instead:

- **`ApolloPalSpecies`** is Reborn's species table, keyed by string ids. The
  first 16 entries mirror Apollo's cases; Reborn species (`capybara`) have none.
  Unknown ids round-trip untouched.
- **Residents** have ids. `apollo.<species>` are Apollo's own Pals (stats in
  `PixelPalsDatabase`); `pal.<uuid>` are Reborn's (stats in the Pal Home
  document): any species, any number.
- **The island channel**: an active Reborn resident borrows a spare Apollo slot
  (otter, platypus, hedgehog…; never superAI or species with extra sheets).
  Its name and stats go into that slot's native record, `ActivePixelPal` points
  at it, the sprite hook draws the resident there, and the pill's
  `FauxCutOutView.nameTag` title is swapped ("the capybara"). Switching away
  (here, or via Apollo's own chooser, `reconcileIsland`) copies hearts and
  distance back and restores the slot exactly (stashed if it was taken).
- **The shelter** (`ApolloPalHomeShelter`): a daily roster of 8 (Reborn species
  always featured) with a coat (fixed for life), a silly name, gender, age,
  personality and quirk. Personalities steer the idle brain.
- **Visiting**: the household strip visits a Pal's home without changing the
  island; their room and care (`feedResident:`, `saveRoom:forResident:`…) are
  their own. "Put on the island" on the Pal card makes them the island Pal.
- **Goodbyes**: the Pal card's wave button rehomes a Pal (with a confirmation):
  they walk out the front to a loving new family, taking their room, stats and
  Apollo record (a borrowed slot is returned first). Never your only Pal.
  The last 12 are archived (`document.rehomed`); the shelter's "Coming home?"
  welcomes them back with their room and stats.
- **Capybaras**: petting drops a yuzu on its head (up to three, "perfectly
  balanced"); they tumble off when it moves.

## Care: Apollo's rules on Apollo's data

Reproduced from the binary (Hopper; 3.x addresses), always written to the
active Pal's native record (a guest's borrowed slot), so the island and Pal
Home never disagree:

| What | Rule | In Pal Home |
|---|---|---|
| Food | earned while browsing, ≤ 1/hour by chance (`sub_10074bb24`) into `foodTokens` | Apollo keeps awarding; the Feed button shows the pantry |
| Feed | −1 food, +¼ heart, weight + uniform(0.4, 2.2) × species factor, `lastTimeFed`; 5 h cooldown (`sub_10004fd34`, `sub_1007e9088`) | Feed button / bowls; the Pal eats its own snack |
| Play | +¼ heart, `lastTimePlayedWith`; 5 h cooldown (`sub_100052e4c`, `sub_1007e8f08`) | the yarn (always fun, earns hearts per the rule) |
| Stats | hearts 0–6 (½ steps shown), age, weight, distance scrolled | sign and Pal card |
| Enable Pixel Pals | `PixelPalsEnabled` | island button on the Pal card |

## Apollo hooks (`src/ApolloPixelPals.xm`)

1. **Sprites**: `+[SKTexture textureWithImageNamed:]` and `+[UIImage
   imageNamed:]` answer `<species>-<action>` names with the coat recolour, or
   with the Reborn guest drawn into its borrowed slot. Pal Home loads its own
   sprites through `APPalCreateSheetForUI` (not hooked).
2. **Entrances** (only while Pal Home is on): island taps (`pixelPalTapped…`,
   `dogBarked…`) push Pal Home on the current tab; pushing
   `PixelPalChooserViewController` pushes Pal Home instead. Always: the
   `pal-home-settings` screen and the `pal-home` route (deep link
   `apollo://reborn/settings/pal-home`, used by the widget). In Classic the
   chooser and care sheet show the "Try Pal Home" card.
3. **Reconciling**: `PixelPalSettingChanged` / app activation settle the island
   channel; Pal Home posts `PixelPalSettingChanged` after native writes so the
   island reloads live.

The island geometry hooks (#826/#1244) and the freeze guard (#305) in the same
file are independent of Pal Home.

## Persistence

`ApolloPalHomeStore` owns the versioned `ApolloRebornPalHome` document in
standard defaults (in settings backups): `rooms`, `residents` (profiles and
Reborn stats), `active`, `channel`, `movedIn`, `shelterSeen`. Visiting writes
nothing until something changes. Unknown fields, residents and room items
round-trip; an unsupported schema is shown read-only. Native writes edit one
record in place, keeping the database's shape, order and unknown fields.

## Sound, haptics, accessibility

- `ApolloPalHomeAmbience` synthesises the room (fire, rain, wind, clocks,
  music box, hum, crickets, bubbles) and plays chiptune stings (moving day,
  unpack, yum, heart, adopt). Ambient category: mixes with other audio, follows
  the silent switch; the speaker button turns it off.
- `ApolloPalHomeHaptics`: taps, toggles, placing, thumps, a Core Haptics purr
  when petting, bites when eating, a heart "ding"; follows system settings.
- Controls are labelled; the room has a spoken description and Pet/Play/Nap
  actions; the selected piece has move actions. Reduce Motion stills the room.
  30 fps (15 in Low Power Mode), paused when hidden.

## Verification

- `sh tests/run_pal_home_store_tests.sh`: persistence, residents, the island
  channel, care rules, per-Pal rooms and migration, forward compatibility.
- `sh tests/run_pal_home_layout_tests.sh`: placement rules, hostile documents,
  every item × variant × on/off × day/night, every style, Pal codes, widget
  sizes (ASan + UBSan).
- `sh tests/run_pal_home_render.sh [dir]`: PNG previews for art review
  (`PAL_SPRITES=<dir>` adds widgets).
- Sim: `SIMCTL_CHILD_APOLLO_OPEN_ROUTE=pal-home scripts/run-in-sim.sh --widgets`.

## Next ideas

Photo → pixel painting, a subreddit "feed frame" wall item, more Reborn
species, a wand play game, lock-screen widgets.
