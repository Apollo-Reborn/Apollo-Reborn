#!/usr/bin/env python3
"""Verify the actual supported IPA contract, independently of its filename."""

from __future__ import annotations

import plistlib
import struct
import sys
import zipfile
from pathlib import Path


def validate_ipa(path: Path, variant: str) -> None:
    with zipfile.ZipFile(path) as ipa:
        plists = [name for name in ipa.namelist()
                  if name.startswith("Payload/") and name.endswith(".app/Info.plist")
                  and name.count("/") == 2]
        if len(plists) != 1:
            raise ValueError(f"{path}: expected exactly one main app")
        info = plistlib.loads(ipa.read(plists[0]))
        if info.get("MinimumOSVersion") != "26.0":
            raise ValueError(f"{path}: MinimumOSVersion must be 26.0")
        if info.get("ARBuildVariant") != variant:
            raise ValueError(f"{path}: incorrect ARBuildVariant")
        if info.get("UIDesignRequiresCompatibility"):
            raise ValueError(f"{path}: classic-design opt-out is still enabled")
        if not all(info.get(key, {}).get("CFBundleAlternateIcons")
                   for key in ("CFBundleIcons", "CFBundleIcons~ipad")):
            raise ValueError(f"{path}: missing alternate icon catalog metadata")
        if plists[0].removesuffix("Info.plist") + "Assets.car" not in ipa.namelist():
            raise ValueError(f"{path}: missing compiled icon catalog")
        executable = plists[0].removesuffix("Info.plist") + info["CFBundleExecutable"]
        binary = ipa.read(executable)
    if len(binary) < 32:
        raise ValueError(f"{path}: truncated executable")
    magic, cpu, _, _, count, command_bytes, _, _ = struct.unpack_from("<8I", binary)
    if magic != 0xFEEDFACF or cpu != 0x0100000C:
        raise ValueError(f"{path}: expected a thin arm64 Mach-O executable")
    end = 32 + command_bytes
    if end > len(binary):
        raise ValueError(f"{path}: truncated load commands")
    offset = 32
    build_versions = []
    rpaths = []
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError(f"{path}: missing load command")
        kind, size = struct.unpack_from("<2I", binary, offset)
        if size < 8 or size % 8 or offset + size > end:
            raise ValueError(f"{path}: malformed load command")
        if kind == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise ValueError(f"{path}: truncated build version")
            build_versions.append(struct.unpack_from("<3I", binary, offset + 8))
        elif kind == 0x8000001C:  # LC_RPATH
            if size < 12:
                raise ValueError(f"{path}: truncated rpath")
            start = struct.unpack_from("<I", binary, offset + 8)[0]
            if start < 12 or start >= size:
                raise ValueError(f"{path}: malformed rpath")
            rpaths.append(binary[offset + start:offset + size].split(b"\0", 1)[0])
        offset += size
    if offset != end or len(build_versions) != 1:
        raise ValueError(f"{path}: expected exactly one build version")
    platform, minimum, sdk = build_versions[0]
    if platform != 2 or minimum != 26 << 16 or sdk < (27 << 16 | 1 << 8):
        raise ValueError(f"{path}: expected iOS 26 minimum and SDK 27.1+ Glass/Duo stamp")
    if len(rpaths) != len(set(rpaths)):
        raise ValueError(f"{path}: duplicate LC_RPATH would prevent launch")


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: validate_current_ipas.py <Apollo-Reborn.ipa> <No-Extensions.ipa>", file=sys.stderr)
        return 2
    try:
        for filename, variant in zip(sys.argv[1:], ("glass", "glass-noext")):
            validate_ipa(Path(filename), variant)
    except (ValueError, KeyError, struct.error, zipfile.BadZipFile) as error:
        print(error, file=sys.stderr)
        return 1
    print("Current IPA contracts passed: iOS 26+, Glass/Duo, icons and variant stamps")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
