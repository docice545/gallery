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
SHM extent checks. Empty WAL in WAL mode does **not** authorize exact promotion.
The historical audit compares retained SHM change counters, page size/count,
frame checksum and salt transition to a fully validated old WAL snapshot, then
reconstructs all primary page bytes, including freelists and non-table pages.
Even a complete match is only historical evidence: SQLite's WAL-index is
[transient](https://www.sqlite.org/walformat.html), not a durable last-commit
journal. It cannot establish that no later committed WAL was lost. Build 22/23
do not supply a durable terminal-write witness. Such matches report
`checkpoint_history_not_terminal` and stay blocked, as do canonical rebuilt SHM,
missing witnesses, truncation, mismatches and scan-limit exhaustion. Previous
attempts are read, never overwritten.

A real-file regression models the persistence image after lost later WAL:
perform a real checkpoint, retain its primary/SHM bytes, then commit a new upload
and a deletion acknowledgement into a new WAL. If that later WAL is lost and SHM
retains its older persisted image, the files still match the old full snapshot.
The initial Build 24 checkpoint inference accepted this image; the corrected
version refuses it. This is a simulated persistence image using actual SQLite
commits, not a hardware power-cut test. A checkpoint performed on our candidate
under the held recovery barrier remains valid; no external historical inference
is needed to apply a candidate recovered from the source's complete WAL.

Diagnosis runs on expendable copies even when WAL proof is absent. Report format
24 distinguishes `not_run`, `passed`, `failed`; unavailable integrity results are
null. Reports expose reason codes, hashes, number of tables and proof fields,
not rows, tokens or account data. ZIP SQLite files themselves are private.

Main awaits the background-worker lock before domain bootstrap. Native leases
exclude a second pool, worker, content-provider read or process while blocked.
Every original/copy is checked again before promotion. Only a healthy candidate
with a drained/absent WAL can enter the existing fsync + atomic selector commit.
SIGKILL before/after selection cannot implicitly choose an older generation.

The generic bootstrap-error screen no longer offers its legacy destructive
SQLite reset. This matters when a later, unrelated bootstrap step fails after
recovery. The file-deletion helper also refuses the primary database before
resolving or touching any path; recreating the separate diagnostic log remains
supported. A real WAL-only pending-upload regression fails on pinned Build 23
(its helper deletes the files) and verifies unchanged primary/WAL/SHM hashes
with the Build 24 guard. The error-screen widget has no delete action.

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
account/queues, both indistinguishable canonical-SHM histories, real checkpoints,
stale retained SHM after lost later commits,
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
thumbnail. A separate fresh emulator exercises exact recovery with a complete
source WAL and the candidate's verified checkpoint.
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

The real API 36 emulator also exposed a pre-existing admission error unrelated to
SQLite: `CloudAdmissionService` rejected `device_config help` before inspecting or
writing any settings. AOSP Android 16's
[`DeviceConfigService.onCommand`](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android16-release/packages/SettingsProvider/src/com/android/providers/settings/DeviceConfigService.java)
prints valid help and returns -1 (process exit 255). The command validator now
accepts that result only for the exact read-only help invocation, with its
expected header, all three reversible-override verbs and empty stderr. Failed
get/list/write commands remain rejected; ownership, readback and undo checks are
unchanged. Policy regressions cover the exception's boundaries, and emulator
receipts capture the real shell exit/stdout/stderr without changing settings.
This admission failure is not evidence of a new SQLite corruption on Samsung.

After that fix, the real Shizuku test reached successful enable/admission and
exposed a reply-order race: `CloudMediaPlugin` posted its result before releasing
the busy flag in the worker's `finally`. The Dart caller could receive that result
and start its next awaited operation while the old flag was still set. Replies
are now constructed first, then posted only after service cleanup and flag
release. The emulator checks consecutive status replies plus immediate repeated
enable on both activation and restart; it does not conceal `busy` errors by retry.

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
Only an engine's root isolate registers that inbound channel. Ordinary sync
worker isolates also call Bootstrap but use BackgroundIsolateBinaryMessenger,
which cannot install inbound handlers. They retain their normal pool access
without replacing or unregistering the root bridge. Android acceptance explicitly
boots and closes a real production worker and verifies that the foreground reader
remains admitted before checking gallery sync and the system picker.

The audit also reproduced a pool shutdown race with real queued read/write
transactions. `sqlite_async` 0.14.2 `close()` closes its response port without
draining already queued requests; those requests can retain native leases and
never receive their completion. Drift's adapter does not drain them either.
After closing Drift/bridge admission, `Drift.close()` now obtains exclusive access
to all readers and the writer **before** closing sqlite_async and the update-pool
reference. Only after releasing that exclusive lease can the native recovery
lease be released. A real-file regression holds a reader and a write transaction,
queues additional queries, starts shutdown, then verifies both committed rows,
last-connection WAL/SHM closure and successful integrity-check on reopen.
The same test fails on the pinned original Build 23: `close()` has already
completed while the test still holds its transaction. That proves the shutdown
race, not that it caused the reported Samsung corruption.

A second real-file regression exposed a healthy-restart false positive: after
PASSIVE/automatic checkpoint and WAL reuse, SQLite normally retains retired
frames at the end of the file. The strict existing validator refuses that tail.
Build 24 keeps this validator unchanged and configures only the already-admitted
writer with `journal_size_limit=0`. SQLite then truncates checkpointed retired
frames when it safely reuses the WAL; this is not a limit on live transactions,
a forced checkpoint, or any operation on the blocked original. Repeated passive
and automatic cycles, an unclean-stop file image, and a concurrent pinned reader
retain all rows and pass startup validation. Unknown legacy recycled tails remain
blocked and unchanged; they are not retrospectively certified as safe.

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
On the synthetic restart fixture a favorite change also changes the collection,
forcing actual provider reads instead of relying on Photo Picker's previous cache.
Before the consented new-library flow, repeated native status requests against
the damaged Build 23 generation must retain its persisted block, expose no
reader, leave every original checksum unchanged and keep the same selection.
