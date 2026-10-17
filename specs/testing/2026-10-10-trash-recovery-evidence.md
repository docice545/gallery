# Signed Trash recovery evidence

`scripts/release/trash_recovery_evidence.py` turns an existing successful isolated
PostgreSQL restore receipt and actual recovered media samples into an Ed25519
envelope. It reads local files, hashes bytes, signs, and writes a new private file.
It does not call Docker, create a backup, perform a restore/export, access an API,
change a policy, enable deletion, or deploy anything. All automated examples and
tests use synthetic data; no production recovery or deployment was run here.

For Synology, use the normal [capture/export/prepare/publish procedure](../../docs/SYNOLOGY-RECOVERY-EVIDENCE.md)
instead of manually constructing the per-root inputs below. The updated NAS
diagnostic records actual sample export times and owner/scope-bound root exports;
`trash_recovery_inputs.py` verifies those source records and writes the compatible
provenance files. Old share-level reports without these records remain useful
historical evidence, but cannot be upgraded by assigning current timestamps.
The schemas below also remain available for other genuine backup/export tools.

## Trust and consent

Recovery evidence belongs to the operator trusted by the server's locally
installed Ed25519 public key. An administrator supplying a hexadecimal digest
alone cannot authorize deletion: the server must load the matching immutable
local envelope, verify the signature, and bind its contents to the owner, scope,
and current effective root identities.

The generator checks actual backup bytes and original/recovered sample bytes.
It also checks provenance bindings and timestamps. A signature does not
authenticate the NAS snapshot system or establish that every file is recoverable.
A dishonest trusted operator could fabricate a restore receipt, snapshot report,
or sample-kind claim and sign it. The trust boundary therefore includes the
operator, the existing isolated restore procedure, and the snapshot/export tool
that captures provenance. Byte comparisons establish recovery of the supplied
samples; snapshot scope remains an explicit operator attestation. Preserve the
private source reports for operator review.

Preparing or renewing proof clears any previous deletion consent. Evidence
installation itself grants no consent. The owner consent endpoint validates and
locks the current preparation; the administrator policy endpoint cannot enable
managed or external consent. External scopes use the exact library UUID and a
separate owner consent endpoint; see
[the external workflow](../../docs/EXTERNAL-LIBRARY-DELETION.md).
Signatures, owner/scope, root identities, freshness,
and consent remain enforced during deletion. Expired or changed evidence blocks
each protected unlink, including after a worker has been stopped and restarted.

## Private inputs

Use absolute paths without symlinks. JSON inputs, the SQL/gzip backup, and the
private PEM signing key must be regular files with exactly mode `0600`. The
operator output directory must already exist with mode `0700`. The generator
walks parent directories with descriptor-relative `O_NOFOLLOW` as well as checking
the leaf; a symlinked parent is rejected. It never prints private filenames,
snapshot references, media contents, PEM contents, or subprocess errors.

The root manifest has exactly these top-level fields:

```json
{
  "hostRoots": { "/data/photos": "/srv/synthetic-storage/photos" },
  "roots": [
    {
      "device": "2049",
      "inode": "12345",
      "mountId": "31",
      "mountNamespace": "mnt:[4026533000]",
      "mountRoot": "/synthetic-storage/photos",
      "mountSource": "/dev/synthetic-device",
      "mountTarget": "/data/photos",
      "mountType": "ext4",
      "path": "/data/photos"
    }
  ],
  "version": 1
}
```

Those identities are illustrative. Capture real root identities **inside the
same running application container's mount namespace**, using the existing
read-only collector. Host mount IDs or invented namespace values cannot stand in
for container identities. Capture the complete effective root set for the target
owner/scope, including managed storage and derivatives when applicable. Obtain
the host mapping from the corresponding real Docker mounts; for a nested root,
append its path relative to the mount target to the host mount source.

This read-only example emits a protected manifest; replace both paths with the
effective container root and its actual host counterpart. It requires a running
container containing the compiled collector, and neither starts a container nor
inherits a remote Docker context:

```bash
umask 077
set -o noclobber
docker --host=unix:///var/run/docker.sock exec -i immich_server \
  node --input-type=module > /private/operator/roots.json <<'NODE'
import {collectRootIdentities} from '/usr/src/app/server/dist/utils/authorized-deletion.js';
const roots = await collectRootIdentities(['/data/photos']);
process.stdout.write(JSON.stringify({version: 1, roots,
  hostRoots: {'/data/photos': '/srv/synthetic-storage/photos'}}));
NODE
```

Do not overwrite an existing evidence manifest with this example. The protected
directory and unused output filename must be prepared first. Root order is
irrelevant: the generator sorts identities by `path`. Duplicate paths, incomplete
identities, and host mappings with missing or extra roots are rejected. This
manifest is limited to 1–128 canonical, non-root absolute paths, and identity
strings, owner IDs and scope strings are limited to 4096 UTF-16 code units to match
the server. This manifest is an operator capture; the generator cannot independently establish
that its supplied identities came from the container. The server compares signed
identities with its own current collector before authorizing deletion.

Supply an existing `backup-verified.json` produced by
`trash_release.py`'s `restore_check`, along with the exact backup that was restored.
The generator does not invoke that procedure or refresh its `checkedAt`. It
requires `PASS_ISOLATED_SQL_TRANSACTION`, `productionChanged: false`, positive
asset/migration counts, the immutable PostgreSQL image ID, and the matching
absolute backup path and SHA-256. It hashes the entire receipt file as supplied.
Renaming another assertion to the expected filename does not establish trustworthy
restore provenance; that is part of the operator trust boundary above.

Use the existing NAS proof structure, augmented with a mandatory private
provenance file per root:

```json
{
  "mounts": {
    "/data/photos": {
      "operator_attests_snapshot_export": true,
      "samples": [
        { "kind": "photo", "original": "/srv/synthetic-storage/photos/photo.sample", "recovered": "/srv/synthetic-recovery/photos/photo.sample" },
        { "kind": "video", "original": "/srv/synthetic-storage/photos/video.sample", "recovered": "/srv/synthetic-recovery/photos/video.sample" }
      ],
      "snapshot_provenance": "/private/operator/photo-export-operation.json",
      "snapshot_reference": "synthetic-snapshot-reference"
    }
  }
}
```

Every supplied root requires 2–128 samples including both photo and video, including for scope
`managed` (lowercase). Proof root coverage must equal manifest root coverage exactly.
Prepared NAS inputs additionally contain an `authorization` object binding
`ownerId`, `scope`, the exact root-manifest SHA-256 and a private completion receipt.
The generator requires that receipt to match the exact prepared proof bytes,
owner/scope and manifest, and to record `consentGranted:false`. Missing receipts
from interrupted preparation or different command-line owner/scope fail before
signing. These fields belong only to the local input contract, not the signed
server payload. Existing genuine per-root input producers without this optional
adapter metadata retain the original generator contract and operator trust boundary.
Empty or photo-only roots cannot satisfy this v1 evidence contract just by
declaring a missing sample. Such preparation must remain blocked until an operator
performs a separately approved recovery exercise using representative disposable
photo/video canaries in that exact root and its real backup/snapshot. The canaries
must actually be exported/restored; a present-day copy or invented provenance is
insufficient. No canary or snapshot is created by this generator or this task.
The administrator policy endpoint can prepare an explicitly selected verified
subset of existing managed roots with `enabled:false`; omitted roots receive no
deletion rights, and the owner must still consent.
Original
files must be under the matching `hostRoots` entry. Recovered files must be under
the provenance export directory and outside **all** deletion host roots. The
export directory cannot contain or be inside any deletion host root. Each pair
must have different `(device, inode)` identities; a same-device copy is allowed,
but a hardlink, symlink, or reference to the original is rejected. SHA-256 and
positive byte lengths must match. The generator reads both copies and checks that
their metadata remains stable throughout each hash operation.

Each `snapshot_provenance` file has exactly the following fields. Its `root` is
the complete corresponding identity object from the manifest, shown as a compact
object below solely for readability:

```json
{
  "exportDirectory": "/srv/synthetic-recovery/photos",
  "exportedAt": "2026-10-10T10:00:00Z",
  "hostRoot": "/srv/synthetic-storage/photos",
  "metadataSource": "SNAPSHOT_EXPORT_OPERATION",
  "operationId": "synthetic-export-operation-id",
  "root": {
    "device": "2049",
    "inode": "12345",
    "mountId": "31",
    "mountNamespace": "mnt:[4026533000]",
    "mountRoot": "/synthetic-storage/photos",
    "mountSource": "/dev/synthetic-device",
    "mountTarget": "/data/photos",
    "mountType": "ext4",
    "path": "/data/photos"
  },
  "samples": [
    { "kind": "photo", "original": "/srv/synthetic-storage/photos/photo.sample", "recovered": "/srv/synthetic-recovery/photos/photo.sample" },
    { "kind": "video", "original": "/srv/synthetic-storage/photos/video.sample", "recovered": "/srv/synthetic-recovery/photos/video.sample" }
  ],
  "snapshotCreatedAt": "2026-10-09T10:00:00Z",
  "snapshotId": "synthetic-snapshot-id",
  "snapshotReference": "synthetic-snapshot-reference",
  "version": 1
}
```

Capture this report from the actual snapshot/export operation when it completes,
using its observed snapshot ID/reference, creation timestamp, operation ID,
export directory, and original/restored sample paths. Preserve the snapshot tool's
underlying report. Do not reconstruct an operation report merely from a current
filesystem copy. `metadataSource` is a fixed format marker, not an independently
authenticated NAS assertion. Both the provenance root identity and snapshot
reference must match the manifest/proof; sample sets must match regardless of
order. The complete provenance file bytes are hashed into the signed payload.
The generator never substitutes the current time for the export timestamp.

UTC timestamps accept seconds and up to six fractional digits, with `Z` or
`+00:00`. The snapshot creation timestamp must be at or before export completion;
future creation/export/restore timestamps are rejected. Snapshot creation itself
may be older than 24 hours. Restore `checkedAt` and export `exportedAt` must be
within the preceding 24 hours. An otherwise fresh input expiring exactly at the
generation time cannot produce usable evidence. Evidence with less than a
millisecond of remaining lifetime is also rejected when its expiry and issuance
would parse as the same JavaScript millisecond.

## Generate and install the evidence

Python 3.11+ and Node.js with `node:crypto` Ed25519 support are the only runtime
requirements; no new Python dependency is needed. Keep an operator-owned Ed25519
PKCS#8 PEM key separate from authentication keys. The private signing key must
never be mounted into the server. The generator reads it only after the backup,
receipt, roots, provenance, media bytes, and output directory checks pass.

After those private inputs already exist, an operator invocation is:

```bash
python3 scripts/release/trash_recovery_evidence.py \
  --owner-id synthetic-owner \
  --scope managed \
  --roots /private/operator/roots.json \
  --backup /private/operator/backup.sql.gz \
  --postgres-receipt /private/operator/backup-verified.json \
  --nas-proof /private/operator/nas-proof.json \
  --signing-key /private/operator/recovery-signing.pem \
  --output-dir /private/operator/signed-evidence \
  --valid-for-hours 24
```

For an external library, `--scope` is the exact library UUID. Stdout contains only
`{"version":1,"evidenceSHA256":"…","bytes":1234}`. Failure messages use fixed
codes and leave signing/output unperformed when source validation fails.

The output filename is `<SHA256-of-entire-envelope-bytes>.json`, created at `0600`
without overwriting any existing file. The envelope has exactly:

```text
{version:1, algorithm:"Ed25519", payload:base64, signature:base64}
```

The payload is UTF-8 compact JSON with sorted keys. The signature is exactly the
64-byte Ed25519 signature over those decoded payload bytes. The envelope is also
compact JSON with sorted keys, without a trailing newline; its SHA-256 includes
its exact base64 fields and serialization.

The decoded payload fields are `version`, `ownerId`, `scope`, `roots`, `verifiedAt`,
`expiresAt`, `postgres`, and `mounts`. `postgres` contains `backupSHA256`,
`receiptSHA256`, `checkedAt`, `restore`, `productionChanged`, `assetCount`,
`migrationCount`, and `postgresImage`. Each mount contains
`snapshotReferenceSHA256`, `snapshotProvenanceSHA256`, `verifiedAt`, and a
`samples` array of `{kind, sha256, size}`. Sample sizes and counts use positive
JavaScript-safe integers. Private host media paths, snapshot IDs and references,
and signing keys are omitted from the signed payload; effective container root
identities remain present because the server must compare them.

Payload `verifiedAt` is verification completion/issuance time. The generator
checks the real current time again after hashing the backup and all samples; a
restore or export that expired during those reads is rejected before the signing
key is touched. Mount `verifiedAt` retains the actual
provenance `exportedAt`. `expiresAt` is the earliest of issuance plus the requested
1–24 hours, restore `checkedAt` plus 24 hours, and every export `exportedAt` plus
24 hours. Reissuing an envelope cannot extend the validity of old recovery proof.

The private writable signing output directory is separate from the server trust
store. Install **copies** of approved digest-named envelopes as single-link
regular files with mode `0444` in a directory with mode `0555`. Install the
corresponding SPKI PEM Ed25519 public key as mode `0444`, outside server-writable
asset storage. Use a read-only container bind mount for the complete trust store;
the server's `W_OK` checks must fail for the store directory and
evidence/public-key files. Without an actual read-only filesystem, each protected
file and directory must belong to a UID different from the application UID.
Application-owned files/directories are rejected even at `0444`/`0555`, because
the application could chmod them. The verifier also checks ancestors for writable
or application-owned directories until it reaches an actual read-only mount or
the protected filesystem root. No checked directory may be group/world writable.

When the application UID is root, use an actual read-only mount verified by the
opened descriptor's mount ID and `/proc/self/mountinfo` read-only flags, or by a
write-access check returning `EROFS`. A mode-permission `EACCES` result alone does
not establish a read-only mount. Root-owned chmod-only protection cannot satisfy
this contract. Mode bits are retained in addition to mount protection; they do
not replace it.

Server configuration:

| Variable                               | Default                                     |
| -------------------------------------- | ------------------------------------------- |
| `GALLERY_DELETION_RECOVERY_DIR`        | `/run/gallery-deletion-recovery/evidence`   |
| `GALLERY_DELETION_RECOVERY_PUBLIC_KEY` | `/run/gallery-deletion-recovery/public.pem` |

Use canonical, symlink-free paths. Never use hardlinks when installing files,
never replace a digest filename's bytes, and never give the application user
write access. Keep the signing key in the private operator environment. Installing
the public key/store or mounting them into an existing deployment requires the
deployment's normal authorization; this document does not run or authorize a
production deployment.

## Synthetic validation

```bash
python3 -m unittest discover -s scripts/release/tests -p test_trash_recovery_evidence.py -v
```

The tests sign and independently verify real Ed25519 signatures using synthetic
keys, SQL/gzip bytes, identities, provenance and photo/video bytes. They cover
managed and external scope, exact whole-file digest, payload signature tampering,
freshness/expiry, backup mismatch, invalid restore markers/counts, missing roots,
wrong provenance identity/reference/operation, source/export membership,
symlinks, hardlinked recovery, differing/empty media, private permissions,
immutable output names, and sanitized CLI output. No test contacts a production
server, creates a restore container, modifies a policy, or invokes deployment.

The server verifier's synthetic trust-store tests use a narrowly scoped
`fs.access` simulation returning `EROFS` for the temporary fixture store. The
Ed25519 signatures and file bytes are real. That simulation tests policy checks;
it does not establish that any production filesystem is mounted read-only.
