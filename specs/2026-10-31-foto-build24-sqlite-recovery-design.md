# FOTO Build 24: ambiguous empty WAL and explicit server restart

Base: Build 23 `a769b7d5982c90fbc6cd68c2a2aa5f4ebd33df25`. Android version
`5.7.3+24`; production package and release signing identity are unchanged.
No server code, migrations or deployment changes belong to this release.

## What the Samsung report proves

Build 23 rejected `missing_or_unprovable_wal` before inspecting tables. Its
`tablesChecked:0`, `diagnosticStatus:null`, `integrityOk:false` do not establish
that a full integrity check failed. The known index error is independently real.

The reported empty WAL digest and SHM digest
`fd4c9fda9cd3f9ae7c962b0ddf37232294d55580e1aa165aa06129b8549389eb`
are reproduced with real SQLite in two different histories: a completed
checkpoint followed by read-only reopening, and loss of an uncheckpointed WAL
followed by the same reopening. The canonical SHM has no retained last-commit
identity. An earlier matching snapshot does not prove that later commits were
not lost. The actual history of the Samsung cannot be determined from its JSON
report. We must not call this state a proven checkpoint.

Build 22 pool shutdown/checkpoint and Build 23's ordinary read-only startup probe
are plausible contributors. In particular, the latter rebuilds the SHM and can
erase checkpoint evidence. Build 24 uses `immutable=1,mode=ro` for the empty-WAL
startup probe under the existing exclusive native admission lease. This preserves
evidence; it does not turn missing evidence into proof.

## Independent exact-repair path

The Build 23 capture, WAL validation, candidate REINDEX, full integrity/FK checks,
all-table content and schema/rowid fingerprints, durable generation selector and
rollback originals remain. `diagnoseAndRepairSqliteSnapshot.promotionAllowed`
remains false. Only explicit one-tap coordination may select a validated candidate.

Nonempty WAL must pass the existing complete manifest, frame checksum, commit and
SHM extent checks. For empty WAL in WAL mode, exact repair requires a coherent
CURRENT retained checkpoint SHM plus a fully validated historical WAL snapshot.
Last change counter, page size/count, frame checksum and salt transition must
match; reconstructing the old primary plus committed WAL must produce exactly the
current primary page-image SHA-256. This includes non-table pages. Canonical
rebuilt SHM, missing witnesses, truncation, mismatches and scan-limit exhaustion
are safe refusals. Previous attempts are read, never overwritten.

Diagnosis runs on expendable copies even when WAL proof is absent. Report format
24 distinguishes `not_run`, `passed`, `failed`; unavailable integrity results are
null. Reports expose reason codes, hashes, number of tables and proof fields,
not rows, tokens or account data. ZIP SQLite files themselves are private.

Main awaits the background-worker lock before domain bootstrap. Native leases
exclude a second pool, worker, content-provider read or process while blocked.
Every original/copy is checked again before promotion. Only a healthy candidate
with a drained/absent WAL can enter the existing fsync + atomic selector commit.
SIGKILL before/after selection cannot implicitly choose an older generation.

## Safe server viewing without local bootstrap

A separate HTTP client can display already uploaded server photographs without
opening the normal app SQLite pools or starting sync. Credentials are read from a
verified durable snapshot and another expendable reading copy; the owner must
match `/users/me`. Only GET requests are implemented; redirects are refused,
images stay in bounded memory. Failure to validate credentials leaves recovery
and external export available. No user database is sent to a server.

## Explicitly consented new local library

The user's later instruction authorizes loss of local caches and unfinished
operations AFTER a verified external backup and explicit warning/consent. This
is a separate operation, never labelled exact recovery or an automatic fallback.

1. Attempt to verify the original owner/session by GET `/users/me`. Never guess
   an older account. If verification fails, offer ordinary login in the new app.
2. SAF `ACTION_CREATE_DOCUMENT`, local-only ZIP includes original SQLite, WAL,
   SHM, rollback journal if present, all Build 22/23/24 attempts and reports.
   Close the output, fsync its descriptor, reopen and SHA-256 the ENTIRE ZIP.
   Missing fsync/readback support, cancellation, read/write errors or changed
   source refuse the operation. The chosen document is never silently uploaded.
3. Native code grants a transient capability tied to the exact current source
   checksums and ZIP checksum. Process death invalidates it: export and consent
   must be repeated. The warning checkbox starts unchecked.
4. Only after consent, begin exclusive recovery; cancel/check old downloader
   tasks. Build a new generation with production Drift migrations. Transfer only
   server-verified user/session/endpoint; never transfer old upload/delete/Trash
   journals, cursors, selections or other settings. Originals and ZIP survive.
5. Validate schema, all new tables, integrity/FKs and fingerprints again before
   native capability-bound atomic selection. A `fresh-start-report.json` explicitly
   records `localStateTransferred:false`, consent and the external ZIP checksum.
6. Execute normal FOTO bootstrap/router. Reusing a token also reuses SERVER-side
   download cursors. Before the first stream, existing `DELETE /sync/ack` with
   **omitted `types`** resets only that session's metadata download cursors. An
   empty types list would reset nothing. Durable local progress makes interruption
   before/after the reset retryable. Normal sync then downloads current photos,
   albums and account metadata and acknowledges only these new events. No old
   deletion or upload intent is replayed; no asset mutation endpoint is invoked.
   Bootstrap explicitly binds the retained token to the native HTTP cookie jar
   before any ordinary API/sync work. A fresh database has no old application
   migration version, so the historical cookie migration would otherwise be
   skipped. This also covers a background launch after interrupted promotion.
7. Automatic backup, album backup and phone-file management start disabled. After
   the library stream and post-processing finish, a durable ready flag permits a
   separate library-review confirmation in the existing backup toggle. The user
   chooses backup albums normally; none are preselected. Safety flags are read
   directly from SQLite, avoiding stale asynchronous Store watcher snapshots.

This yields the ordinary working FOTO app. Unsynchronized local changes are
retained in backups but intentionally absent from the new active generation.
Imported old queued operations must never be replayed onto this new generation.

## Validation boundaries

Real-file tests cover the exact index diagnostic, WAL-only rows, production
account/queues, both indistinguishable canonical-SHM histories, proven checkpoints,
corrupt data pages/WAL, interrupted copy/REINDEX/promotion and process SIGKILL.
New-library tests cover verified identity/login fallback, consent, disk full,
changed candidate, interruptions/retry, empty queues and disabled backup.
A real loopback HTTP server plus production SQLite/sync pipeline proves the
cursor reset downloads existing photographs/albums and repeats without duplicates.
Widget tests cover Russian recovery, one tap, technical reasons, export/consent,
server viewing and the separate backup review.

Native tests cover ZIP content, full readback mismatch, source change, restart
capability invalidation and durable selector/admission failures. Android CI uses
actual pinned Build 23 production code, updates it without uninstall to Build 24
on Android 16, exercises real SAF twice, then normal FOTO startup and a server
thumbnail. A separate fresh emulator exercises proven checkpoint exact recovery.
Only a successful run at the delivered SHA is release evidence.

The cloud does not hold the HP signing key or a physical Samsung/database. CI's
unsigned release verifies compilation/version/plugin registration; it is not a
signed Samsung update. Hardware-specific storage/power loss and real-account
installation remain owner-side checks after signing on HP. Canonical SHM cannot
promise lossless exact recovery; verified ZIP + informed new-library consent is
the supported path when completeness remains unknowable.

The extended local whole-app test run also includes unrelated timeline video
widgets. Three assertions fail in `timeline_video_viewer_test.dart` and
`timeline_preview_video_viewer_test.dart`; the same three failures reproduce in
an isolated checkout of the original Build 23 SHA. Those player/Live Photo files
are unchanged here. The release CI's recovery/bootstrap/sync/UI regression suite
is the scoped gate; the entire pre-existing app suite must not be described as
all green. `networking_settings_test.dart` also stalls in the expanded run; a
separate bounded run reproduces that stall on the pinned Build 23 baseline.

## Shizuku / system Photo Picker acceptance (Build 24 P0 extension)

The new Samsung report does not include a post-Shizuku database or native error
receipt. We cannot retrospectively distinguish a newly corrupt file from the
persisted Build 23 admission block. Activating Shizuku is not evidence of a new
SQLite failure: its shell service only manages the explicitly journaled
DeviceConfig admission keys, never database paths, media or credentials.

The audit did find two concrete reader defects/risks. CloudMediaCatalog required
`user_version == 38`, while the pinned Build 23 Drift schema is already **39**.
That condition reports no signed-in catalog; it does not itself call `halt()`.
It also repeatedly opened the active database using Android's system SQLite
library, separately from Flutter's bundled SQLite and pool. Separate SQLite
libraries in one process do not share their internal POSIX lock bookkeeping;
opening/closing those file descriptors and WAL/SHM handles is an avoidable risk.
This is not a claim that we proved that mechanism caused the Samsung corruption.

The provider now borrows a read transaction from the already admitted Flutter
pool. The native bridge never opens SQLite or WAL/SHM, creates a pool, copies a
live file, changes a generation or checkpoints. It accepts only single SELECT/
WITH statements which SQLite confirms are read-only; PRAGMA/ATTACH/writes/trailing
statements are refused. Query responses are bounded to 201 rows / 4 MiB. The
collection digest streams rows in one read snapshot in the existing pool's
worker, not a full in-memory mirror. Album pagination remains bounded too.
Schema readiness uses the actual Drift schema version, not another native
hard-coded number. Native read leases still honor RecoveryStore admission.
Closing an engine first unregisters the bridge and drains pending read callbacks
before closing the owning sqlite_async pool and its admission lease.

No Shizuku connection is involved in media reads. Existing opt-in, owner scope,
projection visibility and original/preview HTTP behavior remain. A cold system
provider without a validated Flutter pool reports unavailable and never opens a
second SQLite connection. Bootstrap/bridge readiness wakes the existing change
observer; normal app restart must complete its health probe first.

Admission now distinguishes `persisted_recovery_block`, a new `recovery_blocked`,
`startup_probe_pending` and `ready`. A durable enumerated cause and SQLite code
survive restart. Temporary reader timeout/cancellation/engine unavailability is
reported separately and does not manufacture corruption or clear an old block.
Real unsafe SQLite failures halt admission; `native-reader-report.json` and the
retained cause file are included in the normal diagnostic ZIP. Reports contain
no SQL text, paths, rows or credentials. Both the recovery screen and Cloud Media
settings expose the reason; the Russian screen explicitly explains that an old
block alone does not mean newly damaged data.

Real pool tests cover concurrent writer/reader snapshots, WAL-only changes,
the owning pool's WAL checkpoint with an attached native client, read draining,
result limits, attempted native write/checkpoint rejection and retained
corruption gates. Native tests cover repeated native admissions, transient errors
without generation changes and durable block causes across process recreation.
Android acceptance additionally installs a SHA-256-pinned Shizuku 13.6.0 on the
synthetic API 36 emulator (shell UID 2000), operates its real permission dialog,
selects FOTO through actual Photo Picker settings, requires actual provider query
and returned-row counters, then force-stops/restarts FOTO and Shizuku and repeats.
It asserts the same recovered generation, original Build 23 checksums, account,
disabled automatic backup and a successful next startup health probe. Screenshots
and anonymized native counters are CI receipts, not physical Samsung validation.
Before the consented new-library flow, repeated native status requests against
the damaged Build 23 generation must retain its persisted block, expose no
reader, leave every original checksum unchanged and keep the same selection.
