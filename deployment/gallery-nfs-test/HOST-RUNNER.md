# Host-side runner access

The current launcher is `/usr/local/bin/codex-gallery-auto`. Its
`ProtectSystem=strict` sandbox makes mounts read-only unless they are listed in
`ReadWritePaths`. The repository contains the minimal patch
`scripts/codex-gallery-auto-nfs.patch`: it adds write access only to
`/mnt/gallery-nfs-test` and `/mnt/hp-data/gallery-nfs-test`. `NoNewPrivileges`
and the existing production/archive exclusions remain enabled; no privileged
Docker or production path is added.

An HP owner applies the patch once with this idempotent command:

```sh
sudo sh -c 'if ! grep -Fq "NFS_TEST_ROOT=/mnt/gallery-nfs-test" /usr/local/bin/codex-gallery-auto; then patch -d / -p1 --forward --batch < /mnt/hp-data/codex-work/gallery/deployment/gallery-nfs-test/scripts/codex-gallery-auto-nfs.patch; fi'
```

The owner must then relaunch the auto runner so the new systemd mount
namespace is created. Verify in the new session before running the harness:

```sh
findmnt --mountpoint /mnt/gallery-nfs-test --noheadings --output SOURCE,FSTYPE,OPTIONS
```

The source must be exactly
`10.10.10.95:/volume1/Gallery-Test`, the filesystem `nfs`/`nfs4`, and the
per-mount options must not contain `ro`. Do not remount from inside the
executor, edit `/etc/fstab`, change NAS export rules, or expose family mounts.
