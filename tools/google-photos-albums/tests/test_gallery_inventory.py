"""Owner isolation and read-only transport contract; no production access."""

import io
import json
import os
from pathlib import Path
import sys
import unittest
import urllib.error
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gallery_inventory import (
    GalleryInventoryClient,
    InventoryError,
    _NoRedirect,
    fetch_inventory,
)

OWNER = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
ASSET = "33333333-3333-4333-8333-333333333333"
ALBUM = "44444444-4444-4444-8444-444444444444"
SECOND = "55555555-5555-4555-8555-555555555555"


def asset(asset_id=ASSET, owner=OWNER, **extra):
    return {"id": asset_id, "ownerId": owner, "type": "IMAGE", **extra}


class FakeOpener:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def open(self, request, timeout):
        self.calls.append(request)
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return io.BytesIO(json.dumps(response).encode())


class InventoryTests(unittest.TestCase):
    def client(self, responses):
        client = GalleryInventoryClient(
            "https://gallery.example.test", OWNER, "secret-test-key"
        )
        client._opener = FakeOpener(responses)
        return client

    def test_read_only_pagination_and_own_album(self):
        client = self.client(
            [
                {"id": OWNER},
                {
                    "assets": {
                        "items": [
                            asset(originalPath="/library/image.jpg", checksum="opaque")
                        ],
                        "nextPage": "2",
                    }
                },
                {"assets": {"items": [asset(SECOND, type="VIDEO")], "nextPage": None}},
                [{"id": ALBUM}],
                {
                    "id": ALBUM,
                    "albumName": "Family",
                    "albumUsers": [{"role": "owner", "user": {"id": OWNER}}],
                    "assets": [
                        asset(),
                        asset(SECOND),
                        asset("66666666-6666-4666-8666-666666666666", OTHER),
                    ],
                },
            ]
        )
        result = client.collect()
        self.assertEqual(result["ownerId"], OWNER)
        self.assertEqual(len(result["assets"]), 2)
        self.assertEqual(result["albums"][0]["assetIds"], [ASSET, SECOND])
        self.assertEqual(result["albums"][0]["excludedForeignMemberships"], 1)
        self.assertNotIn("contentChecksum", result["assets"][0])
        calls = client._opener.calls
        self.assertEqual(
            [(call.method, call.full_url.split("/api")[1]) for call in calls],
            [
                ("GET", "/users/me"),
                ("POST", "/search/metadata"),
                ("POST", "/search/metadata"),
                ("GET", "/albums?isOwned=true"),
                ("GET", "/albums/" + ALBUM),
            ],
        )
        for call in calls:
            if call.method == "POST":
                body = json.loads(call.data)
                self.assertEqual(body["ownerId"], OWNER)
                self.assertTrue(body["withExif"])
                self.assertFalse(body["withSharedSpaces"])
                self.assertFalse(body["withDeleted"])
        self.assertNotIn("secret-test-key", json.dumps(result))

    def test_authenticated_owner_mismatch_fails_before_library_read(self):
        client = self.client([{"id": OTHER}])
        with self.assertRaisesRegex(InventoryError, "explicit owner"):
            client.collect()
        self.assertEqual(len(client._opener.calls), 1)

    def test_foreign_search_asset_fails_closed(self):
        client = self.client(
            [
                {"id": OWNER},
                {"assets": {"items": [asset(owner=OTHER)], "nextPage": None}},
            ]
        )
        with self.assertRaisesRegex(InventoryError, "cross-owner"):
            client.collect()

    def test_owner_of_listed_album_must_be_proven_by_detail(self):
        client = self.client(
            [
                {"id": OWNER},
                {"assets": {"items": [], "nextPage": None}},
                [{"id": ALBUM}],
                {
                    "id": ALBUM,
                    "albumUsers": [{"role": "owner", "user": {"id": OTHER}}],
                    "assets": [],
                },
            ]
        )
        with self.assertRaisesRegex(InventoryError, "Album owner mismatch"):
            client.collect()

    def test_malformed_album_owner_is_a_safe_schema_error(self):
        client = self.client(
            [
                {"id": OWNER},
                {"assets": {"items": [], "nextPage": None}},
                [{"id": ALBUM}],
                {
                    "id": ALBUM,
                    "albumUsers": [{"role": "owner", "user": None}],
                    "assets": [],
                },
            ]
        )
        with self.assertRaisesRegex(InventoryError, "prove album ownership"):
            client.collect()

    def test_repeated_or_nonprogressing_page_rejected(self):
        for next_page in ("1", "3", "opaque-cursor", True):
            with self.subTest(next_page=next_page):
                client = self.client(
                    [
                        {"id": OWNER},
                        {"assets": {"items": [asset()], "nextPage": next_page}},
                    ]
                )
                with self.assertRaises(InventoryError):
                    client.collect()

    def test_duplicate_asset_across_pages_rejected(self):
        client = self.client(
            [
                {"id": OWNER},
                {"assets": {"items": [asset()], "nextPage": "2"}},
                {"assets": {"items": [asset()], "nextPage": None}},
            ]
        )
        with self.assertRaisesRegex(InventoryError, "repeated asset"):
            client.collect()

    def test_malformed_response_never_becomes_empty_inventory(self):
        client = self.client(
            [{"id": OWNER}, {"assets": {"items": None, "nextPage": None}}]
        )
        with self.assertRaisesRegex(InventoryError, "schema"):
            client.collect()

    def test_https_origin_and_no_credentials_in_url(self):
        for url in (
            "http://gallery.test",
            "https://user:password@gallery.test",
            "https://gallery.test?token=x",
            "https://gallery.test/#frag",
            "https://gallery.test/api/assets",
        ):
            with self.subTest(url=url):
                with self.assertRaises(InventoryError):
                    GalleryInventoryClient(url, OWNER, "key")
        self.assertEqual(
            GalleryInventoryClient("https://gallery.test/api/", OWNER, "key").base,
            "https://gallery.test/api",
        )

    def test_mutating_or_media_endpoints_not_callable(self):
        client = self.client([])
        for method, path in (
            ("DELETE", "/albums/" + ALBUM),
            ("POST", "/albums"),
            ("PUT", "/albums/" + ALBUM + "/assets"),
            ("GET", "/assets/" + ASSET + "/original"),
            ("GET", "/assets/" + ASSET + "/thumbnail"),
        ):
            with self.subTest(method=method, path=path):
                with self.assertRaisesRegex(InventoryError, "allowlist"):
                    client._request(method, path)
        self.assertEqual(client._opener.calls, [])

    def test_redirects_do_not_forward_key(self):
        self.assertIsNone(
            _NoRedirect().redirect_request(
                None, None, 302, "Found", {}, "https://other.test"
            )
        )

    def test_http_failure_redacts_response_and_key(self):
        error = urllib.error.HTTPError(
            "https://gallery.test?secret=private",
            403,
            "secret-test-key",
            {},
            io.BytesIO(b"private-photo-data"),
        )
        client = self.client([error])
        with self.assertRaisesRegex(InventoryError, "HTTP 403") as caught:
            client.collect()
        self.assertEqual(str(caught.exception), "Inventory request failed: HTTP 403")

    def test_network_failure_does_not_log_private_details(self):
        client = self.client([urllib.error.URLError("private connection config")])
        with self.assertRaisesRegex(InventoryError, "connection failed") as caught:
            client.collect()
        self.assertNotIn("private", str(caught.exception))

    def test_environment_key_required_without_cli_secret(self):
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(InventoryError, "empty or invalid"):
                fetch_inventory("https://gallery.test", OWNER)
        with self.assertRaisesRegex(InventoryError, "variable name"):
            fetch_inventory("https://gallery.test", OWNER, "bad=value")

    def test_response_memory_is_bounded(self):
        client = self.client([{"id": OWNER}])
        client.MAX_RESPONSE_BYTES = 8
        with self.assertRaises(InventoryError):
            client.collect()


if __name__ == "__main__":
    unittest.main()
