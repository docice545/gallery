"""Version/icon regression checks; native archive compilation runs on macOS CI."""

import importlib.util
import json
import plistlib
import re
import shutil
import struct
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1]
REPOSITORY = SCRIPTS.parents[1]
IOS = REPOSITORY / "mobile/ios"
CATALOG = IOS / "Runner/Assets.xcassets/AppIcon.appiconset"
spec = importlib.util.spec_from_file_location(
    "metadata_archive_verifier", SCRIPTS / "verify_ios_archive.py"
)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def make_archive(archive, *, version="5.7.2", build="5"):
    application = archive / "Products/Applications/Photos.app"
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
        (bundle / "binary").write_bytes(b"compiled-fixture")
        metadata = {
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "binary",
            "MinimumOSVersion": minimum,
            "AppGroupId": "group.de.opennoodle.gallery.share",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": build,
        }
        if bundle == application:
            metadata["CFBundleIcons"] = {
                "CFBundlePrimaryIcon": {
                    "CFBundleIconName": "AppIcon",
                    "CFBundleIconFiles": ["AppIcon60x60"],
                }
            }
            (bundle / "AppIcon60x60@2x.png").write_bytes(b"compiled-icon-fixture")
            (bundle / "Assets.car").write_bytes(b"compiled-catalog-fixture")
        (bundle / "Info.plist").write_bytes(plistlib.dumps(metadata))
    return application


class VersionSourceTests(unittest.TestCase):
    def test_runner_uses_flutter_generated_versions(self):
        metadata = plistlib.loads((IOS / "Runner/Info.plist").read_bytes())
        self.assertEqual(
            metadata["CFBundleShortVersionString"], "$(FLUTTER_BUILD_NAME)"
        )
        self.assertEqual(metadata["CFBundleVersion"], "$(FLUTTER_BUILD_NUMBER)")
        self.assertEqual(metadata["CFBundleDisplayName"], "Фото")

    def test_all_target_configurations_derive_versions_from_flutter(self):
        project = (IOS / "Runner.xcodeproj/project.pbxproj").read_text()
        versions = re.findall(r"MARKETING_VERSION = (.*);", project)
        builds = re.findall(r"CURRENT_PROJECT_VERSION = (.*);", project)
        self.assertEqual(versions, ['"$(FLUTTER_BUILD_NAME)"'] * 9)
        self.assertEqual(builds, ['"$(FLUTTER_BUILD_NUMBER)"'] * 9)

    def test_project_scope_propagates_generated_values_to_both_extensions(self):
        project = (IOS / "Runner.xcodeproj/project.pbxproj").read_text()
        project_configs = (
            "249021D3217E4FDB00AE95B9",
            "97C147031CF9000F007C117D",
            "97C147041CF9000F007C117D",
        )
        for identifier in project_configs:
            with self.subTest(identifier=identifier):
                block = re.search(
                    rf"\t\t{identifier} /\* .*? \*/ = \{{(.*?)\n\t\t\}};",
                    project,
                    re.DOTALL,
                ).group(1)
                self.assertIn(
                    "baseConfigurationReference = C0DE10072F99000100000001 /* Build.xcconfig */;",
                    block,
                )
        build_config = (IOS / "Build.xcconfig").read_text()
        self.assertIn('#include "Signing.xcconfig"', build_config)
        self.assertIn('#include "Flutter/Generated.xcconfig"', build_config)
        self.assertNotIn("FLUTTER_BUILD_NAME =", build_config)
        self.assertNotIn("FLUTTER_BUILD_NUMBER =", build_config)
        for configuration in ("debug", "release", "profile"):
            self.assertIn(
                f"Pods-ShareExtension.{configuration}.xcconfig",
                project,
            )


class AppIconCatalogTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.catalog = Path(self.directory.name) / "AppIcon.appiconset"
        shutil.copytree(CATALOG, self.catalog)

    def edit_catalog(self, edit):
        path = self.catalog / "Contents.json"
        contents = json.loads(path.read_text())
        edit(contents["images"])
        path.write_text(json.dumps(contents))

    def test_real_branded_catalog_has_correct_pixels_for_every_assigned_slot(self):
        verifier.verify_app_icon_catalog(self.catalog)

    def test_original_102_pixel_45_point_warning_is_rejected(self):
        def restore_wrong_slot(images):
            row = next(image for image in images if image.get("filename") == "102.png")
            row["size"] = "45x45"
            row["subtype"] = "41mm"

        self.edit_catalog(restore_wrong_slot)
        with self.assertRaisesRegex(ValueError, "pixels differ.*102.png"):
            verifier.verify_app_icon_catalog(self.catalog)

    def test_fractional_ipad_points_resolve_to_actual_pixels(self):
        contents = json.loads((self.catalog / "Contents.json").read_text())
        row = next(
            image for image in contents["images"] if image.get("filename") == "167.png"
        )
        self.assertEqual((row["size"], row["scale"]), ("83.5x83.5", "2x"))
        verifier.verify_app_icon_catalog(self.catalog)

    def test_missing_image_fails(self):
        (self.catalog / "1024.png").unlink()
        with self.assertRaises(OSError):
            verifier.verify_app_icon_catalog(self.catalog)

    def test_png_header_corruption_fails(self):
        (self.catalog / "1024.png").write_bytes(b"not-png")
        with self.assertRaisesRegex(ValueError, "valid PNG"):
            verifier.verify_app_icon_catalog(self.catalog)

    def test_truncated_png_header_fails(self):
        (self.catalog / "1024.png").write_bytes(b"\x89PNG\r\n\x1a\n")
        with self.assertRaisesRegex(ValueError, "valid PNG"):
            verifier.verify_app_icon_catalog(self.catalog)

    def test_marketing_icon_pixel_mismatch_fails(self):
        path = self.catalog / "1024.png"
        raw = bytearray(path.read_bytes())
        raw[16:24] = struct.pack(">II", 512, 512)
        path.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, "pixels differ"):
            verifier.verify_app_icon_catalog(self.catalog)

    def test_alpha_channel_marketing_icon_fails(self):
        path = self.catalog / "1024.png"
        raw = bytearray(path.read_bytes())
        raw[25] = 6
        path.write_bytes(raw)
        with self.assertRaisesRegex(ValueError, "no alpha channel"):
            verifier.verify_app_icon_catalog(self.catalog)

    def test_marketing_icon_required(self):
        self.edit_catalog(
            lambda images: images.__setitem__(
                slice(None),
                [image for image in images if image["idiom"] != "ios-marketing"],
            )
        )
        with self.assertRaisesRegex(ValueError, "marketing app icon is missing"):
            verifier.verify_app_icon_catalog(self.catalog)

    def test_unassigned_ios_slot_fails(self):
        self.edit_catalog(lambda images: images[0].pop("filename"))
        with self.assertRaisesRegex(ValueError, "no assigned image"):
            verifier.verify_app_icon_catalog(self.catalog)

    def test_duplicate_slot_fails(self):
        self.edit_catalog(lambda images: images.append(dict(images[0])))
        with self.assertRaisesRegex(ValueError, "duplicate assigned slots"):
            verifier.verify_app_icon_catalog(self.catalog)

    def test_owned_catalog_boundary(self):
        self.edit_catalog(lambda images: images[0].update(filename="../other.png"))
        with self.assertRaisesRegex(ValueError, "owned catalog"):
            verifier.verify_app_icon_catalog(self.catalog)


class CompiledMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = Path(self.directory.name) / "Runner.xcarchive"
        self.application = make_archive(self.archive)

    def edit_plist(self, bundle, edit):
        file = bundle / "Info.plist"
        metadata = plistlib.loads(file.read_bytes())
        edit(metadata)
        file.write_bytes(plistlib.dumps(metadata))

    def verify(self, **kwargs):
        return verifier.verify_archive(
            self.archive,
            bundle_id="de.opennoodle.gallery",
            app_group="group.de.opennoodle.gallery.share",
            expected_version="5.7.2",
            expected_build="5",
            **kwargs,
        )

    def test_all_three_compiled_bundles_have_expected_version_and_build(self):
        self.assertEqual(self.verify(app_icon_catalog=CATALOG), self.application)

    def test_future_flutter_version_bump_propagates_without_native_constants(self):
        future_archive = Path(self.directory.name) / "Future.xcarchive"
        application = make_archive(future_archive, version="6.2.0", build="27")
        self.assertEqual(
            verifier.verify_archive(
                future_archive,
                expected_version="6.2.0",
                expected_build="27",
                app_icon_catalog=CATALOG,
            ),
            application,
        )

    def test_legacy_runner_version_is_rejected(self):
        self.edit_plist(
            self.application,
            lambda metadata: metadata.update(CFBundleShortVersionString="3.0.0"),
        )
        with self.assertRaisesRegex(ValueError, "version differs"):
            self.verify()

    def test_legacy_runner_build_is_rejected(self):
        self.edit_plist(
            self.application, lambda metadata: metadata.update(CFBundleVersion="240")
        )
        with self.assertRaisesRegex(ValueError, "build differs"):
            self.verify()

    def test_each_extension_version_and_build_is_checked(self):
        for extension in ("ShareExtension", "WidgetExtension"):
            bundle = self.application / "PlugIns" / f"{extension}.appex"
            for field, invalid, valid in (
                ("CFBundleShortVersionString", "1.0", "5.7.2"),
                ("CFBundleVersion", "240", "5"),
            ):
                with self.subTest(extension=extension, field=field):
                    self.edit_plist(
                        bundle, lambda metadata: metadata.update({field: invalid})
                    )
                    with self.assertRaises(ValueError):
                        self.verify()
                    self.edit_plist(
                        bundle, lambda metadata: metadata.update({field: valid})
                    )

    def test_unexpanded_flutter_build_setting_fails(self):
        self.edit_plist(
            self.application,
            lambda metadata: metadata.update(CFBundleVersion="$(FLUTTER_BUILD_NUMBER)"),
        )
        with self.assertRaisesRegex(ValueError, "build differs"):
            self.verify()

    def test_missing_compiled_app_icon_metadata_fails(self):
        self.edit_plist(
            self.application, lambda metadata: metadata.pop("CFBundleIcons")
        )
        with self.assertRaisesRegex(ValueError, "app icon is missing"):
            self.verify(app_icon_catalog=CATALOG)

    def test_missing_compiled_app_icon_png_fails(self):
        (self.application / "AppIcon60x60@2x.png").unlink()
        with self.assertRaisesRegex(ValueError, "icon image is missing"):
            self.verify(app_icon_catalog=CATALOG)

    def test_empty_compiled_asset_catalog_fails(self):
        (self.application / "Assets.car").write_bytes(b"")
        with self.assertRaisesRegex(ValueError, "asset catalog is missing"):
            self.verify(app_icon_catalog=CATALOG)


if __name__ == "__main__":
    unittest.main()
