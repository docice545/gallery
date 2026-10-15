import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  analyzePath,
  collectDatabaseDiagnostics,
  describeSource,
  runDiagnostic,
} from "../livephoto_deletion_roots.mjs";

const owner = "11111111-1111-4111-8111-111111111111";
const still = "22222222-2222-4222-8222-222222222222";
const motion = "17f40000-0000-4000-8000-000000000003";
const upload = `/data/upload/${owner}`;
const encoded = `/data/encoded-video/${owner}`;
const jpg = `${upload}/94/c5/44444444-4444-4444-8444-444444444444.jpg`;
const mp4 = `${encoded}/17/f4/${motion}-MP.mp4`;
const roots = [{ path: upload }, { path: encoded }];
const policy = [roots[0]];

test("source provenance reports only a validated public Git commit", () => {
  const expected = "a".repeat(40);
  assert.deepEqual(describeSource(expected, expected), {
    present: true,
    actualCommit: expected,
    expectedMatches: true,
  });
  assert.deepEqual(describeSource("b".repeat(40), expected), {
    present: true,
    actualCommit: "b".repeat(40),
    expectedMatches: false,
  });
  for (const invalid of [
    undefined,
    "",
    "a".repeat(39),
    "a".repeat(41),
    "private-value-not-a-commit",
  ]) {
    assert.deepEqual(describeSource(invalid, expected), {
      present: false,
      actualCommit: null,
      expectedMatches: false,
    });
  }
});

test("exact supplied canonical shapes pass both path predicates with separate admitted roots", () => {
  for (const file of [jpg, mp4]) {
    const result = analyzePath(file, roots, policy);
    assert.equal(result.snapshotStage, "PATH_PREDICATES_PASS");
    assert.equal(result.canonical, true);
    assert.equal(result.quarantineComponent, false);
  }
  assert.equal(
    analyzePath(mp4, roots, policy).candidates[1].label,
    "motion-owner-root",
  );
});
test("wrong still root identifies the still failure without blaming the admitted motion", () => {
  const wrongRoots = [{ path: upload + "-other" }, roots[1]];
  assert.equal(
    analyzePath(jpg, wrongRoots).snapshotStage,
    "SNAPSHOT_ROOT_NOT_FOUND",
  );
  assert.equal(
    analyzePath(mp4, wrongRoots).snapshotStage,
    "PATH_PREDICATES_PASS",
  );
});
test("missing dynamic motion root identifies the motion failure separately from the still", () => {
  assert.equal(analyzePath(jpg, policy).snapshotStage, "PATH_PREDICATES_PASS");
  assert.equal(
    analyzePath(mp4, policy).snapshotStage,
    "SNAPSHOT_ROOT_NOT_FOUND",
  );
});
for (const [description, file, stage] of [
  [
    "noncanonical traversal staying inside root",
    `${upload}/94/../photo.jpg`,
    "OPEN_PARENT_PATH_REJECTED",
  ],
  [
    "traversal escaping root",
    `${upload}/../other/photo.jpg`,
    "SNAPSHOT_ROOT_NOT_FOUND",
  ],
  ["relative path", "data/upload/photo.jpg", "SNAPSHOT_ROOT_NOT_FOUND"],
  ["prefix sibling", `${upload}-other/photo.jpg`, "SNAPSHOT_ROOT_NOT_FOUND"],
  ["root itself", upload, "SNAPSHOT_ROOT_NOT_FOUND"],
  [
    "quarantine entry",
    `${upload}/.gallery-deletion-quarantine/private`,
    "OPEN_PARENT_PATH_REJECTED",
  ],
]) {
  test(`rejects ${description}`, () =>
    assert.equal(analyzePath(file, policy).snapshotStage, stage));
}
test("pure analysis never returns original paths, filenames or identifiers", () => {
  const report = JSON.stringify(analyzePath(mp4, roots, policy));
  for (const privateValue of [mp4, encoded, upload, owner, still, motion])
    assert.ok(!report.includes(privateValue));
});
function mockDatabase({
  readOnly = true,
  motionType = "VIDEO",
  sidecars = [],
} = {}) {
  const calls = [];
  const assets = [
    {
      id: still,
      ownerId: owner,
      libraryId: null,
      originalPath: jpg,
      livePhotoVideoId: motion,
      type: "IMAGE",
    },
    {
      id: motion,
      ownerId: owner,
      libraryId: null,
      originalPath: mp4,
      type: motionType,
    },
  ];
  const receipts = assets.map((asset) => ({
    assetId: asset.id,
    operationId: still,
    ownerId: owner,
    originalPath: asset.originalPath,
    scope: "managed",
    state: "failed",
    filesCount: 0,
    errorCode: "ORIGINAL_OUTSIDE_AUTHORIZED_ROOT",
  }));
  const tx = new Proxy(
    {},
    {
      get(_target, name) {
        assert.equal(
          name,
          "selectFrom",
          `forbidden transaction method: ${String(name)}`,
        );
        return (table) => {
          calls.push(["selectFrom", table]);
          const where = [];
          let limit;
          const query = new Proxy(
            {},
            {
              get(_object, method) {
                if (method === "select") return () => query;
                if (method === "where")
                  return (...args) => {
                    where.push(args);
                    return query;
                  };
                if (method === "limit")
                  return (value) => {
                    limit = value;
                    return query;
                  };
                assert.ok(
                  ["execute", "executeTakeFirst"].includes(method),
                  `forbidden query method: ${String(method)}`,
                );
                return async () => {
                  assert.ok(
                    Number.isInteger(limit) && limit <= 9,
                    "every query must have a bounded limit",
                  );
                  let rows;
                  if (table === "asset_deletion_tombstone")
                    rows = where.some(([column]) => column === "operationId")
                      ? receipts.map(({ assetId }) => ({ assetId }))
                      : receipts;
                  else if (table === "asset") rows = assets;
                  else if (table === "asset_deletion_policy")
                    rows = [
                      {
                        enabled: true,
                        scope: "managed",
                        authorizationMode: "storage",
                        roots: [upload],
                        rootIdentities: policy,
                      },
                    ];
                  else if (table === "asset_file") rows = sidecars;
                  else assert.fail("unexpected table");
                  return method === "executeTakeFirst" ? rows[0] : rows;
                };
              },
            },
          );
          return query;
        };
      },
    },
  );
  const transaction = {
    setAccessMode(value) {
      calls.push(["accessMode", value]);
      return this;
    },
    setIsolationLevel(value) {
      calls.push(["isolationLevel", value]);
      return this;
    },
    async execute(action) {
      return action(tx);
    },
  };
  const database = { transaction: () => transaction };
  const sql = (strings) => {
    const query = strings.join("");
    if (query.startsWith("SELECT"))
      return {
        execute: async () => ({
          rows: [{ session_ro: readOnly ? "on" : "off", transaction_ro: "on" }],
        }),
      };
    assert.equal(query, "jsonb_array_length(files)");
    return { as: () => "filesCount" };
  };
  class AssetRepository {
    constructor(actual) {
      assert.equal(actual, tx);
    }
    async deletionRootsForTarget(actual, asset, configured, ids) {
      assert.equal(actual, tx);
      assert.deepEqual(ids, [still, motion]);
      calls.push(["rootMethod", asset.type]);
      return asset.type === "VIDEO" ? [...configured, roots[1]] : configured;
    }
  }
  const StorageCore = { getFolderLocation: () => encoded };
  return {
    database,
    dependencies: {
      AssetRepository,
      StorageCore,
      StorageFolder: { EncodedVideo: "encoded-video" },
      sql,
    },
    calls,
  };
}
test("collector uses one explicit repeatable-read read-only transaction and only bounded SELECT methods", async () => {
  const f = mockDatabase();
  const report = await collectDatabaseDiagnostics(f.database, f.dependencies, [
    still,
    motion,
    owner,
  ]);
  assert.deepEqual(f.calls.slice(0, 2), [
    ["accessMode", "read only"],
    ["isolationLevel", "repeatable read"],
  ]);
  assert.equal(report.transactionReadOnly, true);
  assert.equal(report.roles.length, 2);
  assert.ok(
    report.roles.every(
      (role) => role.paths[0].snapshotStage === "PATH_PREDICATES_PASS",
    ),
  );
  assert.ok(report.roles.every((role) => role.pathMatchesReceipt));
  assert.deepEqual(
    f.calls.filter(([name]) => name === "rootMethod"),
    [
      ["rootMethod", "IMAGE"],
      ["rootMethod", "VIDEO"],
    ],
  );
  const text = JSON.stringify(report);
  for (const secret of [owner, still, motion, jpg, mp4, upload, encoded])
    assert.ok(!text.includes(secret));
});
test("old compiled repository is identified without invoking a missing helper or inventing roots", async () => {
  const f = mockDatabase();
  f.dependencies.AssetRepository = class {};
  const report = await collectDatabaseDiagnostics(f.database, f.dependencies, [
    still,
    motion,
    owner,
  ]);
  assert.equal(report.transactionReadOnly, true);
  assert.equal(report.roles.length, 2);
  for (const role of report.roles) {
    assert.equal(role.rootStage, "COMPILED_DYNAMIC_ROOTS_HELPER_MISSING");
    assert.equal(role.paths, undefined);
  }
  assert.equal(f.calls.filter(([name]) => name === "rootMethod").length, 0);
  assert.equal(
    f.calls.filter(
      ([name, table]) => name === "selectFrom" && table === "asset_file",
    ).length,
    0,
  );
});

test("collector identifies missing motion type admission without accepting the MP4 by its extension", async () => {
  const f = mockDatabase({ motionType: "OTHER" });
  const report = await collectDatabaseDiagnostics(f.database, f.dependencies, [
    still,
    motion,
    owner,
  ]);
  assert.equal(report.roles[0].paths[0].snapshotStage, "PATH_PREDICATES_PASS");
  assert.equal(
    report.roles[1].paths[0].snapshotStage,
    "SNAPSHOT_ROOT_NOT_FOUND",
  );
});
test("collector stops before asset queries when default transaction read-only cannot be confirmed", async () => {
  const f = mockDatabase({ readOnly: false });
  await assert.rejects(
    collectDatabaseDiagnostics(f.database, f.dependencies, [
      still,
      motion,
      owner,
    ]),
    {
      code: "READ_ONLY_NOT_CONFIRMED",
    },
  );
  assert.equal(f.calls.filter(([name]) => name === "selectFrom").length, 0);
});
test("collector refuses more than eight total checked media paths", async () => {
  const f = mockDatabase({
    sidecars: Array.from({ length: 8 }, () => ({ path: jpg + ".xmp" })),
  });
  await assert.rejects(
    collectDatabaseDiagnostics(f.database, f.dependencies, [
      still,
      motion,
      owner,
    ]),
    {
      code: "TOO_MANY_PATHS",
    },
  );
});
test("invalid CLI arguments fail before loading installed production modules or connecting to a database", async () => {
  await assert.rejects(runDiagnostic(["invalid"]), { code: "INPUT_INVALID" });
  const script = fileURLToPath(
    new URL("../livephoto_deletion_roots.mjs", import.meta.url),
  );
  const result = spawnSync(process.execPath, [script, "invalid"], {
    encoding: "utf8",
  });
  assert.equal(result.status, 1);
  assert.equal(result.stderr, "");
  assert.deepEqual(JSON.parse(result.stdout), {
    readOnly: true,
    error: "INPUT_INVALID",
  });
});
test("actual stdin entry fails sanitized and importing the collector from stdin causes no execution", () => {
  const url = new URL("../livephoto_deletion_roots.mjs", import.meta.url);
  const script = readFileSync(url, "utf8");
  const invalid = spawnSync(
    process.execPath,
    ["--input-type=module", "-", "--", "invalid"],
    {
      input: script,
      encoding: "utf8",
    },
  );
  assert.equal(invalid.status, 1);
  assert.equal(invalid.stderr, "");
  assert.deepEqual(JSON.parse(invalid.stdout), {
    readOnly: true,
    error: "INPUT_INVALID",
  });
  const imported = spawnSync(process.execPath, ["--input-type=module", "-"], {
    input: `import ${JSON.stringify(url.href)};`,
    encoding: "utf8",
  });
  assert.equal(imported.status, 0);
  assert.equal(imported.stdout, "");
  assert.equal(imported.stderr, "");
});
test("runtime configuration enforces read-only SQL and contains no deletion/bootstrap/file mutation entry points", () => {
  const source = readFileSync(
    new URL("../livephoto_deletion_roots.mjs", import.meta.url),
    "utf8",
  );
  assert.match(source, /default_transaction_read_only:\s*['"]on['"]/);
  assert.match(source, /statement_timeout:\s*3000/);
  assert.match(source, /lock_timeout:\s*1000/);
  assert.match(source, /debug:\s*false/);
  assert.match(
    source,
    /storage\.snapshotOriginal === utility\.snapshotOriginal/,
  );
  assert.doesNotMatch(source, /\b(?:snapshotOriginal|probeSnapshotGuard)\s*\(/);
  assert.doesNotMatch(source, /\.open\s*=/);
  assert.doesNotMatch(
    source,
    /\.(?:preparePermanentDeletion|verifyBoundPolicy|onBootstrap|snapshotOriginal|unlinkOriginal|updateTable|insertInto|deleteFrom|writeFile|mkdir|unlink|rename|chmod|chown)\(/,
  );
});
