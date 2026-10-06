"""Offline checks for the macOS lane; these do not compile Apple frameworks."""

import importlib.util
import json
import os
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml

SCRIPTS = Path(__file__).resolve().parents[1]
REPOSITORY = SCRIPTS.parents[1]
spec = importlib.util.spec_from_file_location(
    "archive_verifier", SCRIPTS / "verify_ios_archive.py"
)
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)


def make_archive(archive):
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
        (bundle / "binary").write_bytes(b"compiled-binary-fixture")
        (bundle / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleIdentifier": identifier,
                    "CFBundleExecutable": "binary",
                    "MinimumOSVersion": minimum,
                    "AppGroupId": "group.de.opennoodle.gallery.share",
                }
            )
        )
    return application


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.archive = Path(self.directory.name) / "Runner.xcarchive"
        self.application = make_archive(self.archive)

    def test_complete_app_and_both_extensions(self):
        self.assertEqual(verifier.verify_archive(self.archive), self.application)

    def test_missing_archive(self):
        with self.assertRaises(ValueError):
            verifier.verify_archive(self.archive / "absent")

    def test_missing_extension(self):
        shutil.rmtree(self.application / "PlugIns/ShareExtension.appex")
        with self.assertRaises(OSError):
            verifier.verify_archive(self.archive)

    def test_empty_executable(self):
        (self.application / "PlugIns/WidgetExtension.appex/binary").write_bytes(b"")
        with self.assertRaises(ValueError):
            verifier.verify_archive(self.archive)

    def test_multiple_apps(self):
        (self.application.parent / "Unexpected.app").mkdir()
        with self.assertRaises(ValueError):
            verifier.verify_archive(self.archive)

    def test_wrong_extension_identity(self):
        metadata = self.application / "PlugIns/ShareExtension.appex/Info.plist"
        values = plistlib.loads(metadata.read_bytes())
        values["CFBundleIdentifier"] = "another.app.ShareExtension"
        metadata.write_bytes(plistlib.dumps(values))
        with self.assertRaises(ValueError):
            verifier.verify_archive(self.archive)

    def test_silently_raised_runner_floor(self):
        metadata = self.application / "Info.plist"
        values = plistlib.loads(metadata.read_bytes())
        values["MinimumOSVersion"] = "17.0"
        metadata.write_bytes(plistlib.dumps(values))
        with self.assertRaises(ValueError):
            verifier.verify_archive(self.archive)

    def test_original_fork_bundle_identity_is_required(self):
        with self.assertRaises(ValueError):
            verifier.verify_archive(self.archive, bundle_id="unexpected.bundle")

    def test_original_app_group_identity_is_required(self):
        with self.assertRaises(ValueError):
            verifier.verify_archive(self.archive, app_group="unexpected.group")


class LaneTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        (self.root / "branding").mkdir()
        (self.root / "branding/config.json").write_text(
            json.dumps(
                {
                    "mobile": {
                        "bundle_id": "de.opennoodle.gallery",
                        "shared_group": "group.de.opennoodle.gallery.share",
                    }
                }
            )
        )
        self.mobile = self.root / "mobile"
        scripts = self.mobile / "scripts"
        scripts.mkdir(parents=True)
        for file in ("ios_build_only.sh", "verify_ios_archive.py"):
            shutil.copyfile(SCRIPTS / file, scripts / file)
        self.script = scripts / "ios_build_only.sh"
        (self.mobile / "mise.toml").write_text(
            '[tools."aqua:flutter/flutter"]\nversion = "3.47.2"\n'
        )
        (self.mobile / "pubspec.yaml").write_text("environment:\n  flutter: 3.47.2\n")
        (self.mobile / "ios").mkdir()
        (self.mobile / "pigeon").mkdir()
        for definition in (REPOSITORY / "mobile/pigeon").glob("*.dart"):
            shutil.copyfile(definition, self.mobile / "pigeon" / definition.name)
        (self.mobile / ".dart_tool").mkdir()
        package = self.root / "pigeon/bin"
        package.mkdir(parents=True)
        (package / "pigeon.dart").write_text("// Fixture executable\n")
        (self.mobile / ".dart_tool/package_config.json").write_text(
            json.dumps(
                {"packages": [{"name": "pigeon", "rootUri": (package.parent).as_uri()}]}
            )
        )
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "commands.jsonl"
        self.environment = dict(
            os.environ, PATH=f"{self.bin}:{os.environ['PATH']}", TEST_LOG=str(self.log)
        )
        for command in ("uname", "xcodebuild", "mise", "bundle"):
            executable = self.bin / command
            executable.write_text(
                "#!/usr/bin/env python3\n"
                "import json,os,sys\n"
                "from pathlib import Path\n"
                "command=Path(sys.argv[0]).name\n"
                "with open(os.environ['TEST_LOG'],'a') as log: log.write(json.dumps([command,*sys.argv[1:]])+'\\n')\n"
                "if command=='uname': print(os.environ.get('TEST_OS','Darwin'))\n"
                "if command=='mise' and '--machine' in sys.argv: print(json.dumps({'frameworkVersion':os.environ.get('TEST_FLUTTER','3.47.2')}))\n"
                "if command=='bundle' and sys.argv[1:4]==['exec','pod','install']:\n"
                "    failure='TEST_POD_FAIL_DEPLOYMENT' if '--deployment' in sys.argv else 'TEST_POD_FAIL_REFRESH'\n"
                "    if os.environ.get(failure): raise SystemExit(8)\n"
                "if command=='mise' and 'build' in sys.argv and 'ipa' in sys.argv:\n"
                "    if os.environ.get('TEST_BUILD_FAIL'): raise SystemExit(7)\n"
                "    if os.environ.get('TEST_COPY_ARCHIVE'):\n"
                "        import shutil\n"
                "        shutil.copytree(os.environ['TEST_COPY_ARCHIVE'],Path.cwd()/'build/ios/archive/Runner.xcarchive')\n"
            )
            executable.chmod(0o755)

    def run_lane(self, *arguments):
        return subprocess.run(
            ["bash", str(self.script), *arguments],
            env=self.environment,
            capture_output=True,
            text=True,
        )

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def assert_full_preparation(self, commands):
        self.assertIn(["mise", "run", "//:open-api-dart"], commands)
        self.assertIn(
            ["mise", "exec", "--", "flutter", "pub", "get", "--enforce-lockfile"],
            commands,
        )
        definitions = {command[-1] for command in commands if "--input" in command}
        self.assertEqual(
            definitions,
            {f"pigeon/{file.name}" for file in (self.mobile / "pigeon").glob("*.dart")},
        )
        for generator in (
            "easy_localization:generate",
            "bin/generate_keys.dart",
            "drift_dev",
            "build_runner",
        ):
            self.assertTrue(any(generator in command for command in commands))

    def pod_commands(self, commands):
        return [
            command for command in commands if command[:3] == ["bundle", "exec", "pod"]
        ]

    def test_full_prepare_runs_all_generators_and_locked_install(self):
        result = self.run_lane("--prepare-only")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assert_full_preparation(commands)
        self.assertEqual(
            self.pod_commands(commands),
            [["bundle", "exec", "pod", "install", "--deployment"]],
        )
        self.assertFalse(any("ipa" in command for command in commands))

    def test_explicit_refresh_installs_then_verifies_without_archiving(self):
        result = self.run_lane("--refresh-pods-lock")
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        self.assert_full_preparation(commands)
        self.assertEqual(
            self.pod_commands(commands),
            [
                ["bundle", "exec", "pod", "install"],
                ["bundle", "exec", "pod", "install", "--deployment"],
            ],
        )
        self.assertFalse(any("ipa" in command for command in commands))
        self.assertNotIn("Unsigned build-only archive verified", result.stdout)
        self.assertFalse((self.mobile / "build/ios/archive/Runner.xcarchive").exists())

    def test_refresh_pod_failure_propagates_without_archiving(self):
        for failing_step, expected_calls in (
            ("TEST_POD_FAIL_REFRESH", [["bundle", "exec", "pod", "install"]]),
            (
                "TEST_POD_FAIL_DEPLOYMENT",
                [
                    ["bundle", "exec", "pod", "install"],
                    ["bundle", "exec", "pod", "install", "--deployment"],
                ],
            ),
        ):
            with self.subTest(failing_step=failing_step):
                self.log.unlink(missing_ok=True)
                self.environment[failing_step] = "1"
                result = self.run_lane("--refresh-pods-lock")
                self.environment.pop(failing_step)
                self.assertEqual(result.returncode, 8, result.stderr)
                commands = self.commands()
                self.assertEqual(self.pod_commands(commands), expected_calls)
                self.assertFalse(any("ipa" in command for command in commands))

    def test_non_macos_is_explicit_failure(self):
        self.environment["TEST_OS"] = "Linux"
        result = self.run_lane()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NEEDS_MAC_VALIDATION", result.stderr)
        self.assertEqual(len(self.commands()), 1)

    def test_wrong_flutter_version_fails_before_codegen(self):
        self.environment["TEST_FLUTTER"] = "3.0.0"
        result = self.run_lane()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(
            any("//:open-api-dart" in command for command in self.commands())
        )

    def test_mismatched_pins_fail(self):
        (self.mobile / "pubspec.yaml").write_text("environment:\n  flutter: 3.0.0\n")
        result = self.run_lane()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disagree", result.stderr)

    def test_successful_command_without_artifact_fails(self):
        result = self.run_lane("--skip-prepare")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected Runner.xcarchive is missing", result.stderr)

    def test_stale_archive_cannot_hide_missing_new_artifact(self):
        make_archive(self.mobile / "build/ios/archive/Runner.xcarchive")
        result = self.run_lane("--skip-prepare")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.mobile / "build/ios/archive/Runner.xcarchive").exists())

    def test_build_failure_propagates(self):
        self.environment["TEST_BUILD_FAIL"] = "1"
        self.assertEqual(self.run_lane("--skip-prepare").returncode, 7)

    def test_unsigned_archive_success_without_release_commands(self):
        fixture = self.root / "fixture.xcarchive"
        make_archive(fixture)
        self.environment["TEST_COPY_ARCHIVE"] = str(fixture)
        result = self.run_lane()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.pod_commands(self.commands()),
            [["bundle", "exec", "pod", "install", "--deployment"]],
        )
        self.assertIn(
            [
                "mise",
                "exec",
                "--",
                "flutter",
                "build",
                "ipa",
                "--release",
                "--no-codesign",
            ],
            self.commands(),
        )
        self.assertFalse(
            any(
                any(
                    word in command
                    for word in ("sigh", "security", "fastlane", "upload_to_testflight")
                )
                for command in self.commands()
            )
        )


class WorkflowShellTests(unittest.TestCase):
    def wrapper_steps(self):
        workflow = yaml.load(
            (REPOSITORY / ".github/workflows/gallery-build-mobile.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        for job, name, arguments in (
            (
                "refresh-ios-pods-lock",
                "Refresh and verify CocoaPods lock",
                ["--refresh-pods-lock"],
            ),
            ("build-sign-ios", "Build iOS (no upload)", []),
        ):
            step = next(
                item
                for item in workflow["jobs"][job]["steps"]
                if item.get("name") == name
            )
            yield step, arguments

    def run_wrapper(self, step, status):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scripts = root / "scripts"
            scripts.mkdir()
            (scripts / "ios_build_only.sh").write_text(
                "#!/usr/bin/env bash\n"
                "python3 - \"$@\" <<'PY'\n"
                "import json, os, sys\n"
                "from pathlib import Path\n"
                "Path(os.environ['TEST_ARGUMENTS']).write_text(json.dumps(sys.argv[1:]))\n"
                "print('first 50% diagnostic', flush=True)\n"
                "print('last diagnostic', file=sys.stderr, flush=True)\n"
                "raise SystemExit(int(os.environ['TEST_STATUS']))\n"
                "PY\n"
            )
            arguments = root / "arguments.json"
            result = subprocess.run(
                ["bash", "--noprofile", "--norc", "-e", "-c", step["run"]],
                cwd=root,
                env=dict(
                    os.environ,
                    RUNNER_TEMP=str(root),
                    TEST_ARGUMENTS=str(arguments),
                    TEST_STATUS=str(status),
                ),
                capture_output=True,
                text=True,
            )
            return (
                result,
                json.loads(arguments.read_text()),
                (root / "ios-build-only.log").read_text(),
            )

    def test_failure_keeps_exit_code_and_emits_escaped_annotation(self):
        for step, expected_arguments in self.wrapper_steps():
            with self.subTest(step=step["name"]):
                result, arguments, log = self.run_wrapper(step, 7)
                self.assertEqual(result.returncode, 7, result.stderr)
                self.assertEqual(arguments, expected_arguments)
                self.assertEqual(log, "first 50% diagnostic\nlast diagnostic\n")
                self.assertIn(
                    "::error title=Unsigned iOS build failure::"
                    "first 50%25 diagnostic%0Alast diagnostic",
                    result.stdout,
                )

    def test_success_keeps_zero_and_emits_no_error(self):
        for step, expected_arguments in self.wrapper_steps():
            with self.subTest(step=step["name"]):
                result, arguments, log = self.run_wrapper(step, 0)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(arguments, expected_arguments)
                self.assertEqual(log, "first 50% diagnostic\nlast diagnostic\n")
                self.assertNotIn("::error", result.stdout)


class ConfigurationTests(unittest.TestCase):
    def test_targets_have_independent_floors_in_all_configurations(self):
        project = (
            REPOSITORY / "mobile/ios/Runner.xcodeproj/project.pbxproj"
        ).read_text()
        blocks = dict(
            re.findall(
                r"^\t\t([A-F0-9]{24}) /\*.*?\*/ = \{\n(.*?)^\t\t\};",
                project,
                re.M | re.S,
            )
        )
        for name, floor in (
            ("Runner", "15.0"),
            ("ShareExtension", "16.0"),
            ("WidgetExtension", "17.0"),
        ):
            target = next(
                value
                for value in blocks.values()
                if "isa = PBXNativeTarget;" in value and f"name = {name};" in value
            )
            configuration_list = re.search(
                r"buildConfigurationList = ([A-F0-9]{24})", target
            ).group(1)
            configurations = re.findall(
                r"([A-F0-9]{24}) /\* (?:Debug|Release|Profile) \*/",
                blocks[configuration_list],
            )
            self.assertEqual(len(configurations), 3)
            for configuration in configurations:
                self.assertIn(
                    f"IPHONEOS_DEPLOYMENT_TARGET = {floor};", blocks[configuration]
                )

    def test_all_target_plists_entitlements_and_framework_parse(self):
        ios = REPOSITORY / "mobile/ios"
        for name in ("Runner", "ShareExtension", "WidgetExtension"):
            metadata = plistlib.loads((ios / name / "Info.plist").read_bytes())
            self.assertEqual(metadata["AppGroupId"], "$(CUSTOM_GROUP_ID)")
            entitlements = plistlib.loads(
                (
                    ios
                    / name
                    / f"{name if name != 'Runner' else 'Runner'}.entitlements"
                ).read_bytes()
            )
            self.assertEqual(
                entitlements["com.apple.security.application-groups"],
                ["$(CUSTOM_GROUP_ID)"],
            )
        profile = plistlib.loads(
            (ios / "Runner/RunnerProfile.entitlements").read_bytes()
        )
        self.assertEqual(
            profile["com.apple.security.application-groups"], ["$(CUSTOM_GROUP_ID)"]
        )
        framework = plistlib.loads(
            (ios / "Flutter/AppFrameworkInfo.plist").read_bytes()
        )
        self.assertEqual(framework["MinimumOSVersion"], "15.0")

    def test_build_only_fastlane_has_no_credential_or_signing_call(self):
        fastlane = (REPOSITORY / "mobile/ios/fastlane/Fastfile").read_text()
        build_only = fastlane.split("lane :gha_build_only do", 1)[1]
        self.assertIn("ios_build_only.sh", build_only)
        for forbidden in (
            "get_api_key",
            "sigh(",
            "configure_code_signing",
            "upload_to_testflight",
            "build_app(",
        ):
            self.assertNotIn(forbidden, build_only)

    def test_gallery_dispatch_credentials_are_exclusively_release_gated(self):
        workflow = yaml.load(
            (REPOSITORY / ".github/workflows/gallery-build-mobile.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        job = workflow["jobs"]["build-sign-ios"]
        for step in job["steps"]:
            if "secrets." in json.dumps(step):
                self.assertEqual(
                    step.get("if"), "inputs.version != ''", step.get("name")
                )
            if "security " in step.get("run", ""):
                self.assertIn("inputs.version != ''", step.get("if", ""))
        unsigned = next(
            step for step in job["steps"] if step.get("name") == "Build iOS (no upload)"
        )
        self.assertEqual(unsigned["if"], "inputs.version == ''")
        self.assertIn("ios_build_only.sh", unsigned["run"])
        artifact = next(
            step
            for step in job["steps"]
            if step.get("name") == "Upload unsigned archive"
        )
        self.assertEqual(
            artifact["with"]["path"], "mobile/build/ios/archive/Runner.xcarchive"
        )
        self.assertEqual(artifact["with"]["if-no-files-found"], "error")
        release = next(
            step for step in job["steps"] if step.get("name") == "Upload IPA artifact"
        )
        self.assertEqual(release["with"]["path"], "mobile/build/ios/ipa/gallery.ipa")
        self.assertEqual(release["with"]["if-no-files-found"], "error")
        for key, value in workflow["on"]["workflow_call"]["secrets"].items():
            if key.startswith(
                ("APP_STORE_CONNECT", "IOS_CERTIFICATE", "FASTLANE_TEAM")
            ):
                self.assertEqual(value["required"], "false")

    def test_pod_lock_maintenance_is_explicit_and_writes_only_review_branch(self):
        workflow = yaml.load(
            (REPOSITORY / ".github/workflows/gallery-build-mobile.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        for trigger in ("workflow_dispatch", "workflow_call"):
            option = workflow["on"][trigger]["inputs"]["refresh_ios_pods_lock"]
            self.assertEqual(option["type"], "boolean")
            self.assertEqual(option["default"], "false")
        job = workflow["jobs"]["refresh-ios-pods-lock"]
        for gate in (
            "github.event_name == 'workflow_dispatch'",
            "github.repository == 'docice545/gallery'",
            "inputs.refresh_ios_pods_lock",
            "inputs.build_target == 'ios'",
            "inputs.version == ''",
        ):
            self.assertIn(gate, job["if"])
        self.assertEqual(job["permissions"], {"contents": "write"})
        self.assertNotIn("secrets.", json.dumps(job))
        save = next(step for step in job["steps"] if "git push" in step.get("run", ""))
        self.assertEqual(
            save["env"]["LOCK_BRANCH"], "codex/ios-pods-lock-${{ github.run_id }}"
        )
        self.assertEqual(
            re.findall(r"^\s*git add .*", save["run"], re.M),
            ["git add -- mobile/ios/Podfile.lock"],
        )
        self.assertEqual(
            re.findall(r"^\s*git push .*", save["run"], re.M),
            ['git push origin "HEAD:refs/heads/$LOCK_BRANCH"'],
        )
        for name in ("build-sign-android", "build-sign-ios"):
            build = workflow["jobs"][name]
            self.assertIn("!inputs.refresh_ios_pods_lock", build["if"])
            self.assertEqual(build["permissions"], {"contents": "read"})
            checkout = next(
                step
                for step in build["steps"]
                if step.get("uses", "").startswith("actions/checkout@")
            )
            self.assertEqual(checkout["with"]["persist-credentials"], "false")

    def test_legacy_workflow_release_is_explicit(self):
        workflow = yaml.load(
            (REPOSITORY / ".github/workflows/build-mobile.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        self.assertEqual(
            workflow["on"]["workflow_call"]["inputs"]["ios_release"]["default"], "false"
        )
        for step in workflow["jobs"]["build-sign-ios"]["steps"]:
            if "secrets." in json.dumps(step):
                self.assertEqual(
                    step.get("if"), "inputs.ios_release == true", step.get("name")
                )

    def test_xcode_cloud_uses_pins_and_complete_codegen(self):
        script = (REPOSITORY / "mobile/ios/ci_scripts/ci_post_clone.sh").read_text()
        self.assertNotIn("-b stable", script)
        self.assertIn("mise install", script)
        self.assertIn("ios_build_only.sh --prepare-only", script)


if __name__ == "__main__":
    unittest.main()
