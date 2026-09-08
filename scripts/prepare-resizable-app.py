#!/usr/bin/env python3
"""Opt the legacy Apollo shell into iOS 27 resizing before re-signing it.

This changes the main executable's linked-SDK declaration, not its deployment
target or machine code. It is an experimental compatibility patch, not a rebuild
of Apollo against SDK 27. The tweak still checks runtime API availability.
"""
import argparse
import pathlib
import plistlib
import struct


def prepare(app):
    plist = app / 'Info.plist'
    info = plistlib.loads(plist.read_bytes())
    executable = info['CFBundleExecutable']
    if pathlib.Path(executable).name != executable:
        raise ValueError('Expected a bundle-local executable name')
    if not info.get('UIApplicationSceneManifest'):
        raise ValueError('Resizable Apollo requires its existing scene manifest')
    if not (info.get('UILaunchStoryboardName') or 'UILaunchScreen' in info):
        raise ValueError('Resizable Apollo requires a launch-screen configuration')
    binary = app / executable
    data = bytearray(binary.read_bytes())
    if len(data) < 32 or struct.unpack_from('<I', data)[0] != 0xFEEDFACF:
        raise ValueError('Expected Apollo’s thin 64-bit Mach-O executable')
    count, size = struct.unpack_from('<II', data, 16)
    end = 32 + size
    if end > len(data):
        raise ValueError('Truncated load commands')
    offset, build = 32, None
    for _ in range(count):
        if offset + 8 > end:
            raise ValueError('Truncated load command')
        command, length = struct.unpack_from('<II', data, offset)
        if length < 8 or offset + length > end:
            raise ValueError('Invalid load command length')
        if command == 0x32:  # LC_BUILD_VERSION
            if length < 24 or build is not None:
                raise ValueError('Invalid or duplicate build-version command')
            platform, minimum, sdk = struct.unpack_from('<III', data, offset + 8)
            if platform not in (2, 7):  # iOS / iOS Simulator
                raise ValueError('Expected an iOS or iOS Simulator executable')
            struct.pack_into('<I', data, offset + 16, max(sdk, 27 << 16))
            build = (platform, minimum)
        offset += length
    if build is None or offset != end:
        raise ValueError('Missing build version or inconsistent load-command size')
    orientations = ['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationPortraitUpsideDown',
                    'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']
    info['UISupportedInterfaceOrientations'] = orientations
    info['UISupportedInterfaceOrientations~ipad'] = orientations
    info.pop('UIRequiresFullScreen', None)
    info.pop('UIRequiresFullScreen~ipad', None)
    info['UIApplicationSupportsIndirectInputEvents'] = True
    # Validate everything before either write. Signing is the caller's final step.
    encoded = plistlib.dumps(info)
    binary.write_bytes(data)
    plist.write_bytes(encoded)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    prepare(parser.parse_args().app)
