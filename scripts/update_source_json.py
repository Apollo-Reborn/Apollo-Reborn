#!/usr/bin/env python3
"""Generate AltStore-compatible source JSON files and a release manifest."""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


RELEASE_TAG_RE = re.compile(r"^v(?P<apollo>[^_]+)_(?P<tweak>.+)$")
LEGACY_ASSET_RE = re.compile(
    r"^(?:(?P<prefix>NO-EXTENSIONS_GLASS|NO-EXTENSIONS|GLASS)_)?"
    r"Apollo-(?P<apollo>[^_]+)_Apollo-Reborn-(?P<tweak>.+)\.ipa$"
)
# Longest alternatives first so e.g. "GLASSICONS-NOEXTENSIONS" matches as a
# whole instead of "GLASSICONS" with "-NOEXTENSIONS" left dangling.
REBORN_ASSET_RE = re.compile(
    r"^Apollo-Reborn-(?P<tweak>.+?)"
    r"(?:-(?P<suffix>GLASSICONS-NOEXTENSIONS|GLASS-NOEXTENSIONS|GLASSICONS|NOEXTENSIONS|GLASS))?"
    r"\.ipa$"
)
CURRENT_MINIMUM_VERSION = (4, 1, 0)


def version_components(version: str) -> tuple[int, int, int]:
    match = re.match(r"^(\d+)\.(\d+)(?:\.(\d+))?", version)
    if not match:
        raise ValueError(f"expected a stable semantic version, got {version!r}")
    return tuple(int(part or 0) for part in match.groups())


REBORN_SUFFIX_TO_PREFIX = {
    None: "",
    "GLASS": "GLASS",
    "NOEXTENSIONS": "NO-EXTENSIONS",
    "GLASS-NOEXTENSIONS": "NO-EXTENSIONS_GLASS",
    "GLASSICONS": "GLASS-ICONS",
    "GLASSICONS-NOEXTENSIONS": "NO-EXTENSIONS_GLASS-ICONS",
}


def load_config(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def fetch_releases(repo: str) -> list[dict[str, Any]]:
    api_url = f"https://api.github.com/repos/{repo}/releases"
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "Apollo-Reborn-Source-Generator",
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    request = Request(api_url, headers=headers)
    with urlopen(request, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def build_variant_key(prefix: str | None) -> str:
    mapping = {
        None: "standard",
        "GLASS": "glass",
        "NO-EXTENSIONS": "noExtensions",
        "NO-EXTENSIONS_GLASS": "noExtensionsGlass",
        "GLASS-ICONS": "glassIcons",
        "NO-EXTENSIONS_GLASS-ICONS": "noExtensionsGlassIcons",
    }
    return mapping[prefix]


def load_existing_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"apps": [{}], "news": []}
    return json.loads(path.read_text(encoding="utf-8"))


def markdown_to_plain_text(markdown: str) -> str:
    text = markdown.strip()
    if not text:
        return ""

    # AltStore/Feather version history renders descriptions as plain text, so
    # remove the most visible Markdown syntax while keeping the curated wording.
    text = re.sub(r"<!--.*?-->", "", text, flags=re.DOTALL)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = re.sub(r"__([^_]+)__", r"\1", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r"\1 (\2)", text)
    text = re.sub(r"^#{2,6}\s+", "", text, flags=re.MULTILINE)
    text = re.sub(r"^\s{2,}[-*]\s+", "  - ", text, flags=re.MULTILINE)
    text = re.sub(r"^\s*[-*]\s+", "- ", text, flags=re.MULTILINE)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip()


def format_release_notes(body: str, variant_name: str | None = None) -> str:
    text = markdown_to_plain_text(body)
    if variant_name:
        return f"{variant_name}\n\n{text}" if text else variant_name
    return text


def parse_release_tag(tag: str) -> tuple[str, str] | None:
    match = RELEASE_TAG_RE.match(tag)
    if not match:
        return None
    return match.group("apollo"), match.group("tweak")


def release_sort_key(release: dict[str, Any]) -> tuple[str, tuple[int, int, int]]:
    parsed = parse_release_tag(release.get("tag_name", ""))
    return release.get("published_at") or "", version_components(parsed[1]) if parsed else (0, 0, 0)


def find_matching_asset(release: dict[str, Any], prefix: str | None) -> dict[str, Any] | None:
    wanted = prefix or ""
    for asset in release.get("assets", []):
        name = asset.get("name", "")
        reborn_match = REBORN_ASSET_RE.match(name)
        if reborn_match:
            asset_prefix = REBORN_SUFFIX_TO_PREFIX[reborn_match.group("suffix")]
            # Suffixless assets change meaning at the sunset boundary. Never
            # classify historical classic IPAs as a current Glass download.
            try:
                current_asset = version_components(reborn_match.group("tweak")) >= CURRENT_MINIMUM_VERSION
            except ValueError:
                continue
            if current_asset:
                parsed = parse_release_tag(release.get("tag_name", ""))
                if not parsed or reborn_match.group("tweak") != parsed[1]:
                    continue
                asset_prefix = {None: "GLASS", "NOEXTENSIONS": "NO-EXTENSIONS_GLASS"}.get(
                    reborn_match.group("suffix")
                )
            if asset_prefix == wanted:
                return asset

        legacy_match = LEGACY_ASSET_RE.match(name)
        if legacy_match and (legacy_match.group("prefix") or "") == wanted:
            return asset
    return None


def build_version_entry(
    release: dict[str, Any],
    prefix: str | None,
    variant_name: str | None,
    build_version: str | None,
) -> dict[str, Any] | None:
    parsed = parse_release_tag(release.get("tag_name", ""))
    if not parsed:
        return None

    asset = find_matching_asset(release, prefix)
    if not asset:
        return None

    apollo_version, tweak_version = parsed
    entry = {
        # AltStore's VerifyAppOperation rejects an install when `version` does
        # not equal the IPA's CFBundleShortVersionString, and (when present)
        # when `buildVersion` does not equal its CFBundleVersion. The release
        # pipeline rewrites those fields to the tweak version and the source
        # config's monotonic build number, so the source must mirror that exact
        # pair.
        "version": tweak_version,
        "buildVersion": build_version,
        "marketingVersion": tweak_version,
        "date": release.get("published_at"),
        "localizedDescription": format_release_notes(release.get("body", ""), variant_name),
        "downloadURL": asset.get("browser_download_url"),
        "size": asset.get("size"),
    }
    if version_components(tweak_version) >= CURRENT_MINIMUM_VERSION:
        entry["minOSVersion"] = "26.0"
    return entry


def build_variant_manifest_entry(
    release: dict[str, Any],
    variant: dict[str, Any],
    config: dict[str, Any],
) -> dict[str, Any] | None:
    asset = find_matching_asset(release, variant["prefix"])
    if not asset:
        return None

    output_name = variant["output"]
    source_url = f"{config['distribution']['sourceBaseURL'].rstrip('/')}/{output_name}"
    return {
        "label": variant["app"]["subtitle"],
        "sourceURL": source_url,
        "directDownloadURL": asset.get("browser_download_url"),
        "assetName": asset.get("name"),
        "size": asset.get("size"),
    }


def find_latest_release_with_variants(
    releases: list[dict[str, Any]],
    variants: list[dict[str, Any]],
) -> dict[str, Any] | None:
    sorted_releases = sorted(releases, key=release_sort_key, reverse=True)
    for release in sorted_releases:
        parsed = parse_release_tag(release.get("tag_name", ""))
        if parsed and version_components(parsed[1]) >= CURRENT_MINIMUM_VERSION and all(
            find_matching_asset(release, variant["prefix"]) for variant in variants
        ):
            return release
    return None


def find_deb_asset(release: dict[str, Any], suffix: str) -> dict[str, Any] | None:
    for asset in release.get("assets", []):
        if asset.get("name", "").endswith(suffix):
            return asset
    return None


def write_release_manifest(
    output_path: Path,
    releases: list[dict[str, Any]],
    config: dict[str, Any],
) -> None:
    latest_release = find_latest_release_with_variants(releases, config["variants"])
    if latest_release is None:
        manifest = {
            "updatedAt": None,
            "release": None,
            "variants": {},
            "packages": {},
        }
        output_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        return

    parsed = parse_release_tag(latest_release.get("tag_name", ""))
    apollo_version, tweak_version = parsed if parsed else ("Unknown", "Unknown")

    variants: dict[str, Any] = {}
    for variant in config["variants"]:
        key = build_variant_key(variant["prefix"])
        entry = build_variant_manifest_entry(latest_release, variant, config)
        if entry:
            variants[key] = entry

    manifest = {
        "schemaVersion": 2,
        "updatedAt": latest_release.get("published_at"),
        "release": {
            "tag": latest_release.get("tag_name"),
            "name": latest_release.get("name"),
            "url": latest_release.get("html_url"),
            "apolloVersion": apollo_version,
            "tweakVersion": tweak_version,
            "minimumOSVersion": config["distribution"]["minimumOSVersion"],
        },
        "variants": variants,
        "packages": {},
    }
    output_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def validate_generated_sources(root: Path, config: dict[str, Any]) -> None:
    manifest_path = root / config["distribution"]["manifestOutput"]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    release = manifest.get("release")
    if not release:
        raise ValueError("release-manifest.json has no published release")

    tweak_version = release["tweakVersion"]
    build_version = str(config["app"]["buildVersion"])
    variants = manifest.get("variants") or {}
    expected_variant_keys = {build_variant_key(variant["prefix"]) for variant in config["variants"]}
    missing_variant_keys = sorted(expected_variant_keys - set(variants))
    if missing_variant_keys:
        raise ValueError(f"release-manifest.json is missing variants: {', '.join(missing_variant_keys)}")

    for key, entry in variants.items():
        if not entry.get("sourceURL"):
            raise ValueError(f"manifest variant {key} is missing sourceURL")
        if not entry.get("directDownloadURL"):
            raise ValueError(f"manifest variant {key} is missing directDownloadURL")
        if not entry.get("assetName"):
            raise ValueError(f"manifest variant {key} is missing assetName")

    for variant in config["variants"]:
        output_path = root / variant["output"]
        data = json.loads(output_path.read_text(encoding="utf-8"))
        apps = data.get("apps") or []
        if len(apps) != 1:
            raise ValueError(f"{variant['output']} must contain exactly one app")

        app = apps[0]
        if app.get("version") != tweak_version:
            raise ValueError(f"{variant['output']} version {app.get('version')} != {tweak_version}")
        if str(app.get("buildVersion")) != build_version:
            raise ValueError(f"{variant['output']} buildVersion {app.get('buildVersion')} != {build_version}")
        if app.get("marketingVersion") != tweak_version:
            raise ValueError(f"{variant['output']} marketingVersion {app.get('marketingVersion')} != {tweak_version}")
        if not app.get("downloadURL"):
            raise ValueError(f"{variant['output']} is missing downloadURL")
        if data.get("featuredApps") != [config["app"]["bundleIdentifier"]]:
            raise ValueError(f"{variant['output']} has an invalid featuredApps value")



def build_news_entry(
    release: dict[str, Any],
    config: dict[str, Any],
    variant_name: str | None,
) -> dict[str, Any]:
    parsed = parse_release_tag(release.get("tag_name", ""))
    apollo_version, tweak_version = parsed if parsed else ("Unknown", "Unknown")
    title = f"Apollo v{apollo_version} / Apollo-Reborn v{tweak_version}"
    if variant_name:
        title = f"{title} ({variant_name})"
    return {
        "title": title,
        "identifier": release.get("tag_name"),
        "caption": config["news"]["caption"],
        "date": release.get("published_at"),
        "tintColor": config["source"]["tintColor"],
        "imageURL": config["news"]["imageURL"],
        "url": release.get("html_url"),
    }


def version_entry_key(entry: dict[str, Any]) -> tuple[Any, ...]:
    download_url = entry.get("downloadURL")
    if download_url:
        return ("downloadURL", download_url)
    return (
        "version",
        entry.get("version"),
        entry.get("buildVersion"),
        entry.get("date"),
    )


def merge_version_entries(
    new_entries: list[dict[str, Any]],
    existing_entries: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    merged: dict[tuple[Any, ...], dict[str, Any]] = {}
    for entry in existing_entries:
        merged[version_entry_key(entry)] = entry
    for entry in new_entries:
        merged[version_entry_key(entry)] = entry
    return sorted(
        merged.values(),
        key=lambda item: (item.get("date") or "", version_components(item["version"])),
        reverse=True,
    )


def update_source_json(
    output_path: Path,
    releases: list[dict[str, Any]],
    config: dict[str, Any],
    variant: dict[str, Any],
) -> None:
    data = load_existing_json(output_path)
    data.update(config["source"])
    data.update(variant["source"])
    # Feature the app on the source's About page. bundleIdentifier is required in
    # config, so we always override any stale featuredApps carried over from a
    # previously generated source file.
    data["featuredApps"] = [config["app"]["bundleIdentifier"]]
    if "apps" not in data or not data["apps"]:
        data["apps"] = [{}]

    app = data["apps"][0]
    app.update(config["app"])
    app.update(variant["app"])

    build_version = config["app"].get("buildVersion")
    versions: list[dict[str, Any]] = []
    news: list[dict[str, Any]] = []
    existing_versions = app.get("versions") or []
    if not isinstance(existing_versions, list):
        existing_versions = []

    sorted_releases = sorted(
        releases,
        key=release_sort_key,
    )

    for release in reversed(sorted_releases):
        entry = build_version_entry(
            release, variant["prefix"], variant.get("notesLabel"), build_version
        )
        if not entry:
            continue
        # The source config only knows the current IPA build number. Generate the
        # newest release entry, then preserve older entries already in the source
        # so their historical buildVersion values remain installable.
        if not versions:
            versions.append(entry)
        news.append(build_news_entry(release, config, variant.get("newsLabel")))

    merged_versions = merge_version_entries(versions, existing_versions)
    app["versions"] = merged_versions
    if merged_versions:
        latest = merged_versions[0]
        app["version"] = latest["version"]
        app["buildVersion"] = latest["buildVersion"]
        app["marketingVersion"] = latest["marketingVersion"]
        app["versionDate"] = latest["date"]
        app["versionDescription"] = latest["localizedDescription"]
        app["downloadURL"] = latest["downloadURL"]
        app["size"] = latest["size"]

    data["news"] = sorted(news, key=lambda item: item.get("date") or "")

    output_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def validate_config(config: dict[str, Any]) -> None:
    required_top_level = {"repo", "distribution", "source", "app", "news", "variants"}
    missing = sorted(required_top_level - set(config))
    if missing:
        raise KeyError(f"missing config keys: {', '.join(missing)}")


def freeze_legacy_distribution(root: Path, config: dict[str, Any]) -> None:
    """Keep the original updater contract on 4.0.x, including its source URLs.

    Old clients read a global version before looking up their variant and do
    not enforce a minimum OS. Publishing 4.1 at that URL is unsafe even if the
    retired variant records are omitted. Glass sources keep updating, so their
    legacy counterparts must be snapshotted before the first current update.
    """
    manifest_path = root / config["distribution"]["legacyManifestOutput"]
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    release = manifest.get("release") or {}
    legacy_version = release.get("tweakVersion", "")
    if version_components(legacy_version) >= CURRENT_MINIMUM_VERSION:
        raise ValueError("legacy manifest must remain on the final 4.0.x release")
    base = config["distribution"]["sourceBaseURL"].rstrip("/")
    for variant in config["variants"]:
        filename = variant["output"]
        snapshot = root / "distribution" / "legacy" / filename
        if not snapshot.exists():
            data = (root / filename).read_bytes()
            source = json.loads(data)
            if source["apps"][0]["version"] != legacy_version:
                raise ValueError("publish the final 4.0.x sources before freezing the legacy feed")
            snapshot.parent.mkdir(parents=True, exist_ok=True)
            snapshot.write_bytes(data)
        # Validate existing snapshots too. Never silently overwrite an archive.
        if json.loads(snapshot.read_text())["apps"][0]["version"] != legacy_version:
            raise ValueError("legacy snapshot and manifest disagree; restore the final 4.0.x snapshot")
        key = build_variant_key(variant["prefix"])
        manifest["variants"][key]["sourceURL"] = f"{base}/distribution/legacy/{filename}"
    manifest["status"] = "legacy"
    manifest["supportedThrough"] = "4.0.x"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def generate_sources(root: Path, config: dict[str, Any], releases: list[dict[str, Any]]) -> None:
    # Preflight before mutating any published source. A partial release or a
    # stale config must not relabel an older IPA with the next build number.
    releases = [r for r in releases if not r.get("draft") and not r.get("prerelease")]
    current = [r for r in releases if (parsed := parse_release_tag(r.get("tag_name", "")))
               and version_components(parsed[1]) >= CURRENT_MINIMUM_VERSION]
    if not current:
        raise ValueError("no published 4.1+ release; legacy sources were left unchanged")
    latest = max(current, key=release_sort_key)
    if not all(find_matching_asset(latest, variant["prefix"]) for variant in config["variants"]):
        raise ValueError("newest current release is missing one of the two supported IPA assets")
    control = (root / "control").read_text(encoding="utf-8")
    match = re.search(r"^Version:\s*(.+)$", control, re.MULTILINE)
    expected = re.sub(r"-[0-9]+$", "", match.group(1).strip().replace("~", "-")) if match else None
    if parse_release_tag(latest["tag_name"])[1] != expected:
        raise ValueError("published release and control disagree; do not rewrite historical build numbers")
    for variant in config["variants"]:
        existing = load_existing_json(root / variant["output"])["apps"][0]
        asset_url = find_matching_asset(latest, variant["prefix"])["browser_download_url"]
        for entry in existing.get("versions", []):
            if entry.get("downloadURL") == asset_url and str(entry.get("buildVersion")) != str(config["app"]["buildVersion"]):
                raise ValueError("refusing to change the build number of an already published IPA")
    freeze_legacy_distribution(root, config)
    for variant in config["variants"]:
        update_source_json(root / variant["output"], current, config, variant)
    write_release_manifest(root / config["distribution"]["manifestOutput"], current, config)
    validate_generated_sources(root, config)


def main() -> int:
    root = Path(__file__).resolve().parent.parent
    config = load_config(root / "distribution" / "config.json")
    validate_config(config)
    try:
        generate_sources(root, config, fetch_releases(config["repo"]))
        print("Updated the two current sources; legacy release and history preserved")
    except (HTTPError, URLError, ValueError) as exc:
        print(f"Source update failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
