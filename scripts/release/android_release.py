#!/usr/bin/env python3
"""Prepare/verify an HP Android APK using the existing release identity.

No git updates, signing-key generation, installation or production operations.
Preflight/postflight are read-only. Build writes normal ignored build/codegen
outputs and refuses unexpected source changes rather than discarding them.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import tomllib
import zipfile


APP_ID = "de.opennoodle.gallery"
CERTIFICATE_SHA256 = "ad3e9c15946efe274efa83f96655c1b14d57539867cea27964ea9793a88ded18"
CI_BUILD_NUMBER = 8
CI_RUN = 37944044747
CI_SOURCE_SHA = "6a558b554e26e8c0fc5bc5c99259a92e7ef26a56"
CI_APK_SHA256 = "ae3ed08bfe8794e1f12193e5d29733c22c22e7671672726e1a27b869483a4527"
CI_CERTIFICATE_SHA256 = "d7bfd9bf0ff80fc97c3db14fdf96cf9996488439a8e906d7bece8078eef40410"
SIGN_EXISTING_CHECKS = ["pinned-ci-apk", "ci-package-manifest-signature", "unchanged-apk-payload", "production-signature"]
BUILD_TOOLS = "36.0.0"
STAGES = [
    "locked-codegen",
    "dart-format",
    "flutter-analyze",
    "flutter-tests",
    "android-native-tests",
    "release-locked-dependencies",
]
ROOT = Path(__file__).resolve().parents[2]
GRADLE_REPORT = "mobile/android/build/reports/problems/problems-report.html"
CLOUD_PROVIDER_CLASS = "app.alextran.immich.cloudmedia.GalleryCloudMediaProvider"
CLOUD_PROVIDER_AUTHORITY = f"{APP_ID}.cloudmedia"
CLOUD_PROVIDER_PERMISSION = (
    "com.android.providers.media.permission.MANAGE_CLOUD_MEDIA_PROVIDERS"
)
CLOUD_PROVIDER_ACTION = "android.content.action.CLOUD_MEDIA_PROVIDER"


class ReleaseError(Exception):
    pass


def run(command: list[str], cwd: Path, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True)
    if result.returncode:
        # Do not dump arbitrary environment, signing output or private file paths.
        raise ReleaseError(
            f"{Path(command[0]).name} verification failed (exit {result.returncode})"
        )
    return result.stdout + result.stderr


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def dependency_snapshot(mobile: Path) -> tuple[str, str]:
    """Ignore config timestamps, but retain the tested resolved package graph."""
    config = json.loads((mobile / ".dart_tool/package_config.json").read_text())
    packages = sorted(
        [
            {
                key: package.get(key)
                for key in ("name", "rootUri", "packageUri", "languageVersion")
            }
            for package in config["packages"]
        ],
        key=lambda package: package["name"],
    )
    graph = hashlib.sha256(json.dumps(packages, sort_keys=True).encode()).hexdigest()
    return digest(mobile / "pubspec.lock"), graph


def apk_build_command(name: str, number: int) -> list[str]:
    # Flutter 3.47 skips release-mode registrant regeneration with --no-pub.
    # Normal --pub refresh removes dev-only plugins after native integration tests.
    return [
        "flutter",
        "build",
        "apk",
        "--release",
        f"--build-name={name}",
        f"--build-number={number}",
        "--pub",
    ]


def repository_check(root: Path, expected: str) -> None:
    if not re.fullmatch(r"[0-9a-f]{40}", expected):
        raise ReleaseError(
            "--expected-head must be the full, reviewed 40-character commit SHA"
        )
    if run(["git", "branch", "--show-current"], root).strip() != "work":
        raise ReleaseError("branch must be work")
    if run(["git", "rev-parse", "HEAD"], root).strip() != expected:
        raise ReleaseError(
            "HEAD differs from --expected-head; no fetch/merge/reset is performed"
        )
    origin = run(["git", "remote", "get-url", "origin"], root).strip()
    if origin.removesuffix(".git") not in {
        "https://github.com/docice545/gallery",
        "git@github.com:docice545/gallery",
    }:
        raise ReleaseError(
            "origin must identify docice545/gallery on GitHub; credentials are not printed"
        )
    if run(["git", "status", "--porcelain"], root).strip():
        raise ReleaseError(
            "working tree is not clean; review/save changes without reset/clean"
        )


def sdk_path(env: dict[str, str]) -> Path:
    home, sdk = env.get("ANDROID_HOME"), env.get("ANDROID_SDK_ROOT")
    if not (home or sdk):
        raise ReleaseError("set ANDROID_HOME to the existing Android SDK")
    if home and sdk and Path(home).resolve() != Path(sdk).resolve():
        raise ReleaseError("ANDROID_HOME and ANDROID_SDK_ROOT disagree")
    return Path(home or sdk or "").resolve()


def version_name(root: Path) -> str:
    text = (root / "mobile/pubspec.yaml").read_text()
    found = re.search(
        r"^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+\s*$", text, re.MULTILINE
    )
    if not found:
        raise ReleaseError(
            "pubspec.yaml must contain an explicit semantic version/build"
        )
    return found.group(1)


def validate_cloud_provider_manifest(xmltree: str) -> None:
    """Check the release APK's actual merged provider declaration.

    A source-manifest check cannot catch a flavor/manifest merge mistake or a
    provider removed from the packaged APK.  ``aapt dump xmltree`` is used here
    because it reads the binary manifest from the exact artifact being handed
    to the user.
    """
    blocks: list[list[str]] = []
    current: list[str] | None = None
    depth = 0
    for line in xmltree.splitlines():
        element = re.match(r"^(\s*)E:", line)
        if current is not None and element and len(element[1]) <= depth:
            blocks.append(current)
            current = None
        if re.match(r"^\s*E: provider \(line=", line):
            current = [line]
            depth = len(line) - len(line.lstrip())
        elif current is not None:
            current.append(line)
    if current is not None:
        blocks.append(current)

    def attributes(lines: list[str]) -> dict[str, str]:
        result = {}
        for line in lines[1:]:
            if re.match(r"^\s*E:", line):
                break
            match = re.match(r"^\s*A: android:(\w+)(?:\([^)]*\))?=(.*)$", line)
            if match:
                if match[1] in result:
                    raise ReleaseError("duplicate CloudMediaProvider manifest attribute")
                result[match[1]] = match[2].strip()
        return result

    def string(value: str | None) -> str | None:
        match = re.fullmatch(r'"([^"]*)"(?: \(Raw: "[^"]*"\))?', value or "")
        return match[1] if match else None

    providers = [block for block in blocks if string(attributes(block).get("name")) == CLOUD_PROVIDER_CLASS]
    if len(providers) != 1:
        raise ReleaseError("release APK has no Gallery CloudMediaProvider declaration")
    provider = providers[0]
    attrs = attributes(provider)
    # aapt (SDK 36) emits typed binary booleans, not the source XML spelling.
    exported = attrs.get("exported") in {"true", "(type 0x12)0xffffffff", "(type 0x12)0x1"}
    permissions = all(
        string(attrs.get(key, attrs.get("permission"))) == CLOUD_PROVIDER_PERMISSION
        for key in ("readPermission", "writePermission")
    )
    action = any(
        re.match(r"^\s*E: action \(line=", line)
        and string(attributes(provider[index:]).get("name")) == CLOUD_PROVIDER_ACTION
        for index, line in enumerate(provider)
    )
    if string(attrs.get("authorities")) != CLOUD_PROVIDER_AUTHORITY or not exported or not permissions or not action:
        raise ReleaseError(
            "release APK CloudMediaProvider declaration is missing authority, "
            "exported state, signature read/write permissions or intent action"
        )


def check_key_files(root: Path) -> None:
    # Gradle reads the existing credentials. This tool never opens either file.
    paths = ["mobile/android/key.jks", "mobile/android/key.properties"]
    for name in paths:
        path = root / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ReleaseError(
                "existing nonempty Android signing files are required; never generate replacements"
            )
    if run(["git", "ls-files", "--", *paths], root).strip():
        raise ReleaseError("signing files must not be tracked")
    ignored = run(["git", "check-ignore", "--", *paths], root).splitlines()
    if set(ignored) != set(paths):
        raise ReleaseError("both existing signing files must be ignored")


def preflight(root: Path, expected: str, env: dict[str, str]) -> bool:
    failures = []

    def check(name: str, operation) -> None:
        try:
            operation()
            print(f"PASS {name}")
        except (ReleaseError, OSError, ValueError, KeyError) as error:
            failures.append(name)
            print(f"FAIL {name}: {error}")

    check(
        "reviewed repository / HEAD / work / clean working tree",
        lambda: repository_check(root, expected),
    )
    check(
        "existing ignored signing files (contents not read)",
        lambda: check_key_files(root),
    )

    def dependencies() -> None:
        for tool in ["git", "bash", "flutter", "dart", "java", "mise"]:
            if not shutil.which(tool, path=env.get("PATH")):
                raise ReleaseError(f"required existing tool is missing: {tool}")
        if (
            not env.get("JAVA_HOME")
            or not (Path(env["JAVA_HOME"]) / "bin/java").is_file()
        ):
            raise ReleaseError("JAVA_HOME must point to the existing JDK 17")
        java = run([str(Path(env["JAVA_HOME"]) / "bin/java"), "-version"], root, env)
        if not re.search(r'version "17\.', java):
            raise ReleaseError("Android JAVA_HOME must use JDK 17")
        path_java = run(["java", "-version"], root, env)
        if not re.search(r'version "17\.', path_java):
            raise ReleaseError("PATH java must also be JDK 17")
        pin = tomllib.loads((root / "mobile/mise.toml").read_text())["tools"][
            "aqua:flutter/flutter"
        ]["version"]
        flutter = json.loads(run(["flutter", "--version", "--machine"], root, env))
        if flutter["frameworkVersion"] != pin:
            raise ReleaseError(f"Flutter must match repository pin {pin}")
        flutter_sdk = (
            Path(shutil.which("flutter", path=env.get("PATH")) or "")
            .resolve()
            .parents[1]
        )
        path_dart = Path(shutil.which("dart", path=env.get("PATH")) or "").resolve()
        if path_dart != (flutter_sdk / "bin/dart").resolve():
            raise ReleaseError("PATH dart must come from the same pinned Flutter SDK")

    check("existing pinned Flutter/Dart and JDK 17", dependencies)

    def android_sdk() -> None:
        sdk = sdk_path(env)
        for relative in [
            "platforms/android-36/android.jar",
            f"build-tools/{BUILD_TOOLS}/apksigner",
            f"build-tools/{BUILD_TOOLS}/aapt",
            "platform-tools/adb",
        ]:
            if not (sdk / relative).is_file():
                raise ReleaseError(f"existing SDK package is missing: {relative}")

    check("existing SDK 36 / Build Tools 36.0.0", android_sdk)

    def no_overrides() -> None:
        names = [
            name
            for name in [
                "ALIAS",
                "ANDROID_KEY_PASSWORD",
                "ANDROID_STORE_PASSWORD",
                "PR_NUMBER",
            ]
            if env.get(name)
        ]
        if names:
            raise ReleaseError("remove CI signing/PR overrides: " + ", ".join(names))

    check("no CI signing or PR overrides", no_overrides)
    check("explicit mobile version", lambda: version_name(root))
    print("PASS PREPARED" if not failures else "FAIL PREFLIGHT")
    print(
        "INFO No keys were generated/read; no build/install/production operation was executed."
    )
    return not failures


def apk_metadata(apk: Path, sdk: Path, root: Path, name: str, number: int,
                 certificate: str = CERTIFICATE_SHA256) -> dict:
    if not apk.is_file() or not apk.stat().st_size:
        raise ReleaseError("expected nonempty APK is missing")
    output = run(
        [str(sdk / f"build-tools/{BUILD_TOOLS}/aapt"), "dump", "badging", str(apk)],
        root,
    )
    package = next(
        (line for line in output.splitlines() if line.startswith("package:")), None
    )
    if not package:
        raise ReleaseError("APK package metadata is missing")
    fields = dict(
        item.split("=", 1) for item in shlex.split(package)[1:] if "=" in item
    )
    if (fields.get("name"), fields.get("versionName"), fields.get("versionCode")) != (
        APP_ID,
        name,
        str(number),
    ):
        raise ReleaseError(
            "actual APK applicationId/version differs from requested release"
        )
    manifest_xml = run(
        [
            str(sdk / f"build-tools/{BUILD_TOOLS}/aapt"),
            "dump",
            "xmltree",
            str(apk),
            "AndroidManifest.xml",
        ],
        root,
    )
    validate_cloud_provider_manifest(manifest_xml)
    signature = run(
        [
            str(sdk / f"build-tools/{BUILD_TOOLS}/apksigner"),
            "verify",
            "--verbose",
            "--print-certs",
            str(apk),
        ],
        root,
    )
    signers = re.findall(
        r"^Signer #\d+ certificate SHA-256 digest:\s*([0-9a-fA-F:]+)\s*$",
        signature,
        re.MULTILINE,
    )
    if len(signers) != 1 or signers[0].lower().replace(":", "") != certificate:
        raise ReleaseError(
            "APK is not signed by the existing foto release certificate (CI/debug APK rejected)"
        )
    return {
        "application_id": APP_ID,
        "version_name": name,
        "version_code": number,
        "certificate_sha256": certificate,
        "apk_sha256": digest(apk),
        "apk_bytes": apk.stat().st_size,
    }


def artifact_paths(root: Path, expected: str, number: int) -> tuple[Path, Path]:
    directory = (
        root
        / "mobile/build/release-handoff"
        / f"android-{version_name(root)}-{number}-{expected[:12]}"
    )
    return directory / "Foto.apk", directory / "manifest.json"


def postflight(root: Path, expected: str, number: int, env: dict[str, str]) -> dict:
    repository_check(root, expected)
    apk, receipt = artifact_paths(root, expected, number)
    if not receipt.is_file():
        raise ReleaseError(
            "release manifest is missing; source provenance cannot be inferred from APK version alone"
        )
    manifest = json.loads(receipt.read_text())
    if (
        manifest.get("source_commit") != expected
        or manifest.get("source_branch") != "work"
    ):
        raise ReleaseError("release manifest source provenance does not match")
    resigned = manifest.get("delivery_mode") == "resign-verified-ci"
    if resigned and (expected != CI_SOURCE_SHA or number != CI_BUILD_NUMBER or
                    manifest.get("ci_run") != CI_RUN or manifest.get("ci_input_sha256") != CI_APK_SHA256):
        raise ReleaseError("resigned APK does not identify the pinned successful CI build")
    if manifest.get("completed_checks") != (SIGN_EXISTING_CHECKS if resigned else STAGES):
        raise ReleaseError("release manifest does not record all required build checks")
    actual = apk_metadata(apk, sdk_path(env), root, version_name(root), number)
    for field, value in actual.items():
        if manifest.get(field) != value:
            raise ReleaseError(f"release manifest disagrees with actual APK: {field}")
    print(
        "PASS POSTFLIGHT: actual package/version, release certificate, APK hash and source receipt"
    )
    print(f"SOURCE_HEAD {expected}")
    print(f"APK {apk}")
    print(f"APK_SHA256 {actual['apk_sha256']}")
    print(f"CERTIFICATE_SHA256 {CERTIFICATE_SHA256}")
    print("INFO This verifies the file, not a physical Samsung installation.")
    return manifest


def apk_payload(apk: Path) -> dict:
    """Signing may replace META-INF signatures and the APK signing block only."""
    with zipfile.ZipFile(apk) as archive:
        if archive.testzip() is not None or len(archive.namelist()) != len(set(archive.namelist())):
            raise ReleaseError("APK ZIP integrity failed")
        files = {name: hashlib.sha256(archive.read(name)).hexdigest()
                 for name in archive.namelist()
                 if not re.fullmatch(r"META-INF/(?:MANIFEST\.MF|[^/]+\.(?:SF|RSA|DSA|EC))", name, re.IGNORECASE)}
        if not all(name in files for name in ("classes.dex", "lib/arm64-v8a/libapp.so", "lib/arm64-v8a/libflutter.so")):
            raise ReleaseError("pinned arm64 APK/native libraries missing")
        return files


def sign_existing(root: Path, expected: str, number: int, source: Path, env: dict[str, str]) -> None:
    """HP-only signing of the already tested exact APK; no Flutter/Gradle build."""
    repository_check(root, expected)
    if expected != CI_SOURCE_SHA or number != CI_BUILD_NUMBER or version_name(root) != "5.7.2":
        raise ReleaseError("sign-existing requires the exact approved source/build profile")
    if digest(source) != CI_APK_SHA256:
        raise ReleaseError("input APK differs from run in the approved profile; nothing signed")
    sdk = sdk_path(env)
    apk_metadata(source, sdk, root, "5.7.2", CI_BUILD_NUMBER, CI_CERTIFICATE_SHA256)
    payload = apk_payload(source)
    check_key_files(root)
    before_keys = signing_stats(root)
    java = Path(env.get("JAVA_HOME", "")) / "bin/java"
    if not java.is_file() or not re.search(r'version "17\.', run([str(java), "-version"], root, env)):
        raise ReleaseError("existing JDK 17 required")
    apk, receipt = artifact_paths(root, expected, number)
    if receipt.exists():
        postflight(root, expected, number, env)
        print("PASS REUSED signed APK; no rebuild/signing repeated")
        return
    if apk.exists():
        raise ReleaseError("unverified existing Foto.apk; nothing overwritten")
    apk.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.TemporaryDirectory(prefix="sign-existing-", dir=apk.parent) as temporary:
        output = Path(temporary) / "Foto.apk"
        run([str(java), str(Path(__file__).with_name("SignExistingApk.java")),
             str(root / "mobile/android"), str(sdk / f"build-tools/{BUILD_TOOLS}/apksigner"),
             str(source.resolve()), str(output)], root, env)
        if before_keys != signing_stats(root):
            raise ReleaseError("existing signing files changed; output rejected")
        if apk_payload(output) != payload:
            raise ReleaseError("signing changed application payload; output rejected")
        metadata = apk_metadata(output, sdk, root, "5.7.2", CI_BUILD_NUMBER)
        run([str(sdk / f"build-tools/{BUILD_TOOLS}/zipalign"), "-c", "-P", "16", "4", str(output)], root, env)
        repository_check(root, expected)
        manifest = {"source_commit": expected, "source_branch": "work", "delivery_mode": "resign-verified-ci",
                    "ci_run": CI_RUN, "ci_input_sha256": CI_APK_SHA256,
                    "completed_checks": SIGN_EXISTING_CHECKS, **metadata}
        os.rename(output, apk)
        with receipt.open("x") as handle:
            json.dump(manifest, handle, indent=2)
            handle.write("\n")
    postflight(root, expected, number, env)
    print("PASS existing CI payload signed; no codegen/tests/mobile rebuild or installation")


def signing_stats(root: Path) -> list[tuple]:
    return [
        (
            item.stat().st_dev,
            item.stat().st_ino,
            item.stat().st_size,
            item.stat().st_mtime_ns,
        )
        for item in [
            root / "mobile/android/key.jks",
            root / "mobile/android/key.properties",
        ]
    ]


def restore_owned_report(root: Path, original: bytes | None, directory: Path) -> None:
    """Only the historical tracked Gradle report changed by this clean build.

    Preserve the generated diagnostic privately before returning the single
    build output to its initial bytes. Never restore other source/user files.
    """
    report = root / GRADLE_REPORT
    if original is not None and report.is_file() and report.read_bytes() != original:
        diagnostic = directory / "gradle-problems-generated.html"
        descriptor = os.open(diagnostic, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(report.read_bytes())
        report.write_bytes(original)
        print(
            "PASS Restored only this build's tracked Gradle diagnostic; generated diagnostic retained privately."
        )


def build(root: Path, expected: str, number: int, env: dict[str, str]) -> None:
    if not preflight(root, expected, env):
        raise ReleaseError("preflight failed; no build was started")
    apk, receipt = artifact_paths(root, expected, number)
    if receipt.exists():
        postflight(root, expected, number, env)
        print("PASS REUSED verified existing artifact; tests/build were not rerun.")
        return
    before_keys = signing_stats(root)
    mobile = root / "mobile"
    apk.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    tracked_report = run(["git", "ls-files", "--", GRADLE_REPORT], root).strip()
    original_report = (root / GRADLE_REPORT).read_bytes() if tracked_report else None

    def stage(label: str, command: list[str], cwd: Path) -> None:
        print(f"RUN {label}", flush=True)
        log = apk.parent / f"{label}.log"
        descriptor = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as handle:
            result = subprocess.run(
                command, cwd=cwd, env=env, stdout=handle, stderr=subprocess.STDOUT
            )
        if result.returncode:
            raise ReleaseError(
                f"{label} failed (exit {result.returncode}); inspect its private build log"
            )
        print(f"PASS {label}", flush=True)

    try:
        stage("locked-codegen", ["bash", "scripts/android_media_codegen.sh"], mobile)
        source_files = run(
            [
                "git",
                "ls-files",
                "--",
                "mobile/lib",
                "mobile/test",
                "mobile/integration_test",
            ],
            root,
        ).splitlines()
        dart_files = [
            str(root / item)
            for item in source_files
            if item.endswith(".dart")
            and not item.endswith(
                (".g.dart", ".freezed.dart", ".drift.dart", ".gr.dart")
            )
        ]
        if not dart_files:
            raise ReleaseError(
                "no tracked Dart source files were found for the format check"
            )
        stage(
            "dart-format",
            ["dart", "format", "--output=none", "--set-exit-if-changed", *dart_files],
            mobile,
        )
        stage("flutter-analyze", ["flutter", "analyze", "--no-pub"], mobile)
        stage("flutter-tests", ["flutter", "test", "--no-pub"], mobile)
        android = mobile / "android"
        if (
            not (android / "gradlew").is_file()
            or not (android / "gradle/wrapper/gradle-wrapper.jar").is_file()
        ):
            flutter = (
                Path(shutil.which("flutter", path=env.get("PATH")) or "")
                .resolve()
                .parents[1]
            )
            wrapper = flutter / "bin/cache/artifacts/gradle_wrapper"
            for relative in ["gradlew", "gradle/wrapper/gradle-wrapper.jar"]:
                source, target = wrapper / relative, android / relative
                if not source.is_file():
                    raise ReleaseError(
                        "pinned Flutter Gradle wrapper artifact is missing"
                    )
                if not target.exists():
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, target)
        stage(
            "android-native-tests",
            ["bash", "gradlew", ":app:testDebugUnitTest", "--console=plain"],
            android,
        )
        restore_owned_report(root, original_report, apk.parent)
        repository_check(root, expected)
        tested_dependencies = dependency_snapshot(mobile)
        stage(
            "release-locked-dependencies",
            ["flutter", "pub", "get", "--enforce-lockfile"],
            mobile,
        )
        if dependency_snapshot(mobile) != tested_dependencies:
            raise ReleaseError(
                "locked release refresh changed the tested dependency graph"
            )
        repository_check(root, expected)
        source_apk = mobile / "build/app/outputs/flutter-apk/app-release.apk"
        # Never accept an old APK if Flutter fails to emit a new artifact.
        if source_apk.exists():
            descriptor, previous = tempfile.mkstemp(
                prefix="previous-output-", suffix=".apk", dir=apk.parent
            )
            os.close(descriptor)
            os.replace(source_apk, previous)
        stage(
            "apk-build",
            apk_build_command(version_name(root), number),
            mobile,
        )
        if not source_apk.is_file():
            raise ReleaseError(
                "Flutter did not produce a fresh APK; stale output rejected"
            )
        if dependency_snapshot(mobile) != tested_dependencies:
            raise ReleaseError("release build changed the tested dependency graph")
        restore_owned_report(root, original_report, apk.parent)
        repository_check(root, expected)
        if signing_stats(root) != before_keys:
            raise ReleaseError(
                "existing signing file metadata changed during build; release rejected"
            )
        shutil.copy2(source_apk, apk)
        metadata = apk_metadata(apk, sdk_path(env), root, version_name(root), number)
        manifest = {
            "source_commit": expected,
            "source_branch": "work",
            "completed_checks": STAGES,
            **metadata,
        }
        descriptor, temporary = tempfile.mkstemp(
            prefix="manifest-", suffix=".json", dir=apk.parent
        )
        with os.fdopen(descriptor, "w") as handle:
            json.dump(manifest, handle, indent=2)
            handle.write("\n")
        os.replace(temporary, receipt)
        postflight(root, expected, number, env)
        print(
            "PASS BUILD COMPLETE; no APK installed and no production service touched."
        )
    finally:
        restore_owned_report(root, original_report, apk.parent)
        if signing_stats(root) != before_keys:
            raise ReleaseError(
                "existing signing file metadata changed; do not install the output"
            )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["preflight", "build", "postflight", "sign-existing"])
    parser.add_argument("--repository", type=Path, default=ROOT)
    parser.add_argument("--input-apk", type=Path)
    parser.add_argument("--candidate-profile", type=Path)
    parser.add_argument("--candidate-profile-sha256")
    parser.add_argument("--authorize-production-signing", action="store_true")
    parser.add_argument("--expected-head", required=True)
    parser.add_argument(
        "--build-number",
        type=int,
        default=8,
        help="next production-key update build (default: 8; installed baseline: 7)",
    )
    args = parser.parse_args()
    if args.build_number <= 7:
        parser.error("build number must exceed installed production build 7")
    env = os.environ.copy()
    root = args.repository.resolve()
    try:
        if args.candidate_profile is not None or args.candidate_profile_sha256 is not None:
            import release_candidate
            profile = release_candidate.load(args.candidate_profile, args.candidate_profile_sha256)
            if args.expected_head != profile['sourceCommit'] or args.build_number != profile['mobileBuild']:
                raise ReleaseError("candidate profile does not match requested source/build")
            global CI_SOURCE_SHA, CI_BUILD_NUMBER, CI_RUN, CI_APK_SHA256, CI_CERTIFICATE_SHA256
            CI_SOURCE_SHA, CI_BUILD_NUMBER, CI_RUN = profile['sourceCommit'], profile['mobileBuild'], profile['android']['run']
            CI_APK_SHA256, CI_CERTIFICATE_SHA256 = profile['android']['sha256'], profile['android']['certificateSHA256']
        if args.action == "sign-existing":
            if not args.authorize_production_signing or not args.input_apk:
                raise ReleaseError("explicit production signing approval and --input-apk required")
            lock = root / "mobile/build/release-handoff/.android-release.lock"
            lock.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
            with os.fdopen(descriptor, "w") as handle:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                sign_existing(root, args.expected_head, args.build_number, args.input_apk, env)
            return 0
        if args.action == "preflight":
            return 0 if preflight(root, args.expected_head, env) else 1
        if args.action == "build":
            repository_check(root, args.expected_head)
            lock = root / "mobile/build/release-handoff/.android-release.lock"
            lock.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
            with os.fdopen(descriptor, "w") as handle:
                try:
                    fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError as error:
                    raise ReleaseError(
                        "another Android release build is active; do not run Gradle concurrently"
                    ) from error
                build(root, args.expected_head, args.build_number, env)
        else:
            postflight(root, args.expected_head, args.build_number, env)
        return 0
    except (ReleaseError, OSError, ValueError, KeyError) as error:
        print(f"FAIL {args.action.upper()}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
