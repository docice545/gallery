from __future__ import annotations

import base64
import contextlib
import hashlib
import io
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import takeout_albums as tool


OWNER = "00000000-0000-0000-0000-000000000001"
OTHER = "00000000-0000-0000-0000-000000000002"
CAPTURE = "1577836800"
FIXTURES = Path(__file__).parent / "fixtures"


class TakeoutTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "Google Photos"
        self.root.mkdir()
        self.snapshot = {"ownerId": OWNER, "assets": [], "albums": []}

    def write(self, relative, data):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return path

    def album(self, directory="Holiday", title="Family holiday", legacy=False):
        data = json.loads(
            (
                FIXTURES / ("album-legacy.json" if legacy else "album-modern.json")
            ).read_text()
        )
        (data["albumData"] if legacy else data)["title"] = title
        self.write(f"{directory}/metadata.json", data)

    def item(self, directory="Holiday", title="IMG_0001.JPG", filename=None, **extra):
        data = json.loads((FIXTURES / "photo.json").read_text())
        data["title"] = title
        data.update(extra)
        self.write(f"{directory}/{filename or title + '.json'}", data)
        return data

    def asset(self, asset_id="a1", title="IMG_0001.JPG", directory="Holiday", **extra):
        row = {
            "id": asset_id,
            "ownerId": OWNER,
            "type": tool.media_type(title),
            "originalPath": str(self.root / directory / title),
            "originalFileName": title,
            "fileCreatedAt": "2020-01-01T00:00:00Z",
            "visibility": "timeline",
        }
        row.update(extra)
        self.snapshot["assets"].append(row)
        return row

    def build(self, **kwargs):
        return tool.build_mapping(self.root, self.snapshot, OWNER, **kwargs)

    def test_modern_album_with_geo_data_and_photo_exact(self):
        self.album()
        self.item()
        self.asset()
        result = self.build()
        self.assertEqual(result["summary"]["googleAlbumsFound"], 1)
        self.assertEqual(result["items"][0]["confidence"], "EXACT")
        self.assertEqual(result["albums"][0]["proposedAssetIds"], ["a1"])
        self.assertIsNone(result["albums"][0]["order"])
        self.assertIsNone(result["albums"][0]["coverAssetId"])

    def test_legacy_album_data_wrapper(self):
        self.album(legacy=True)
        self.assertEqual(self.build()["summary"]["googleAlbumsFound"], 1)

    def test_title_only_known_metadata_is_not_proven_album(self):
        self.write("Something/metadata.json", {"title": "Maybe an album"})
        result = self.build()
        self.assertEqual(result["summary"]["googleAlbumsFound"], 0)
        self.assertEqual(result["summary"]["albumsToCreate"], 0)
        self.assertEqual(result["albums"][0]["status"], "REQUIRES_ALBUM_CONFIRMATION")
        self.assertTrue(result["albums"][0]["reviewRequired"])

    def test_arbitrary_title_json_does_not_establish_album(self):
        self.write("Not an album/notes.json", {"title": "Personal notes"})
        self.assertEqual(self.build()["summary"]["unknownRecords"], 1)
        self.assertFalse(self.build()["albums"])

    def test_directory_alone_is_never_album(self):
        self.item("Interesting name")
        self.assertFalse(self.build()["albums"])

    def test_service_and_year_directories_are_not_albums(self):
        for name in ("2020", "Photos from 2020", "Google Photos", "Фотографии за 2020"):
            self.album(directory=name)
        self.assertFalse(self.build()["albums"])

    def test_membership_is_not_inferred_recursively(self):
        self.album()
        self.item("Holiday/unrelated")
        self.asset(directory="Holiday/unrelated")
        self.assertEqual(self.build()["summary"]["totalAlbumMemberships"], 0)

    def test_one_photo_in_multiple_albums(self):
        self.album("A", "First")
        self.album("B", "Second")
        self.item("A")
        self.item("B")
        self.asset(directory="Originals")
        result = self.build()
        self.assertEqual(result["summary"]["totalAlbumMemberships"], 2)
        self.assertEqual(
            [row["proposedAssetIds"] for row in result["albums"]], [["a1"], ["a1"]]
        )

    def test_high_confidence_name_and_capture_time_without_path(self):
        self.item()
        self.asset(directory="Existing library")
        result = self.build()["items"][0]
        self.assertEqual(result["confidence"], "HIGH_CONFIDENCE")
        self.assertIn("capture timestamp within one second", result["evidence"])

    def test_same_names_different_directories_resolved_by_exact_path(self):
        self.item()
        self.asset("correct")
        self.asset("weaker", directory="Elsewhere")
        row = self.build()["items"][0]
        self.assertEqual(row["assetId"], "correct")
        self.assertEqual(row["weakerCandidateIds"], ["weaker"])

    def test_equal_names_and_times_without_matching_paths_are_ambiguous(self):
        self.item()
        self.asset("first", directory="A")
        self.asset("second", directory="B")
        row = self.build()["items"][0]
        self.assertEqual(row["confidence"], "AMBIGUOUS")
        self.assertIsNone(row["assetId"])

    def test_unique_filename_alone_is_not_high_confidence(self):
        self.item(photoTakenTime=None)
        self.asset(directory="Elsewhere")
        row = self.build()["items"][0]
        self.assertEqual(row["confidence"], "AMBIGUOUS")
        self.assertIsNone(row["assetId"])

    def test_creation_time_is_not_capture_time(self):
        self.item(photoTakenTime=None, creationTime={"timestamp": CAPTURE})
        self.asset(directory="Elsewhere")
        self.assertEqual(self.build()["items"][0]["confidence"], "AMBIGUOUS")

    def test_missing_never_proposes_upload(self):
        self.item()
        row = self.build()["items"][0]
        self.assertEqual(row["confidence"], "MISSING")
        self.assertIsNone(row["assetId"])
        self.assertFalse(self.build()["safety"]["mediaUpload"])

    def test_duplicate_json_and_records_merge_source_provenance(self):
        self.album()
        data = self.item()
        self.write("Holiday/copy-sidecar.json", data)
        self.asset()
        result = self.build()
        self.assertEqual(result["summary"]["duplicateRecords"], 1)
        self.assertEqual(len(result["items"]), 1)
        self.assertEqual(len(result["items"][0]["sourceJsons"]), 2)
        self.assertEqual(result["summary"]["totalAlbumMemberships"], 1)

    def test_repeated_dry_run_is_byte_deterministic(self):
        self.album()
        self.item()
        self.asset()
        self.assertEqual(
            tool.canonical_json(self.build()), tool.canonical_json(self.build())
        )

    def test_future_ledger_membership_replay_is_idempotent(self):
        self.album()
        self.item()
        self.asset()
        initial = self.build()
        key = initial["albums"][0]["key"]
        self.snapshot["albums"] = [
            {
                "id": "album-1",
                "ownerId": OWNER,
                "albumName": "Family holiday",
                "assetIds": ["a1"],
            }
        ]
        ledger = {
            "ownerId": OWNER,
            "albumMappings": [
                {"ownerId": OWNER, "migrationKey": key, "albumId": "album-1"}
            ],
        }
        replay = self.build(ledger=ledger)
        self.assertEqual(replay["summary"]["albumsToCreate"], 0)
        self.assertEqual(replay["summary"]["albumsAlreadyMatched"], 1)
        self.assertEqual(replay["albums"][0]["proposedMissingMembershipIds"], [])
        self.assertEqual(
            tool.canonical_json(replay), tool.canonical_json(self.build(ledger=ledger))
        )
        self.assertFalse(replay["safety"]["applyImplemented"])

    def test_existing_album_same_title_not_automatically_reused(self):
        self.album()
        self.snapshot["albums"] = [
            {"id": "unrelated", "ownerId": OWNER, "albumName": "Family holiday"}
        ]
        row = self.build()["albums"][0]
        self.assertIsNone(row["targetAlbumId"])
        self.assertTrue(row["reviewRequired"])
        self.assertEqual(row["sameTitleAlbumIdsRequireReview"], ["unrelated"])

    def test_jpeg_heic_heif_and_video_are_supported_without_conversion(self):
        for index, title in enumerate(
            ("photo.jpeg", "photo.HEIC", "photo.heif", "video.mp4", "video.MOV")
        ):
            self.item(title=title)
            self.asset(str(index), title=title)
        result = self.build()
        self.assertEqual(result["summary"]["matches"]["EXACT"], 5)
        self.assertEqual(result["summary"]["unsupportedRecords"], 0)

    def test_heic_and_jpeg_are_not_interchangeable(self):
        self.item(title="photo.HEIC")
        self.asset(title="photo.JPG")
        self.assertEqual(self.build()["items"][0]["confidence"], "MISSING")

    def test_motion_photo_is_logical_still_asset(self):
        self.album()
        self.item(title="Samsung.MP.jpg")
        self.asset("still", title="Samsung.MP.jpg", livePhotoVideoId="motion")
        self.asset("motion", title="Samsung.MP.mp4", visibility="hidden")
        row = self.build()["items"][0]
        self.assertEqual(row["assetId"], "still")
        self.assertEqual(row["livePhotoVideoId"], "motion")

    def test_live_pair_metadata_deduplicates_logical_membership(self):
        self.album()
        self.item(title="Apple.HEIC")
        self.item(title="Apple.MOV")
        self.asset("still", title="Apple.HEIC", livePhotoVideoId="motion")
        self.asset("motion", title="Apple.MOV", visibility="hidden")
        result = self.build()
        component = next(
            row for row in result["items"] if row.get("relatedMotionComponent")
        )
        self.assertEqual(component["assetId"], "still")
        self.assertEqual(component["matchedComponentAssetId"], "motion")
        self.assertEqual(result["albums"][0]["proposedAssetIds"], ["still"])
        self.assertEqual(result["summary"]["totalAlbumMemberships"], 1)

    def test_unlinked_hidden_video_is_not_added(self):
        self.item(title="video.mp4")
        self.asset(title="video.mp4", visibility="hidden")
        self.assertEqual(self.build()["items"][0]["confidence"], "MISSING")

    def test_normal_video_remains_video_membership(self):
        self.album()
        self.item(title="movie.mp4")
        self.asset(title="movie.mp4")
        self.assertEqual(self.build()["albums"][0]["proposedAssetIds"], ["a1"])

    def test_edited_version_cannot_match_unedited_original(self):
        self.item(title="photo.jpg", filename="photo-edited.jpg.json")
        self.asset(title="photo.jpg")
        self.assertEqual(self.build()["items"][0]["confidence"], "MISSING")

    def test_edited_version_matches_its_own_asset(self):
        self.item(title="photo.jpg", filename="photo-edited.jpg.json")
        self.asset(title="photo-edited.jpg")
        self.assertEqual(self.build()["items"][0]["confidence"], "EXACT")

    def test_truncated_supplemental_filename_uses_full_google_title(self):
        title = "A very long original filename with many characters.JPG"
        self.item(
            title=title, filename="A very long original fil.supplemental-metadata.json"
        )
        self.asset(title=title, directory="Originals")
        self.assertEqual(self.build()["items"][0]["confidence"], "HIGH_CONFIDENCE")

    def test_actual_transformed_media_filename_is_preferred(self):
        self.item(title="photo.jpg", filename="photo(1).jpg.json")
        (self.root / "Holiday/photo(1).jpg").write_bytes(b"synthetic bytes")
        self.asset(title="photo(1).jpg")
        self.assertEqual(self.build()["items"][0]["confidence"], "EXACT")

    def test_cross_owner_matching_is_forbidden(self):
        self.item()
        self.asset(ownerId=OTHER)
        row = self.build()["items"][0]
        self.assertEqual(row["confidence"], "MISSING")
        self.assertFalse(row["candidates"])

    def test_missing_requested_owner_fails_closed(self):
        with self.assertRaises(tool.MappingError):
            tool.build_mapping(self.root, self.snapshot, "")

    def test_missing_inventory_owner_fails_closed(self):
        del self.snapshot["ownerId"]
        with self.assertRaises(tool.MappingError):
            self.build()

    def test_owner_mismatch_fails_closed(self):
        self.snapshot["ownerId"] = OTHER
        with self.assertRaises(tool.MappingError):
            self.build()

    def test_asset_without_owner_fails_closed(self):
        self.asset()
        del self.snapshot["assets"][0]["ownerId"]
        with self.assertRaises(tool.MappingError):
            self.build()

    def test_foreign_ledger_fails_closed(self):
        with self.assertRaises(tool.MappingError):
            self.build(ledger={"ownerId": OTHER, "albumMappings": []})

    def test_foreign_album_reference_fails_closed(self):
        self.album()
        key = self.build()["albums"][0]["key"]
        self.snapshot["albums"] = [{"id": "foreign", "ownerId": OTHER}]
        with self.assertRaises(tool.MappingError):
            self.build(
                ledger={
                    "ownerId": OWNER,
                    "albumMappings": [
                        {"ownerId": OWNER, "migrationKey": key, "albumId": "foreign"}
                    ],
                }
            )

    def test_typed_content_checksum_matches_renamed_asset(self):
        checksum = {
            "algorithm": "sha1",
            "value": hashlib.sha1(b"same bytes").hexdigest(),
        }
        self.item(contentChecksum=checksum)
        self.asset(title="renamed.jpg", directory="Elsewhere", contentChecksum=checksum)
        self.assertEqual(self.build()["items"][0]["confidence"], "EXACT")

    def test_external_path_checksum_is_never_content_evidence(self):
        digest = hashlib.sha1(b"path:/different/file.jpg").digest()
        self.item(contentChecksum={"algorithm": "sha1", "value": digest.hex()})
        self.asset(
            title="renamed.jpg",
            checksum=base64.b64encode(digest).decode(),
            libraryId="external-lib",
            checksumAlgorithm="sha1-path",
        )
        self.assertEqual(self.build()["items"][0]["confidence"], "MISSING")

    def test_untyped_api_checksum_is_not_used_even_when_library_id_null(self):
        digest = hashlib.sha1(b"bytes").digest()
        self.item(contentChecksum={"algorithm": "sha1", "value": digest.hex()})
        self.asset(
            title="renamed.jpg",
            checksum=base64.b64encode(digest).decode(),
            libraryId=None,
        )
        self.assertEqual(self.build()["items"][0]["confidence"], "MISSING")

    def test_explicit_content_sha1_algorithm_is_accepted(self):
        digest = hashlib.sha1(b"bytes").digest()
        self.item(contentChecksum={"algorithm": "sha1", "value": digest.hex()})
        self.asset(
            title="renamed.jpg",
            checksum=base64.b64encode(digest).decode(),
            checksumAlgorithm="sha1",
        )
        self.assertEqual(self.build()["items"][0]["confidence"], "EXACT")

    def test_equal_content_duplicates_remain_ambiguous(self):
        checksum = {
            "algorithm": "sha256",
            "value": hashlib.sha256(b"bytes").hexdigest(),
        }
        self.item(contentChecksum=checksum)
        self.asset("a1", title="first.jpg", contentChecksum=checksum)
        self.asset("a2", title="second.jpg", contentChecksum=checksum)
        self.assertEqual(self.build()["items"][0]["confidence"], "AMBIGUOUS")

    def test_dimensions_allow_rotated_orientation(self):
        self.item(width=4000, height=3000)
        self.asset(width=3000, height=4000)
        self.assertEqual(self.build()["items"][0]["confidence"], "EXACT")

    def test_conflicting_dimensions_reject_match(self):
        self.item(width=4000, height=3000)
        self.asset(width=1920, height=1080)
        self.assertEqual(self.build()["items"][0]["confidence"], "MISSING")

    def test_exif_size_and_dimensions_are_used(self):
        self.item(fileSize=1234, width=4000, height=3000)
        self.asset(
            exifInfo={
                "fileSizeInByte": 1234,
                "exifImageWidth": 4000,
                "exifImageHeight": 3000,
            }
        )
        evidence = self.build()["items"][0]["evidence"]
        self.assertIn("size", evidence)
        self.assertIn("dimensions (orientation independent)", evidence)

    def test_mismatching_capture_timestamp_rejects_match(self):
        self.item()
        self.asset(fileCreatedAt="2021-01-01T00:00:00Z")
        self.assertEqual(self.build()["items"][0]["confidence"], "MISSING")

    def test_explicit_path_map_matches_metadata_staged_elsewhere(self):
        self.item()
        self.asset(originalPath="/nas/photos/source/IMG_0001.JPG")
        row = self.build(
            path_maps=[
                {"metadataPrefix": "Holiday", "assetPrefix": "/nas/photos/source"}
            ]
        )["items"][0]
        self.assertEqual(row["confidence"], "EXACT")

    def test_longest_prefix_wins(self):
        self.item("A/B")
        self.asset(directory="A/B", originalPath="/correct/IMG_0001.JPG")
        row = self.build(
            path_maps=[
                {"metadataPrefix": "A", "assetPrefix": "/incorrect"},
                {"metadataPrefix": "A/B", "assetPrefix": "/correct"},
            ]
        )["items"][0]
        self.assertEqual(row["confidence"], "EXACT")

    def test_conflicting_or_escaping_path_maps_fail_closed(self):
        for maps in (
            [{"metadataPrefix": "../escape", "assetPrefix": "/nas"}],
            [{"metadataPrefix": "A", "assetPrefix": "relative"}],
            [
                {"metadataPrefix": "A", "assetPrefix": "/nas"},
                {"metadataPrefix": "A", "assetPrefix": "/other"},
            ],
        ):
            with self.subTest(maps=maps), self.assertRaises(tool.MappingError):
                self.build(path_maps=maps)

    def test_unsupported_and_malformed_records_are_reported(self):
        self.item(title="data.txt")
        self.write("mystery.json", [1, 2, 3])
        (self.root / "broken.json").write_text("{", encoding="utf-8")
        result = self.build()
        self.assertEqual(result["summary"]["unsupportedRecords"], 1)
        self.assertEqual(result["summary"]["unknownRecords"], 2)

    def test_unsafe_title_path_is_not_read(self):
        self.item(title="../../secret.jpg", filename="unsafe.json")
        self.assertEqual(self.build()["summary"]["unknownRecords"], 1)

    def test_symlink_metadata_and_directories_are_not_followed(self):
        outside = self.base / "outside.json"
        outside.write_text('{"title":"private"}')
        (self.root / "linked.json").symlink_to(outside)
        (self.root / "linked-dir").symlink_to(self.base, target_is_directory=True)
        result = self.build()
        self.assertEqual(result["summary"]["unknownRecords"], 1)

    def test_readonly_media_hash_is_opt_in_and_streamed(self):
        self.item()
        original = self.root / "Holiday/IMG_0001.JPG"
        original.write_bytes(b"not a real private image")
        self.asset(
            exifInfo={"fileSizeInByte": original.stat().st_size},
            contentChecksum={
                "algorithm": "sha1",
                "value": hashlib.sha1(original.read_bytes()).hexdigest(),
            },
        )
        before = original.read_bytes()
        row = self.build(hash_media=True)["items"][0]
        self.assertIn("content checksum", row["evidence"])
        self.assertEqual(original.read_bytes(), before)

    def test_default_never_reads_media_contents(self):
        self.item()
        original = self.root / "Holiday/IMG_0001.JPG"
        original.write_bytes(b"original")
        self.asset()
        real_open = Path.open

        def guarded_open(path, *args, **kwargs):
            if path == original:
                raise AssertionError("media opened without --hash-media")
            return real_open(path, *args, **kwargs)

        with patch.object(Path, "open", guarded_open):
            self.assertEqual(self.build()["items"][0]["confidence"], "EXACT")

    def test_output_inside_takeout_or_media_root_is_rejected(self):
        result = self.build(
            path_maps=[{"metadataPrefix": "", "assetPrefix": str(self.base / "media")}]
        )
        for target in (self.root / "audit.json", self.base / "media/audit.json"):
            with self.subTest(target=target), self.assertRaises(tool.MappingError):
                tool.write_mapping(result, str(target), self.base / "snapshot.json")

    def test_output_does_not_overwrite_existing_file(self):
        output = self.base / "audit.json"
        output.write_text("existing")
        with self.assertRaises(tool.MappingError):
            tool.write_mapping(self.build(), str(output), self.base / "snapshot.json")
        self.assertEqual(output.read_text(), "existing")

    def test_safe_output_and_sources_unchanged(self):
        self.album()
        self.item()
        self.asset()
        before = {str(path): path.read_bytes() for path in self.root.rglob("*.json")}
        output = self.base / "audit.json"
        tool.write_mapping(self.build(), str(output), self.base / "snapshot.json")
        self.assertEqual(json.loads(output.read_text())["mode"], "DRY_RUN_ONLY")
        self.assertEqual(
            before, {str(path): path.read_bytes() for path in self.root.rglob("*.json")}
        )

    def test_cli_requires_owner_and_has_no_apply_flag(self):
        result = subprocess.run(
            [sys.executable, str(Path(tool.__file__)), "--apply"],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("apply", tool.main.__doc__ or "")

    def test_cli_offline_success_stdout(self):
        self.album()
        self.item()
        self.asset()
        inventory = self.base / "inventory.json"
        inventory.write_text(json.dumps(self.snapshot))
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            result = tool.main(
                [
                    "--owner",
                    OWNER,
                    "--takeout",
                    str(self.root),
                    "--inventory",
                    str(inventory),
                    "--output",
                    "-",
                ]
            )
        self.assertEqual(result, 0)
        self.assertFalse(json.loads(output.getvalue())["safety"]["productionRead"])

    def test_cli_online_and_offline_mapping_only_differ_in_read_flag(self):
        self.album()
        self.item()
        self.asset()
        output = io.StringIO()
        with (
            patch("gallery_inventory.fetch_inventory", return_value=self.snapshot),
            contextlib.redirect_stdout(output),
        ):
            result = tool.main(
                [
                    "--owner",
                    OWNER,
                    "--takeout",
                    str(self.root),
                    "--server",
                    "https://example.invalid",
                    "--output",
                    "-",
                ]
            )
        self.assertEqual(result, 0)
        online = json.loads(output.getvalue())
        self.assertTrue(online["safety"]["productionRead"])
        online["safety"]["productionRead"] = False
        self.assertEqual(online, self.build())

    def test_api_owner_rejection_creates_no_output(self):
        from gallery_inventory import InventoryError

        output = self.base / "should-not-exist.json"
        with (
            patch(
                "gallery_inventory.fetch_inventory",
                side_effect=InventoryError("owner mismatch"),
            ),
            contextlib.redirect_stderr(io.StringIO()),
        ):
            result = tool.main(
                [
                    "--owner",
                    OWNER,
                    "--takeout",
                    str(self.root),
                    "--server",
                    "https://example.invalid",
                    "--output",
                    str(output),
                ]
            )
        self.assertEqual(result, 2)
        self.assertFalse(output.exists())

    def test_contradictory_duplicate_asset_ids_fail_closed(self):
        self.asset()
        self.asset(ownerId=OWNER, originalPath="/different")
        with self.assertRaises(tool.MappingError):
            self.build()

    def test_conflicting_album_metadata_fails_closed(self):
        self.album()
        self.write(
            "Holiday/another.json",
            {"title": "Other", "access": "protected", "description": "different"},
        )
        with self.assertRaises(tool.MappingError):
            self.build()

    def test_asset_index_limits_each_item_to_related_candidates(self):
        assets = [
            dict(
                self.asset(
                    str(index), title=f"unrelated-{index}.jpg", directory="Others"
                )
            )
            for index in range(500)
        ]
        chosen = self.asset("chosen")
        self.item()
        parsed = tool.parse_takeout(self.root, OWNER, [])
        candidates = tool.AssetIndex(assets + [chosen]).candidates(parsed["items"][0])
        self.assertEqual([row["id"] for row in candidates], ["chosen"])

    def test_offline_assets_are_not_matched(self):
        self.item()
        self.asset(isOffline=True)
        self.assertEqual(self.build()["items"][0]["confidence"], "MISSING")

    def test_offline_live_parent_does_not_contribute_membership(self):
        self.item(title="Apple.MOV")
        self.asset(
            "still", title="Apple.HEIC", livePhotoVideoId="motion", isOffline=True
        )
        self.asset("motion", title="Apple.MOV", visibility="hidden")
        self.assertEqual(self.build()["items"][0]["confidence"], "MISSING")

    def test_hash_media_never_self_confirms_a_mapped_gallery_target(self):
        self.item()
        target = self.base / "gallery-originals"
        target.mkdir()
        media = target / "IMG_0001.JPG"
        media.write_bytes(b"unrelated target bytes")
        checksum = {
            "algorithm": "sha1",
            "value": hashlib.sha1(media.read_bytes()).hexdigest(),
        }
        self.asset(originalPath=str(media), contentChecksum=checksum)
        row = self.build(
            hash_media=True,
            path_maps=[{"metadataPrefix": "Holiday", "assetPrefix": str(target)}],
        )["items"][0]
        self.assertNotIn("content checksum", row["evidence"])

    def test_independent_source_hash_rejects_wrong_mapped_target_bytes(self):
        self.item()
        (self.root / "Holiday/IMG_0001.JPG").write_bytes(b"actual source bytes")
        target = self.base / "gallery-originals"
        target.mkdir()
        media = target / "IMG_0001.JPG"
        media.write_bytes(b"incorrect target bytes")
        self.asset(
            originalPath=str(media),
            contentChecksum={
                "algorithm": "sha1",
                "value": hashlib.sha1(media.read_bytes()).hexdigest(),
            },
        )
        row = self.build(
            hash_media=True,
            path_maps=[{"metadataPrefix": "Holiday", "assetPrefix": str(target)}],
        )["items"][0]
        self.assertEqual(row["confidence"], "MISSING")

    def test_output_cannot_be_in_snapshot_original_directory_without_map(self):
        originals = self.base / "nas-originals"
        originals.mkdir()
        self.asset(originalPath=str(originals / "original.jpg"))
        with self.assertRaises(tool.MappingError):
            tool.write_mapping(
                self.build(), str(originals / "audit.json"), self.base / "snapshot.json"
            )
        self.assertFalse((originals / "audit.json").exists())

    def test_arbitrary_gmail_album_like_metadata_is_not_photos(self):
        gmail = self.base / "Gmail"
        gmail.mkdir()
        (gmail / "metadata.json").write_text(
            json.dumps(
                {
                    "title": "Private mail",
                    "access": "protected",
                    "description": "not photos",
                }
            )
        )
        with self.assertRaises(tool.MappingError):
            tool.build_mapping(gmail, self.snapshot, OWNER)

    def test_mixed_takeout_reads_only_google_photos_subtree(self):
        self.album()
        gmail = self.base / "Gmail"
        gmail.mkdir()
        (gmail / "metadata.json").write_text(
            json.dumps(
                {
                    "title": "Private mail",
                    "access": "protected",
                    "description": "not photos",
                }
            )
        )
        result = tool.build_mapping(self.base, self.snapshot, OWNER)
        self.assertEqual(result["summary"]["googleAlbumsFound"], 1)
        self.assertEqual(result["albums"][0]["title"], "Family holiday")

    def test_explicitly_confirmed_isolated_photos_root_supported(self):
        metadata = self.base / "docice"
        metadata.mkdir()
        (metadata / "Album").mkdir()
        (metadata / "Album/metadata.json").write_text(
            (FIXTURES / "album-modern.json").read_text()
        )
        result = tool.build_mapping(
            metadata, self.snapshot, OWNER, photos_root_confirmed=True
        )
        self.assertEqual(result["summary"]["googleAlbumsFound"], 1)

    def test_indexed_json_only_media_association_stays_ambiguous(self):
        for filename in (
            "IMG_0001.JPG(1).json",
            "IMG_0001.JPG.supplemental-metadata(1).json",
            "IMG_0001(1).JPG.json",
        ):
            self.item(filename=filename)
        self.asset()
        rows = self.build()["items"]
        self.assertEqual(len(rows), 3)
        self.assertTrue(
            all(
                row["confidence"] == "AMBIGUOUS" and row["assetId"] is None
                for row in rows
            )
        )

    def test_malformed_path_map_records_fail_closed(self):
        for row in (None, 5, "bad"):
            with self.subTest(row=row), self.assertRaises(tool.MappingError):
                self.build(path_maps=[row])

    def test_malformed_asset_path_fails_closed(self):
        self.asset(originalPath={"wrong": "shape"})
        with self.assertRaises(tool.MappingError):
            self.build()

    def test_supported_extensions_match_actual_gallery_source(self):
        source = (
            Path(__file__).resolve().parents[3] / "server/src/utils/mime-types.ts"
        ).read_text()

        def extensions(name):
            block = re.search(
                r"const " + name + r"(?:[^=]+)? = \{(.*?)\n\};", source, re.DOTALL
            )
            self.assertIsNotNone(block, name)
            return set(re.findall(r"'(\.[a-z0-9]+)':", block.group(1)))

        images = (
            extensions("raw")
            | extensions("webSupportedImage")
            | extensions("heif")
            | extensions("webUnsupportedImage")
        )
        self.assertEqual(tool.IMAGE_SUFFIXES, images)
        self.assertEqual(tool.VIDEO_SUFFIXES, extensions("video"))

    def test_raw_heif_and_other_supported_formats_are_classified(self):
        for index, title in enumerate(
            (
                "photo.CR3",
                "photo.NEF",
                "photo.RAF",
                "photo.ARW",
                "photo.HIF",
                "photo.JXL",
                "video.WMV",
                "video.TS",
            )
        ):
            self.item(title=title)
            self.asset(str(index), title=title)
        self.assertEqual(self.build()["summary"]["matches"]["EXACT"], 8)

    def test_directory_permission_error_fails_closed(self):
        def failing_walk(*args, **kwargs):
            kwargs["onerror"](PermissionError("unreadable"))
            return iter(())

        with (
            patch.object(tool.os, "walk", side_effect=failing_walk),
            self.assertRaises(tool.MappingError),
        ):
            self.build()

    def test_unknown_record_inside_album_requires_review(self):
        self.album()
        self.write("Holiday/mystery.json", {"something": "unknown"})
        self.assertTrue(self.build()["albums"][0]["reviewRequired"])

    def test_malformed_access_is_unknown_or_unconfirmed_not_crash(self):
        self.write("Folder/metadata.json", {"title": "Unproven", "access": []})
        self.assertEqual(
            self.build()["albums"][0]["status"], "REQUIRES_ALBUM_CONFIRMATION"
        )

    def test_malformed_album_membership_fails_closed(self):
        self.snapshot["albums"] = [
            {"id": "a", "ownerId": OWNER, "assetIds": [{"unexpected": "object"}]}
        ]
        with self.assertRaises(tool.MappingError):
            self.build()


if __name__ == "__main__":
    unittest.main()
