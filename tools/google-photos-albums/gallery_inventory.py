"""Read-only, owner-verified Gallery inventory for the Takeout dry-run.

Only /users/me, /search/metadata (a read-only POST), and owned album GETs
are allowed. No originals, previews, mutations or database access.
"""

from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request
import uuid
from typing import Any


class InventoryError(ValueError):
    """Fail closed without exposing API keys or private server responses."""


def _uuid(value: Any, label: str) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError) as exc:
        raise InventoryError(f"Invalid {label} UUID") from exc


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Never forward an API key to a redirected URL, even on the same host.
        return None


class GalleryInventoryClient:
    MAX_RESPONSE_BYTES = 32 * 1024 * 1024
    MAX_PAGES = 100_000

    def __init__(self, server: str, owner: str, api_key: str):
        parsed = urllib.parse.urlsplit(server)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
            or parsed.path.rstrip("/") not in ("", "/api")
        ):
            raise InventoryError(
                "Use an HTTPS Gallery origin or /api URL without credentials/query"
            )
        if not api_key or "\r" in api_key or "\n" in api_key:
            raise InventoryError("API key environment variable is empty or invalid")
        self.base = urllib.parse.urlunsplit(
            (parsed.scheme, parsed.netloc, "/api", "", "")
        )
        self.owner = _uuid(owner, "owner")
        self._api_key = api_key
        self._opener = urllib.request.build_opener(_NoRedirect())

    def _request(self, method: str, path: str, body: dict | None = None) -> Any:
        allowed = (
            (method == "GET" and path in ("/users/me", "/albums?isOwned=true"))
            or (method == "POST" and path == "/search/metadata")
            or (
                method == "GET"
                and re.fullmatch(r"/albums/[0-9a-f-]{36}", path) is not None
            )
        )
        if not allowed:
            raise InventoryError(
                "Endpoint is not part of the read-only inventory allowlist"
            )
        payload = json.dumps(body).encode("utf-8") if body is not None else None
        request = urllib.request.Request(
            self.base + path,
            data=payload,
            method=method,
            headers={
                "x-api-key": self._api_key,
                "Accept": "application/json",
                "Content-Type": "application/json",
            },
        )
        try:
            with self._opener.open(request, timeout=60) as response:
                data = response.read(self.MAX_RESPONSE_BYTES + 1)
            if len(data) > self.MAX_RESPONSE_BYTES:
                raise InventoryError("Inventory response exceeds the bounded page size")
            return json.loads(data)
        except InventoryError:
            raise
        except urllib.error.HTTPError as exc:
            # Do not include response bodies, URLs with credentials or request headers.
            raise InventoryError(f"Inventory request failed: HTTP {exc.code}") from None
        except (urllib.error.URLError, TimeoutError, OSError):
            raise InventoryError(
                "Inventory connection failed; no changes were made"
            ) from None
        except (ValueError, UnicodeError):
            raise InventoryError("Inventory response is not valid JSON") from None

    def _check_asset(self, asset: Any) -> dict:
        if (
            not isinstance(asset, dict)
            or _uuid(asset.get("ownerId"), "asset owner") != self.owner
        ):
            raise InventoryError(
                "Asset owner mismatch; cross-owner matching is forbidden"
            )
        _uuid(asset.get("id"), "asset")
        return asset

    def collect(self) -> dict:
        me = self._request("GET", "/users/me")
        if (
            not isinstance(me, dict)
            or _uuid(me.get("id"), "authenticated user") != self.owner
        ):
            raise InventoryError("API key does not belong to the explicit owner")

        assets: dict[str, dict] = {}
        page = 1
        while True:
            response = self._request(
                "POST",
                "/search/metadata",
                {
                    "ownerId": self.owner,
                    "page": page,
                    "size": 1000,
                    "withExif": True,
                    "withSharedSpaces": False,
                    "withDeleted": False,
                    "isOffline": False,
                    "order": "asc",
                },
            )
            result = response.get("assets") if isinstance(response, dict) else None
            if not isinstance(result, dict) or not isinstance(
                result.get("items"), list
            ):
                raise InventoryError("Search inventory schema is unsupported")
            for raw in result["items"]:
                asset = self._check_asset(raw)
                # Deletion/offline/visibility state must not become migration candidates.
                # Keep original DTO fields (including hidden motion IDs) in the snapshot;
                # the matcher excludes hidden/locked/trashed/offline records explicitly.
                asset_id = _uuid(asset["id"], "asset")
                if asset_id in assets:
                    raise InventoryError(
                        "Search pages contain a repeated asset; retry a stable snapshot"
                    )
                assets[asset_id] = asset
            next_page = result.get("nextPage")
            if next_page is None:
                break
            if isinstance(next_page, bool) or not str(next_page).isdigit():
                raise InventoryError("Unsupported search pagination token")
            new_page = int(next_page)
            if new_page != page + 1 or new_page > self.MAX_PAGES or not result["items"]:
                raise InventoryError("Invalid or non-progressing inventory pagination")
            page = new_page

        listed = self._request("GET", "/albums?isOwned=true")
        if not isinstance(listed, list):
            raise InventoryError("Album inventory schema is unsupported")
        albums = []
        seen_albums: set[str] = set()
        for listed_album in listed:
            if not isinstance(listed_album, dict):
                raise InventoryError("Album inventory schema is unsupported")
            album_id = _uuid(listed_album.get("id"), "album")
            if album_id in seen_albums:
                raise InventoryError("Album inventory contains repeated IDs")
            seen_albums.add(album_id)
            album = self._request("GET", "/albums/" + album_id)
            if (
                not isinstance(album, dict)
                or _uuid(album.get("id"), "album") != album_id
            ):
                raise InventoryError("Album detail does not match the requested album")
            members = album.get("albumUsers")
            if not isinstance(members, list):
                raise InventoryError("Cannot prove album ownership")
            owners = []
            for member in members:
                if not isinstance(member, dict):
                    raise InventoryError("Malformed album user")
                if member.get("role") == "owner":
                    user = member.get("user")
                    if not isinstance(user, dict):
                        raise InventoryError("Cannot prove album ownership")
                    owners.append(user.get("id"))
            if len(owners) != 1 or _uuid(owners[0], "album owner") != self.owner:
                raise InventoryError("Album owner mismatch")
            raw_memberships = album.get("assets")
            if not isinstance(raw_memberships, list):
                raise InventoryError("Album memberships are unavailable")
            # An owned shared album can legitimately contain another user's assets.
            # Preserve only IDs from this explicit owner's verified asset inventory.
            asset_ids = []
            foreign_count = 0
            for member in raw_memberships:
                if not isinstance(member, dict):
                    raise InventoryError("Malformed album membership")
                member_id = _uuid(member.get("id"), "album asset")
                member_owner = _uuid(member.get("ownerId"), "album asset owner")
                if member_owner != self.owner:
                    foreign_count += 1
                    continue
                if member_id in assets:
                    asset_ids.append(member_id)
            albums.append(
                {
                    "id": album_id,
                    "ownerId": self.owner,
                    "albumName": album.get("albumName", ""),
                    "description": album.get("description", ""),
                    "assetIds": sorted(set(asset_ids)),
                    "excludedForeignMemberships": foreign_count,
                }
            )

        return {
            "ownerId": self.owner,
            "assets": [assets[asset_id] for asset_id in sorted(assets)],
            "albums": sorted(albums, key=lambda item: item["id"]),
            "inventorySource": "Gallery owner-scoped read-only API",
            "consistency": "Paginated live view; concurrent library changes require a repeated dry-run",
        }


def fetch_inventory(
    server: str, owner: str, api_key_env: str = "GALLERY_TAKEOUT_API_KEY"
) -> dict:
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", api_key_env):
        raise InventoryError("Invalid API key environment variable name")
    return GalleryInventoryClient(
        server, owner, os.environ.get(api_key_env, "")
    ).collect()
