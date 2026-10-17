"""Sealed APK signing guards with synthetic ZIPs and mocked SDK/Java tools.

No real key, Android signing operation, install or production access is used.
"""

from contextlib import ExitStack, redirect_stdout
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import zipfile


RELEASE = Path(__file__).parents[1]
sys.path.insert(0, str(RELEASE))
try:
    SPEC = importlib.util.spec_from_file_location(
        "gallery_android_sign_package_tests", RELEASE / "android_sign_package.py"
    )
    assert SPEC and SPEC.loader
    signing = importlib.util.module_from_spec(SPEC)
    SPEC.loader.exec_module(signing)
finally:
    sys.path.remove(str(RELEASE))

SOURCE = "1" * 40
PROFILE_SHA = "2" * 64
CI_CERTIFICATE = "3" * 64
OTHER_CERTIFICATE = "4" * 64
PAYLOAD = {
    "AndroidManifest.xml": b"synthetic manifest, not installable",
    "classes.dex": b"synthetic bytecode",
    "lib/arm64-v8a/libapp.so": b"synthetic application native library",
    "lib/arm64-v8a/libflutter.so": b"synthetic Flutter native library",
    "assets/test-photo.bin": b"disposable synthetic media",
}


def apk(path, certificate=CI_CERTIFICATE, changed=False):
    with zipfile.ZipFile(path, "w") as archive:
        for name, data in PAYLOAD.items():
            archive.writestr(name, data + (b" tampered" if changed and name == "classes.dex" else b""))
        archive.writestr("META-INF/CERT.SF", certificate)
        archive.writestr("META-INF/CERT.RSA", b"synthetic certificate, not a private key")
    path.chmod(0o600)


class AndroidSignPackageTests(unittest.TestCase):
    def setUp(self):
        self.stack = ExitStack()
        self.addCleanup(self.stack.close)
        self.root = Path(self.stack.enter_context(tempfile.TemporaryDirectory(prefix="gallery-sign-fixture-")))
        self.root.chmod(0o700)
        self.source = self.root / "input.apk"
        apk(self.source)
        self.keys = self.root / "synthetic-existing-keys"
        self.keys.mkdir(mode=0o700)
        for name in ("key.jks", "key.properties"):
            path = self.keys / name
            path.write_text("SYNTHETIC FIXTURE ONLY; NO KEY OR PASSWORD")
            path.chmod(0o600)
        self.sdk = self.root / "sdk"
        self.sdk.mkdir()
        self.java_home = self.root / "java"
        (self.java_home / "bin").mkdir(parents=True)
        (self.java_home / "bin/java").write_text("synthetic tool; must never execute")
        self.env = {"JAVA_HOME": str(self.java_home)}
        self.output = self.root / "signed-output"
        self.profile = {
            "sourceCommit": SOURCE,
            "mobileVersion": "5.7.3",
            "mobileBuild": 11,
            "android": {
                "sha256": signing.android.digest(self.source),
                "run": 123456,
                "certificateSHA256": CI_CERTIFICATE,
            },
        }
        self.sign_count = 0
        self.tool_commands = []
        self.metadata_calls = []
        self.changed_output = False
        self.output_certificate = signing.android.CERTIFICATE_SHA256
        self.after_sign = None
        self.metadata_hook = None
        self.key_checked = self.stack.enter_context(
            patch.object(signing, "key_stats", wraps=signing.key_stats)
        )
        self.stack.enter_context(patch.object(signing.android, "sdk_path", return_value=self.sdk))
        self.stack.enter_context(patch.object(signing.android, "apk_metadata", side_effect=self.metadata))
        self.tools = self.stack.enter_context(patch.object(signing.android, "run", side_effect=self.run_tool))

    def metadata(self, file, sdk, cwd, version, number, certificate=signing.android.CERTIFICATE_SHA256):
        self.metadata_calls.append((file, version, number, certificate))
        with zipfile.ZipFile(file) as archive:
            actual = archive.read("META-INF/CERT.SF").decode()
        if actual != certificate:
            raise signing.android.ReleaseError("wrong synthetic signing certificate")
        result = {
            "application_id": signing.android.APP_ID,
            "version_name": version,
            "version_code": number,
            "certificate_sha256": certificate,
            "apk_sha256": signing.android.digest(file),
            "apk_bytes": file.stat().st_size,
        }
        if self.metadata_hook:
            self.metadata_hook(file)
        return result

    def run_tool(self, command, cwd, env):
        self.tool_commands.append(command)
        if command[-1] == "-version":
            return 'openjdk version "17.0.16"\n'
        if str(command[1]).endswith("SignExistingApk.java"):
            self.sign_count += 1
            source, output = Path(command[-2]), Path(command[-1])
            with zipfile.ZipFile(source) as archive:
                files = {name: archive.read(name) for name in archive.namelist()}
            files["META-INF/CERT.SF"] = self.output_certificate.encode()
            if self.changed_output:
                files["classes.dex"] += b" changed during signing"
            with zipfile.ZipFile(output, "w") as archive:
                for name, data in files.items():
                    archive.writestr(name, data)
            if self.after_sign:
                self.after_sign()
            return ""
        if Path(command[0]).name == "zipalign":
            return ""
        raise AssertionError("unexpected mocked command")

    def sign(self):
        with redirect_stdout(io.StringIO()):
            return signing.sign(
                self.profile, PROFILE_SHA, self.source, self.keys, self.output, self.env
            )

    def test_sealed_input_signed_without_changing_payload_or_keys(self):
        before = [file.read_bytes() for file in sorted(self.keys.iterdir())]
        result = self.sign()
        self.assertEqual(self.sign_count, 1)
        self.assertEqual(signing.android.apk_payload(self.source), signing.android.apk_payload(self.output / "Foto.apk"))
        self.assertEqual(result["sourceCommit"], SOURCE)
        self.assertEqual(result["profileSHA256"], PROFILE_SHA)
        self.assertEqual(result["inputSHA256"], self.profile["android"]["sha256"])
        self.assertEqual(result["certificate_sha256"], signing.android.CERTIFICATE_SHA256)
        self.assertEqual([file.read_bytes() for file in sorted(self.keys.iterdir())], before)
        self.assertEqual((self.output / "Foto.apk").stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.output / "android-signed.json").stat().st_mode & 0o777, 0o600)

    def test_no_approval_rejects_before_profile_import_or_key_access(self):
        with (
            patch.dict(sys.modules, {"build11_artifacts": Mock(load=Mock(side_effect=AssertionError("must not load")))}),
            patch.object(signing, "sign", side_effect=AssertionError("must not access signing paths")),
            redirect_stdout(io.StringIO()) as output,
        ):
            result = signing.main([
                "--profile", str(self.root / "unused-profile.json"),
                "--profile-sha256", PROFILE_SHA,
                "--input-apk", str(self.source), "--android-directory", str(self.keys),
                "--output", str(self.output),
            ])
        self.assertEqual(result, 1)
        self.assertIn("FAIL", output.getvalue())
        self.key_checked.assert_not_called()
        self.tools.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_explicit_approval_loads_pinned_profile_before_signing(self):
        load = Mock(return_value=self.profile)
        profile_path = self.root / "profile.json"
        with (
            patch.dict(sys.modules, {"build11_artifacts": SimpleNamespace(load=load)}),
            patch.dict(signing.os.environ, self.env, clear=True),
            redirect_stdout(io.StringIO()) as output,
        ):
            result = signing.main([
                "--authorize-production-signing", "--profile", str(profile_path),
                "--profile-sha256", PROFILE_SHA, "--input-apk", str(self.source),
                "--android-directory", str(self.keys), "--output", str(self.output),
            ])
        self.assertEqual(result, 0)
        load.assert_called_once_with(profile_path, PROFILE_SHA)
        self.assertEqual(self.sign_count, 1)
        self.assertIn("NOT INSTALLED", output.getvalue())
        self.assertNotIn("SYNTHETIC FIXTURE", output.getvalue())

    def test_invalid_profile_rejects_before_key_or_input_access(self):
        load = Mock(side_effect=ValueError("untrusted credential detail must not print"))
        with (
            patch.dict(sys.modules, {"build11_artifacts": SimpleNamespace(load=load)}),
            patch.object(signing, "sign") as sign,
            redirect_stdout(io.StringIO()) as output,
        ):
            result = signing.main([
                "--authorize-production-signing", "--profile", str(self.root / "profile.json"),
                "--profile-sha256", PROFILE_SHA, "--input-apk", str(self.source),
                "--android-directory", str(self.keys), "--output", str(self.output),
            ])
        self.assertEqual(result, 1)
        sign.assert_not_called()
        self.key_checked.assert_not_called()
        self.assertNotIn("untrusted credential", output.getvalue())

    def test_input_sha_mismatch_stops_before_key_access(self):
        apk(self.source, changed=True)
        with self.assertRaisesRegex(signing.android.ReleaseError, "input APK differs"):
            self.sign()
        self.key_checked.assert_not_called()
        self.tools.assert_not_called()
        self.assertFalse(self.output.exists())

    def test_input_symlink_rejected_before_key_access(self):
        linked = self.root / "linked.apk"
        linked.symlink_to(self.source)
        self.source = linked
        with self.assertRaises(signing.android.ReleaseError):
            self.sign()
        self.key_checked.assert_not_called()
        self.tools.assert_not_called()

    def test_wrong_version_rejects_before_key_access(self):
        self.profile["mobileBuild"] = 10
        with self.assertRaisesRegex(signing.android.ReleaseError, "exact Build 11"):
            self.sign()
        self.key_checked.assert_not_called()
        self.tools.assert_not_called()

    def test_wrong_ci_certificate_stops_before_key_access(self):
        self.profile["android"]["certificateSHA256"] = OTHER_CERTIFICATE
        with self.assertRaisesRegex(signing.android.ReleaseError, "certificate"):
            self.sign()
        self.key_checked.assert_not_called()
        self.tools.assert_not_called()

    def test_nonprivate_output_parent_rejected(self):
        self.root.chmod(0o755)
        with self.assertRaisesRegex(signing.android.ReleaseError, "owned and private"):
            self.sign()
        self.key_checked.assert_not_called()
        self.tools.assert_not_called()

    def test_existing_output_symlink_rejected(self):
        outside = self.root / "untrusted-output"
        outside.mkdir(mode=0o700)
        self.output.symlink_to(outside)
        with self.assertRaises(signing.android.ReleaseError):
            self.sign()
        self.key_checked.assert_not_called()
        self.tools.assert_not_called()

    def test_nonprivate_key_files_rejected_without_signing(self):
        for name in ("key.jks", "key.properties"):
            with self.subTest(name=name):
                path = self.keys / name
                path.chmod(0o644)
                with self.assertRaisesRegex(signing.android.ReleaseError, "owned and private"):
                    self.sign()
                self.assertEqual(self.sign_count, 0)
                path.chmod(0o600)

    def test_symlink_key_file_rejected_without_signing(self):
        file = self.keys / "key.jks"
        target = self.root / "synthetic-target"
        file.rename(target)
        file.symlink_to(target)
        with self.assertRaisesRegex(signing.android.ReleaseError, "owned and private"):
            self.sign()
        self.assertEqual(self.sign_count, 0)

    def test_empty_key_file_rejected_without_signing(self):
        (self.keys / "key.jks").write_bytes(b"")
        with self.assertRaisesRegex(signing.android.ReleaseError, "existing nonempty"):
            self.sign()
        self.assertEqual(self.sign_count, 0)

    def test_wrong_hp_certificate_rejected_without_publishing(self):
        self.output_certificate = OTHER_CERTIFICATE
        with self.assertRaisesRegex(signing.android.ReleaseError, "certificate"):
            self.sign()
        self.assertFalse((self.output / "Foto.apk").exists())
        self.assertFalse((self.output / "android-signed.json").exists())

    def test_signed_payload_tamper_rejected_without_publishing(self):
        self.changed_output = True
        with self.assertRaisesRegex(signing.android.ReleaseError, "payload"):
            self.sign()
        self.assertFalse((self.output / "Foto.apk").exists())
        self.assertFalse((self.output / "android-signed.json").exists())

    def test_key_metadata_change_rejected_without_publishing(self):
        self.after_sign = lambda: (self.keys / "key.jks").write_bytes(b"changed synthetic fixture")
        with self.assertRaisesRegex(signing.android.ReleaseError, "key metadata changed"):
            self.sign()
        self.assertFalse((self.output / "Foto.apk").exists())

    def test_idempotent_completed_output_never_resigns_or_reads_keys(self):
        first = self.sign()
        self.key_checked.reset_mock()
        self.tools.reset_mock()
        second = self.sign()
        self.assertEqual(first, second)
        self.assertEqual(self.sign_count, 1)
        self.key_checked.assert_not_called()
        self.assertTrue(all(Path(call.args[0][0]).name == "zipalign" for call in self.tools.call_args_list))

    def test_interrupted_receipt_creation_reuses_verified_signed_apk_without_key_access(self):
        first = self.sign()
        (self.output / "android-signed.json").unlink()
        self.key_checked.reset_mock()
        self.tools.reset_mock()
        resumed = self.sign()
        self.assertEqual(first, resumed)
        self.assertEqual(self.sign_count, 1)
        self.assertTrue((self.output / "android-signed.json").exists())
        self.key_checked.assert_not_called()
        self.assertTrue(all(Path(call.args[0][0]).name == "zipalign" for call in self.tools.call_args_list))

    def test_interrupted_receipt_write_resumes_without_resigning_or_key_access(self):
        def interrupted_dump(value, handle, **kwargs):
            handle.write('{"partial":')
            raise KeyboardInterrupt()
        with patch.object(signing.json, "dump", side_effect=interrupted_dump):
            with self.assertRaises(KeyboardInterrupt):
                self.sign()
        self.assertTrue((self.output / "Foto.apk").exists())
        self.assertFalse((self.output / "android-signed.json").exists())
        self.key_checked.reset_mock()
        self.tools.reset_mock()
        result = self.sign()
        self.assertEqual(result["sourceCommit"], SOURCE)
        self.assertEqual(self.sign_count, 1)
        self.key_checked.assert_not_called()
        self.assertTrue(all(Path(call.args[0][0]).name == "zipalign" for call in self.tools.call_args_list))

    def test_existing_invalid_receipt_remains_untouched(self):
        self.sign()
        report = self.output / "android-signed.json"
        report.write_text('{"invalid":')
        before = report.read_bytes()
        self.key_checked.reset_mock()
        self.tools.reset_mock()
        with self.assertRaises(ValueError):
            self.sign()
        self.assertEqual(report.read_bytes(), before)
        self.assertEqual(self.sign_count, 1)
        self.key_checked.assert_not_called()

    def test_existing_symlink_apk_is_rejected_without_target_changes(self):
        self.output.mkdir(mode=0o700)
        target = self.root / "signed-target.apk"
        apk(target, signing.android.CERTIFICATE_SHA256)
        (self.output / "Foto.apk").symlink_to(target)
        before = target.read_bytes()
        with self.assertRaises(signing.android.ReleaseError):
            self.sign()
        self.assertEqual(target.read_bytes(), before)
        self.key_checked.assert_not_called()
        self.assertEqual(self.sign_count, 0)

    def test_existing_symlink_receipt_is_rejected_without_target_changes(self):
        self.sign()
        report = self.output / "android-signed.json"
        target = self.root / "existing-receipt-target.json"
        report.rename(target)
        report.symlink_to(target)
        before = target.read_bytes()
        self.key_checked.reset_mock()
        with self.assertRaises(signing.android.ReleaseError):
            self.sign()
        self.assertEqual(target.read_bytes(), before)
        self.key_checked.assert_not_called()
        self.assertEqual(self.sign_count, 1)

    def test_existing_apk_with_other_payload_is_not_overwritten(self):
        self.output.mkdir(mode=0o700)
        existing = self.output / "Foto.apk"
        apk(existing, signing.android.CERTIFICATE_SHA256, changed=True)
        before = existing.read_bytes()
        with self.assertRaisesRegex(signing.android.ReleaseError, "payload"):
            self.sign()
        self.assertEqual(existing.read_bytes(), before)
        self.key_checked.assert_not_called()
        self.tools.assert_not_called()

    def test_existing_other_signed_apk_is_not_overwritten(self):
        self.output.mkdir(mode=0o700)
        existing = self.output / "Foto.apk"
        apk(existing, OTHER_CERTIFICATE)
        before = existing.read_bytes()
        with self.assertRaisesRegex(signing.android.ReleaseError, "certificate"):
            self.sign()
        self.assertEqual(existing.read_bytes(), before)
        self.key_checked.assert_not_called()
        self.tools.assert_not_called()

    def test_existing_receipt_without_apk_is_not_overwritten(self):
        self.output.mkdir(mode=0o700)
        report = self.output / "android-signed.json"
        report.write_text("existing receipt")
        report.chmod(0o600)
        with self.assertRaisesRegex(signing.android.ReleaseError, "receipt without APK"):
            self.sign()
        self.assertEqual(report.read_text(), "existing receipt")
        self.key_checked.assert_not_called()
        self.tools.assert_not_called()

    def test_existing_receipt_mismatch_never_overwritten(self):
        self.sign()
        report = self.output / "android-signed.json"
        content = json.loads(report.read_text())
        content["sourceCommit"] = "5" * 40
        report.write_text(json.dumps(content))
        before = report.read_bytes()
        self.key_checked.reset_mock()
        self.tools.reset_mock()
        with self.assertRaisesRegex(signing.android.ReleaseError, "receipt mismatch"):
            self.sign()
        self.assertEqual(report.read_bytes(), before)
        self.key_checked.assert_not_called()
        self.assertTrue(all(Path(call.args[0][0]).name == "zipalign" for call in self.tools.call_args_list))

    def test_input_changed_during_preflight_is_not_signed(self):
        def mutate(file):
            if self.sign_count == 0:
                apk(file, changed=True)
        self.metadata_hook = mutate
        with self.assertRaises(signing.android.ReleaseError):
            self.sign()
        self.assertEqual(self.sign_count, 0)
        self.key_checked.assert_not_called()

    def test_original_input_change_after_staging_cannot_change_signed_payload(self):
        original_payload = signing.android.apk_payload(self.source)
        def mutate_original(file):
            if file != self.source and self.sign_count == 0:
                apk(self.source, changed=True)
        self.metadata_hook = mutate_original
        self.sign()
        self.assertEqual(signing.android.apk_payload(self.output / "Foto.apk"), original_payload)
        self.assertEqual(self.sign_count, 1)
        java_calls = [command for command in self.tool_commands if len(command) > 1 and str(command[1]).endswith("SignExistingApk.java")]
        self.assertEqual(len(java_calls), 1)
        self.assertNotEqual(Path(java_calls[0][-2]), self.source)

    def test_existing_nonprivate_lock_rejected_before_key_access(self):
        self.output.mkdir(mode=0o700)
        lock = self.output / ".sign.lock"
        lock.write_text("existing lock, preserve")
        lock.chmod(0o644)
        with self.assertRaises(signing.android.ReleaseError):
            self.sign()
        self.assertEqual(lock.read_text(), "existing lock, preserve")
        self.key_checked.assert_not_called()
        self.assertEqual(self.sign_count, 0)

    def test_existing_symlink_lock_rejected_before_key_access(self):
        self.output.mkdir(mode=0o700)
        target = self.root / "existing-lock-target"
        target.write_text("target must survive")
        target.chmod(0o600)
        (self.output / ".sign.lock").symlink_to(target)
        with self.assertRaises(OSError):
            self.sign()
        self.assertEqual(target.read_text(), "target must survive")
        self.key_checked.assert_not_called()
        self.assertEqual(self.sign_count, 0)

    def test_zipalign_failure_does_not_publish_apk_or_receipt(self):
        def tool(command, cwd, env):
            if Path(command[0]).name == "zipalign":
                raise signing.android.ReleaseError("alignment failed")
            return self.run_tool(command, cwd, env)
        self.tools.side_effect = tool
        with self.assertRaises(signing.android.ReleaseError):
            self.sign()
        self.assertFalse((self.output / "Foto.apk").exists())
        self.assertFalse((self.output / "android-signed.json").exists())

    def test_interruption_before_publish_leaves_no_final_output(self):
        self.after_sign = lambda: (_ for _ in ()).throw(KeyboardInterrupt())
        with self.assertRaises(KeyboardInterrupt):
            self.sign()
        self.assertFalse((self.output / "Foto.apk").exists())
        self.assertFalse((self.output / "android-signed.json").exists())
        self.assertFalse(any(self.output.glob(".sign-*/Foto.apk")))

    def test_output_created_during_signing_is_never_overwritten(self):
        def occupy():
            file = self.output / "Foto.apk"
            file.write_bytes(b"existing concurrent output must survive")
            file.chmod(0o600)
        self.after_sign = occupy
        with self.assertRaises((signing.android.ReleaseError, FileExistsError)):
            self.sign()
        self.assertEqual((self.output / "Foto.apk").read_bytes(), b"existing concurrent output must survive")
        self.assertFalse((self.output / "android-signed.json").exists())


if __name__ == "__main__":
    unittest.main()
