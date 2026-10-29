#!/usr/bin/env python3
"""Offline release-transition regressions; no network or real IPA is required."""

import importlib.util
import json
import plistlib
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def module(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


sources = module("update_source_json")
contracts = module("validate_current_ipas")


def release(version="4.1.0", legacy=False):
    suffixes = ("", "-NOEXTENSIONS", "-GLASS", "-GLASS-NOEXTENSIONS",
                "-GLASSICONS", "-GLASSICONS-NOEXTENSIONS") if legacy else ("", "-NOEXTENSIONS")
    return {
        "tag_name": f"v1.15.11_{version}", "name": version,
        "published_at": f"2026-10-{'25' if legacy else '29'}T12:00:00Z",
        "html_url": f"https://example.com/releases/{version}", "body": "Release notes",
        "assets": [{"name": f"Apollo-Reborn-{version}{suffix}.ipa", "size": 123,
                    "browser_download_url": f"https://example.com/{version}{suffix}.ipa"}
                   for suffix in suffixes],
    }


class SourceTransitionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.config = json.loads((ROOT / "distribution/config.json").read_text())
        self.config["app"]["buildVersion"] = "303"
        # Fixed legacy fixtures must keep working after the real active sources
        # have advanced to 4.1+. Do not copy today's generated sources here.
        legacy_variants = [
            ("apps.json", "standard", "standard", ""),
            ("apps_noext.json", "noextensions", "noExtensions", "-NOEXTENSIONS"),
            ("apps_glass.json", "glass", "glass", "-GLASS"),
            ("apps_noext_glass.json", "noextensionsglass", "noExtensionsGlass", "-GLASS-NOEXTENSIONS"),
            ("apps_glass_icons.json", "glassicons", "glassIcons", "-GLASSICONS"),
            ("apps_noext_glass_icons.json", "noextensionsglassicons", "noExtensionsGlassIcons", "-GLASSICONS-NOEXTENSIONS"),
        ]
        manifest = {"release": {"tweakVersion": "4.0.0", "tag": "v1.15.11_4.0.0"}, "variants": {}}
        for name, identifier, key, suffix in legacy_variants:
            versions = [{"version": version, "buildVersion": build, "marketingVersion": version,
                         "date": date, "localizedDescription": "Historical notes",
                         "downloadURL": f"https://example.com/{version}{suffix}.ipa", "size": 123}
                        for version, build, date in [("4.0.0", "302", "2026-10-25T12:00:00Z"),
                                                     ("3.9.0", "301", "2026-10-01T12:00:00Z")]]
            app = {"bundleIdentifier": "com.christianselig.Apollo", "versions": versions, **versions[0]}
            data = {"identifier": "app.apolloreborn." + identifier, "apps": [app], "news": []}
            (self.root / name).write_text(json.dumps(data))
            manifest["variants"][key] = {"sourceURL": "https://example.com/" + name,
                                         "directDownloadURL": versions[0]["downloadURL"]}
        (self.root / "release-manifest.json").write_text(json.dumps(manifest))
        (self.root / "control").write_text("Version: 4.1.0\n")
        self.before = {p.name: p.read_bytes() for p in self.root.glob("*.json")}

    def generate(self, releases=None):
        sources.generate_sources(self.root, self.config, releases or [release()])

    def test_current_pair_and_metadata(self):
        self.generate()
        manifest = json.loads((self.root / "release-manifest-v2.json").read_text())
        self.assertEqual(set(manifest["variants"]), {"glass", "noExtensionsGlass"})
        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertEqual(manifest["release"]["minimumOSVersion"], "26.0")
        self.assertEqual(manifest["packages"], {})
        for variant in self.config["variants"]:
            source = json.loads((self.root / variant["output"]).read_text())
            app = source["apps"][0]
            self.assertEqual(source["identifier"], json.loads(self.before[variant["output"]])["identifier"])
            self.assertEqual(app["version"], "4.1.0")
            self.assertEqual(app["buildVersion"], "303")
            self.assertEqual(app["versions"][0]["minOSVersion"], "26.0")
            self.assertNotIn("minOSVersion", app)

    def test_retired_sources_and_history_remain_unchanged(self):
        self.generate()
        for name in ("apps.json", "apps_noext.json", "apps_glass_icons.json", "apps_noext_glass_icons.json"):
            self.assertEqual((self.root / name).read_bytes(), self.before[name])
        for variant in self.config["variants"]:
            name = variant["output"]
            old = json.loads(self.before[name])["apps"][0]["versions"]
            current = json.loads((self.root / name).read_text())["apps"][0]["versions"]
            self.assertEqual(current[1:], old)
            self.assertEqual((self.root / "distribution/legacy" / name).read_bytes(), self.before[name])

    def test_old_clients_keep_final_legacy_release_and_snapshot_sources(self):
        self.generate()
        old = json.loads(self.before["release-manifest.json"])
        frozen = json.loads((self.root / "release-manifest.json").read_text())
        self.assertEqual(frozen["release"], old["release"])
        self.assertEqual(frozen["status"], "legacy")
        for key in ("glass", "noExtensionsGlass"):
            self.assertIn("/distribution/legacy/", frozen["variants"][key]["sourceURL"])
            self.assertEqual(frozen["variants"][key]["directDownloadURL"], old["variants"][key]["directDownloadURL"])

    def test_repeat_generation_does_not_change_archive(self):
        self.generate()
        archive = {p: p.read_bytes() for p in (self.root / "distribution/legacy").glob("*.json")}
        frozen = (self.root / "release-manifest.json").read_bytes()
        self.config["app"]["buildVersion"] = "304"
        (self.root / "control").write_text("Version: 4.1.1\n")
        self.generate([release("4.1.1"), release()])
        self.assertEqual((self.root / "release-manifest.json").read_bytes(), frozen)
        for path, contents in archive.items():
            self.assertEqual(path.read_bytes(), contents)

    def test_missing_asset_fails_before_any_source_write(self):
        partial = release()
        partial["assets"].pop()
        with self.assertRaisesRegex(ValueError, "missing one"):
            self.generate([partial, release("4.0.0", legacy=True)])
        for name, data in self.before.items():
            self.assertEqual((self.root / name).read_bytes(), data)
        self.assertFalse((self.root / "distribution/legacy").exists())

    def test_drafts_and_prereleases_never_update_stable_sources(self):
        for field in ("draft", "prerelease"):
            with self.subTest(field=field):
                unpublished = release()
                unpublished[field] = True
                with self.assertRaisesRegex(ValueError, "no published"):
                    self.generate([unpublished, release("4.0.0", legacy=True)])

    def test_stale_control_cannot_relabel_old_release(self):
        (self.root / "control").write_text("Version: 4.1.1\n")
        with self.assertRaisesRegex(ValueError, "control disagree"):
            self.generate()

    def test_existing_ipa_build_number_cannot_be_rewritten(self):
        self.generate()
        self.config["app"]["buildVersion"] = "304"
        with self.assertRaisesRegex(ValueError, "already published"):
            self.generate()

    def test_filename_boundary_preserves_old_variant_meaning(self):
        old = release("4.0.9", legacy=True)
        new = release()
        for prefix, suffix in ((None, ".ipa"), ("GLASS", "-GLASS.ipa"),
                               ("NO-EXTENSIONS_GLASS", "-GLASS-NOEXTENSIONS.ipa")):
            self.assertTrue(sources.find_matching_asset(old, prefix)["name"].endswith(suffix))
        self.assertTrue(sources.find_matching_asset(new, "GLASS")["name"].endswith("4.1.0.ipa"))
        self.assertIsNone(sources.find_matching_asset(new, None))
        self.assertIsNone(sources.find_matching_asset(new, "GLASS-ICONS"))

    def test_later_legacy_maintenance_release_cannot_replace_current_source(self):
        legacy = release("4.0.9", legacy=True)
        legacy["published_at"] = "2026-11-01T12:00:00Z"
        self.generate([legacy, release()])
        for variant in self.config["variants"]:
            app = json.loads((self.root / variant["output"]).read_text())["apps"][0]
            self.assertEqual(app["version"], "4.1.0")
            self.assertFalse(any(v["version"] == "4.0.9" for v in app["versions"]))

    def test_asset_version_must_match_release_tag(self):
        wrong = release()
        wrong["assets"][0]["name"] = "Apollo-Reborn-4.2.0.ipa"
        with self.assertRaisesRegex(ValueError, "missing one"):
            self.generate([wrong])
        for name, contents in self.before.items():
            self.assertEqual((self.root / name).read_bytes(), contents)

    def test_old_six_asset_release_is_not_the_current_release(self):
        self.assertIsNone(sources.find_latest_release_with_variants(
            [release("4.0.9", legacy=True)], self.config["variants"]))


class IPAContractTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name) / "Apollo.ipa"

    def write_ipa(self, minimum=26 << 16, sdk=27 << 16 | 1 << 8, variant="glass", **changes):
        info = {"CFBundleExecutable": "Apollo", "MinimumOSVersion": "26.0",
                "ARBuildVariant": variant,
                "CFBundleIcons": {"CFBundleAlternateIcons": {"Example": {}}},
                "CFBundleIcons~ipad": {"CFBundleAlternateIcons": {"Example": {}}}}
        info.update(changes)
        binary = struct.pack("<8I", 0xFEEDFACF, 0x0100000C, 0, 2, 1, 24, 0, 0)
        binary += struct.pack("<6I", 0x32, 24, 2, minimum, sdk, 0)
        with zipfile.ZipFile(self.path, "w") as ipa:
            ipa.writestr("Payload/Apollo.app/Info.plist", plistlib.dumps(info))
            ipa.writestr("Payload/Apollo.app/Apollo", binary)
            ipa.writestr("Payload/Apollo.app/Assets.car", b"fixture")

    def test_both_supported_stamps(self):
        for variant in ("glass", "glass-noext"):
            self.write_ipa(variant=variant)
            contracts.validate_ipa(self.path, variant)

    def test_old_macho_floor_is_rejected_even_with_new_plist(self):
        self.write_ipa(minimum=15 << 16)
        with self.assertRaisesRegex(ValueError, "iOS 26 minimum"):
            contracts.validate_ipa(self.path, "glass")

    def test_old_plist_floor_is_rejected_even_with_new_macho(self):
        self.write_ipa(MinimumOSVersion="15.0")
        with self.assertRaisesRegex(ValueError, "MinimumOSVersion"):
            contracts.validate_ipa(self.path, "glass")

    def test_classic_opt_out_is_rejected(self):
        self.write_ipa(UIDesignRequiresCompatibility=True)
        with self.assertRaisesRegex(ValueError, "opt-out"):
            contracts.validate_ipa(self.path, "glass")

    def test_wrong_stamp_is_rejected(self):
        self.write_ipa(variant="ipa")
        with self.assertRaisesRegex(ValueError, "ARBuildVariant"):
            contracts.validate_ipa(self.path, "glass")

    def test_missing_icons_are_rejected(self):
        self.write_ipa(CFBundleIcons={})
        with self.assertRaisesRegex(ValueError, "icon catalog"):
            contracts.validate_ipa(self.path, "glass")

    def test_pre_duo_sdk_stamp_is_rejected(self):
        self.write_ipa(sdk=19 << 16)
        with self.assertRaisesRegex(ValueError, "SDK 27.1"):
            contracts.validate_ipa(self.path, "glass")


if __name__ == "__main__":
    unittest.main()
