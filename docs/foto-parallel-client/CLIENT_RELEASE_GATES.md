# FOTO parallel client release gates

| Gate | Status | Evidence / blocker |
|---|---|---|
| Published base and independent branch | PASS | final RC `4bd351510bba8750f0f54d8777523d6603a44fdd` |
| Build 21 provenance compared | PASS | Build 21 `57b79cf3a7f11960ead971ca8963d666cc6baa91` is a different line; final RC carries the missing client commits |
| Offline catalogue / persistent previews | NOT TESTED | focused source tests pending; Samsung cold-start required |
| Wi-Fi/cellular prefetch consent | SOURCE PRESENT | widget tests/device path pending |
| Android local/remote Live Photo | SOURCE PRESENT | unit tests/device decoded frames pending |
| Web one-active Live Photo | SOURCE PRESENT | real Chromium media run not available |
| Places and Russian names | SOURCE PRESENT | native tiles/geodata/device blocked |
| Four-tool editor and Magic Eraser | SOURCE PRESENT | APK route/Samsung/iOS/HP inference blocked |
| Unmodified Noodle Gallery Android compatibility | NOT TESTED | requires fixed upstream APK and HP/test account |
| Unmodified Noodle Gallery iOS compatibility | NOT TESTED | requires iOS device and HP/test account |
| Backend/DB/NAS/migrations | NOT TESTED | HP/disposable staging unavailable; no production changes authorized |
| Release readiness | NOT RELEASE READY | hardware, upstream-client and HP gates remain open |
