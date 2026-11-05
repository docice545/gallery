import importlib.util
import struct
import tempfile
import unittest
import zipfile
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "unsigned_android",
    Path(__file__).resolve().parents[1] / "verify_unsigned_android.py",
)
unsigned = importlib.util.module_from_spec(spec)
spec.loader.exec_module(unsigned)


class UnsignedAndroidTests(unittest.TestCase):
    badging = (
        "package: name='de.opennoodle.gallery' versionCode='36' versionName='5.7.3'"
    )

    def fixture(self, directory, *, omit=None, extra=None):
        apk = Path(directory) / "Foto-unsigned.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            archive.writestr("AndroidManifest.xml", "fixture")
            for abi in unsigned.ABIS:
                for library in ("libflutter.so", "libapp.so", "libsqlite3.so"):
                    name = f"lib/{abi}/{library}"
                    if name != omit:
                        archive.writestr(name, "fixture")
            if extra:
                archive.writestr(extra, "signature fixture")
        return apk

    def test_valid_universal_fixture_remains_explicitly_unverified_on_device(self):
        with tempfile.TemporaryDirectory() as directory:
            result = unsigned.inspect(
                self.fixture(directory), self.badging, "5.7.3", "36"
            )
            self.assertEqual(result["versionCode"], 36)
            self.assertEqual(result["signing"], "UNSIGNED")
            self.assertEqual(result["deviceAcceptance"], "NOT_TESTED")
            self.assertFalse(result["releaseReady"])
            self.assertRegex(result["sha256"], r"^[a-f0-9]{64}$")

    def test_wrong_package_version_and_build_are_rejected(self):
        for badging in (
            self.badging.replace("gallery'", "gallery.debug'"),
            self.badging.replace("5.7.3", "5.7.2"),
            self.badging.replace("36", "37"),
            "",
        ):
            with tempfile.TemporaryDirectory() as directory, self.assertRaisesRegex(
                ValueError, "package/version"
            ):
                unsigned.inspect(self.fixture(directory), badging, "5.7.3", "36")

    def test_missing_sqlite_library_and_signature_entries_fail(self):
        with tempfile.TemporaryDirectory() as directory, self.assertRaisesRegex(
            ValueError, "native library"
        ):
            unsigned.inspect(
                self.fixture(directory, omit="lib/arm64-v8a/libsqlite3.so"),
                self.badging,
                "5.7.3",
                "36",
            )
        for name in ("META-INF/CERT.RSA", "META-INF/CERT.SF", "META-INF/SIG-TEST"):
            with tempfile.TemporaryDirectory() as directory, self.assertRaisesRegex(
                ValueError, "v1 signature"
            ):
                unsigned.inspect(
                    self.fixture(directory, extra=name), self.badging, "5.7.3", "36"
                )

    def test_v2_or_v3_block_is_rejected_without_trusting_apksigner_exit_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            apk = self.fixture(directory)
            with zipfile.ZipFile(apk) as archive:
                central = archive.start_dir
            data = apk.read_bytes()
            block = struct.pack("<Q", 24) * 2 + b"APK Sig Block 42"
            data = bytearray(data[:central] + block + data[central:])
            eocd = data.rfind(b"PK\x05\x06")
            struct.pack_into("<I", data, eocd + 16, central + len(block))
            apk.write_bytes(data)
            with self.assertRaisesRegex(ValueError, "signing block"):
                unsigned.inspect(apk, self.badging, "5.7.3", "36")


if __name__ == "__main__":
    unittest.main()
