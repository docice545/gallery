# Build 37 mobile baseline provenance

Build 37 starts at `bc97d7f1397489b50a1600abc5a85e17386b5cf1`, with its own
Android/iOS UX specification. Build 36 release starts separately at
`26223d2285ef181006e87e0654ca9df4e4d82cd5`. No branch merge is needed or performed.

The common ancestor is `03d8ee5aa7cbe318736556b380249487beed8b8e`. Build 37 contains
the independent HP Web checkpoint `ad7a8e77a3662756a8bb72574ceb98343ad7b706`, but
its mobile and locale trees were byte-identical to that common ancestor. It
therefore lacked the subsequently verified mobile safeguards, rather than already
containing a second implementation of them.

Before adding new UI, these eight existing commits were inspected for provenance,
file scope and order. Every source commit is an ancestor of the verified Build 36
release branch. Their application touches only mobile code/tests and ten required
locale files; no Backend, Web, SDK, migration, dependency or signing change is
included. The resulting mobile/locale trees match Build 36's verified starting
source exactly. The HP Web implementation remains untouched.

| Original commit | Purpose and dependency |
| --- | --- |
| `6b5a5850d628901ca32844b6c4b5358963e608ca` | Retain active stack frames during optimistic trash; depends on original 03d8 Viewer |
| `72188ac315b67485b9992f59444c2aa502ee5f4b` | Correct final-frame/standalone details; follows retained-page fix |
| `acd159a10232464c02140da4c5cad7aa1cc3149c` | Active AutoRoute branch on cold start; no native-player changes |
| `9fee33bf6bbeafb07bd37d7b3b0efdad0c0578d7` | Verified device-only selected cleanup and cancellation/selection guards |
| `32e81072312cc737ad4aeeb2f1e0cefecd5c355f` | Test the existing remote-pair playback contract, without runtime changes |
| `93521a1a5f8105157f5f3835922aa5804a9d64f6` | Reactive album list/cover queries; existing Future APIs retained |
| `46a9e2830fbe2c505b99b286fb8ab15411909b6f` | Recently Added capture order, endpoint-only stable tie-break |
| `31a6e9a9eabe82fac0061de54611c91eb09d4485` | Whole-album device-photo cleanup; depends on selected cleanup and its localized result |

These are prerequisites for new gesture, animation, empty-album and editing
regressions, not a claim that Build 37 UX already exists. Existing 220 ms stack
navigation, ID ownership boundaries, original-preserving editor copies and
verified MediaStore acknowledgements must remain in place.

## Platform decision: device album removal

On 2026-11-03 the owner explicitly selected **FOTO-only hiding on Android**, with
clear disclosure that files and other galleries are unchanged. Android albums are
filesystem-derived MediaStore buckets and the pinned plugin has no independent
non-destructive collection-delete API. Do not implement that gesture by deleting
or moving its photos, or by calling the repository's sync-cache `deleteAlbum()`.
Provide a discoverable way to show the hidden album again. Hiding concerns the
device-album list, not removal of the original files or backup selections.

iOS can remove an editable PhotoKit album collection while preserving assets and
other memberships. Its OS confirmation/error handling and metadata-only cache
reconciliation remain separate from Android hiding and from the explicit
"delete all photos from this device" action. Neither branch operation implies
server asset deletion.

## Validation boundary

Backport verification uses the same bounded 25 Flutter files covering the original
mobile fixes, then new Build 37 stages add actual gesture/animation/platform tests.
Cloud widget/fixture results never establish physical Samsung/iPhone behavior,
production signing continuity, SideStore installation or production readiness.
Build 36 Docker/APK/IPA readiness and Build 37 UX acceptance stay independent.
