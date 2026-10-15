#!/usr/bin/env node
// Read-only input diagnosis. This script never prepares deletion or opens media files.
import crypto from "node:crypto";
import fs from "node:fs";
import { createRequire } from "node:module";
import { isAbsolute, relative, resolve, sep } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export function describeSource(source, expectedSource) {
  // Public Git provenance only; never return arbitrary environment contents.
  const actualCommit = /^[0-9a-f]{40}$/.test(source ?? "") ? source : null;
  return {
    present: actualCommit !== null,
    actualCommit,
    expectedMatches: actualCommit !== null && actualCommit === expectedSource,
  };
}

export function analyzePath(file, roots, policyRoots = roots) {
  const below = (root) => {
    const part = relative(root, file);
    return (
      part !== "" &&
      part !== ".." &&
      !part.startsWith(".." + sep) &&
      !isAbsolute(part)
    );
  };
  const candidates = roots.map((root, index) => ({
    label: policyRoots.some((entry) => entry.path === root.path)
      ? `policy-${index + 1}`
      : "motion-owner-root",
    below: below(root.path),
  }));
  const index = candidates.findIndex((candidate) => candidate.below);
  const canonical = isAbsolute(file) && resolve(file) === file;
  const quarantineComponent =
    index !== -1 &&
    relative(roots[index].path, file)
      .split(sep)
      .includes(".gallery-deletion-quarantine");
  return {
    canonical,
    candidates,
    quarantineComponent,
    snapshotStage:
      index === -1
        ? "SNAPSHOT_ROOT_NOT_FOUND"
        : !canonical || quarantineComponent
          ? "OPEN_PARENT_PATH_REJECTED"
          : "PATH_PREDICATES_PASS",
  };
}
const codes = new Set(
  `ORIGINAL_OUTSIDE_AUTHORIZED_ROOT MOTION_ORIGINAL_OUTSIDE_MANAGED_ROOT
MOTION_SCOPE_MISMATCH ORIGINAL_SHARED_WITH_OTHER_ASSET DELETION_ROOT_CHANGED UNSUPPORTED_DELETION_FILESYSTEM
UNSUPPORTED_DELETION_SCOPE ENOENT EACCES EPERM ENOTDIR ELOOP ESTALE EIO ETIMEDOUT ECONNREFUSED 57014
42P01 42703 42501 READ_ONLY_NOT_CONFIRMED INPUT_INVALID TOO_MANY_PATHS OPERATION_NOT_FOUND POLICY_NOT_FOUND`.split(
    /\s+/,
  ),
);
const safeCode = (error) =>
  codes.has(error?.code) ? error.code : "DIAGNOSTIC_STAGE_FAILED";
const fail = (code) => {
  throw Object.assign(new Error(code), { code });
};
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Injectable only for isolated tests; production uses the installed compiled classes.
export async function collectDatabaseDiagnostics(
  database,
  { AssetRepository, StorageCore, StorageFolder, sql },
  [stillId, motionId, ownerId],
) {
  const result = { roles: [] };
  await database
    .transaction()
    .setAccessMode("read only")
    .setIsolationLevel("repeatable read")
    .execute(async (tx) => {
      const session =
        await sql`SELECT current_setting('default_transaction_read_only') AS session_ro, current_setting('transaction_read_only') AS transaction_ro`.execute(
          tx,
        );
      if (
        session.rows[0]?.session_ro !== "on" ||
        session.rows[0]?.transaction_ro !== "on"
      )
        fail("READ_ONLY_NOT_CONFIRMED");
      result.transactionReadOnly = true;
      const receipts = await tx
        .selectFrom("asset_deletion_tombstone")
        .select([
          "assetId",
          "operationId",
          "ownerId",
          "scope",
          "state",
          "errorCode",
          "originalPath",
        ])
        .select(sql`jsonb_array_length(files)`.as("filesCount"))
        .where("assetId", "in", [stillId, motionId])
        .limit(2)
        .execute();
      if (receipts.length !== 2) fail("OPERATION_NOT_FOUND");
      const operationId = receipts.find(
        (row) => row.assetId === stillId,
      )?.operationId;
      result.operation = {
        same: receipts.every((row) => row.operationId === operationId),
        parentIsStill: operationId === stillId,
        ownerMatches: receipts.every((row) => row.ownerId === ownerId),
      };
      const operation = await tx
        .selectFrom("asset_deletion_tombstone")
        .select("assetId")
        .where("operationId", "=", operationId)
        .limit(9)
        .execute();
      if (operation.length > 8) fail("TOO_MANY_PATHS");
      const assets = await tx
        .selectFrom("asset")
        .select([
          "id",
          "type",
          "ownerId",
          "libraryId",
          "originalPath",
          "livePhotoVideoId",
          "status",
        ])
        .where("id", "in", [stillId, motionId])
        .limit(2)
        .execute();
      const still = assets.find((asset) => asset.id === stillId);
      const motion = assets.find((asset) => asset.id === motionId);
      result.relationship = {
        stillPresent: !!still,
        motionPresent: !!motion,
        linked: !!still && still.livePhotoVideoId === motionId,
        ownerMatches:
          assets.length === 2 &&
          assets.every((asset) => asset.ownerId === ownerId),
        libraryMatches:
          assets.length === 2 && still.libraryId === motion.libraryId,
      };
      const repo = new AssetRepository(tx);
      let pathCount = 0;
      for (const [role, id] of [
        ["still", stillId],
        ["motion", motionId],
      ]) {
        const asset = assets.find((entry) => entry.id === id);
        const receipt = receipts.find((entry) => entry.assetId === id);
        const item = {
          role,
          present: !!asset,
          state: [
            "preparing",
            "pending",
            "failed",
            "complete",
            "files-removed",
          ].includes(receipt.state)
            ? receipt.state
            : "UNKNOWN",
          filesCount: receipt.filesCount,
          receiptError:
            receipt.errorCode == null
              ? null
              : safeCode({ code: receipt.errorCode }),
        };
        result.roles.push(item);
        if (!asset) continue;
        item.type = ["IMAGE", "VIDEO", "AUDIO", "OTHER"].includes(asset.type)
          ? asset.type
          : "UNKNOWN";
        item.ownerMatches = asset.ownerId === ownerId;
        item.pathMatchesReceipt = asset.originalPath === receipt.originalPath;
        const policy = await tx
          .selectFrom("asset_deletion_policy")
          .select([
            "enabled",
            "scope",
            "authorizationMode",
            "roots",
            "rootIdentities",
          ])
          .where("ownerId", "=", ownerId)
          .where("scope", "=", receipt.scope)
          .limit(1)
          .executeTakeFirst();
        if (!policy) {
          item.rootStage = "POLICY_NOT_FOUND";
          continue;
        }
        item.policy = {
          enabled: policy.enabled,
          scope: policy.scope === "managed" ? "managed" : "external",
          mode: ["storage", "recovery"].includes(policy.authorizationMode)
            ? policy.authorizationMode
            : "OTHER",
          rootCount: policy.roots.length,
          pathsMatchIdentities:
            policy.roots.length === policy.rootIdentities.length &&
            policy.roots.every((root) =>
              policy.rootIdentities.some((identity) => identity.path === root),
            ),
        };
        if (typeof repo.deletionRootsForTarget !== "function") {
          item.rootStage = "COMPILED_DYNAMIC_ROOTS_HELPER_MISSING";
          continue;
        }
        let roots;
        try {
          roots = await repo.deletionRootsForTarget(
            tx,
            asset,
            policy.rootIdentities,
            operation.map((row) => row.assetId),
          );
          item.rootStage = "ROOTS_COMPUTED";
        } catch (error) {
          item.rootStage = safeCode(error);
          continue;
        }
        const sidecars = await tx
          .selectFrom("asset_file")
          .select("path")
          .where("assetId", "=", id)
          .where("type", "=", "sidecar")
          .limit(8)
          .execute();
        const paths = [
          asset.originalPath,
          ...sidecars.map((entry) => entry.path),
        ];
        pathCount += paths.length;
        if (pathCount > 8) fail("TOO_MANY_PATHS");
        item.paths = [];
        for (const [index, file] of paths.entries())
          item.paths.push({
            kind: index ? "sidecar" : "original",
            ...analyzePath(file, roots, policy.rootIdentities),
            belowComputedEncodedRoot: analyzePath(file, [
              {
                path: StorageCore.getFolderLocation(
                  StorageFolder.EncodedVideo,
                  ownerId,
                ),
              },
            ]).candidates[0].below,
          });
      }
    });
  return result;
}
export async function runDiagnostic(args) {
  if (
    args.length !== 4 ||
    args[0] === args[1] ||
    !args.slice(0, 3).every((id) => uuid.test(id)) ||
    !/^[0-9a-f]{40}$/.test(args[3])
  )
    fail("INPUT_INVALID");
  const [stillId, motionId, ownerId, expectedSource] = args;
  const prefix = "/usr/src/app/server/";
  const require = createRequire(prefix + "package.json");
  const load = (name) =>
    import(pathToFileURL(prefix + "dist/" + name + ".js").href);
  const result = {
    readOnly: true,
    filesystemWrites: false,
    mediaOpened: false,
    stage: "MODULES",
    modules: {},
    roles: [],
  };
  let database;
  try {
    const [
      { ConfigRepository },
      { AssetRepository },
      { StorageCore },
      { StorageService },
      { StorageFolder },
      utility,
      { AssetService },
      { StorageRepository },
    ] = await Promise.all([
      load("repositories/config.repository"),
      load("repositories/asset.repository"),
      load("cores/storage.core"),
      load("services/storage.service"),
      load("enum"),
      load("utils/authorized-deletion"),
      load("services/asset.service"),
      load("repositories/storage.repository"),
    ]);
    for (const module of [
      "repositories/asset.repository",
      "utils/authorized-deletion",
      "cores/storage.core",
      "services/asset.service",
      "services/storage.service",
      "repositories/storage.repository",
    ]) {
      const bytes = fs.readFileSync(prefix + "dist/" + module + ".js");
      const text = bytes.toString("utf8");
      result.modules[module] = {
        sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
      };
      if (module === "repositories/asset.repository")
        result.modules[module].dynamicRootsPresent = text.includes(
          "deletionRootsForTarget",
        );
      if (module === "services/asset.service")
        result.modules[module].rootsForwardingPresent =
          /snapshotOriginal\(path,\s*roots\)/.test(text);
    }
    const storage = new StorageRepository({ setContext() {} });
    result.snapshotBindingMatchesUtility =
      storage.snapshotOriginal === utility.snapshotOriginal;
    result.methods = Object.fromEntries(
      [
        [
          "deletionRootsForTarget",
          AssetRepository.prototype.deletionRootsForTarget,
        ],
        ["snapshotOriginal", utility.snapshotOriginal],
        ["getFolderLocation", StorageCore.getFolderLocation],
        [
          "preparePermanentDeletion",
          AssetRepository.prototype.preparePermanentDeletion,
        ],
        ["permanentlyDelete", AssetService.prototype.permanentlyDelete],
        ["handleAssetDeletion", AssetService.prototype.handleAssetDeletion],
      ].map(([name, method]) => [
        name,
        typeof method === "function"
          ? {
              sha256: crypto
                .createHash("sha256")
                .update(method.toString())
                .digest("hex"),
              ...(name === "preparePermanentDeletion"
                ? {
                    usesDynamicRoots: /this\.deletionRootsForTarget\(/.test(
                      method.toString(),
                    ),
                  }
                : {}),
              ...(["permanentlyDelete", "handleAssetDeletion"].includes(name)
                ? {
                    forwardsSnapshotRoots:
                      /snapshotOriginal\(path,\s*roots\)/.test(
                        method.toString(),
                      ),
                  }
                : {}),
            }
          : { present: false },
      ]),
    );
    result.source = describeSource(
      process.env.IMMICH_SOURCE_COMMIT,
      expectedSource,
    );
    const configRepository = new ConfigRepository();
    const config = configRepository.getEnv();
    // These methods only read configuration and directory existence. Never bootstrap a service.
    const media = StorageService.prototype.detectMediaLocation.call({
      configRepository,
      storageRepository: { existsSync: fs.existsSync },
    });
    StorageCore.setMediaLocation(media);
    result.media = {
      canonical: isAbsolute(media) && resolve(media) === media,
      dataRoot: media === "/data",
      legacyRoot: media === "/usr/src/app/upload",
    };
    const postgres = require("postgres");
    const { Kysely, sql } = require("kysely");
    const { PostgresJSDialect } = require("kysely-postgres-js");
    const options = {
      max: 1,
      connect_timeout: 5,
      idle_timeout: 2,
      prepare: false,
      onnotice: () => {},
      debug: false,
      connection: {
        default_transaction_read_only: "on",
        statement_timeout: 3000,
        lock_timeout: 1000,
        idle_in_transaction_session_timeout: 15000,
        application_name: "gallery-livephoto-roots-readonly",
      },
    };
    const db = config.database.config;
    const client =
      db.connectionType === "url"
        ? postgres(db.url, options)
        : postgres({
            ...options,
            host: db.host,
            port: db.port,
            username: db.username,
            password: db.password,
            database: db.database,
            ssl: db.ssl,
          });
    database = new Kysely({
      dialect: new PostgresJSDialect({ postgres: client }),
      log: [],
    });
    result.stage = "DATABASE";
    Object.assign(
      result,
      await collectDatabaseDiagnostics(
        database,
        {
          AssetRepository,
          StorageCore,
          StorageFolder,
          sql,
        },
        [stillId, motionId, ownerId],
      ),
    );
    result.stage = "COMPLETE";
  } catch (error) {
    result.error = safeCode(error);
  } finally {
    await database?.destroy().catch(() => {});
  }
  return result;
}
// stdin execution (`node --input-type=module - -- ...`) is the intended HP entry.
if (
  (process.argv[1] === "-" &&
    fileURLToPath(import.meta.url) === resolve("[eval1]")) ||
  (process.argv[1] &&
    import.meta.url === pathToFileURL(resolve(process.argv[1])).href)
) {
  const watchdog = setTimeout(() => {
    console.log(
      JSON.stringify({ readOnly: true, error: "DIAGNOSTIC_TIMEOUT" }),
    );
    process.exit(124);
  }, 25_000);
  watchdog.unref();
  try {
    const args = process.argv
      .slice(2)
      .filter((arg, index) => !(index === 0 && arg === "--"));
    const result = await runDiagnostic(args);
    console.log(JSON.stringify(result, null, 2));
    process.exitCode = result.error ? 1 : 0;
  } catch (error) {
    console.log(JSON.stringify({ readOnly: true, error: safeCode(error) }));
    process.exitCode = 1;
  } finally {
    clearTimeout(watchdog);
  }
}
