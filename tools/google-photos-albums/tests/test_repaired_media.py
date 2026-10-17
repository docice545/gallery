from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import takeout_albums as tool


OWNER = "00000000-0000-0000-0000-000000000001"
OTHER_OWNER = "00000000-0000-0000-0000-000000000002"
ORIGINAL_DATE = "2020-01-01T00:00:00Z"
REPAIRED_DATE = "2023-09-23T12:34:56Z"
GALLERY_DIRECTORY = "/nas/gallery/docice/originals"
FIXTURE = Path(__file__).parent / "fixtures" / "repaired-media.json"


def checksum(value: bytes, algorithm: str = "sha256") -> dict[str, str]:
    return {"algorithm": algorithm, "value": hashlib.new(algorithm, value).hexdigest()}


class RepairedMediaTests(unittest.TestCase):
    """Logical identity cannot be decided by the repair-sensitive capture date alone."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "Google Photos"
        self.root.mkdir()
        self.fixture = json.loads(FIXTURE.read_text(encoding="utf-8"))
        self.snapshot = {"ownerId": OWNER, "assets": [], "albums": []}
        self.path_maps = [{"metadataPrefix": "Album", "assetPrefix": GALLERY_DIRECTORY}]

    def write_json(self, relative: str, value: dict) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def album(self, directory: str = "Album"):
        metadata = copy.deepcopy(self.fixture["albumMetadata"])
        metadata["title"] = directory
        self.write_json(f"{directory}/metadata.json", metadata)

    def sidecar(
        self,
        directory: str = "Album",
        *,
        video: bool = False,
        filename: str | None = None,
        **extra,
    ) -> dict:
        data = copy.deepcopy(self.fixture["videoSidecar" if video else "photoSidecar"])
        data.update(extra)
        self.write_json(f"{directory}/{filename or data['title'] + '.json'}", data)
        return data

    def asset(
        self,
        asset_id: str = "matched-photo",
        *,
        video: bool = False,
        **extra,
    ) -> dict:
        sidecar = self.fixture["videoSidecar" if video else "photoSidecar"]
        row = {
            "id": asset_id,
            "ownerId": OWNER,
            "type": "VIDEO" if video else "IMAGE",
            "originalPath": f"{GALLERY_DIRECTORY}/{sidecar['title']}",
            "originalFileName": sidecar["title"],
            "fileCreatedAt": ORIGINAL_DATE,
            "visibility": "timeline",
            "width": sidecar["width"],
            "height": sidecar["height"],
        }
        row.update(extra)
        if video:
            row.setdefault("duration", sidecar["durationMilliseconds"])
        self.snapshot["assets"].append(row)
        return row

    def build(self, *, mapped: bool = True, **extra) -> dict:
        return tool.build_mapping(
            self.root,
            self.snapshot,
            OWNER,
            path_maps=self.path_maps if mapped else [],
            **extra,
        )

    def matched(self, *, mapped: bool = True, **extra) -> dict:
        return self.build(mapped=mapped, **extra)["items"][0]

    def assert_not_proposed(self, result: dict):
        self.assertIsNone(result["items"][0]["assetId"])
        for album in result["albums"]:
            self.assertEqual(album["proposedAssetIds"], [])
            self.assertEqual(album["proposedMissingMembershipIds"], [])

    def assert_difference(self, row: dict, field: str):
        matching = [
            difference
            for difference in row["metadataDifferences"]
            if difference["field"] == field
        ]
        self.assertEqual(len(matching), 1)
        difference = matching[0]
        self.assertNotEqual(difference["sourceValue"], difference["assetValue"])
        self.assertTrue(difference["sourceProvenance"])
        self.assertTrue(difference["assetProvenance"])

    def test_unchanged_original_is_exact(self):
        content_hash = checksum(b"unchanged synthetic original")
        self.sidecar(contentChecksum=content_hash)
        self.asset(contentChecksum=content_hash)
        row = self.matched()
        self.assertEqual(row["confidence"], "EXACT")
        self.assertEqual(row["assetId"], "matched-photo")
        self.assertIn("content checksum", row["evidence"])

    def test_anna_unstacked_assets_match_only_annas_owner_scope(self):
        anna = "bb8ccc0b-9322-40ea-9ae5-672d497b3e01"
        self.sidecar()
        self.snapshot["ownerId"] = anna
        self.asset("anna-existing", ownerId=anna, stackId=None)
        self.asset("docice-excluded", ownerId="de9b2d19-cd6a-4b82-8230-33e17134a3bf")
        self.asset("lenia-excluded", ownerId="47f6a3fc-75d9-4214-899f-8b4234eb8202")
        result = tool.build_mapping(
            self.root, self.snapshot, anna, path_maps=self.path_maps
        )
        item = result["items"][0]
        self.assertEqual(result["ownerId"], anna)
        self.assertEqual(item["assetId"], "anna-existing")
        self.assertEqual(item["confidence"], "EXACT")
        self.assertEqual(
            [row["assetId"] for row in item["candidates"]], ["anna-existing"]
        )

    def test_verified_path_proves_photo_with_repaired_capture_date(self):
        self.sidecar()
        self.asset(fileCreatedAt=REPAIRED_DATE)
        row = self.matched()
        self.assertEqual(row["confidence"], "HIGH_CONFIDENCE")
        self.assertEqual(row["assetId"], "matched-photo")
        self.assert_difference(row, "captureTimestamp")

    def test_verified_path_proves_photo_with_exif_changed_hash(self):
        self.sidecar(contentChecksum=checksum(b"original EXIF bytes"))
        self.asset(contentChecksum=checksum(b"repaired EXIF bytes"))
        row = self.matched()
        self.assertEqual(row["confidence"], "HIGH_CONFIDENCE")
        self.assertEqual(row["assetId"], "matched-photo")
        self.assert_difference(row, "contentChecksum")

    def test_repaired_date_and_exif_changed_hash_remain_evidenced_not_exact(self):
        self.sidecar(contentChecksum=checksum(b"original media"))
        self.asset(
            fileCreatedAt=REPAIRED_DATE,
            contentChecksum=checksum(b"repaired media metadata"),
        )
        row = self.matched()
        self.assertEqual(row["confidence"], "HIGH_CONFIDENCE")
        self.assertEqual(row["assetId"], "matched-photo")
        self.assert_difference(row, "captureTimestamp")
        self.assert_difference(row, "contentChecksum")

    def test_changed_filesystem_mtime_is_not_capture_evidence(self):
        self.sidecar()
        original = self.root / "Album/IMG_REPAIRED.JPG"
        original.write_bytes(b"synthetic bytes, not a private original")
        os.utime(original, (1577836800, 1577836800))
        self.asset()
        before = self.matched()
        os.utime(original, (1749360000, 1749360000))
        self.snapshot["assets"][0].update(
            fileModifiedAt="2025-06-07T08:09:10Z",
            updatedAt="2025-06-08T08:09:10Z",
            mtime=1749360000,
        )
        after = self.matched()
        self.assertEqual(after["confidence"], "EXACT")
        self.assertEqual(after["assetId"], before["assetId"])
        self.assertEqual(after["evidence"], before["evidence"])
        self.assertEqual(
            original.read_bytes(), b"synthetic bytes, not a private original"
        )

    def test_unique_equal_comparable_hash_resolves_duplicate_filename(self):
        original_hash = checksum(b"original logical item")
        self.sidecar(contentChecksum=original_hash)
        self.asset(
            "right",
            originalPath="/nas/A/IMG_REPAIRED.JPG",
            fileCreatedAt=REPAIRED_DATE,
            contentChecksum=original_hash,
        )
        self.asset(
            "wrong",
            originalPath="/nas/B/IMG_REPAIRED.JPG",
            contentChecksum=checksum(b"different logical item"),
        )
        row = self.matched(mapped=False)
        self.assertEqual(row["confidence"], "EXACT")
        self.assertEqual(row["assetId"], "right")

    def test_date_repair_removes_weak_duplicate_filename_discriminator(self):
        self.album()
        self.sidecar()
        self.asset(
            "date-repaired",
            originalPath="/nas/A/IMG_REPAIRED.JPG",
            fileCreatedAt=REPAIRED_DATE,
        )
        self.asset("date-equal", originalPath="/nas/B/IMG_REPAIRED.JPG")
        result = self.build(mapped=False)
        self.assertEqual(result["items"][0]["confidence"], "AMBIGUOUS")
        self.assert_not_proposed(result)
        self.assertIn("date-repaired", json.dumps(result["items"][0]))
        self.assertIn("date-equal", json.dumps(result["items"][0]))

    def test_foreign_owner_is_never_matched_even_with_path_and_equal_hash(self):
        content_hash = checksum(b"same bytes")
        self.album()
        self.sidecar(contentChecksum=content_hash)
        self.asset(ownerId=OTHER_OWNER, contentChecksum=content_hash)
        result = self.build()
        row = result["items"][0]
        self.assertEqual(row["confidence"], "MISSING")
        self.assertFalse(row["candidates"])
        self.assert_not_proposed(result)

    def test_video_repaired_timestamp_uses_verified_path_and_dimensions(self):
        self.album()
        self.sidecar(video=True)
        self.asset("matched-video", video=True, fileCreatedAt=REPAIRED_DATE)
        result = self.build()
        row = result["items"][0]
        self.assertEqual(row["confidence"], "HIGH_CONFIDENCE")
        self.assertEqual(row["assetId"], "matched-video")
        self.assertEqual(result["albums"][0]["proposedAssetIds"], ["matched-video"])
        self.assertIn("dimensions (orientation independent)", row["evidence"])
        self.assertIn("duration", " ".join(row["evidence"]))

    def test_edited_item_cannot_guess_unedited_asset_after_date_repair(self):
        self.album()
        self.sidecar(filename="IMG_REPAIRED-edited.JPG.json", isEdited=True)
        self.asset(fileCreatedAt=REPAIRED_DATE)
        result = self.build()
        self.assertEqual(result["items"][0]["confidence"], "MISSING")
        self.assert_not_proposed(result)

    def test_one_repaired_asset_belongs_to_multiple_explicit_albums(self):
        self.album("First")
        self.album("Second")
        self.sidecar("First")
        self.sidecar("Second")
        self.path_maps = [
            {"metadataPrefix": directory, "assetPrefix": GALLERY_DIRECTORY}
            for directory in ("First", "Second")
        ]
        self.asset(fileCreatedAt=REPAIRED_DATE)
        result = self.build()
        self.assertEqual(result["summary"]["googleAlbumsFound"], 2)
        self.assertEqual(result["summary"]["uniqueMatchedAssets"], 1)
        self.assertEqual(result["summary"]["totalAlbumMemberships"], 2)
        self.assertEqual(result["summary"]["matches"]["HIGH_CONFIDENCE"], 2)
        for album in result["albums"]:
            self.assertEqual(album["proposedAssetIds"], ["matched-photo"])

    def test_metadata_only_tree_needs_no_original_media_read_for_path_proof(self):
        self.album()
        self.sidecar()
        self.asset(fileCreatedAt=REPAIRED_DATE)
        original_inputs = {
            str(path): path.read_bytes()
            for path in self.root.rglob("*")
            if path.is_file()
        }
        self.assertTrue(all(Path(path).suffix == ".json" for path in original_inputs))
        real_open = Path.open

        def json_only_open(path, *args, **kwargs):
            if path.suffix != ".json":
                raise AssertionError(
                    "Metadata-only matching attempted to read media bytes"
                )
            return real_open(path, *args, **kwargs)

        with patch.object(Path, "open", json_only_open):
            result = self.build()
        self.assertEqual(result["items"][0]["confidence"], "HIGH_CONFIDENCE")
        self.assertEqual(
            original_inputs,
            {
                str(path): path.read_bytes()
                for path in self.root.rglob("*")
                if path.is_file()
            },
        )
        self.assertFalse(result["safety"]["productionWrite"])
        self.assertFalse(result["safety"]["mediaUpload"])
        self.assertFalse(result["safety"]["sourceWrite"])
        self.assertFalse(result["safety"]["applyImplemented"])

    def test_equal_bytes_still_prove_identity_after_capture_date_repair(self):
        content_hash = checksum(b"unchanged bytes, repaired Gallery database date")
        self.sidecar(contentChecksum=content_hash)
        self.asset(
            originalPath="/nas/elsewhere/renamed.JPG",
            originalFileName="renamed.JPG",
            fileCreatedAt=REPAIRED_DATE,
            contentChecksum=content_hash,
        )
        row = self.matched(mapped=False)
        self.assertEqual(row["confidence"], "EXACT")
        self.assertEqual(row["assetId"], "matched-photo")
        self.assert_difference(row, "captureTimestamp")

    def test_unique_filename_and_repaired_date_without_path_are_ambiguous(self):
        self.album()
        self.sidecar()
        self.asset(fileCreatedAt=REPAIRED_DATE)
        result = self.build(mapped=False)
        self.assertEqual(result["items"][0]["confidence"], "AMBIGUOUS")
        self.assert_not_proposed(result)

    def test_hash_difference_without_path_never_becomes_high_confidence(self):
        self.album()
        self.sidecar(contentChecksum=checksum(b"original"))
        self.asset(contentChecksum=checksum(b"different metadata or content"))
        result = self.build(mapped=False)
        self.assertIn(result["items"][0]["confidence"], ("AMBIGUOUS", "MISSING"))
        self.assert_not_proposed(result)

    def test_capture_timestamp_tolerance_is_not_broadened(self):
        self.album()
        self.sidecar()
        self.asset(fileCreatedAt="2020-01-01T00:00:02Z")
        result = self.build(mapped=False)
        self.assertEqual(result["items"][0]["confidence"], "AMBIGUOUS")
        self.assert_not_proposed(result)

    def test_dimensions_contradiction_is_not_explained_away_as_exif_repair(self):
        self.album()
        self.sidecar()
        self.asset(fileCreatedAt=REPAIRED_DATE, width=1920, height=1080)
        result = self.build()
        self.assertEqual(result["items"][0]["confidence"], "MISSING")
        self.assert_not_proposed(result)

    def test_duplicate_mapped_path_candidates_do_not_choose_by_list_order(self):
        self.album()
        self.sidecar()
        self.asset("first", fileCreatedAt=REPAIRED_DATE)
        self.asset("second", fileCreatedAt=REPAIRED_DATE)
        result = self.build()
        self.assertEqual(result["items"][0]["confidence"], "AMBIGUOUS")
        self.assert_not_proposed(result)
        self.snapshot["assets"].reverse()
        self.assertEqual(tool.canonical_json(result), tool.canonical_json(self.build()))

    def test_old_and_supplemental_json_forms_keep_repaired_match(self):
        self.asset(fileCreatedAt=REPAIRED_DATE)
        for filename in (
            "IMG_REPAIRED.JPG.json",
            "IMG_REPAIRED.JPG.supplemental-metadata.json",
        ):
            with self.subTest(filename=filename):
                self.sidecar(filename=filename)
        result = self.build()
        self.assertTrue(result["items"])
        self.assertTrue(
            all(row["confidence"] == "HIGH_CONFIDENCE" for row in result["items"])
        )
        self.assertTrue(
            all(row["assetId"] == "matched-photo" for row in result["items"])
        )

    def test_indexed_json_only_association_remains_ambiguous_after_repair(self):
        self.album()
        self.sidecar(filename="IMG_REPAIRED.JPG(1).json")
        self.asset(fileCreatedAt=REPAIRED_DATE)
        result = self.build()
        self.assertEqual(result["items"][0]["confidence"], "AMBIGUOUS")
        self.assert_not_proposed(result)

    def test_untyped_external_checksum_cannot_establish_identity_after_repair(self):
        content_hash = checksum(b"external API path bytes", algorithm="sha1")
        self.album()
        self.sidecar(contentChecksum=content_hash)
        self.asset(
            fileCreatedAt=REPAIRED_DATE,
            checksum=content_hash["value"],
            libraryId="external-library",
            checksumAlgorithm="sha1-path",
        )
        result = self.build(mapped=False)
        self.assertEqual(result["items"][0]["confidence"], "AMBIGUOUS")
        self.assert_not_proposed(result)

    def test_dry_run_is_deterministic_after_date_and_hash_repair(self):
        self.album()
        self.sidecar(contentChecksum=checksum(b"original"))
        self.asset(
            fileCreatedAt=REPAIRED_DATE, contentChecksum=checksum(b"modified EXIF")
        )
        first = tool.canonical_json(self.build())
        self.assertEqual(first, tool.canonical_json(self.build()))

    def test_file_size_drift_due_to_written_exif_is_recorded_not_exact(self):
        self.sidecar(fileSize=5000000)
        self.asset(fileSize=5000128)
        row = self.matched()
        self.assertEqual(row["confidence"], "HIGH_CONFIDENCE")
        self.assertEqual(row["assetId"], "matched-photo")
        self.assert_difference(row, "fileSize")

    def test_unmapped_capture_and_hash_and_size_drift_remains_ambiguous(self):
        self.album()
        self.sidecar(fileSize=5000000, contentChecksum=checksum(b"old bytes"))
        self.asset(
            fileCreatedAt=REPAIRED_DATE,
            fileSize=5000128,
            contentChecksum=checksum(b"new metadata bytes"),
        )
        result = self.build(mapped=False)
        self.assertEqual(result["items"][0]["confidence"], "AMBIGUOUS")
        self.assert_not_proposed(result)

    def test_implicit_local_path_does_not_authorize_accepting_repair_drift(self):
        self.album()
        self.sidecar()
        self.asset(
            originalPath=str(self.root / "Album/IMG_REPAIRED.JPG"),
            fileCreatedAt=REPAIRED_DATE,
        )
        result = self.build(mapped=False)
        self.assertEqual(result["items"][0]["confidence"], "AMBIGUOUS")
        self.assert_not_proposed(result)

    def test_verified_path_requires_matching_original_filename_after_repair(self):
        self.album()
        self.sidecar()
        self.asset(
            originalFileName="different-original-name.JPG", fileCreatedAt=REPAIRED_DATE
        )
        result = self.build()
        self.assertIn(result["items"][0]["confidence"], ("AMBIGUOUS", "MISSING"))
        self.assert_not_proposed(result)

    def test_verified_repaired_path_outranks_unmapped_filename_and_capture_time(self):
        self.sidecar()
        self.asset("path-proven", fileCreatedAt=REPAIRED_DATE)
        self.asset("weak-date", originalPath="/nas/other/IMG_REPAIRED.JPG")
        row = self.matched()
        self.assertEqual(row["confidence"], "HIGH_CONFIDENCE")
        self.assertEqual(row["assetId"], "path-proven")

    def test_distinct_hash_and_mapped_path_strong_proofs_remain_ambiguous(self):
        self.album()
        original_hash = checksum(b"original")
        self.sidecar(contentChecksum=original_hash)
        self.asset(
            "path-proven",
            fileCreatedAt=REPAIRED_DATE,
            contentChecksum=checksum(b"repaired metadata bytes"),
        )
        self.asset(
            "hash-proven",
            originalPath="/nas/other/IMG_REPAIRED.JPG",
            contentChecksum=original_hash,
        )
        result = self.build()
        self.assertEqual(result["items"][0]["confidence"], "AMBIGUOUS")
        self.assert_not_proposed(result)

    def test_video_duration_structural_conflict_cannot_be_explained_by_date_repair(
        self,
    ):
        self.album()
        self.sidecar(video=True)
        self.asset(
            "wrong-video", video=True, fileCreatedAt=REPAIRED_DATE, duration=10000
        )
        result = self.build()
        self.assertEqual(result["items"][0]["confidence"], "MISSING")
        self.assert_not_proposed(result)

    def test_unknown_unit_numeric_google_duration_does_not_create_fake_evidence(self):
        self.sidecar(video=True, durationMilliseconds=None, duration=30)
        self.asset("matched-video", video=True, fileCreatedAt=REPAIRED_DATE)
        row = self.matched()
        self.assertEqual(row["confidence"], "HIGH_CONFIDENCE")
        self.assertFalse(any("duration" in evidence for evidence in row["evidence"]))

    def test_no_exif_size_duration_or_media_bytes_required_for_metadata_path_proof(
        self,
    ):
        self.sidecar(width=None, height=None, fileSize=None, contentChecksum=None)
        self.asset(fileCreatedAt=REPAIRED_DATE, width=None, height=None)
        row = self.matched()
        self.assertEqual(row["confidence"], "HIGH_CONFIDENCE")
        self.assertEqual(row["assetId"], "matched-photo")

    def test_year_sidecar_does_not_create_album_after_repaired_match(self):
        self.sidecar("Photos from 2020")
        self.path_maps = [
            {"metadataPrefix": "Photos from 2020", "assetPrefix": GALLERY_DIRECTORY}
        ]
        self.asset(fileCreatedAt=REPAIRED_DATE)
        result = self.build()
        self.assertEqual(result["items"][0]["confidence"], "HIGH_CONFIDENCE")
        self.assertEqual(result["albums"], [])
        self.assertEqual(result["summary"]["totalAlbumMemberships"], 0)

    def test_metadata_differences_require_item_and_album_manual_review(self):
        self.album()
        self.sidecar(contentChecksum=checksum(b"original bytes"))
        self.asset(
            fileCreatedAt=REPAIRED_DATE,
            contentChecksum=checksum(b"metadata rewritten bytes"),
        )
        result = self.build()
        self.assertEqual(result["items"][0]["confidence"], "HIGH_CONFIDENCE")
        self.assertTrue(result["items"][0]["requiresMetadataReview"])
        self.assertTrue(result["albums"][0]["reviewRequired"])

    def test_equal_hash_with_repaired_date_is_exact_but_still_requires_review(self):
        original_hash = checksum(b"unaltered media bytes")
        self.album()
        self.sidecar(contentChecksum=original_hash)
        self.asset(fileCreatedAt=REPAIRED_DATE, contentChecksum=original_hash)
        result = self.build()
        self.assertEqual(result["items"][0]["confidence"], "EXACT")
        self.assertTrue(result["items"][0]["requiresMetadataReview"])
        self.assertTrue(result["albums"][0]["reviewRequired"])
        self.assert_difference(result["items"][0], "captureTimestamp")

    def test_unchanged_exact_identity_does_not_trigger_metadata_review(self):
        original_hash = checksum(b"unaltered media bytes")
        self.album()
        self.sidecar(contentChecksum=original_hash)
        self.asset(contentChecksum=original_hash)
        result = self.build()
        self.assertEqual(result["items"][0]["confidence"], "EXACT")
        self.assertFalse(result["items"][0]["requiresMetadataReview"])
        self.assertEqual(result["items"][0]["metadataDifferences"], [])
        self.assertFalse(result["albums"][0]["reviewRequired"])


if __name__ == "__main__":
    unittest.main()
