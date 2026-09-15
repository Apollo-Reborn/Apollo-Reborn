"""Verify the compatibility patch preserves binary layout and rejects bad input."""
import importlib.util
import os
import pathlib
import plistlib
import stat
import struct
import tempfile
import unittest
import sys
import zipfile
from unittest import mock

sys.dont_write_bytecode = True

root = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('prepare', root / 'scripts/prepare-resizable-app.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
archive_spec = importlib.util.spec_from_file_location(
    'validate_resizable_ipa', root / 'scripts/validate-resizable-ipa.py')
archive_module = importlib.util.module_from_spec(archive_spec)
archive_spec.loader.exec_module(archive_module)


class ResizableShellTests(unittest.TestCase):
    def fixture(self, directory, platform=7, sdk=19):
        app = pathlib.Path(directory)
        app.mkdir(parents=True, exist_ok=True)
        data = struct.pack('<8I', 0xFEEDFACF, 0x100000C, 0, 2, 1, 24, 0, 0)
        data += struct.pack('<6I', 0x32, 24, platform, 15 << 16, sdk << 16, 0)
        data += b'unchanged machine code'
        (app / 'Apollo').write_bytes(data)
        (app / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'Apollo', 'UIApplicationSceneManifest': {'UISceneConfigurations': {}},
            'UILaunchStoryboardName': 'LaunchScreen', 'MinimumOSVersion': '14.0',
            'UIRequiresFullScreen': True, 'UIRequiresFullScreen~ipad': True,
        }))
        return app, data

    def test_device_and_simulator_preserve_platform_minimum_and_code(self):
        for platform in (2, 7):
            with self.subTest(platform=platform), tempfile.TemporaryDirectory() as directory:
                app, before = self.fixture(directory, platform)
                module.prepare(app)
                after = (app / 'Apollo').read_bytes()
                self.assertEqual(after[:48], before[:48])
                self.assertEqual(after[52:], before[52:])
                self.assertEqual(struct.unpack_from('<I', after, 48)[0], 27 << 16)
                info = plistlib.loads((app / 'Info.plist').read_bytes())
                self.assertEqual(info['MinimumOSVersion'], '14.0')
                self.assertNotIn('UIRequiresFullScreen', info)
                self.assertNotIn('UIRequiresFullScreen~ipad', info)
                self.assertEqual(len(info['UISupportedInterfaceOrientations']), 4)
                first_plist = (app / 'Info.plist').read_bytes()
                module.prepare(app)
                self.assertEqual((app / 'Apollo').read_bytes(), after)
                self.assertEqual((app / 'Info.plist').read_bytes(), first_plist)

    def test_never_downgrades_a_newer_sdk(self):
        with tempfile.TemporaryDirectory() as directory:
            app, before = self.fixture(directory, sdk=28)
            module.prepare(app)
            self.assertEqual((app / 'Apollo').read_bytes(), before)

    def test_invalid_binary_does_not_change_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            app, _ = self.fixture(directory)
            before = (app / 'Info.plist').read_bytes()
            (app / 'Apollo').write_bytes(b'invalid')
            with self.assertRaises(ValueError):
                module.prepare(app)
            self.assertEqual((app / 'Info.plist').read_bytes(), before)
            self.assertEqual((app / 'Apollo').read_bytes(), b'invalid')

    def test_rejects_symlinked_app_directory_without_changing_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target, binary_before = self.fixture(root / 'target')
            plist_before = (target / 'Info.plist').read_bytes()
            (root / 'Apollo.app').symlink_to(target, target_is_directory=True)
            with self.assertRaises(ValueError):
                module.prepare(root / 'Apollo.app')
            self.assertEqual((target / 'Apollo').read_bytes(), binary_before)
            self.assertEqual((target / 'Info.plist').read_bytes(), plist_before)

    def test_rejects_symlinked_payload_ancestor_without_changing_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            target, binary_before = self.fixture(root / 'real-payload' / 'Apollo.app')
            plist_before = (target / 'Info.plist').read_bytes()
            (root / 'Payload').symlink_to(root / 'real-payload', target_is_directory=True)
            with self.assertRaises(ValueError):
                module.prepare(root / 'Payload' / 'Apollo.app')
            self.assertEqual((target / 'Apollo').read_bytes(), binary_before)
            self.assertEqual((target / 'Info.plist').read_bytes(), plist_before)

    def test_rejects_symlinked_info_plist_without_changing_external_sentinel(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            app, _ = self.fixture(root / 'Apollo.app')
            sentinel = root / 'outside-info.plist'
            sentinel.write_bytes((app / 'Info.plist').read_bytes())
            before = sentinel.read_bytes()
            (app / 'Info.plist').unlink()
            (app / 'Info.plist').symlink_to(sentinel)
            with self.assertRaises(ValueError):
                module.prepare(app)
            self.assertEqual(sentinel.read_bytes(), before)

    def test_rejects_symlinked_executable_without_changing_external_sentinel(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            app, binary_before = self.fixture(root / 'Apollo.app')
            sentinel = root / 'outside-Apollo'
            sentinel.write_bytes(binary_before)
            (app / 'Apollo').unlink()
            (app / 'Apollo').symlink_to(sentinel)
            with self.assertRaises(ValueError):
                module.prepare(app)
            self.assertEqual(sentinel.read_bytes(), binary_before)

    def test_rejects_hard_linked_info_plist_without_changing_external_sentinel(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            app, _ = self.fixture(root / 'Apollo.app')
            sentinel = root / 'outside-info.plist'
            sentinel.write_bytes((app / 'Info.plist').read_bytes())
            before = sentinel.read_bytes()
            (app / 'Info.plist').unlink()
            os.link(sentinel, app / 'Info.plist')
            with self.assertRaises(ValueError):
                module.prepare(app)
            self.assertEqual(sentinel.read_bytes(), before)

    def test_rejects_hard_linked_executable_without_changing_external_sentinel(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            app, binary_before = self.fixture(root / 'Apollo.app')
            sentinel = root / 'outside-Apollo'
            sentinel.write_bytes(binary_before)
            (app / 'Apollo').unlink()
            os.link(sentinel, app / 'Apollo')
            with self.assertRaises(ValueError):
                module.prepare(app)
            self.assertEqual(sentinel.read_bytes(), binary_before)


class ResizableArchiveTests(unittest.TestCase):
    def archive(self, path, members):
        with zipfile.ZipFile(path, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            for member, contents in members:
                archive.writestr(member, contents)

    def test_valid_ipa_inventory_is_compatible(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = pathlib.Path(directory) / 'Apollo.ipa'
            self.archive(ipa, [
                ('Payload/', b''),
                ('Payload/Apollo.app/', b''),
                ('Payload/Apollo.app/Info.plist', b'plist'),
                ('Payload/Apollo.app/Apollo', b'macho'),
                ('Payload/Apollo.app/PlugIns/Widget.appex/Widget', b'widget'),
            ])
            count, size = archive_module.validate(ipa)
            self.assertEqual(count, 5)
            self.assertEqual(size, 16)

    def test_rejects_unsafe_member_paths(self):
        for name in ('/absolute', '../outside', 'Payload/../outside', 'Payload\\outside',
                     'Payload//Apollo.app', './Payload/Apollo.app'):
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                ipa = pathlib.Path(directory) / 'bad.ipa'
                self.archive(ipa, [(name, b'x')])
                with self.assertRaises(ValueError):
                    archive_module.validate(ipa)

    def test_rejects_symlink_and_special_members(self):
        for kind in (stat.S_IFLNK, stat.S_IFIFO):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as directory:
                ipa = pathlib.Path(directory) / 'bad.ipa'
                member = zipfile.ZipInfo('Payload/Apollo.app/Apollo')
                member.create_system = 3
                member.external_attr = (kind | 0o755) << 16
                self.archive(ipa, [(member, b'outside')])
                with self.assertRaises(ValueError):
                    archive_module.validate(ipa)

    def test_rejects_duplicates_and_casefold_collisions(self):
        for names in (
                ('Payload/Apollo.app/Apollo', 'Payload/Apollo.app/Apollo'),
                ('Payload/Apollo.app/Info.plist', 'payload/apollo.app/info.PLIST')):
            with self.subTest(names=names), tempfile.TemporaryDirectory() as directory:
                ipa = pathlib.Path(directory) / 'bad.ipa'
                self.archive(ipa, [(name, b'x') for name in names])
                with self.assertRaises(ValueError):
                    archive_module.validate(ipa)

    def test_rejects_descendant_of_file_regardless_of_inventory_order(self):
        for members in (
                [('Payload/Apollo.app', b'file'), ('Payload/Apollo.app/Apollo', b'child')],
                [('Payload/Apollo.app/Apollo', b'child'), ('Payload/Apollo.app', b'file')]):
            with self.subTest(members=members), tempfile.TemporaryDirectory() as directory:
                ipa = pathlib.Path(directory) / 'bad.ipa'
                self.archive(ipa, members)
                with self.assertRaises(ValueError):
                    archive_module.validate(ipa)

    def test_rejects_entry_and_expanded_size_limits(self):
        with tempfile.TemporaryDirectory() as directory:
            ipa = pathlib.Path(directory) / 'bad.ipa'
            self.archive(ipa, [('Payload/a', b'1234'), ('Payload/b', b'5678')])
            with mock.patch.object(archive_module, 'MAX_ENTRIES', 1):
                with self.assertRaises(ValueError):
                    archive_module.validate(ipa)
            with mock.patch.object(archive_module, 'MAX_MEMBER_BYTES', 3):
                with self.assertRaises(ValueError):
                    archive_module.validate(ipa)
            with mock.patch.object(archive_module, 'MAX_EXPANDED_BYTES', 7):
                with self.assertRaises(ValueError):
                    archive_module.validate(ipa)

    def test_resizable_simulator_validates_before_both_extractions(self):
        source = (root / 'scripts/run-in-sim.sh').read_text()
        base_validation = source.index('python3 scripts/validate-resizable-ipa.py "$BASE_IPA"')
        glass_patch = source.index('./patch.sh "$BASE_IPA" --liquid-glass')
        source_validation = source.index('python3 scripts/validate-resizable-ipa.py "$SRC_IPA"')
        payload_removal = source.index('rm -rf "$WORK_DIR/Payload"')
        extraction = source.index('unzip -q "$SRC_IPA"')
        self.assertLess(base_validation, glass_patch)
        self.assertLess(source_validation, payload_removal)
        self.assertLess(source_validation, extraction)


if __name__ == '__main__':
    unittest.main()
