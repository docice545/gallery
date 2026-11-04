# Metadata writes, sidecars and concurrent extraction

Manual metadata updates and background extraction share `asset_exif`. A pending
manual update adds its fields to `lockedProperties`. The Sidecar queue writes
those fields to XMP and then permits extraction to import that XMP again.

Two independent races break this sequence:

1. Reading EXIF values and pending properties in different statements can pair
   an old `rating = null` snapshot with the lock for a newly committed rating 3.
   This writes XMP `Rating: 0` and acknowledges the wrong update.
2. An extraction can read the original file before XMP exists, then finish after
   rating 3 has been written and unlocked. Checking only the current lock list
   admits its stale `rating = null` result.

## Invariants

- `AssetJobRepository.writeSidecar` reads values and pending fields together,
  under a PostgreSQL row lock. The transaction holds an asset key-share lock
  before locking EXIF, preserving asset → EXIF → file lock order.
- Writers for the same asset serialize across workers. Manual changes wait for
  the current write to finish, then create their own pending update. Different
  assets can still be processed concurrently.
- The file-I/O callback performs no database operations. Snapshot, registration
  and unlock use the same transaction/connection; concurrent workers do not hold
  one pool connection while waiting for another one to finish the transaction.
- XMP registration and unlocking commit only after the file write (including S3
  upload) succeeds. A file error propagates; rollback retains the pending edit
  for retry. A crash after file I/O but before commit also retains the edit.
- Extraction captures the existing EXIF `updateId` before reading media. Its
  conflict update preserves lockable fields if the revision changed, even if a
  sidecar writer has already cleared the lock. A null revision represents an
  EXIF row that did not yet exist. No schema migration or API field is needed.
- A registered XMP read failure fails extraction. It must not be interpreted as
  an empty rating, caption or tag list. Original-file extraction retains its
  existing best-effort behavior.

The transaction spans external file I/O. A slow write can therefore delay a
manual edit of that same asset; the existing ExifTool/S3 timeouts and job retry
policy apply. This is deliberate serialization, not a new background worker.
It does not provide transactional storage across PostgreSQL and a filesystem;
pending database state makes an interrupted write retryable.

## Reproduction and regression checks

`server/test/medium/specs/services/metadata-rating-race.spec.ts` uses a disposable
PostgreSQL database and synthetic files in a unique temporary directory. It
pauses an extraction after reading old media, commits rating 3 and its sidecar,
then resumes extraction and checks both database rating and actual XMP. A
separate test observes PostgreSQL lock waits while concurrent writers/manual
updates contend. Other cases cover failed writes, failed XMP reads and existing
thumbnail/preview/video file rows, including captions and tags.

`metadata-sidecar-snapshot.spec.ts` separately reproduces mixing stale values
with newer locks and verifies that the file writer consumes only its coherent
snapshot. Existing null-rating semantics remain XMP `Rating: 0` when clearing a
rating was actually requested.

The historical Web E2E failure at the space fixture's rating assertion has the
same persisted symptom as the extraction race. A matching symptom alone does
not identify the production interleaving. Keep the Web assertion at 3 and run
the complete end-to-end job on the corrected source.
