"""Release guards with benign mocked tools; no real key/build/deployment."""

from contextlib import redirect_stdout
import importlib.util
import io
import json
import re
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location(
    "android_release", Path(__file__).parents[1] / "android_release.py"
)
assert SPEC and SPEC.loader
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)
HEAD = "a" * 40


class AndroidReleaseGuards(unittest.TestCase):
    def test_release_build_regenerates_mode_specific_plugins(self):
        command = release.apk_build_command("5.7.2", 6)
        self.assertEqual(command[:3], ["flutter", "build", "apk"])
        self.assertIn("--release", command)
        self.assertIn("--pub", command)
        self.assertNotIn("--no-pub", command)

    def test_dependency_snapshot_ignores_generated_timestamp_but_not_packages(self):
        with tempfile.TemporaryDirectory() as temporary:
            mobile = Path(temporary)
            config = mobile / ".dart_tool/package_config.json"
            config.parent.mkdir()
            (mobile / "pubspec.lock").write_text("locked dependency versions")
            package = {
                "name": "plugin",
                "rootUri": "file:///existing-cache/plugin/",
                "packageUri": "lib/",
                "languageVersion": "3.13",
            }
            config.write_text(
                json.dumps({"generated": "before", "packages": [package]})
            )
            before = release.dependency_snapshot(mobile)
            config.write_text(json.dumps({"generated": "after", "packages": [package]}))
            self.assertEqual(before, release.dependency_snapshot(mobile))
            package["rootUri"] = "file:///different-cache/plugin/"
            config.write_text(json.dumps({"generated": "after", "packages": [package]}))
            self.assertNotEqual(before, release.dependency_snapshot(mobile))

    def test_dependency_snapshot_rejects_changed_lock(self):
        with tempfile.TemporaryDirectory() as temporary:
            mobile = Path(temporary)
            config = mobile / ".dart_tool/package_config.json"
            config.parent.mkdir()
            config.write_text(json.dumps({"packages": []}))
            lock = mobile / "pubspec.lock"
            lock.write_text("tested versions")
            before = release.dependency_snapshot(mobile)
            lock.write_text("different versions")
            self.assertNotEqual(before, release.dependency_snapshot(mobile))

    def test_expected_sha_must_be_full(self):
        with patch.object(release, "run") as run:
            with self.assertRaisesRegex(release.ReleaseError, "40-character"):
                release.repository_check(Path("/unused"), "aaaa")
            run.assert_not_called()

    def test_wrong_branch_is_rejected(self):
        with patch.object(release, "run", return_value="main\n"):
            with self.assertRaisesRegex(release.ReleaseError, "branch"):
                release.repository_check(Path("/unused"), HEAD)

    def test_wrong_head_is_rejected(self):
        with patch.object(release, "run", side_effect=["work\n", "b" * 40]):
            with self.assertRaisesRegex(release.ReleaseError, "HEAD differs"):
                release.repository_check(Path("/unused"), HEAD)

    def test_uncommitted_work_is_rejected_without_restoring_it(self):
        with patch.object(
            release,
            "run",
            side_effect=[
                "work\n",
                HEAD,
                "https://github.com/docice545/gallery.git",
                " M mobile/lib/user-work.dart\n",
            ],
        ) as run:
            with self.assertRaisesRegex(release.ReleaseError, "not clean"):
                release.repository_check(Path("/unused"), HEAD)
            self.assertEqual(len(run.call_args_list), 4)
            self.assertTrue(
                all(
                    call.args[0][1] in {"branch", "rev-parse", "remote", "status"}
                    for call in run.call_args_list
                )
            )

    def test_matching_clean_repository_is_accepted(self):
        with patch.object(
            release,
            "run",
            side_effect=[
                "work\n",
                HEAD,
                "https://github.com/docice545/gallery.git",
                "",
            ],
        ):
            release.repository_check(Path("/unused"), HEAD)

    def test_supported_https_and_ssh_origins(self):
        for origin in (
            "https://github.com/docice545/gallery.git",
            "git@github.com:docice545/gallery.git",
        ):
            with (
                self.subTest(origin=origin),
                patch.object(release, "run", side_effect=["work", HEAD, origin, ""]),
            ):
                release.repository_check(Path("/unused"), HEAD)

    def test_wrong_or_credential_bearing_origin_fails_without_echoing_it(self):
        for origin in (
            "https://github.com/unrelated/gallery.git",
            "https://private-token@github.com/docice545/gallery.git",
        ):
            with (
                self.subTest(origin=origin),
                patch.object(release, "run", side_effect=["work", HEAD, origin]),
            ):
                with self.assertRaises(release.ReleaseError) as error:
                    release.repository_check(Path("/unused"), HEAD)
                self.assertIn("docice545/gallery", str(error.exception))
                self.assertNotIn("private-token", str(error.exception))
                self.assertNotIn(origin, str(error.exception))

    def test_sdk_environment_must_agree(self):
        with self.assertRaisesRegex(release.ReleaseError, "disagree"):
            release.sdk_path({"ANDROID_HOME": "/a", "ANDROID_SDK_ROOT": "/b"})

    def test_sdk_environment_must_exist(self):
        with self.assertRaisesRegex(release.ReleaseError, "ANDROID_HOME"):
            release.sdk_path({})

    def test_signing_preflight_never_opens_key_or_password_file(self):
        paths = ["mobile/android/key.jks", "mobile/android/key.properties"]
        with (
            patch.object(Path, "is_file", return_value=True),
            patch.object(Path, "stat", return_value=SimpleNamespace(st_size=10)),
            patch.object(
                Path, "open", side_effect=AssertionError("must not read credentials")
            ),
            patch.object(release, "run", side_effect=["", "\n".join(paths)]),
        ):
            release.check_key_files(Path("/unused"))

    def test_missing_existing_keys_cannot_create_a_replacement(self):
        with (
            patch.object(Path, "is_file", return_value=False),
            patch.object(Path, "open") as opened,
            patch.object(release, "run") as run,
        ):
            with self.assertRaisesRegex(release.ReleaseError, "never generate"):
                release.check_key_files(Path("/unused"))
            opened.assert_not_called()
            run.assert_not_called()

    def test_failed_preflight_cannot_start_build_or_create_outputs(self):
        with (
            patch.object(release, "preflight", return_value=False),
            patch.object(release, "artifact_paths") as paths,
            patch.object(release.subprocess, "run") as process,
        ):
            with self.assertRaisesRegex(release.ReleaseError, "no build was started"):
                release.build(Path("/unused"), HEAD, 6, {})
            paths.assert_not_called()
            process.assert_not_called()

    def test_tool_failure_does_not_echo_captured_sensitive_output(self):
        with patch.object(
            release.subprocess,
            "run",
            return_value=SimpleNamespace(
                returncode=1, stdout="", stderr="never print this credential"
            ),
        ):
            with self.assertRaises(release.ReleaseError) as error:
                release.run(["gradlew", "unused"], Path("/unused"))
            self.assertNotIn("credential", str(error.exception))

    def test_missing_apk_fails_without_running_any_tool(self):
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(release, "run") as run,
        ):
            with self.assertRaisesRegex(release.ReleaseError, "missing"):
                release.apk_metadata(
                    Path(temporary) / "missing.apk",
                    Path("/unused"),
                    Path(temporary),
                    "5.7.2",
                    6,
                )
            run.assert_not_called()

    def apk_check(self, package=None, certificate=None, signers=1):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        apk = root / "benign-fixture.apk"
        apk.write_bytes(b"fixture bytes: never installed or signed")
        package = (
            package
            or "package: name='de.opennoodle.gallery' versionCode='6' versionName='5.7.2'\n"
        )
        certificate = certificate or release.CERTIFICATE_SHA256
        signature = "\n".join(
            f"Signer #{index + 1} certificate SHA-256 digest: {certificate}"
            for index in range(signers)
        )
        manifest = """\
          E: provider (line=93)
            A: android:name(0x01010003)=\"app.alextran.immich.cloudmedia.GalleryCloudMediaProvider\"
            A: android:readPermission(0x01010006)=\"com.android.providers.media.permission.MANAGE_CLOUD_MEDIA_PROVIDERS\"
            A: android:writePermission(0x01010007)=\"com.android.providers.media.permission.MANAGE_CLOUD_MEDIA_PROVIDERS\"
            A: android:exported(0x01010010)=true
            A: android:authorities(0x01010018)=\"de.opennoodle.gallery.cloudmedia\"
              E: intent-filter (line=100)
                  E: action (line=101)
                    A: android:name(0x01010003)=\"android.content.action.CLOUD_MEDIA_PROVIDER\"
        """
        with patch.object(release, "run", side_effect=[package, manifest, signature]):
            return release.apk_metadata(apk, root, root, "5.7.2", 6)

    def test_packaged_cloud_provider_manifest_is_required(self):
        with self.assertRaisesRegex(release.ReleaseError, "no Gallery CloudMediaProvider"):
            release.validate_cloud_provider_manifest(
                "E: provider (line=1)\n A: android:name=\"other.Provider\""
            )

    def test_packaged_cloud_provider_permission_and_action_are_required(self):
        manifest = """
          E: provider (line=1)
            A: android:name=\"app.alextran.immich.cloudmedia.GalleryCloudMediaProvider\"
            A: android:readPermission=\"wrong.permission\"
            A: android:exported(0x01010010)=true
            A: android:authorities(0x01010018)=\"de.opennoodle.gallery.cloudmedia\"
              E: intent-filter (line=2)
                A: android:name=\"android.content.action.CLOUD_MEDIA_PROVIDER\"
        """
        with self.assertRaisesRegex(release.ReleaseError, "missing authority"):
            release.validate_cloud_provider_manifest(manifest)

    def provider_manifest(self, exported="(type 0x12)0xffffffff"):
        return f"""  E: application (line=1)
    E: provider (line=2)
      A: android:name(0x01010003)="{release.CLOUD_PROVIDER_CLASS}" (Raw: "{release.CLOUD_PROVIDER_CLASS}")
      A: android:readPermission(0x01010007)="{release.CLOUD_PROVIDER_PERMISSION}"
      A: android:writePermission(0x01010008)="{release.CLOUD_PROVIDER_PERMISSION}"
      A: android:exported(0x01010010)={exported}
      A: android:authorities(0x01010018)="{release.CLOUD_PROVIDER_AUTHORITY}"
      E: intent-filter (line=3)
        E: action (line=4)
          A: android:name(0x01010003)="{release.CLOUD_PROVIDER_ACTION}"
    E: activity (line=5)
      A: android:exported(0x01010010)=true
"""

    def test_sdk36_binary_boolean_and_source_true_are_accepted(self):
        for value in ["(type 0x12)0xffffffff", "(type 0x12)0x1", "true"]:
            with self.subTest(value=value):
                release.validate_cloud_provider_manifest(self.provider_manifest(value))

    def test_false_or_invalid_exported_cannot_borrow_sibling_true(self):
        for value in ["false", "(type 0x12)0x0", "(type 0x10)0xffffffff", '"true"', ""]:
            with self.subTest(value=value), self.assertRaises(release.ReleaseError):
                release.validate_cloud_provider_manifest(self.provider_manifest(value))

    def test_both_signature_permissions_and_exact_authority_are_required(self):
        for field in ["readPermission", "writePermission", "authorities"]:
            manifest = self.provider_manifest()
            manifest = re.sub(rf'(android:{field}\([^)]*\)=)"[^"]*"', r'\1"wrong"', manifest)
            with self.subTest(field=field), self.assertRaises(release.ReleaseError):
                release.validate_cloud_provider_manifest(manifest)

    def test_android_common_permission_protects_both_directions(self):
        manifest = self.provider_manifest().replace('android:readPermission', 'android:permission')
        manifest = '\n'.join(line for line in manifest.splitlines() if 'android:writePermission' not in line)
        release.validate_cloud_provider_manifest(manifest)
        manifest = manifest.replace('      E: intent-filter', '      A: android:writePermission(0x01010008)="wrong"\n      E: intent-filter')
        with self.assertRaises(release.ReleaseError):
            release.validate_cloud_provider_manifest(manifest)

    def test_sibling_action_or_nested_provider_name_cannot_satisfy_contract(self):
        manifest = self.provider_manifest().replace(f'"{release.CLOUD_PROVIDER_ACTION}"', '"wrong"')
        manifest += f'      E: action (line=6)\n        A: android:name="{release.CLOUD_PROVIDER_ACTION}"\n'
        with self.assertRaises(release.ReleaseError):
            release.validate_cloud_provider_manifest(manifest)
        manifest = self.provider_manifest().replace(f'"{release.CLOUD_PROVIDER_CLASS}"', '"other.Provider"', 1)
        with self.assertRaises(release.ReleaseError):
            release.validate_cloud_provider_manifest(manifest)

    def test_actual_release_identity_and_streamed_checksum(self):
        metadata = self.apk_check()
        self.assertEqual(metadata["application_id"], release.APP_ID)
        self.assertEqual(metadata["version_code"], 6)
        self.assertEqual(len(metadata["apk_sha256"]), 64)

    def test_debug_certificate_is_rejected(self):
        with self.assertRaisesRegex(release.ReleaseError, "CI/debug"):
            self.apk_check(certificate="0" * 64)

    def test_unexpected_second_signer_is_rejected(self):
        with self.assertRaisesRegex(release.ReleaseError, "certificate"):
            self.apk_check(signers=2)

    def test_wrong_application_id_is_rejected(self):
        with self.assertRaisesRegex(release.ReleaseError, "applicationId"):
            self.apk_check(
                package="package: name='de.opennoodle.gallery.debug' versionCode='6' versionName='5.7.2'\n"
            )

    def test_old_build_number_is_rejected(self):
        with self.assertRaisesRegex(release.ReleaseError, "version"):
            self.apk_check(
                package="package: name='de.opennoodle.gallery' versionCode='5' versionName='5.7.2'\n"
            )

    def test_wrong_version_name_is_rejected(self):
        with self.assertRaisesRegex(release.ReleaseError, "version"):
            self.apk_check(
                package="package: name='de.opennoodle.gallery' versionCode='6' versionName='3.2.0'\n"
            )

    def test_missing_provenance_manifest_is_rejected(self):
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(release, "repository_check"),
            patch.object(
                release,
                "artifact_paths",
                return_value=(
                    Path(temporary) / "Foto.apk",
                    Path(temporary) / "missing.json",
                ),
            ),
        ):
            with self.assertRaisesRegex(release.ReleaseError, "provenance"):
                release.postflight(Path(temporary), HEAD, 6, {})

    def test_artifact_hash_receipt_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            manifest = root / "manifest.json"
            manifest.write_text(
                json.dumps(
                    {
                        "source_commit": HEAD,
                        "source_branch": "work",
                        "completed_checks": release.STAGES,
                        "apk_sha256": "old",
                    }
                )
            )
            with (
                patch.object(release, "repository_check"),
                patch.object(
                    release,
                    "artifact_paths",
                    return_value=(root / "Foto.apk", manifest),
                ),
                patch.object(release, "version_name", return_value="5.7.2"),
                patch.object(release, "sdk_path", return_value=root),
                patch.object(
                    release, "apk_metadata", return_value={"apk_sha256": "changed"}
                ),
            ):
                with self.assertRaisesRegex(release.ReleaseError, "apk_sha256"):
                    release.postflight(root, HEAD, 6, {})

    def test_completed_artifact_reuse_does_not_run_build_or_read_keys(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            receipt = root / "manifest.json"
            receipt.write_text("{}")
            with (
                patch.object(release, "preflight", return_value=True),
                patch.object(
                    release, "artifact_paths", return_value=(root / "Foto.apk", receipt)
                ),
                patch.object(release, "postflight") as post,
                patch.object(release, "signing_stats") as keys,
                patch.object(release.subprocess, "run") as process,
                redirect_stdout(io.StringIO()),
            ):
                release.build(root, HEAD, 6, {})
                post.assert_called_once()
                keys.assert_not_called()
                process.assert_not_called()

    def test_restore_only_owned_generated_report_and_preserve_diagnostic(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = root / release.GRADLE_REPORT
            report.parent.mkdir(parents=True)
            report.write_bytes(b"generated by this build")
            unrelated = root / "user-work.txt"
            unrelated.write_bytes(b"preserve me")
            output = root / "private-output"
            output.mkdir()
            with redirect_stdout(io.StringIO()):
                release.restore_owned_report(root, b"original report", output)
                release.restore_owned_report(root, b"original report", output)
            self.assertEqual(report.read_bytes(), b"original report")
            self.assertEqual(
                (output / "gradle-problems-generated.html").read_bytes(),
                b"generated by this build",
            )
            self.assertEqual(unrelated.read_bytes(), b"preserve me")

    def test_no_report_snapshot_never_restores_user_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            report = root / release.GRADLE_REPORT
            report.parent.mkdir(parents=True)
            report.write_bytes(b"do not alter")
            release.restore_owned_report(root, None, root)
            self.assertEqual(report.read_bytes(), b"do not alter")


if __name__ == "__main__":
    unittest.main()
