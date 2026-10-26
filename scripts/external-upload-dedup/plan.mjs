#!/usr/bin/env node
// Offline planner only: no DB/network/media access and no executable mutation commands.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const SCOPES = Object.freeze([
  "ownership",
  "files",
  "metadata",
  "albums",
  "stacks",
  "favorites",
  "faces",
  "sharing",
  "memories",
  "edits",
  "search",
  "jobs",
  "sync",
  "checksums",
  "deletion",
  "moves",
  "workflows",
]);
export const RELATIONS = Object.freeze([
  "asset",
  "library",
  "library_user",
  "asset_file",
  "asset_exif",
  "asset_metadata",
  "asset_audio",
  "asset_video",
  "asset_keyframe",
  "video_stream",
  "album",
  "album_asset",
  "album_space_asset",
  "activity",
  "stack",
  "stack_suppression",
  "asset_favorite",
  "asset_face",
  "person",
  "person_group",
  "face_identity",
  "face_identity_face",
  "face_person_verdict",
  "face_repair_decline",
  "face_repair_scan",
  "face_repair_scan_flagged_face",
  "face_search",
  "pet_search",
  "shared_space_person",
  "shared_space_person_face",
  "shared_space_face_match_backfill_target",
  "shared_link_asset",
  "shared_space_asset",
  "shared_space",
  "shared_space_album",
  "shared_space_album_asset",
  "shared_space_library",
  "shared_space_member",
  "partner",
  "memory_asset",
  "memory_candidate",
  "asset_edit",
  "asset_ocr",
  "ocr_search",
  "smart_search",
  "asset_job_status",
  "redis_jobs",
  "asset_audit",
  "asset_face_audit",
  "asset_file_audit",
  "asset_metadata_audit",
  "asset_favorite_audit",
  "album_asset_audit",
  "library_asset_audit",
  "stack_audit",
  "sync_checkpoint",
  "asset_duplicate_checksum",
  "asset_deletion_tombstone",
  "asset_deletion_policy",
  "move_history",
  "storage_migration_log",
  "workflow_log",
]);
const supported = new Set(RELATIONS);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const digest = /^[0-9a-f]{64}$/;
const object = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const canonical = (value) =>
  JSON.stringify(value, (_, item) =>
    object(item)
      ? Object.fromEntries(
          Object.keys(item)
            .sort()
            .map((key) => [key, item[key]]),
        )
      : item,
  );
const hash = (value) =>
  createHash("sha256").update(canonical(value)).digest("hex");
const maxProofAge = 15 * 60 * 1000;

export function planManifest(manifest, { now = Date.now() } = {}) {
  const errors = [];
  const reject = (code) => errors.push(code);
  if (!object(manifest) || manifest.version !== 1)
    reject("INVALID_MANIFEST_VERSION");
  if (!uuid.test(manifest?.ownerId ?? "")) reject("INVALID_OWNER");
  if (!Array.isArray(manifest?.allowlist) || manifest.allowlist.length === 0)
    reject("EMPTY_ALLOWLIST");
  if (!Array.isArray(manifest?.pairs)) reject("MISSING_PAIR_AUDITS");
  if (!object(manifest?.records)) reject("MISSING_FULL_SOURCE_RECORDS");
  if (errors.length) return { status: "BLOCKED", blockers: errors, pairs: [] };
  const allowlist = manifest.allowlist;
  const pairKey = (pair) => `${pair?.externalId}/${pair?.managedId}`;
  const allowedKeys = allowlist.map(pairKey);
  const allIds = allowlist.flatMap((pair) => [
    pair?.externalId,
    pair?.managedId,
  ]);
  if (
    allIds.some((id) => !uuid.test(id ?? "")) ||
    new Set(allIds).size !== allIds.length
  ) {
    reject("INVALID_OR_REUSED_ALLOWLIST_ID");
  }
  const auditKeys = manifest.pairs.map((pair) =>
    pairKey({
      externalId: pair?.external?.id,
      managedId: pair?.managed?.id,
    }),
  );
  if (canonical([...allowedKeys].sort()) !== canonical([...auditKeys].sort()))
    reject("ALLOWLIST_AUDIT_MISMATCH");
  const plans = manifest.pairs
    .map((pair) => {
      const blockers = [];
      const fail = (code) => blockers.push(code);
      if (!object(pair))
        return { status: "BLOCKED", blockers: ["INVALID_PAIR"] };
      const { external, managed, inventory } = pair;
      const ids = [external?.id, managed?.id];
      for (const [kind, asset] of [
        ["external", external],
        ["managed", managed],
      ]) {
        if (!object(asset) || asset.ownerId !== manifest.ownerId)
          fail(`${kind}:OWNER_MISMATCH`);
        if (typeof asset?.path !== "string" || !isAbsolute(asset.path))
          fail(`${kind}:INVALID_PATH`);
        const proof = asset?.proof;
        if (
          !object(proof) ||
          proof.path !== asset?.path ||
          proof.kind !== "regular-file" ||
          proof.readable !== true ||
          proof.stable !== true ||
          proof.symlink !== false ||
          !digest.test(proof.sha256 ?? "") ||
          !Number.isSafeInteger(proof.size) ||
          proof.size <= 0 ||
          !["device", "inode", "mountIdentity", "evidenceRef"].every(
            (key) => typeof proof[key] === "string" && proof[key].length > 0,
          )
        )
          fail(`${kind}:INVALID_FILE_EVIDENCE`);
        const checkedAt = Date.parse(proof?.checkedAt);
        if (
          !Number.isFinite(checkedAt) ||
          checkedAt > now ||
          now - checkedAt > maxProofAge
        ) {
          fail(`${kind}:STALE_FILE_EVIDENCE`);
        }
      }
      if (
        external?.isExternal !== true ||
        !uuid.test(external?.libraryId ?? "") ||
        external?.libraryOwnerId !== manifest.ownerId ||
        external?.libraryReadable !== true ||
        external?.libraryDeleted !== false
      )
        fail("INVALID_EXTERNAL_LIBRARY");
      if (managed?.isExternal !== false || managed?.libraryId !== null)
        fail("INVALID_MANAGED_ASSET");
      if (
        [external, managed].some(
          (asset) =>
            asset?.status !== "active" ||
            asset?.deleted !== false ||
            asset?.offline !== false,
        )
      )
        fail("ASSET_NOT_ACTIVE_AND_AVAILABLE");
      if (external?.path === managed?.path) fail("SHARED_ORIGINAL_PATH");
      if (
        external?.proof?.sha256 !== managed?.proof?.sha256 ||
        external?.proof?.size !== managed?.proof?.size
      )
        fail("ORIGINAL_BYTES_DIFFER");
      if (
        external?.proof?.device === managed?.proof?.device &&
        external?.proof?.inode === managed?.proof?.inode
      )
        fail("SHARED_FILE_IDENTITY");
      const scopedIds = Array.isArray(inventory?.assetIds)
        ? inventory.assetIds
        : [];
      const catalogNames = Array.isArray(inventory?.catalogRelations)
        ? inventory.catalogRelations
        : [];
      if (
        !object(inventory) ||
        inventory.complete !== true ||
        !digest.test(inventory?.catalogFingerprint ?? "") ||
        canonical([...scopedIds].sort()) !== canonical([...ids].sort()) ||
        !Array.isArray(inventory?.relations) ||
        !Array.isArray(inventory?.catalogRelations)
      ) {
        fail("INCOMPLETE_DEPENDENCY_INVENTORY");
      }
      const relations = Array.isArray(inventory?.relations)
        ? inventory.relations
        : [];
      if (
        SCOPES.some(
          (scope) => !relations.some((relation) => relation?.scope === scope),
        )
      ) {
        fail("MISSING_DEPENDENCY_SCOPE");
      }
      const relationNames = relations.map((relation) => relation?.name);
      if (
        new Set(relationNames).size !== relationNames.length ||
        catalogNames.some((name) => !relationNames.includes(name))
      ) {
        fail("UNREVIEWED_CATALOG_RELATION");
      }
      const remaps = [];
      for (const relation of relations) {
        const name = relation?.name;
        if (!supported.has(name) || !SCOPES.includes(relation?.scope))
          fail(`UNKNOWN_RELATION:${name}`);
        const decision = relation?.decision;
        const refs = relation?.sourceRecordRefs;
        if (
          !Array.isArray(refs) ||
          !object(decision) ||
          decision.reviewed !== true ||
          !["none", "remap", "deduplicate", "preserve-unmodified"].includes(
            decision.action,
          ) ||
          typeof decision.reason !== "string" ||
          !decision.reason.trim()
        )
          fail(`UNREVIEWED_RELATION:${name}`);
        if (
          !Array.isArray(relation?.conflicts) ||
          relation.conflicts.length > 0
        )
          fail(`CONFLICT:${name}`);
        if (
          refs?.length &&
          (decision?.action === "none" ||
            decision?.targetAssetId !== external?.id)
        ) {
          fail(`INVALID_REMAP:${name}`);
        }
        const targetRefs = decision?.targetRecordRefs ?? [];
        if (
          !Array.isArray(targetRefs) ||
          (decision?.action === "deduplicate" && targetRefs.length === 0)
        ) {
          fail(`MISSING_TARGET_RECORDS:${name}`);
        }
        for (const [refsToCheck, assetId] of [
          [refs, managed?.id],
          [targetRefs, external?.id],
        ]) {
          for (const ref of Array.isArray(refsToCheck) ? refsToCheck : []) {
            const record = manifest.records[ref];
            if (
              typeof ref !== "string" ||
              !object(record) ||
              record.complete !== true ||
              record.relation !== name ||
              record.assetId !== assetId ||
              !object(record.row) ||
              Object.keys(record.row).length === 0
            ) {
              fail(`INCOMPLETE_RECORD:${name}:${ref}`);
            }
          }
        }
        if (Array.isArray(refs) && refs.length > 0)
          remaps.push({
            relation: name,
            action: decision?.action,
            sourceRecordRefs: [...refs].sort(),
            targetRecordRefs: Array.isArray(targetRefs)
              ? [...targetRefs].sort()
              : [],
            sourceAssetId: managed?.id,
            targetAssetId: external?.id,
          });
      }
      return {
        externalId: external?.id,
        managedId: managed?.id,
        status: blockers.length ? "BLOCKED" : "REVIEW_REQUIRED",
        blockers: [...new Set(blockers)].sort(),
        survivor: { id: external?.id, path: external?.path },
        dependencyRemaps: remaps.sort((a, b) =>
          a.relation.localeCompare(b.relation),
        ),
        stages: blockers.length
          ? []
          : [
              "Future approval + durable journal + atomic dependency remap; not implemented.",
              "Verify committed survivor access and old-client sync before any file operation.",
              "Only then propose identity-checked quarantine of the Managed-only original; separate approval.",
            ],
      };
    })
    .sort((a, b) => String(a.externalId).localeCompare(String(b.externalId)));
  return {
    version: 1,
    planId: hash(manifest),
    ownerId: manifest.ownerId,
    status:
      errors.length || plans.some((pair) => pair.status === "BLOCKED")
        ? "BLOCKED"
        : "REVIEW_REQUIRED",
    blockers: [...new Set(errors)].sort(),
    pairs: plans,
    authority: "OFFLINE_REVIEW_ONLY_NO_APPLY",
  };
}

if (
  process.argv[1] &&
  resolve(process.argv[1]) === fileURLToPath(import.meta.url)
) {
  try {
    if (process.argv.length !== 3 || process.argv[2].startsWith("--"))
      throw new Error(
        "Usage: node plan.mjs audit.json (or - for JSON stdin); no apply mode",
      );
    const input = readFileSync(
      process.argv[2] === "-" ? 0 : process.argv[2],
      "utf8",
    );
    const plan = planManifest(JSON.parse(input));
    process.stdout.write(`${JSON.stringify(plan, null, 2)}\n`);
    process.exitCode = plan.status === "BLOCKED" ? 2 : 0;
  } catch (error) {
    process.stderr.write(`Planner refused input: ${error.message}\n`);
    process.exitCode = 1;
  }
}
