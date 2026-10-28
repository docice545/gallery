# HP read-only duplicate audit

Run once per owner on HP with a test copy of the report directory. The command
does not mutate PostgreSQL, Redis, Synology, Managed Assets, stacks or albums.
Do not upload the JSON reports to GitHub: they contain private paths and IDs.

```bash
export FOTO_PSQL_URL='postgresql://readonly-user@127.0.0.1:5432/immich'
mkdir -p /var/tmp/foto-dedup-audit
python3 scripts/external-upload-dedup/hp-readonly-audit.py \
  '<owner-uuid>' /var/tmp/foto-dedup-audit/chudo_anna.json \
  --owner-label chudo_anna
```

For every other owner, repeat with that owner's UUID and label. Review
`exactByteDuplicateGroups`, `ambiguousCases`, relation counts, and
`stackExcludedOwnerCheck` separately. A group is a review candidate even when
the bytes match; the script never chooses a survivor or removes a file.

For `chudo_anna`, verify the running backend still contains the owner in
`STACK_EXCLUDED_OWNERS` and that the previously dissolved 757 stacks remain
dissolved. Do not re-enable auto-stacking while reviewing duplicates.
