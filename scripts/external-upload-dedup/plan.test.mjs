import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { planManifest, SCOPES } from "./plan.mjs";

const now = Date.parse("2026-10-26T18:00:00Z");
const id = (number) =>
  `00000000-0000-4000-8000-${String(number).padStart(12, "0")}`;
const scopeRelations = [
  "asset",
  "asset_file",
  "asset_exif",
  "album_asset",
  "stack",
  "asset_favorite",
  "asset_face",
  "shared_link_asset",
  "memory_asset",
  "asset_edit",
  "ocr_search",
  "redis_jobs",
  "asset_audit",
  "asset_duplicate_checksum",
  "asset_deletion_tombstone",
  "move_history",
  "workflow_log",
];
function fixture(count = 1, checkedAt = now) {
  const manifest = {
    version: 1,
    ownerId: id(1),
    allowlist: [],
    pairs: [],
    records: {},
  };
  for (let i = 0; i < count; i++) {
    const externalId = id(10 + i * 2),
      managedId = id(11 + i * 2);
    manifest.allowlist.push({ externalId, managedId });
    const asset = (assetId, external) => {
      const path = `/synthetic/${external ? "external" : "managed"}/${assetId}.jpg`;
      return {
        id: assetId,
        ownerId: manifest.ownerId,
        path,
        isExternal: external,
        libraryId: external ? id(2) : null,
        libraryOwnerId: manifest.ownerId,
        libraryReadable: true,
        libraryDeleted: false,
        status: "active",
        deleted: false,
        offline: false,
        proof: {
          path,
          kind: "regular-file",
          readable: true,
          stable: true,
          symlink: false,
          sha256: "a".repeat(64),
          size: 80,
          device: "synthetic-device",
          inode: assetId,
          mountIdentity: "synthetic-mount",
          evidenceRef: `audit:${assetId}`,
          checkedAt: new Date(checkedAt).toISOString(),
        },
      };
    };
    const relations = SCOPES.map((scope, n) => ({
      name: scopeRelations[n],
      scope,
      sourceRecordRefs: [],
      conflicts: [],
      decision: {
        action: "none",
        reviewed: true,
        reason: "Audited: no source records.",
      },
    }));
    const album = relations.find((relation) => relation.name === "album_asset");
    const ref = `album-source:${managedId}`;
    album.sourceRecordRefs = [ref];
    album.decision = {
      action: "remap",
      reviewed: true,
      targetAssetId: externalId,
      reason: "Preserve the exact source album relation.",
    };
    manifest.records[ref] = {
      relation: "album_asset",
      assetId: managedId,
      complete: true,
      row: {
        assetId: managedId,
        albumId: id(3),
        createdAt: "2026-10-25T10:00:00Z",
      },
    };
    manifest.pairs.push({
      external: asset(externalId, true),
      managed: asset(managedId, false),
      inventory: {
        complete: true,
        catalogFingerprint: "b".repeat(64),
        assetIds: [externalId, managedId],
        catalogRelations: [...scopeRelations],
        relations,
      },
    });
  }
  return manifest;
}
const run = (manifest) => planManifest(manifest, { now });
const blocked = (manifest, fragment) => {
  const plan = run(manifest);
  assert.equal(plan.status, "BLOCKED");
  const reasons = [
    ...plan.blockers,
    ...plan.pairs.flatMap((pair) => pair.blockers),
  ];
  assert(
    reasons.some((reason) => reason.includes(fragment)),
    JSON.stringify(reasons),
  );
};

test("one synthetic pair retains the real External UUID/path and full source record refs", () => {
  const manifest = fixture(),
    plan = run(manifest),
    pair = plan.pairs[0];
  assert.equal(plan.status, "REVIEW_REQUIRED");
  assert.equal(plan.authority, "OFFLINE_REVIEW_ONLY_NO_APPLY");
  assert.deepEqual(pair.survivor, {
    id: manifest.pairs[0].external.id,
    path: manifest.pairs[0].external.path,
  });
  assert.deepEqual(pair.dependencyRemaps[0].sourceRecordRefs, [
    "album-source:" + id(11),
  ]);
  assert.match(pair.stages[2], /Only then.*Managed-only.*separate approval/);
  assert(!JSON.stringify(plan).includes("DELETE FROM"));
});
test("six pairs are deterministic/idempotent and inputs including source rows stay unchanged", () => {
  const manifest = fixture(6),
    before = JSON.stringify(manifest);
  const first = run(manifest);
  assert.equal(first.pairs.length, 6);
  assert.equal(first.status, "REVIEW_REQUIRED");
  assert.deepEqual(run(manifest), first);
  assert.equal(JSON.stringify(manifest), before);
});
const cases = [
  [
    "different owner",
    (m) => {
      m.pairs[0].managed.ownerId = id(999);
    },
    "OWNER_MISMATCH",
  ],
  [
    "different bytes",
    (m) => {
      m.pairs[0].managed.proof.sha256 = "c".repeat(64);
    },
    "ORIGINAL_BYTES_DIFFER",
  ],
  [
    "different size",
    (m) => {
      m.pairs[0].managed.proof.size++;
    },
    "ORIGINAL_BYTES_DIFFER",
  ],
  [
    "missing proof",
    (m) => {
      delete m.pairs[0].external.proof;
    },
    "INVALID_FILE_EVIDENCE",
  ],
  [
    "unreadable original",
    (m) => {
      m.pairs[0].external.proof.readable = false;
    },
    "INVALID_FILE_EVIDENCE",
  ],
  [
    "unstable original",
    (m) => {
      m.pairs[0].external.proof.stable = false;
    },
    "INVALID_FILE_EVIDENCE",
  ],
  [
    "symlink",
    (m) => {
      m.pairs[0].external.proof.symlink = true;
    },
    "INVALID_FILE_EVIDENCE",
  ],
  [
    "stale proof",
    (m) => {
      m.pairs[0].external.proof.checkedAt = "2026-10-26T17:00:00Z";
    },
    "STALE_FILE_EVIDENCE",
  ],
  [
    "future proof",
    (m) => {
      m.pairs[0].external.proof.checkedAt = "2026-10-27T17:00:00Z";
    },
    "STALE_FILE_EVIDENCE",
  ],
  [
    "wrong library owner",
    (m) => {
      m.pairs[0].external.libraryOwnerId = id(999);
    },
    "INVALID_EXTERNAL_LIBRARY",
  ],
  [
    "offline external",
    (m) => {
      m.pairs[0].external.offline = true;
    },
    "ASSET_NOT_ACTIVE_AND_AVAILABLE",
  ],
  [
    "shared path",
    (m) => {
      m.pairs[0].managed.path = m.pairs[0].external.path;
    },
    "SHARED_ORIGINAL_PATH",
  ],
  [
    "same inode",
    (m) => {
      m.pairs[0].managed.proof.inode = m.pairs[0].external.proof.inode;
    },
    "SHARED_FILE_IDENTITY",
  ],
  [
    "unknown relation",
    (m) => {
      m.pairs[0].inventory.relations[0].name = "future_unknown";
    },
    "UNKNOWN_RELATION",
  ],
  [
    "unreviewed relation",
    (m) => {
      m.pairs[0].inventory.relations[0].decision.reviewed = false;
    },
    "UNREVIEWED_RELATION",
  ],
  [
    "missing scope",
    (m) => {
      m.pairs[0].inventory.relations.pop();
    },
    "MISSING_DEPENDENCY_SCOPE",
  ],
  [
    "missing catalog dependency",
    (m) => {
      m.pairs[0].inventory.catalogRelations.push("new_asset_fk");
    },
    "UNREVIEWED_CATALOG_RELATION",
  ],
  [
    "incomplete inventory",
    (m) => {
      m.pairs[0].inventory.complete = false;
    },
    "INCOMPLETE_DEPENDENCY_INVENTORY",
  ],
  [
    "missing source row",
    (m) => {
      m.records = {};
    },
    "INCOMPLETE_RECORD",
  ],
  [
    "partial source row",
    (m) => {
      Object.values(m.records)[0].complete = false;
    },
    "INCOMPLETE_RECORD",
  ],
  [
    "wrong remap target",
    (m) => {
      m.pairs[0].inventory.relations[3].decision.targetAssetId = id(999);
    },
    "INVALID_REMAP",
  ],
  [
    "unlisted pair",
    (m) => {
      m.allowlist[0].managedId = id(999);
    },
    "ALLOWLIST_AUDIT_MISMATCH",
  ],
  [
    "reused UUID",
    (m) => {
      m.allowlist[0].managedId = m.allowlist[0].externalId;
    },
    "INVALID_OR_REUSED_ALLOWLIST_ID",
  ],
];
for (const [name, mutate, reason] of cases)
  test(`blocks ${name}`, () => {
    const manifest = fixture();
    mutate(manifest);
    blocked(manifest, reason);
  });
for (const scope of ["metadata", "stacks", "faces", "edits"])
  test(`blocks ambiguous ${scope} decisions`, () => {
    const manifest = fixture();
    manifest.pairs[0].inventory.relations.find(
      (relation) => relation.scope === scope,
    ).conflicts = ["Manual conflict"];
    blocked(manifest, "CONFLICT");
  });
test("missing/malformed structural evidence produces BLOCKED rather than a plan", () => {
  for (const input of [null, {}, [], { ...fixture(), records: null }])
    assert.equal(run(input).status, "BLOCKED");
  const manifest = fixture();
  manifest.pairs[0].inventory.assetIds = 42;
  blocked(manifest, "INCOMPLETE_DEPENDENCY_INVENTORY");
});
test("CLI reads JSON stdin, never applies, and rejects an apply flag", () => {
  const cli = fileURLToPath(new URL("./plan.mjs", import.meta.url));
  const input = fixture(1, Date.now());
  const result = spawnSync(process.execPath, [cli, "-"], {
    input: JSON.stringify(input),
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(JSON.parse(result.stdout).status, "REVIEW_REQUIRED");
  const refused = spawnSync(process.execPath, [cli, "--apply"], {
    encoding: "utf8",
  });
  assert.equal(refused.status, 1);
  assert.match(refused.stderr, /no apply mode/);
});
