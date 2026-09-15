#!/usr/bin/env python3
"""Reject unsafe IPA member inventories before resizable simulator extraction."""

import argparse
import pathlib
import stat
import unicodedata
import zipfile


MAX_ENTRIES = 10_000
MAX_MEMBER_BYTES = 2 * 1024 * 1024 * 1024
MAX_EXPANDED_BYTES = 4 * 1024 * 1024 * 1024


def _member_parts(name):
    if not name or '\\' in name or pathlib.PurePosixPath(name).is_absolute():
        raise ValueError(f'Unsafe IPA member path: {name!r}')
    raw = name[:-1] if name.endswith('/') else name
    parts = raw.split('/')
    if not raw or any(part in ('', '.', '..') for part in parts):
        raise ValueError(f'Unsafe IPA member path: {name!r}')
    return parts


def _member_is_directory(member):
    directory = member.is_dir()
    if member.create_system == 3:
        kind = stat.S_IFMT(member.external_attr >> 16)
        if kind not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise ValueError(f'IPA member is a symlink or special file: {member.filename!r}')
        if kind == stat.S_IFDIR and not directory:
            raise ValueError(f'IPA directory member lacks a trailing slash: {member.filename!r}')
        if kind == stat.S_IFREG and directory:
            raise ValueError(f'IPA file member has directory syntax: {member.filename!r}')
    return directory


def validate(archive_path):
    entries = {}
    expanded_bytes = 0
    with zipfile.ZipFile(archive_path) as archive:
        members = archive.infolist()
        if len(members) > MAX_ENTRIES:
            raise ValueError(f'IPA has too many entries ({len(members)} > {MAX_ENTRIES})')
        for member in members:
            parts = _member_parts(member.filename)
            directory = _member_is_directory(member)
            if member.flag_bits & 1:
                raise ValueError(f'Encrypted IPA member is unsupported: {member.filename!r}')
            if member.file_size > MAX_MEMBER_BYTES:
                raise ValueError(f'IPA member is too large: {member.filename!r}')
            expanded_bytes += member.file_size
            if expanded_bytes > MAX_EXPANDED_BYTES:
                raise ValueError(f'IPA expands beyond {MAX_EXPANDED_BYTES} bytes')
            key = tuple(unicodedata.normalize('NFC', part).casefold() for part in parts)
            if key in entries:
                raise ValueError(
                    f'Duplicate or case-colliding IPA members: {entries[key][0]!r}, {member.filename!r}')
            entries[key] = (member.filename, directory)

    # Check after collecting the whole inventory so a file that appears after
    # its descendants cannot evade the ancestor-type rule.
    for key, (name, _) in entries.items():
        for length in range(1, len(key)):
            ancestor = entries.get(key[:length])
            if ancestor is not None and not ancestor[1]:
                raise ValueError(f'IPA member descends through non-directory {ancestor[0]!r}: {name!r}')
    return len(entries), expanded_bytes


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=pathlib.Path)
    count, size = validate(parser.parse_args().ipa)
    print(f'Validated resizable IPA inventory: {count} entries, {size} expanded bytes')
