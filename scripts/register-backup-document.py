#!/usr/bin/env python3
"""Register Apollo's backup document icon in an unsigned app bundle or IPA.

The archive contents remain ZIP-compatible. Registration belongs to the main
app's Info.plist (not the injected dylib or its resource bundle), and must happen
before signing. Existing document declarations are preserved; repeated packaging
replaces only our own declaration. Restore remains an explicit in-app action.
"""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
import zipfile

TYPE_ID = "app.apolloreborn.backup"
ICON_NAME = "ApolloBackupIcon.png"
ICON = Path(__file__).resolve().parent.parent / "Resources/BackupDocument" / ICON_NAME


def registered_plist(data):
    info = plistlib.loads(data)
    exported = {
        "UTTypeIdentifier": TYPE_ID,
        "UTTypeDescription": "Apollo Reborn Backup",
        "UTTypeConformsTo": ["public.zip-archive", "public.content"],
        "UTTypeTagSpecification": {"public.filename-extension": ["apollobackup"]},
        "UTTypeIconFiles": [ICON_NAME],
        # The visible label describes the archive format, independently of its
        # Apollo-specific filename extension. iOS composes it below the badge.
        "UTTypeIcons": {"UTTypeIconText": "ZIP"},
    }
    document = {
        "CFBundleTypeName": "Apollo Reborn Backup",
        "LSItemContentTypes": [TYPE_ID],
        "CFBundleTypeIconFiles": [ICON_NAME],
        # Export the icon without advertising an unimplemented Open In handler.
        # The settings restore picker owns validation and user confirmation.
        "CFBundleTypeRole": "None",
        "LSHandlerRank": "None",
    }
    info["UTExportedTypeDeclarations"] = [
        item for item in info.get("UTExportedTypeDeclarations", [])
        if item.get("UTTypeIdentifier") != TYPE_ID
    ] + [exported]
    info["CFBundleDocumentTypes"] = [
        item for item in info.get("CFBundleDocumentTypes", [])
        if TYPE_ID not in item.get("LSItemContentTypes", [])
    ] + [document]
    return plistlib.dumps(info, fmt=plistlib.FMT_BINARY, sort_keys=False)


def register_app(app):
    plist = app / "Info.plist"
    updated = registered_plist(plist.read_bytes())
    shutil.copyfile(ICON, app / ICON_NAME)
    plist.write_bytes(updated)
    shutil.rmtree(app / "_CodeSignature", ignore_errors=True)


def register_ipa(ipa):
    # Rewrite only the main plist/icon, preserving every other member's metadata.
    # Stage beside the IPA so replacement is atomic, including on external disks.
    fd, temporary = tempfile.mkstemp(prefix=".backup-document-", suffix=".ipa", dir=ipa.parent)
    os.close(fd)
    try:
        with zipfile.ZipFile(ipa) as source:
            plists = [name for name in source.namelist()
                      if name.startswith("Payload/") and name.endswith(".app/Info.plist")
                      and name.count("/") == 2]
            if len(plists) != 1:
                raise ValueError("Expected exactly one main app in the IPA")
            plist_name = plists[0]
            app = plist_name.rsplit("/", 1)[0] + "/"
            updated = registered_plist(source.read(plist_name))
            with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as output:
                for entry in source.infolist():
                    if entry.filename == app + ICON_NAME or entry.filename.startswith(app + "_CodeSignature/"):
                        continue
                    output.writestr(entry, updated if entry.filename == plist_name else source.read(entry))
                output.write(ICON, app + ICON_NAME)
        os.chmod(temporary, ipa.stat().st_mode & 0o777)
        os.replace(temporary, ipa)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="Unsigned .app directory or .ipa file")
    args = parser.parse_args()
    if args.path.is_dir():
        register_app(args.path)
    else:
        register_ipa(args.path)
    print("Registered Apollo Reborn Backup document icon")


if __name__ == "__main__":
    main()
