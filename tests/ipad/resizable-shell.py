"""Verify the compatibility patch preserves binary layout and rejects bad input."""
import importlib.util
import pathlib
import plistlib
import struct
import tempfile
import unittest
import sys

sys.dont_write_bytecode = True

root = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('prepare', root / 'scripts/prepare-resizable-app.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ResizableShellTests(unittest.TestCase):
    def fixture(self, directory, platform=7, sdk=19):
        app = pathlib.Path(directory)
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
                module.prepare(app)
                self.assertEqual((app / 'Apollo').read_bytes(), after)

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


if __name__ == '__main__':
    unittest.main()
