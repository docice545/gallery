"""Offline release-tool regressions; no Xcode, Apple provisioning or install claim."""

import argparse
import json
import plistlib
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS / "release"))
import ios_artifact  # noqa: E402
import ios_unsigned  # noqa: E402
import prepare_sidestore  # noqa: E402
from package_unsigned_ios import package_unsigned_archive  # noqa: E402

COMMIT = "a" * 40
TEAM = "A1B2C3D4E5"


def make_archive(root: Path) -> Path:
    application = root / "Products/Applications/Photos.app"
    for bundle, identifier, minimum, name in (
        (application, ios_artifact.BUNDLE_ID, "15.0", "Foto"),
        (
            application / "PlugIns/ShareExtension.appex",
            ios_artifact.BUNDLE_ID + ".ShareExtension",
            "16.0",
            "Foto Share",
        ),
        (
            application / "PlugIns/WidgetExtension.appex",
            ios_artifact.BUNDLE_ID + ".Widget",
            "17.0",
            "Foto Widget",
        ),
    ):
        bundle.mkdir(parents=True)
        binary = bundle / "binary"
        binary.write_bytes(b"synthetic-not-mach-o")
        binary.chmod(0o755)
        metadata = {
            "CFBundleIdentifier": identifier,
            "CFBundleExecutable": "binary",
            "MinimumOSVersion": minimum,
            "AppGroupId": ios_artifact.APP_GROUP,
            "CFBundleShortVersionString": "5.7.2",
            "CFBundleVersion": "6",
            "CFBundleDisplayName": name,
            "CFBundleName": name,
        }
        if bundle == application:
            metadata["CFBundleURLTypes"] = [
                {
                    "CFBundleURLSchemes": [
                        "old-oauth",
                        "ShareMedia-de.opennoodle.gallery",
                    ]
                }
            ]
            metadata["BGTaskSchedulerPermittedIdentifiers"] = [
                "de.opennoodle.gallery.refreshUpload"
            ]
        (bundle / "Info.plist").write_bytes(
            plistlib.dumps(metadata, fmt=plistlib.FMT_BINARY)
        )
    (application / "ru.lproj").mkdir()
    (application / "ru.lproj/InfoPlist.strings").write_bytes(
        plistlib.dumps({"CFBundleDisplayName": "Фото"}, fmt=plistlib.FMT_BINARY)
    )
    return application


class IpaFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / "original.xcarchive"
        self.application = make_archive(self.archive)
        self.ipa = self.root / "Photos-unsigned.ipa"
        self.inspection_count = 0

    def package(self):
        package_unsigned_archive(self.archive, self.ipa)

    def verify(self):
        self.inspection_count += 1
        stage = self.root / f"stage-{self.inspection_count}.xcarchive"
        ios_artifact.extract_ipa(self.ipa, stage)
        return ios_artifact.verify_ipa_archive(stage, version="5.7.2", build="6")


class IpaOwnershipTests(IpaFixture):
    def test_exact_targets_names_russian_version_and_executable_preserved(self):
        self.package()
        verified = self.verify()
        self.assertEqual(len(ios_artifact.bundles(verified)), 3)
        self.assertEqual((verified / "binary").stat().st_mode & 0o777, 0o755)

    def test_base_runner_cyrillic_rejected_even_with_valid_russian_localization(self):
        metadata = plistlib.loads((self.application / "Info.plist").read_bytes())
        metadata["CFBundleDisplayName"] = "Фото"
        (self.application / "Info.plist").write_bytes(plistlib.dumps(metadata))
        self.package()
        with self.assertRaisesRegex(ValueError, "ASCII"):
            self.verify()

    def test_extension_base_name_cyrillic_rejected(self):
        path = self.application / "PlugIns/WidgetExtension.appex/Info.plist"
        metadata = plistlib.loads(path.read_bytes())
        metadata["CFBundleName"] = "Фото"
        path.write_bytes(plistlib.dumps(metadata))
        self.package()
        with self.assertRaisesRegex(ValueError, "ASCII"):
            self.verify()

    def test_russian_resource_missing_rejected(self):
        (self.application / "ru.lproj/InfoPlist.strings").unlink()
        self.package()
        with self.assertRaises(FileNotFoundError):
            self.verify()

    def test_unexpected_extension_and_profile_rejected(self):
        (self.application / "PlugIns/Surprise.appex").mkdir()
        self.package()
        with self.assertRaisesRegex(ValueError, "exactly"):
            self.verify()
        shutil.rmtree(self.application / "PlugIns/Surprise.appex")
        (self.application / "embedded.mobileprovision").write_bytes(b"not-unsigned")
        self.package()
        with self.assertRaisesRegex(ValueError, "profiles"):
            self.verify()

    def test_zip_traversal_rejected_before_writing(self):
        with zipfile.ZipFile(self.ipa, "w") as package:
            package.writestr("Payload/Photos.app/../../escape", b"must-not-write")
        with self.assertRaisesRegex(ValueError, "unsafe"):
            ios_artifact.extract_ipa(self.ipa, self.root / "stage")
        self.assertFalse((self.root / "escape").exists())

    def test_symlink_child_and_escape_rejected(self):
        for suffix, target, child in (
            ("child", "owned", True),
            ("escape", "/tmp", False),
        ):
            path = self.root / f"{suffix}.ipa"
            with zipfile.ZipFile(path, "w") as package:
                link = zipfile.ZipInfo("Payload/Photos.app/link")
                link.create_system = 3
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                package.writestr(link, target)
                if child:
                    package.writestr(
                        "Payload/Photos.app/link/binary", b"must-not-write"
                    )
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                ios_artifact.extract_ipa(path, self.root / f"stage-{suffix}")

    def test_duplicate_zip_entry_rejected(self):
        with zipfile.ZipFile(self.ipa, "w") as package:
            package.writestr("Payload/Photos.app/binary", b"one")
            with self.assertWarns(UserWarning):
                package.writestr("Payload/Photos.app/binary", b"two")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            ios_artifact.extract_ipa(self.ipa, self.root / "stage")

    def test_owned_relative_framework_links_survive(self):
        framework = self.application / "Frameworks/Example.framework"
        binary = framework / "Versions/A/Example"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"framework-fixture")
        (framework / "Versions/Current").symlink_to("A", target_is_directory=True)
        (framework / "Example").symlink_to("Versions/Current/Example")
        self.package()
        verified = self.verify()
        link = verified / "Frameworks/Example.framework/Example"
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.read_bytes(), b"framework-fixture")


class SideStoreSeedTests(IpaFixture):
    def args(self, **changes):
        self.package()
        values = dict(
            ipa=self.ipa,
            input_sha256=ios_artifact.sha256(self.ipa),
            team_id=TEAM,
            version="5.7.2",
            build="6",
            output=self.root / "Photos-5.7.2-6-SideStore-seed-unsigned.ipa",
            check_only=True,
        )
        return argparse.Namespace(**{**values, **changes})

    def test_check_only_validates_copy_without_creating_output_or_modifying_original(
        self,
    ):
        args = self.args()
        original = self.ipa.read_bytes()
        result = prepare_sidestore.prepare(args)
        self.assertIn("NEEDS MACOS", result["status"])
        self.assertFalse(args.output.exists())
        self.assertEqual(self.ipa.read_bytes(), original)

    def test_metadata_mapping_preserves_ids_bg_tasks_schemes_and_names(self):
        before = {
            bundle: plistlib.loads((bundle / "Info.plist").read_bytes())
            for bundle in ios_artifact.bundles(self.application)
        }
        prepare_sidestore.patch_seed(self.application, TEAM)
        for bundle, original in before.items():
            patched = plistlib.loads((bundle / "Info.plist").read_bytes())
            self.assertEqual(patched["AppGroupId"], ios_artifact.APP_GROUP + "." + TEAM)
            for key in (
                "CFBundleIdentifier",
                "BGTaskSchedulerPermittedIdentifiers",
                "CFBundleDisplayName",
                "CFBundleName",
            ):
                self.assertEqual(patched.get(key), original.get(key))
        metadata = plistlib.loads((self.application / "Info.plist").read_bytes())
        schemes = [
            scheme
            for entry in metadata["CFBundleURLTypes"]
            for scheme in entry["CFBundleURLSchemes"]
        ]
        self.assertIn("old-oauth", schemes)
        self.assertIn("ShareMedia-de.opennoodle.gallery", schemes)
        self.assertIn("ShareMedia-de.opennoodle.gallery." + TEAM, schemes)

    def test_wrong_hash_and_stock_team_fail_without_output(self):
        for changes in (
            {"input_sha256": "0" * 64},
            {"team_id": "77MWNP37MV"},
            {"team_id": "2W7AC6T8T5"},
            {"team_id": "placeholder"},
        ):
            args = self.args(**changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                prepare_sidestore.prepare(args)
            self.assertFalse(args.output.exists())

    def test_non_macos_preparation_fails_before_output(self):
        args = self.args(check_only=False)
        with (
            patch.object(prepare_sidestore.platform, "system", return_value="Linux"),
            self.assertRaisesRegex(ValueError, "MACOS"),
        ):
            prepare_sidestore.prepare(args)
        self.assertFalse(args.output.exists())

    def test_codesign_plan_nested_first_and_group_entitlement_unsuffixed(self):
        framework = self.application / "Frameworks/Test.framework"
        framework.mkdir(parents=True)
        calls = []

        def codesign(arguments, **kwargs):
            calls.append(arguments)
            if "--entitlements" in arguments and "-d" not in arguments:
                path = Path(arguments[arguments.index("--entitlements") + 1])
                self.assertEqual(
                    plistlib.loads(path.read_bytes()),
                    prepare_sidestore.SEED_ENTITLEMENTS,
                )
            return subprocess.CompletedProcess(
                arguments,
                0,
                stdout=plistlib.dumps(prepare_sidestore.SEED_ENTITLEMENTS),
                stderr=b"",
            )

        with patch.object(prepare_sidestore.subprocess, "run", side_effect=codesign):
            prepare_sidestore.sign_seed(self.application, self.root)
        signing = [call for call in calls if "--sign" in call]
        self.assertEqual(signing[0][-1], str(framework.resolve()))
        self.assertEqual(
            [Path(call[-1]).name for call in signing[1:]],
            ["ShareExtension.appex", "WidgetExtension.appex", "Photos.app"],
        )
        self.assertEqual(calls[-1][:4], ["codesign", "--verify", "--deep", "--strict"])

    def test_codesign_failure_does_not_package_an_install_claim(self):
        args = self.args(check_only=False)
        with (
            patch.object(prepare_sidestore.platform, "system", return_value="Darwin"),
            patch.object(prepare_sidestore.shutil, "which", return_value="codesign"),
            patch.object(
                prepare_sidestore,
                "sign_seed",
                side_effect=subprocess.CalledProcessError(1, "codesign"),
            ),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            prepare_sidestore.prepare(args)
        self.assertFalse(args.output.exists())


class WorkflowProvenanceTests(unittest.TestCase):
    def cached_output(self, root, **changes):
        output = root / "release"
        output.mkdir()
        ipa = output / "Photos-unsigned.ipa"
        ipa.write_bytes(b"cached-content-hash-fixture")
        receipt = {
            "repository": ios_unsigned.REPOSITORY,
            "commit": COMMIT,
            "run_id": 123,
            "artifact_name": ios_unsigned.ARTIFACT,
            "artifact_id": 42,
            "version": "5.7.2",
            "build": "6",
            "sha256": ios_artifact.sha256(ipa),
            **changes,
        }
        (output / "release-manifest.json").write_text(json.dumps(receipt))
        return output

    def responses(self, *, paid="skipped", sha=COMMIT, artifact=True):
        return [
            {
                "head_sha": sha,
                "head_branch": "work",
                "path": ios_unsigned.WORKFLOW_PATH,
                "event": "workflow_dispatch",
                "status": "completed",
                "conclusion": "success",
            },
            {
                "jobs": [
                    {
                        "name": ios_unsigned.UNSIGNED_JOB,
                        "conclusion": "success",
                        "steps": [
                            {"name": "Build iOS (no upload)", "conclusion": "success"},
                            *[
                                {"name": name, "conclusion": paid}
                                for name in (
                                    "Create API Key",
                                    "Import Certificate",
                                    "Create keychain and import certificate",
                                    "Build and deploy to TestFlight",
                                )
                            ],
                        ],
                    }
                ]
            },
            {
                "artifacts": [
                    {"name": ios_unsigned.ARTIFACT, "expired": False, "id": 42}
                ]
                if artifact
                else []
            },
        ]

    def test_success_requires_exact_revision_unsigned_steps_and_artifact(self):
        with patch.object(ios_unsigned, "api", side_effect=self.responses()):
            self.assertEqual(ios_unsigned.verify_run(123, COMMIT)[2]["id"], 42)

    def test_wrong_revision_paid_signing_missing_artifact_fail(self):
        for changes in ({"sha": "b" * 40}, {"paid": "success"}, {"artifact": False}):
            with (
                self.subTest(changes=changes),
                patch.object(
                    ios_unsigned, "api", side_effect=self.responses(**changes)
                ),
                self.assertRaises(ValueError),
            ):
                ios_unsigned.verify_run(123, COMMIT)

    def test_dispatch_never_selects_paid_release_or_cancels_an_active_run(self):
        with (
            patch.object(ios_unsigned, "preflight"),
            patch.object(
                ios_unsigned,
                "api",
                return_value={"workflow_runs": [{"id": 1, "status": "in_progress"}]},
            ),
            patch.object(ios_unsigned, "command") as execute,
            self.assertRaisesRegex(ValueError, "already active"),
        ):
            ios_unsigned.dispatch(COMMIT, wait=False)
        execute.assert_not_called()
        with (
            patch.object(ios_unsigned, "preflight"),
            patch.object(
                ios_unsigned,
                "api",
                side_effect=[
                    {"workflow_runs": []},
                    {"workflow_runs": [{"id": 2, "head_sha": COMMIT}]},
                ],
            ),
            patch.object(ios_unsigned, "command") as execute,
        ):
            self.assertEqual(ios_unsigned.dispatch(COMMIT, wait=False), 2)
        arguments = execute.call_args.args[0]
        self.assertIn("version=", arguments)
        self.assertIn("build_target=ios", arguments)
        self.assertIn("android_media_pilot=false", arguments)

    def test_download_failure_does_not_expose_signed_storage_urls(self):
        result = subprocess.CompletedProcess(
            ["gh"],
            1,
            stdout="",
            stderr="https://private.example/artifact?sig=PRIVATE_TOKEN",
        )
        with (
            patch.object(ios_unsigned.subprocess, "run", return_value=result),
            self.assertRaises(ValueError) as caught,
        ):
            ios_unsigned.command(["gh", "run", "download"])
        self.assertNotIn("PRIVATE_TOKEN", str(caught.exception))
        self.assertNotIn("private.example", str(caught.exception))

    def test_fetch_verifies_output_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "fixture.xcarchive"
            make_archive(archive)
            ipa = root / "fixture-unsigned.ipa"
            package_unsigned_archive(archive, ipa)
            output = root / "release"

            def download(arguments, **kwargs):
                directory = Path(arguments[arguments.index("--dir") + 1])
                directory.mkdir()
                shutil.copyfile(ipa, directory / "Photos-unsigned.ipa")
                return ""

            with (
                patch.object(ios_unsigned, "api", side_effect=self.responses()),
                patch.object(ios_unsigned, "command", side_effect=download),
            ):
                released = ios_unsigned.fetch(123, COMMIT, output, "5.7.2", "6")
            self.assertEqual(released["sha256"], ios_artifact.sha256(ipa))
            self.assertEqual(released["artifact_id"], 42)
            self.assertTrue((output / "release-manifest.json").is_file())
            with (
                patch.object(ios_unsigned, "api", side_effect=self.responses()),
                patch.object(ios_unsigned, "command") as download_again,
            ):
                repeated = ios_unsigned.fetch(123, COMMIT, output, "5.7.2", "6")
            download_again.assert_not_called()
            self.assertIn("already exists", repeated["status"])
            (output / "Photos-unsigned.ipa").write_bytes(b"tampered")
            with (
                patch.object(ios_unsigned, "api", side_effect=self.responses()),
                self.assertRaisesRegex(ValueError, "checksum"),
            ):
                ios_unsigned.fetch(123, COMMIT, output, "5.7.2", "6")

    def test_dispatch_retry_reuses_verified_original_run_without_new_ci(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = self.cached_output(Path(temporary))
            with (
                patch.object(ios_unsigned, "preflight") as preflight,
                patch.object(ios_unsigned, "api", side_effect=self.responses()),
                patch.object(ios_unsigned, "dispatch") as launch,
            ):
                result = ios_unsigned.dispatch_or_reuse(
                    COMMIT, wait=True, output=output, version="5.7.2", build="6"
                )
            launch.assert_not_called()
            preflight.assert_called_once_with(COMMIT)
            self.assertEqual(result["run_id"], 123)
            self.assertIn("already exists", result["status"])

    def test_dispatch_retry_rejects_wrong_receipt_before_new_ci(self):
        for changes in (
            {"commit": "b" * 40},
            {"version": "5.7.1"},
            {"sha256": "0" * 64},
            {"run_id": True},
        ):
            with (
                self.subTest(changes=changes),
                tempfile.TemporaryDirectory() as temporary,
            ):
                output = self.cached_output(Path(temporary), **changes)
                before = (output / "Photos-unsigned.ipa").read_bytes()
                with (
                    patch.object(ios_unsigned, "preflight"),
                    patch.object(ios_unsigned, "dispatch") as launch,
                    patch.object(ios_unsigned, "api") as api,
                    self.assertRaises(ValueError),
                ):
                    ios_unsigned.dispatch_or_reuse(
                        COMMIT, wait=True, output=output, version="5.7.2", build="6"
                    )
                launch.assert_not_called()
                api.assert_not_called()
                self.assertEqual((output / "Photos-unsigned.ipa").read_bytes(), before)

    def test_dispatch_retry_still_requires_successful_unsigned_remote_proof(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = self.cached_output(Path(temporary))
            with (
                patch.object(ios_unsigned, "preflight"),
                patch.object(
                    ios_unsigned, "api", side_effect=self.responses(paid="success")
                ),
                patch.object(ios_unsigned, "dispatch") as launch,
                self.assertRaisesRegex(ValueError, "Paid"),
            ):
                ios_unsigned.dispatch_or_reuse(
                    COMMIT, wait=True, output=output, version="5.7.2", build="6"
                )
            launch.assert_not_called()

    def test_dispatch_existing_unowned_output_fails_without_new_ci(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            with (
                patch.object(ios_unsigned, "preflight"),
                patch.object(ios_unsigned, "dispatch") as launch,
                self.assertRaisesRegex(ValueError, "no owned"),
            ):
                ios_unsigned.dispatch_or_reuse(
                    COMMIT, wait=True, output=output, version="5.7.2", build="6"
                )
            launch.assert_not_called()


if __name__ == "__main__":
    unittest.main()
