#!/usr/bin/env python3
"""Generate LiquidGlassIconPreviews.gen.h from icons.json.

Groups are defined in icons.json under the top-level "groups" key:

  "groups": [
    { "id": "original", "title": "Original",
      "coverIconIDs": ["igerman00", "jryng"], "description": "..." },
    { "id": "helios",   "title": "Helios" }
  ]

Every icon must belong either to one Liquid Glass "group" or to a supported
native-style pack through "standardPack". Standard-pack icons are compiled
into Assets.car and emitted separately for their owning picker, so they never
appear in Liquid Glass pack grids or the Daily Spotlight rotation.
The generator emits one per-group entry array and a kLGIconGroups[]
descriptor table that the picker reads at runtime — no source changes are
needed to add, rename, or reorder groups.

Per-group optional fields:

  "coverIconIDs" — ordered icon IDs to sample for that pack's fan artwork
                    on the main screen. Falls back at runtime to the first
                    few icons in the group if omitted or if none of the
                    listed IDs are registered on a given IPA.
  "description"  — short sentence shown as a header above the pack's icon
                    grid.

Pack-level authors are intentionally unsupported. Credits belong on each icon
through its "designer" field, where they remain visible inside the pack. The
picker selects its daily Featured icons from these generated group entries at
runtime, so Featured choices require no separate registry field.

Optional top-level "seasons" give the Daily Spotlight a holiday lean:

  "seasons": [
    { "id": "halloween", "title": "Halloween", "start": "10-01", "end": "10-31",
      "iconIDs": ["witching-hour"], "colorMatchIconIDs": ["LG-andru"] }
  ]

  "start"/"end"      — inclusive MM-DD window in one calendar year (no wrap
                       past Dec 31). Windows may not overlap.
  "iconIDs"          — icons made for the holiday; featured first.
  "colorMatchIconIDs"— icons that only share the holiday's colors; they fill
                       any seasonal slots the made-for icons leave open.

Seasons may list Liquid Glass "group" icons, the tweak's "standardPack"
additions, and Apollo's own icons described under top-level "nativeIcons":

  "nativeIcons": [
    { "id": "santapollo", "displayName": "Santapollo", "designer": "Matthew Skiles",
      "standardPack": "ultra", "nativeRow": 37 }
  ]

  "id"           — Apollo's alternate icon name (CFBundleAlternateIcons key).
  "standardPack" — originals | community | ultra | sekrit.
  "nativeRow"    — the icon's row in Apollo 1.15.11's own list for that pack
                   (Ultra rows don't count the tweak's inserted sequels). The
                   picker saves it as the selected Standard row, so the pack
                   shows the right checkmark after a Spotlight tap.

Standard-pack and native icons are holiday-only: they never join the everyday
rotation. The runtime claims 1–3 of the five Spotlight slots for the active
season, rising as the window's end date approaches.

Preview images are NOT embedded here. They are compiled as named imagesets
into the app's Assets.car by rebuild_assets.py and loaded at runtime via
[UIImage imageNamed:@"lg-preview-{iconID}-{variant}"].
"""
from __future__ import annotations

import datetime
import json
import os
import re
import sys


# Standard packs a "nativeIcons" entry can belong to (LGStandardPack in the picker).
NATIVE_STANDARD_PACKS = {"originals", "community", "ultra", "sekrit"}


def escape(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"')


def c_id(s: str) -> str:
    """Convert an arbitrary string to a valid C identifier fragment."""
    return re.sub(r"[^a-zA-Z0-9_]", "_", s)


def load_registry(lg_dir: str) -> dict:
    path = os.path.join(lg_dir, "icons.json")
    with open(path) as fp:
        registry = json.load(fp)
    if "icons" not in registry or "primaryIconID" not in registry:
        print(f"invalid registry at {path}", file=sys.stderr)
        sys.exit(1)
    return registry


def write_string_array(fp, name: str, values: list[str]) -> str:
    """Writes a C string array when non-empty; returns its name or NULL."""
    if not values:
        return "NULL"
    fp.write(f"static const char *const {name}[] = {{\n")
    for value in values:
        fp.write(f'    "{escape(value)}",\n')
    fp.write("};\n\n")
    return name


def write_native_icons(fp, natives: list[dict]) -> None:
    fp.write("// Apollo's own icons that seasons can feature (icons.json \"nativeIcons\").\n")
    fp.write("// nativeRow is the icon's row in Apollo 1.15.11's list for standardPack.\n")
    fp.write("typedef struct {\n")
    fp.write("    const char *iconID;\n")
    fp.write("    const char *displayName;\n")
    fp.write("    const char *designer;\n")
    fp.write("    const char *standardPack;\n")
    fp.write("    int         nativeRow;\n")
    fp.write("} LGNativeIconEntry;\n\n")
    fp.write("static const LGNativeIconEntry kLGNativeIcons[] = {\n")
    for native in natives:
        fp.write(f'    {{ "{escape(native["id"])}", "{escape(native["displayName"])}", '
                 f'"{escape(native["designer"])}", "{native["standardPack"]}", {native["nativeRow"]} }},\n')
    if not natives:
        # Zero-length arrays are not standard C/C++; keep one inert row.
        fp.write("    { NULL, NULL, NULL, NULL, 0 },\n")
    fp.write("};\n")
    fp.write(f"static const size_t kLGNativeIconCount = {len(natives)};\n\n")


def parse_native_icons(raw_natives, taken_ids: set[str]):
    """Validates icons.json "nativeIcons"; returns normalized dicts or None."""
    if not isinstance(raw_natives, list):
        print('error: "nativeIcons" must be a list', file=sys.stderr)
        return None
    natives: list[dict] = []
    seen: set[str] = set()
    for raw in raw_natives:
        icon_id = raw.get("id") if isinstance(raw, dict) else None
        if not isinstance(icon_id, str) or not icon_id or icon_id in seen or icon_id in taken_ids:
            print(f"error: native icon {raw!r} needs an \"id\" not used by any other icon",
                  file=sys.stderr)
            return None
        seen.add(icon_id)
        display_name = raw.get("displayName")
        designer = raw.get("designer", "")
        pack = raw.get("standardPack")
        native_row = raw.get("nativeRow")
        if not isinstance(display_name, str) or not display_name.strip() or not isinstance(designer, str):
            print(f'error: native icon "{icon_id}" needs a "displayName" (and a string "designer")',
                  file=sys.stderr)
            return None
        if pack not in NATIVE_STANDARD_PACKS:
            print(f'error: native icon "{icon_id}" has invalid "standardPack" {pack!r}; must be one '
                  f'of {sorted(NATIVE_STANDARD_PACKS)}', file=sys.stderr)
            return None
        if isinstance(native_row, bool) or not isinstance(native_row, int) or native_row < 0:
            print(f'error: native icon "{icon_id}" needs a nonnegative integer "nativeRow"',
                  file=sys.stderr)
            return None
        for other in natives:
            if other["standardPack"] == pack and other["nativeRow"] == native_row:
                print(f'error: native icons "{other["id"]}" and "{icon_id}" share {pack} row '
                      f'{native_row}', file=sys.stderr)
                return None
        natives.append({"id": icon_id, "displayName": display_name, "designer": designer,
                        "standardPack": pack, "nativeRow": native_row})
    return natives


def write_seasons(fp, seasons: list[dict]) -> None:
    fp.write("// Daily Spotlight seasons (icons.json \"seasons\"). Windows are inclusive\n")
    fp.write("// Gregorian month/day ranges within one year and never overlap.\n")
    fp.write("typedef struct {\n")
    fp.write("    const char        *seasonID;\n")
    fp.write("    const char        *title;\n")
    fp.write("    int                startMonth;\n")
    fp.write("    int                startDay;\n")
    fp.write("    int                endMonth;\n")
    fp.write("    int                endDay;\n")
    fp.write("    const char *const *iconIDs;\n")
    fp.write("    size_t             iconIDCount;\n")
    fp.write("    const char *const *colorMatchIconIDs;\n")
    fp.write("    size_t             colorMatchIconIDCount;\n")
    fp.write("} LGSeasonDef;\n\n")

    rows = []
    for season in seasons:
        sid = c_id(season["id"])
        icons = write_string_array(fp, f"kLGSeasonIcons_{sid}", season["iconIDs"])
        matches = write_string_array(fp, f"kLGSeasonColorMatches_{sid}", season["colorMatchIconIDs"])
        (start_month, start_day), (end_month, end_day) = season["start"], season["end"]
        rows.append(f'    {{ "{escape(season["id"])}", "{escape(season["title"])}", '
                    f'{start_month}, {start_day}, {end_month}, {end_day}, '
                    f'{icons}, {len(season["iconIDs"])}, '
                    f'{matches}, {len(season["colorMatchIconIDs"])} }},\n')
    if not rows:
        # Zero-length arrays are not standard C/C++; keep one inert row.
        rows.append("    { NULL, NULL, 0, 0, 0, 0, NULL, 0, NULL, 0 },\n")
    fp.write("static const LGSeasonDef kLGSeasons[] = {\n")
    for row in rows:
        fp.write(row)
    fp.write("};\n")
    fp.write(f"static const size_t kLGSeasonCount = {len(seasons)};\n\n")


def parse_month_day(value, season_id: str, key: str):
    match = re.fullmatch(r"(\d{2})-(\d{2})", value) if isinstance(value, str) else None
    if not match:
        print(f'error: season "{season_id}" has invalid "{key}" {value!r}; use "MM-DD"',
              file=sys.stderr)
        return None
    month, day = int(match.group(1)), int(match.group(2))
    try:
        # 2026 is not a leap year, so 02-29 is rejected: it would only exist
        # one year in four.
        datetime.date(2026, month, day)
    except ValueError:
        print(f'error: season "{season_id}" has impossible "{key}" {value!r}', file=sys.stderr)
        return None
    return month, day


def parse_seasons(raw_seasons, featurable_ids: set[str]):
    """Validates icons.json "seasons"; returns normalized dicts or None."""
    if not isinstance(raw_seasons, list):
        print('error: "seasons" must be a list', file=sys.stderr)
        return None
    seasons: list[dict] = []
    seen_ids: set[str] = set()
    for raw in raw_seasons:
        season_id = raw.get("id") if isinstance(raw, dict) else None
        if not isinstance(season_id, str) or not season_id or season_id in seen_ids:
            print(f"error: season {raw!r} needs a unique string \"id\"", file=sys.stderr)
            return None
        seen_ids.add(season_id)
        title = raw.get("title")
        if not isinstance(title, str) or not title.strip():
            print(f'error: season "{season_id}" needs a "title"', file=sys.stderr)
            return None
        start = parse_month_day(raw.get("start"), season_id, "start")
        if start is None:
            return None
        end = parse_month_day(raw.get("end"), season_id, "end")
        if end is None:
            return None
        if start > end:
            print(f'error: season "{season_id}" starts after it ends; windows cannot wrap '
                  'past Dec 31 (split it into two seasons)', file=sys.stderr)
            return None

        lists = {}
        used: set[str] = set()
        for key in ("iconIDs", "colorMatchIconIDs"):
            values = raw.get(key, [])
            if not isinstance(values, list) or not all(isinstance(v, str) for v in values):
                print(f'error: season "{season_id}" "{key}" must be a list of icon IDs',
                      file=sys.stderr)
                return None
            for icon_id in values:
                if icon_id not in featurable_ids:
                    print(f'error: season "{season_id}" lists "{icon_id}", which is not a '
                          'Liquid Glass group icon, a standardPack icon, or a "nativeIcons" entry',
                          file=sys.stderr)
                    return None
                if icon_id in used:
                    print(f'error: season "{season_id}" lists "{icon_id}" twice', file=sys.stderr)
                    return None
                used.add(icon_id)
            lists[key] = values
        if not used:
            print(f'error: season "{season_id}" has no icons', file=sys.stderr)
            return None

        for other in seasons:
            if start <= other["end"] and other["start"] <= end:
                print(f'error: seasons "{other["id"]}" and "{season_id}" overlap',
                      file=sys.stderr)
                return None
        seasons.append({"id": season_id, "title": title, "start": start, "end": end, **lists})
    return seasons


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: generate_previews_header.py <output_header_path>", file=sys.stderr)
        return 2

    out_path = sys.argv[1]
    scripts_dir = os.path.dirname(os.path.abspath(__file__))
    lg_dir = os.path.abspath(os.path.join(scripts_dir, ".."))
    registry = load_registry(lg_dir)

    raw_groups = registry.get("groups", [])
    if not raw_groups:
        print('error: icons.json has no "groups"', file=sys.stderr)
        return 1
    for group in raw_groups:
        if "author" in group:
            print(f'error: group "{group.get("id", "(unknown)")}" uses unsupported '
                  'pack-level "author"; credit individual icons with "designer" instead',
                  file=sys.stderr)
            return 1

    # icon_id -> (displayName, designer), used for both Liquid Glass groups
    # and tweak-owned additions to Apollo's native-style packs.
    icon_lookup: dict[str, tuple[str, str]] = {}
    for entry in registry["icons"]:
        icon_lookup[entry["id"]] = (entry.get("displayName", entry["id"]), entry.get("designer", ""))

    # Bucket icons by exactly one placement, preserving registry order.
    buckets: dict[str, list[tuple[str, str, str]]] = {g["id"]: [] for g in raw_groups}
    standard_buckets: dict[str, list[tuple[str, str, str, int]]] = {"ultra": []}
    for entry in registry["icons"]:
        icon_id      = entry["id"]
        display_name, designer = icon_lookup[icon_id]
        group = entry.get("group")
        standard_pack = entry.get("standardPack")
        if (group is None) == (standard_pack is None):
            print(f'error: icon "{icon_id}" must declare exactly one of '
                  '"group" or "standardPack"', file=sys.stderr)
            return 1
        if group is not None:
            if group not in buckets:
                print(f'error: icon "{icon_id}" has invalid "group" {group!r}; '
                      f'must be one of {sorted(buckets)}', file=sys.stderr)
                return 1
            buckets[group].append((icon_id, display_name, designer))
        else:
            if standard_pack not in standard_buckets:
                print(f'error: icon "{icon_id}" has unsupported "standardPack" '
                      f'{standard_pack!r}; must be one of {sorted(standard_buckets)}', file=sys.stderr)
                return 1
            native_anchor_row = entry.get("insertAfterNativeRow", -1)
            if (isinstance(native_anchor_row, bool) or
                    not isinstance(native_anchor_row, int) or native_anchor_row < -1):
                print(f'error: icon "{icon_id}" has invalid "insertAfterNativeRow" '
                      f'{native_anchor_row!r}; must be -1 or a nonnegative integer',
                      file=sys.stderr)
                return 1
            standard_buckets[standard_pack].append(
                (icon_id, display_name, designer, native_anchor_row)
            )

    group_icon_ids = {icon_id for entries in buckets.values() for icon_id, _, _ in entries}
    standard_icon_ids = {entry[0] for entries in standard_buckets.values() for entry in entries}
    natives = parse_native_icons(registry.get("nativeIcons", []), group_icon_ids | standard_icon_ids)
    if natives is None:
        return 1
    native_icon_ids = {native["id"] for native in natives}
    seasons = parse_seasons(registry.get("seasons", []),
                            group_icon_ids | standard_icon_ids | native_icon_ids)
    if seasons is None:
        return 1

    with open(out_path, "w") as fp:
        fp.write("// Auto-generated by liquid-glass/scripts/generate_previews_header.py.\n")
        fp.write("// Do not edit by hand. Regenerate with `make lg-previews`.\n")
        fp.write("#pragma once\n\n")

        # ── Types ──────────────────────────────────────────────────────────
        fp.write("typedef struct {\n")
        fp.write("    const char *iconID;\n")
        fp.write("    const char *displayName;\n")
        fp.write("    const char *designer;\n")
        fp.write("    int nativeAnchorRow;\n")
        fp.write("} LGIconRowEntry;\n\n")

        fp.write("typedef struct {\n")
        fp.write("    const char          *groupID;\n")
        fp.write("    const char          *title;\n")
        fp.write("    const char          *description;\n")
        fp.write("    const LGIconRowEntry *entries;\n")
        fp.write("    size_t               entryCount;\n")
        fp.write("    const char *const   *coverIconIDs;\n")
        fp.write("    size_t               coverIconIDCount;\n")
        fp.write("} LGIconGroupDef;\n\n")

        # ── Per-group entry arrays ─────────────────────────────────────────
        for g in raw_groups:
            gid     = g["id"]
            entries = buckets[gid]
            fp.write(f"static const LGIconRowEntry kLGGroupEntries_{c_id(gid)}[] = {{\n")
            for icon_id, display_name, designer in entries:
                fp.write(f'    {{ "{escape(icon_id)}", "{escape(display_name)}", '
                         f'"{escape(designer)}", -1 }},\n')
            fp.write("};\n\n")

        # ── Per-group cover-icon-ID arrays (only when non-empty) ───────────
        for g in raw_groups:
            gid       = g["id"]
            cover_ids = g.get("coverIconIDs", [])
            if not cover_ids:
                continue
            fp.write(f"static const char *const kLGGroupCover_{c_id(gid)}[] = {{\n")
            for icon_id in cover_ids:
                fp.write(f'    "{escape(icon_id)}",\n')
            fp.write("};\n\n")

        # ── Group descriptor table ─────────────────────────────────────────
        fp.write("static const LGIconGroupDef kLGIconGroups[] = {\n")
        for g in raw_groups:
            gid         = g["id"]
            title       = g.get("title", gid)
            description = g.get("description", "")
            arr         = f"kLGGroupEntries_{c_id(gid)}"
            n           = len(buckets[gid])
            cover_ids   = g.get("coverIconIDs", [])
            if cover_ids:
                cover_arr  = f"kLGGroupCover_{c_id(gid)}"
                cover_n    = len(cover_ids)
            else:
                cover_arr  = "NULL"
                cover_n    = 0
            fp.write(f'    {{ "{escape(gid)}", "{escape(title)}", "{escape(description)}", '
                     f'{arr}, {n}, {cover_arr}, {cover_n} }},\n')
        fp.write("};\n\n")

        # ── Tweak-owned additions to native-style Standard packs ──────────
        for pack_id, entries in standard_buckets.items():
            array_name = f"kLGStandardPackEntries_{c_id(pack_id)}"
            fp.write(f"static const LGIconRowEntry {array_name}[] = {{\n")
            for icon_id, display_name, designer, native_anchor_row in entries:
                fp.write(f'    {{ "{escape(icon_id)}", "{escape(display_name)}", '
                         f'"{escape(designer)}", {native_anchor_row} }},\n')
            fp.write("};\n")
            fp.write(f"static const size_t {array_name}Count = {len(entries)};\n\n")

        fp.write(f"static const size_t kLGIconGroupCount = {len(raw_groups)};\n\n")

        write_native_icons(fp, natives)
        write_seasons(fp, seasons)

        primary = registry["primaryIconID"]
        fp.write(f'static const char *const kLGPrimaryIconIDCString = "{escape(primary)}";\n')

    total = sum(len(v) for v in buckets.values()) + sum(len(v) for v in standard_buckets.values())
    summary_parts = [f"{len(buckets[g['id']])} {g['id']}" for g in raw_groups]
    summary_parts.extend(f"{len(entries)} standard/{pack_id}"
                         for pack_id, entries in standard_buckets.items() if entries)
    summary = ", ".join(summary_parts)
    season_summary = ", ".join(
        f"{season['id']} {len(season['iconIDs'])}+{len(season['colorMatchIconIDs'])}"
        for season in seasons
    ) or "none"
    print(f"Wrote {len(raw_groups)} groups ({summary}), {total} total, "
          f"{len(natives)} native; seasons: {season_summary} → {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
