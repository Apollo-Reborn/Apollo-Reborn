#!/usr/bin/env python3
"""Opt the legacy Apollo shell into iOS 27 resizing before re-signing it.

This changes the main executable's linked-SDK declaration, not its deployment
target or machine code. It is an experimental compatibility patch, not a rebuild
of Apollo against SDK 27. The tweak still checks runtime API availability.
"""
import argparse
import os
import pathlib
import plistlib
import stat
import struct


def _open_app_directory(app):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if hasattr(os, 'O_CLOEXEC'):
        flags |= os.O_CLOEXEC
    app_path = pathlib.Path(app)
    if not app_path.name or app_path.name in ('.', '..'):
        raise ValueError('Expected a named app directory')
    try:
        # Open the immediate archive-created parent without following it, then
        # resolve the app relative to that retained descriptor. A crafted
        # Payload symlink therefore cannot redirect the bundle open.
        parent_descriptor = os.open(app_path.parent, flags)
    except OSError as error:
        raise ValueError('Expected a non-symlink app parent directory') from error
    try:
        try:
            descriptor = os.open(app_path.name, flags, dir_fd=parent_descriptor)
        except OSError as error:
            raise ValueError('Expected a non-symlink app directory') from error
        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid():
            os.close(descriptor)
            raise ValueError('Expected an owned app directory')
        return descriptor
    finally:
        os.close(parent_descriptor)


def _open_owned_member(app_descriptor, name):
    flags = os.O_RDWR | os.O_NOFOLLOW
    if hasattr(os, 'O_CLOEXEC'):
        flags |= os.O_CLOEXEC
    try:
        descriptor = os.open(name, flags, dir_fd=app_descriptor)
    except OSError as error:
        raise ValueError(f'Expected a non-symlink app member: {name}') from error
    metadata = os.fstat(descriptor)
    if (not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or
            metadata.st_nlink != 1):
        os.close(descriptor)
        raise ValueError(f'Expected an owned, unlinked regular app member: {name}')
    return descriptor


def _read_file(descriptor):
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            return b''.join(chunks)
        chunks.append(chunk)


def _write_file(descriptor, contents):
    os.lseek(descriptor, 0, os.SEEK_SET)
    remaining = memoryview(contents)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError('Could not write app member')
        remaining = remaining[written:]
    os.ftruncate(descriptor, len(contents))


def prepare(app):
    app_descriptor = _open_app_directory(app)
    plist_descriptor = None
    binary_descriptor = None
    try:
        # Retain all descriptors through validation and both writes. Member
        # lookup is relative to the retained directory descriptor, while
        # O_NOFOLLOW and fstat reject archive-supplied links and special files.
        plist_descriptor = _open_owned_member(app_descriptor, 'Info.plist')
        info = plistlib.loads(_read_file(plist_descriptor))
        executable = info['CFBundleExecutable']
        if not isinstance(executable, str) or not executable or pathlib.Path(executable).name != executable:
            raise ValueError('Expected a bundle-local executable name')
        if not info.get('UIApplicationSceneManifest'):
            raise ValueError('Resizable Apollo requires its existing scene manifest')
        if not (info.get('UILaunchStoryboardName') or 'UILaunchScreen' in info):
            raise ValueError('Resizable Apollo requires a launch-screen configuration')
        binary_descriptor = _open_owned_member(app_descriptor, executable)
        data = bytearray(_read_file(binary_descriptor))
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
        _write_file(binary_descriptor, data)
        _write_file(plist_descriptor, encoded)
    finally:
        if binary_descriptor is not None:
            os.close(binary_descriptor)
        if plist_descriptor is not None:
            os.close(plist_descriptor)
        os.close(app_descriptor)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=pathlib.Path)
    prepare(parser.parse_args().app)
