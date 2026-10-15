# Gallery Build 11 — Recovery

Continue existing work. Do not restart from scratch.

Repo: /mnt/hp-data/codex-work/gallery
Branch: fix/gallery-final-p1-cli
HEAD: dcc78926f

Goals:
- Google Photos-style trash, restore, permanent deletion.
- Safe managed NAS and writable external library deletion.
- iOS/Android device-side deletion.
- Live Photos timeline playback.
- Server, web, mobile, integration tests.
- Release and rollback documentation.

Preserve all commits, modified files and untracked files.
Audit the existing implementation before making changes.

Previous results (must recheck):
- Server deletion/recovery tests passed.
- Python release tests: 21 run, 4 skipped.
- Web build/import errors were under investigation.
- Controller tests and rootless Docker were blocked by the old Codex sandbox.

Use only synthetic test data and rootless Docker.
Never access production Docker or real NAS photos.
Never restart or deploy production services.
Never alter existing Immich jobs or queues.

Finish all Build 11 requirements autonomously.
Report actual test results and remaining issues.
No production deployment.
