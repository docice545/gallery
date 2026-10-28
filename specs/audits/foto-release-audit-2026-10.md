# FOTO release audit (2026-10-28)

This is a continuation of the FOTO audit. No production operation, HP change, APK installation,
release publication, or new APK build was performed.

## Cloud versus HP boundaries

The new Cloud runtime can reach GitHub and now exposes the historical refs. The earlier runtime's
proxy/Docker failures were Cloud-only observations; they were not changed through production or HP
infrastructure. Cloud can run repository/unit/static checks once dependencies and SDKs are available.

HP/device checks remain separate: production PostgreSQL/geodata, the `immich-gallery-inpainting-1`
container, backend-to-ML traffic, decoded video frames, Samsung playback, iOS playback, and production
API behaviour require the HP host or physical devices. They remain BLOCKED here and were not run.

## Historical audit

The remote refs were verified with Git:

- `origin/codex/foto-android-places-editor` → `96c8be0d9bb428202e35c4256ed912e6265bcf60`;
- `origin/pr-11` contains `e2a95e6aeee9d9da8d23ca7643a6a061c61944c3`;
- `735f01e401251f35b304b8e1e3e7fde561656723` is the Web Live Photo pool;
- `f49e63f1e022247e058800340fe67b5d4523cd22` is the Android timeline autoplay fix;
- `4a65a24767c27d7bd69210690884800bae8a65e1` and its follow-up commits contain Places, clustering,
  localized map labels, session-scoped place names, and map lifecycle fixes;
- `7dd47c463f996d210d53b817aa95d16e757af729` adds the private inpainting service and API;
- `ec7424a33f864f6ff44b2d61861cdaad6cf16d6d` through `bdd58a7a00ffcf22db9fa88ad0c1555f3f1a1fc4`
  restore the layered editor, history, compact controls, Magic Eraser, and save-as-copy flow.

Those changes were cherry-picked into the current checkout as local commits. The resulting local SHAs
include `abd2c5569` (Web), `2b0375091` (Android Live Photo), `a23eb5805`/`6978a8a8f` (Places and
localized map), `3e7f93a19` (inpainting backend), and `a904b13d3` (four-tool editor integration).

## Implemented functionality

### Web Live Photo

`web/src/lib/utils/live-photo-autoplay.ts` provides one shared playback lease. It selects one settled,
sufficiently visible candidate, uses geometry and stable identity rather than DOM order, stops during
scroll/navigation/tab hiding, releases the old decoder before granting another lease, and uses a one-shot
Live Photo video (`loop=false`). `Thumbnail.svelte` keeps fullscreen/manual playback independent and
does not filter candidates by remote origin. Existing unit, component, and Playwright tests cover the
single-active invariant, center/visibility selection, scroll settling, route/viewer transitions,
errors, completion without cascading, and manual playback.

### Android/iOS Live Photo

`TimelineLivePhotoScope` and `LivePhotoAutoplayController` restore bounded Android timeline playback,
with lifecycle, selection, scroll, player release, and local video resolution. The historical code
excluded `AssetState.remote`; that conflict was found in `chooseLivePhotoCandidate` and
`_prepareLocalSource`. It is now fixed: a remote/merged `RemoteAsset` with a paired
`livePhotoVideoId` can be selected, and `NativeVideoViewer` creates one authenticated
`/assets/{motionId}/video/playback` source for the focused remote candidate. Local candidates still
require a verified local file. Existing tests were updated to assert remote playback and merged remote
fallback. Real frame decoding on Samsung/iOS remains BLOCKED.

iOS retains native `PHLivePhoto` mapping, paired download/save code, and backend-compatible remote
asset handling from the restored branch. No original Noodle Gallery app was modified.

### Places and Russian names

The restored Android branch includes MapLibre source clustering, camera fitting to actual GPS assets,
compact bottom-sheet layout, color style preservation, place identity scoping, localized map label
expressions, and session-scoped place names with fallback. The prior accidental Hawaii/default-location
path is replaced by asset-bound fitting. Russian and foreign place data still require HP geodata and
device verification; the Cloud checkout alone cannot prove rendered labels for production data.

### Editor and Magic Eraser

The restored editor exposes crop, markup, text, and Magic Eraser in the primary compact UI, with undo/
redo, preview/cancel, save-as-copy, and non-destructive original handling. The backend API is under
`server/src/controllers/magic-eraser.controller.ts` and the Android client uses
`mobile/lib/repositories/magic_eraser.repository.dart`; the service is implemented under `inpainting/`.
The API explicitly distinguishes unsupported backend, unavailable photo, authorization, and service
failures. The actual HP container and object removal are not proven from Cloud.

### Offline gallery and original-client compatibility

The historical offline slice is now present: configurable Library cards and a Live Photos collection,
reactive album previews, Android opt-in Cloud Media Provider/Shizuku admission with reversible state,
account-scoped collection generation and cancellation handling, and iOS background Live Photo transfer
draining/pair validation. These changes are additive to the existing sync/cache contracts; the original
Noodle Gallery apps were not modified. Android/iOS device, Photo Picker, Shizuku, and offline/online
recovery scenarios remain BLOCKED in Cloud.

## Reproducible HP/device checks

Run only on HP, with a test account and without changing production state:

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
docker inspect immich-gallery-inpainting-1 --format '{{.State.Status}} {{.Config.Image}}'
curl -fsS http://127.0.0.1:2283/api/server/ping
curl -fsS -H "x-api-key: $FOTO_API_KEY" http://127.0.0.1:2283/api/map/markers
curl -fsS -H "x-api-key: $FOTO_API_KEY" 'http://127.0.0.1:2283/api/map/reverse-geocode?lat=55.7558&lon=37.6173'
```

Required scenarios: two local and two remote Live Photos while scrolling on Samsung; browser Web
scroll/tab-hide/navigation and manual fullscreen playback; iOS remote-only pair download/playback;
Places with Moscow, a foreign location, duplicate coordinates, and no-GPS assets; Magic Eraser mask,
preview, cancel, 401/403/404/503 handling, save-as-copy, and original hash comparison.

## Release matrix

| Area | Status | Evidence / blocker |
|---|---|---|
| Web single active Live Photo, stable selection, no loop | IMPLEMENTED / UNIT TESTED | `web/src/lib/utils/live-photo-autoplay*.spec.ts`, `VideoThumbnail.spec.ts` |
| Web browser playback and manual fullscreen | NOT TESTED IN THIS RUNTIME | Playwright requires installed dependencies and browser; HP/real browser still separate |
| Web remote Live Photo candidate | IMPLEMENTED / TESTED BY CONTRACT | No remote-origin filter; real authenticated media remains environment-dependent |
| Android local Live Photo autoplay | IMPLEMENTED / TESTS PRESENT, EXECUTION BLOCKED | `live_photo_autoplay_test.dart`, `live_photo_scope_test.dart`; Flutter/device decoding unavailable |
| Android remote Live Photo autoplay | IMPLEMENTED / TESTS PRESENT, EXECUTION BLOCKED | Updated candidate/source path; Flutter and Samsung E2E unavailable |
| iOS Live Photo/backend compatibility | NOT TESTED | Physical iOS + HP required |
| Places camera fit and clustering | IMPLEMENTED / TESTS PRESENT, EXECUTION BLOCKED | Restored map/place tests; Flutter/rendered device/geodata check unavailable |
| Russian geographic names | IMPLEMENTED BY RESTORED DESIGN / DEVICE CHECK BLOCKED | Localized expression/session fallback code present; HP geodata required |
| Four-tool editor and save-as-copy | IMPLEMENTED / TESTS PRESENT, EXECUTION BLOCKED | Restored editor acceptance/layout/history tests; Flutter/Samsung/iOS UI unavailable |
| Magic Eraser API and copy save | IMPLEMENTED / SERVER+INPAINTING TESTED | 57 server tests and 55 Python tests passed; mobile/real `immich-gallery-inpainting-1` unavailable |
| Offline Library/Cloud Media and iOS transfer | IMPLEMENTED BY RESTORED COMMITS | Cloud Media/Library tests present; Android/iOS offline device checks BLOCKED |
| Offline gallery/API regressions | NOT TESTED | Flutter/Docker/HP/device checks unavailable here |
| Overall RELEASE READY | NOT RELEASE READY | Mandatory HP, Samsung, iOS, browser and production-data evidence is missing |
