"""Offline IPA packaging checks; these fixtures do not compile or sign iOS."""

import importlib.util
import json
import os
import plistlib
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "unsigned_ios_packager", SCRIPTS / "package_unsigned_ios.py"
)
packager = importlib.util.module_from_spec(spec)
with patch.object(sys, "path", [str(SCRIPTS), *sys.path]):
    spec.loader.exec_module(packager)


def make_archive(archive):
    application = archive / "Products/Applications/Фото.app"
    for bundle, identifier, minimum in (
        (application, "de.opennoodle.gallery", "15.0"),
        (
            application / "PlugIns/ShareExtension.appex",
            "de.opennoodle.gallery.ShareExtension",
            "16.0",
        ),
        (
            application / "PlugIns/WidgetExtension.appex",
            "de.opennoodle.gallery.Widget",
            "17.0",
        ),
    ):
        bundle.mkdir(parents=True)
        binary = bundle / "binary"
        binary.write_bytes(b"compiled-binary-fixture")
        binary.chmod(0o755)
        (bundle / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": identifier,
                    "CFBundleExecutable": "binary",
                    "CFBundleShortVersionString": "5.7.2",
                    "CFBundleVersion": "5",
                    "MinimumOSVersion": minimum,
                    "AppGroupId": "group.de.opennoodle.gallery.share",
                }
            )
        )
    (archive / "dSYMs").mkdir()
    (archive / "dSYMs/private-symbols").write_bytes(b"not-part-of-ipa")
    return application


class UnsignedPackageTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.archive = self.root / "Runner.xcarchive"
        self.application = make_archive(self.archive)
        self.output = self.root / "output/Photos-unsigned.ipa"
        self.expected = {
            "bundle_id": "de.opennoodle.gallery",
            "app_group": "group.de.opennoodle.gallery.share",
            "expected_version": "5.7.2",
            "expected_build": "5",
        }

    def package(self, **overrides):
        return packager.package_unsigned_archive(
            self.archive, self.output, **{**self.expected, **overrides}
        )

    def test_payload_preserves_app_and_extensions_without_archive_metadata(self):
        before = (self.application / "Info.plist").read_bytes()
        self.assertEqual(self.package(), self.output)
        self.assertGreater(self.output.stat().st_size, 0)
        with zipfile.ZipFile(self.output) as result:
            self.assertIsNone(result.testzip())
            self.assertIn("Payload/Фото.app/binary", result.namelist())
            for name in ("ShareExtension", "WidgetExtension"):
                self.assertEqual(
                    result.read(f"Payload/Фото.app/PlugIns/{name}.appex/binary"),
                    b"compiled-binary-fixture",
                )
            self.assertTrue(
                all(name.startswith("Payload/") for name in result.namelist())
            )
            self.assertFalse(any("dSYMs" in name for name in result.namelist()))
            mode = result.getinfo("Payload/Фото.app/binary").external_attr >> 16
            self.assertTrue(stat.S_ISREG(mode))
            self.assertEqual(stat.S_IMODE(mode), 0o755)
        self.assertEqual((self.application / "Info.plist").read_bytes(), before)

    def test_contents_are_deterministic_despite_filesystem_dates(self):
        self.package()
        first = self.output.read_bytes()
        for path in self.application.rglob("*"):
            os.utime(path, (1800000000, 1800000000))
        self.package()
        self.assertEqual(first, self.output.read_bytes())
        with zipfile.ZipFile(self.output) as result:
            self.assertTrue(
                all(
                    info.date_time == packager.ZIP_TIMESTAMP
                    for info in result.infolist()
                )
            )

    def test_real_framework_relative_symlinks_are_preserved(self):
        framework = self.application / "Frameworks/Example.framework"
        version = framework / "Versions/A"
        version.mkdir(parents=True)
        (version / "Example").write_bytes(b"framework-fixture")
        (version / "Example").chmod(0o755)
        (framework / "Versions/Current").symlink_to("A", target_is_directory=True)
        (framework / "Example").symlink_to("Versions/Current/Example")
        self.package()
        with zipfile.ZipFile(self.output) as result:
            link = result.getinfo(
                "Payload/Фото.app/Frameworks/Example.framework/Example"
            )
            self.assertTrue(stat.S_ISLNK(link.external_attr >> 16))
            self.assertEqual(result.read(link), b"Versions/Current/Example")
            self.assertEqual(
                result.read(
                    "Payload/Фото.app/Frameworks/Example.framework/Versions/A/Example"
                ),
                b"framework-fixture",
            )
            self.assertFalse(
                any("Versions/Current/Example" in name for name in result.namelist())
            )

    def test_missing_archive_fails_without_output(self):
        shutil.rmtree(self.archive)
        with self.assertRaises(ValueError):
            self.package()
        self.assertFalse(self.output.exists())

    def test_missing_extension_fails_without_output(self):
        shutil.rmtree(self.application / "PlugIns/ShareExtension.appex")
        with self.assertRaises(OSError):
            self.package()
        self.assertFalse(self.output.exists())

    def test_empty_executable_fails_without_output(self):
        (self.application / "binary").write_bytes(b"")
        with self.assertRaises(ValueError):
            self.package()
        self.assertFalse(self.output.exists())

    def test_duplicate_application_is_rejected(self):
        (self.application.parent / "Other.app").mkdir()
        with self.assertRaises(ValueError):
            self.package()

    def test_version_build_identity_and_group_are_verified(self):
        for argument, value in (
            ("expected_version", "3.0.0"),
            ("expected_build", "240"),
            ("bundle_id", "another.app"),
            ("app_group", "another.group"),
        ):
            with self.subTest(argument=argument), self.assertRaises(ValueError):
                self.package(**{argument: value})
        self.assertFalse(self.output.exists())

    def test_source_catalog_and_compiled_icon_verification_are_not_skipped(self):
        catalog = self.root / "AppIcon.appiconset"
        catalog.mkdir()
        (catalog / "Contents.json").write_text(
            json.dumps(
                {
                    "images": [
                        {
                            "idiom": "ios-marketing",
                            "size": "1024x1024",
                            "scale": "1x",
                            "filename": "icon.png",
                        }
                    ]
                }
            )
        )
        header = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR"
        (catalog / "icon.png").write_bytes(
            header + struct.pack(">II", 1024, 1024) + b"\x08\x02" + b"\x00" * 7
        )
        with self.assertRaisesRegex(ValueError, "Compiled Runner app icon"):
            self.package(app_icon_catalog=catalog)
        plist = self.application / "Info.plist"
        metadata = plistlib.loads(plist.read_bytes())
        metadata["CFBundleIcons"] = {
            "CFBundlePrimaryIcon": {
                "CFBundleIconName": "AppIcon",
                "CFBundleIconFiles": ["AppIcon60x60"],
            }
        }
        plist.write_bytes(plistlib.dumps(metadata))
        (self.application / "AppIcon60x60@2x.png").write_bytes(b"compiled-icon-fixture")
        (self.application / "Assets.car").write_bytes(b"compiled-assets-fixture")
        self.package(app_icon_catalog=catalog)

    def test_symlinked_archive_is_rejected(self):
        link = self.root / "Link.xcarchive"
        link.symlink_to(self.archive, target_is_directory=True)
        self.archive = link
        with self.assertRaises(ValueError):
            self.package()

    def test_symlinked_products_root_is_rejected(self):
        products = self.archive / "Products"
        moved = self.root / "external-products"
        products.rename(moved)
        products.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.package()

    def test_symlinked_app_root_is_rejected(self):
        moved = self.root / "External.app"
        self.application.rename(moved)
        self.application.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.package()

    def test_links_outside_app_are_rejected_before_verifier_reads_them(self):
        outside = self.root / "outside-private-data"
        outside.write_bytes(b"not-media")
        for target in (str(outside), "../../../outside-private-data"):
            with self.subTest(target=target):
                link = self.application / "Info.plist"
                original = link.read_bytes()
                link.unlink()
                link.symlink_to(target)
                with self.assertRaises(ValueError):
                    self.package()
                link.unlink()
                link.write_bytes(original)
        self.assertFalse(self.output.exists())

    def test_broken_and_cyclic_links_are_rejected(self):
        link = self.application / "invalid-link"
        for target in ("missing-resource", "invalid-link"):
            with self.subTest(target=target):
                link.symlink_to(target)
                with self.assertRaises(ValueError):
                    self.package()
                link.unlink()

    def test_unsafe_zip_names_are_rejected(self):
        (self.application / "bad\\name").write_bytes(b"invalid")
        with self.assertRaises(ValueError):
            self.package()

    def test_unsupported_filesystem_entries_are_rejected(self):
        os.mkfifo(self.application / "fifo")
        with self.assertRaises(ValueError):
            self.package()

    def test_output_inside_source_archive_is_rejected(self):
        self.output = self.archive / "Photos-unsigned.ipa"
        with self.assertRaises(ValueError):
            self.package()
        self.assertFalse(self.output.exists())

    def test_symlinked_output_is_rejected_without_modifying_target(self):
        target = self.root / "unrelated"
        target.write_bytes(b"keep-me")
        self.output.parent.mkdir()
        self.output.symlink_to(target)
        with self.assertRaises(ValueError):
            self.package()
        self.assertEqual(target.read_bytes(), b"keep-me")

    def test_output_must_be_explicitly_labelled_unsigned(self):
        for name in ("Photos.ipa", "Photos-unsigned.zip"):
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.output = self.root / name
                self.package()

    def test_failed_packaging_cleans_partial_output_and_keeps_previous(self):
        self.package()
        previous = self.output.read_bytes()
        with patch.object(
            packager.shutil, "copyfileobj", side_effect=OSError("copy failed")
        ):
            with self.assertRaises(OSError):
                self.package()
        self.assertEqual(self.output.read_bytes(), previous)
        self.assertEqual(list(self.output.parent.glob(".unsigned-ios-*")), [])

    def test_cli_accepts_verifier_flags_and_explains_signing_gate(self):
        config = self.root / "branding.json"
        config.write_text(
            json.dumps(
                {
                    "mobile": {
                        "bundle_id": self.expected["bundle_id"],
                        "shared_group": self.expected["app_group"],
                    }
                }
            )
        )
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPTS / "package_unsigned_ios.py"),
                str(self.archive),
                str(self.output),
                "--branding-config",
                str(config),
                "--expected-version",
                "5.7.2",
                "--expected-build",
                "5",
            ],
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("SHA-256:", result.stdout)
        self.assertIn("not installable yet", result.stdout)
        self.assertIn("requires user-side signing", result.stdout)

    def test_cli_failure_is_nonzero_and_does_not_emit_success(self):
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPTS / "package_unsigned_ios.py"),
                str(self.archive),
                str(self.output),
                "--expected-build",
                "240",
            ],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Unsigned iOS packaging failed", result.stderr)
        self.assertNotIn("unsigned IPA packaged", result.stdout)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
