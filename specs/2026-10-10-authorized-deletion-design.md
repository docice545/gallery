# Gallery 5.7.2 (9): deletion contract

This candidate supersedes frozen application source `6a558b554e26e8c0fc5bc5c99259a92e7ef26a56` (build 8).
It reuses Immich AssetDelete, existing authentication/accounts/API keys and the existing NFS mounts.
It introduces no NAS service, new credentials, privileged unlink helper, or filesystem permission changes.
Production `work` remains `42790b06edc21438811e56e40c431eee37c24894` until separate approval.

## Evidence boundary

The owner's physical 2026-10-02 test proved managed docice JPEG soft Trash preserves the NAS original,
and permanent deletion removes the DB row and NAS original, without the file appearing in the checked
recycle directories. This is historical evidence for that asset/account/library only. New software adds
explicit per-owner/per-library authorization and durable suppression around that existing lifecycle.
External libraries, other accounts, restore and physical device APIs need independent acceptance.

## Server contract

- Ordinary `DELETE /api/assets` (`force=false`) marks Trash; never unlinks. Existing Restore updates
  only restorable rows and returns actual acknowledgements; capture date, timezone, album links and pair
  identity remain unchanged. Offline external index tombstones are distinct from user Trash.
- `POST /api/assets/permanent-deletion` accepts 1..200 selected IDs and `confirmed=true`; returns one
  owner-scoped `complete/failed/pending/blocked` receipt per ID. Unknown/foreign/active assets fail closed.
  Existing force-delete delegates to this contract and rejects partial success; Empty Trash prechecks
  every library, then processes bounded batches. Normal Trash remains available with retention disabled.
- `PUT /api/assets/deletion-policy` is existing admin + system-config permission. An owner and either
  `managed` or an existing owner's library UUID are required. Defaults: disabled. Enabling requires
  exact existing roots, verified exclusive roots and SHA-256 recovery proof. No permission expansion.
  Roots must be canonical, writable through current permissions, disjoint from other users (including
  lexical ancestry and inode aliases). Read-only storage remains read-only and returns failure.
- `GET /api/assets/:id/deletion-status` / bounded bulk POST return owner-scoped receipts after row removal.
  API key permissions remain enforced by existing guards. Private paths/proofs are never returned.
- `asset_deletion_policy` and `asset_deletion_tombstone` are additive tables. Authorization, original
  identity, pairing, checksums and aliases survive asset/library FK cascade. Hashing streams files.
  Intent commits before long hashing. Failed unlink retains the row/receipt and reports failure;
  retries verify current authorization and exact inode/size/mtime/hash, never guess a replacement.
- Only the worker that removes the row emits delete/quota/FileDelete effects. Originals and sidecars
  are removed under the receipt, derivatives only enter FileDelete. Bare legacy FileDelete cannot
  remove originals. Retention jobs (including old jobs with cutoff) are skipped unconditionally;
  this release does not grant retention approval. Library index cleanup preserves originals.
- Live still's exclusively linked same-owner/same-library hidden video is journaled and removed first.
  Failed video removal keeps the still row available in Trash. Shared companions are preserved.
- Permanent suppression uses owner+canonical path and comparable SHA-1/duplicate aliases. DB insert
  triggers serialize against deletion; external scan additionally streams bytes only for owners with
  receipts, so renamed byte-identical media cannot reimport. No fuzzy identity or cross-owner checksum
  blocking. Arbitrarily edited media is a new identity, not provably the same asset.

The filesystem has no POSIX conditional-unlink-by-inode API. Anchored parent descriptors, no-follow,
identity/hash checks and DB serialization protect ordinary Gallery operations. Root opt-in additionally
requires an exclusive controlled filesystem namespace: an independent process replacing entries at the
last check/unlink boundary is outside the guaranteed contract. Do not authorize a root shared with an
uncontrolled writer; verify actual NFS inode behavior on disposable media before authorizing family roots.

## Mobile/web behavior

Trash resolves the server operation before local deletion and keeps optimistic revision state through
uncertain responses. Definite rejection rolls back; ambiguous delivery survives restart/reconnect.
OS APIs supply the actual deleted IDs. Denial/partial result is visible, not reported as all-success.
Permanent deletion only removes local copies for server-confirmed completed items and uses OS delete,
not local Trash. Retained stable local IDs survive remote row removal and even a changed local checksum.
Backup/local timeline filter durable markers. Restore never silently recreates intentionally deleted
local files; the NAS-backed remote asset returns at its original timestamp without reupload.
Late Restore acknowledgements cannot clear a newer Trash/permanent marker. Empty Trash captures a
bounded selection and reports each partial server/local result. Web prunes completed receipts only.

## Rollback boundary

Never down-migrate/drop suppression evidence. The new migration refuses down, and revert-to-Immich
refuses a DB with the journal. Returning to an old image without migration recognition would fail boot.
The existing release tooling has an explicit build-9 profile and an API-only rollback recognition overlay
on the exact previous immutable image. Only two marker files are added; previous API code/config/layers
remain. Original DB triggers/tables persist and deletion workers stay disabled. File deletion cannot be
undone by a SQL restore alone: exact NAS recovery plus reconciliation is an operator recovery task.
Before enabling any permanent deletion, preserve both fresh DB recovery and the unchanged NAS proof.
