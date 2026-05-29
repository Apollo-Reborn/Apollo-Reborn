#!/usr/bin/env python3
"""Validate release metadata before the expensive IPA build starts."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def read_control_version() -> str:
    match = re.search(
        r"^Version:\s*(.+)$",
        (ROOT / "control").read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if not match:
        raise ValueError("control is missing a Version field")
    version = match.group(1).strip().replace("~", "-")
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}(?:[-+][A-Za-z0-9.-]+)?", version):
        raise ValueError(f"control Version looks invalid: {version}")
    return version


def read_build_version() -> str:
    config = json.loads((ROOT / "distribution" / "config.json").read_text(encoding="utf-8"))
    build_version = str(config.get("app", {}).get("buildVersion", "")).strip()
    if not build_version:
        raise ValueError("distribution/config.json is missing app.buildVersion")
    if not re.fullmatch(r"[0-9]+", build_version):
        raise ValueError(f"app.buildVersion must be numeric and monotonic, got: {build_version}")
    return build_version


def marketing_version(version: str) -> str:
    # Drop a trailing dpkg-style numeric revision (e.g. "3.0.0-1" -> "3.0.0") so
    # the changelog/tag track the human-facing semantic version. Lettered
    # versions like "2.12.0b" have no "-<number>" tail and are left untouched.
    return re.sub(r"-[0-9]+$", "", version)


def validate_changelog(version: str) -> None:
    changelog = ROOT / "CHANGELOG.md"
    if not changelog.exists():
        raise ValueError("CHANGELOG.md is missing; release notes need a matching changelog entry")
    text = changelog.read_text(encoding="utf-8")
    if not re.search(rf"^## \[v?{re.escape(version)}\](?:\s+-\s+.+)?\s*$", text, re.MULTILINE):
        raise ValueError(f"CHANGELOG.md is missing a ## [v{version}] release entry")


def validate_tag_available(apollo_version: str, tweak_version: str) -> str:
    tag = f"v{apollo_version}_{tweak_version}"
    result = subprocess.run(
        ["git", "ls-remote", "--tags", "origin", f"refs/tags/{tag}"],
        cwd=ROOT,
        check=False,
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        raise ValueError(f"could not check existing release tag {tag}: {result.stderr.strip()}")
    if result.stdout.strip():
        raise ValueError(f"release tag already exists: {tag}")
    return tag


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: validate_release_inputs.py <apollo-version>", file=sys.stderr)
        return 2

    apollo_version = sys.argv[1].strip()
    if not apollo_version:
        print("Usage: validate_release_inputs.py <apollo-version>", file=sys.stderr)
        return 2

    try:
        # The changelog and release tag track the semantic tweak version, not the
        # dpkg packaging revision carried in control (e.g. "2.14.0-33" -> "2.14.0").
        release_version = marketing_version(read_control_version())
        build_version = read_build_version()
        validate_changelog(release_version)
        tag = validate_tag_available(apollo_version, release_version)
    except ValueError as exc:
        print(f"Release preflight failed: {exc}", file=sys.stderr)
        return 1

    print(f"Release preflight OK: Apollo {apollo_version}, Apollo-Reborn {release_version}, build {build_version}, tag {tag}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
