import { BadRequestException, ConflictException, ForbiddenException, Injectable } from '@nestjs/common';
import { isUndefined, omitBy } from 'lodash-es';
import { isAbsolute } from 'node:path';
import type { ShallowDehydrateObject } from 'kysely';
import type { AssetFace, AssetFile } from 'src/database.js';
import type { AuthDto } from 'src/dtos/auth.dto.js';
import type { ArgOf } from 'src/repositories/event.repository.js';
import type { LinkedSpacePerson } from 'src/repositories/shared-space.repository.js';
import type { DeletionRootIdentity } from 'src/schema/tables/asset-deletion.table.js';
import type { JobItem, JobOf } from 'src/types.js';
import { StorageCore } from 'src/cores/storage.core.js';
import { OnEvent, OnJob } from 'src/decorators.js';
import {
  DeletionPolicyDto,
  DeletionPreflightResultDto,
  ManagedDeletionStatusDto,
  PermanentDeletionBatchStatusDto,
  PermanentDeletionResultDto,
  PrepareManagedDeletionDto,
  TrashDeletionScopeDto,
} from 'src/dtos/asset-deletion.dto.js';
import { AssetResponseDto, SanitizedAssetResponseDto, mapAsset } from 'src/dtos/asset-response.dto.js';
import {
  AssetBulkDeleteDto,
  AssetBulkUpdateDto,
  AssetCopyDto,
  AssetJobName,
  AssetJobsDto,
  AssetMetadataBulkDeleteDto,
  AssetMetadataBulkResponseDto,
  AssetMetadataBulkUpsertDto,
  AssetMetadataResponseDto,
  AssetMetadataUpsertDto,
  AssetStatsDto,
  UpdateAssetDto,
  mapStats,
} from 'src/dtos/asset.dto.js';
import {
  AssetEditAction,
  type AssetEditActionItem,
  AssetEditsCreateDto,
  AssetEditsResponseDto,
  type TrimParameters,
} from 'src/dtos/editing.dto.js';
import { AssetOcrResponseDto } from 'src/dtos/ocr.dto.js';
import {
  AssetFileType,
  AssetStatus,
  AssetType,
  AssetVisibility,
  JobName,
  JobStatus,
  Permission,
  QueueName,
  StorageFolder,
} from 'src/enum.js';
import { BaseService } from 'src/services/base.service.js';
import { getAssetDeleteBatchJobId } from 'src/repositories/job.repository.js';
import { StorageService } from 'src/services/storage.service.js';
import { requireElevatedPermission } from 'src/utils/access.js';
import {
  getAssetFiles,
  getDimensions,
  isPanorama,
  onAfterUnlink,
  onBeforeLink,
  onBeforeUnlink,
} from 'src/utils/asset.util.js';
import {
  DeletionError,
  assertWritableDeletionRoots,
  collectRootIdentities,
  deletionCode,
  refreshStorageRootIdentities,
  sameRootIdentity,
} from 'src/utils/authorized-deletion.js';
import { isDeadlockError, retryOnDeadlock, updateLockedColumns } from 'src/utils/database.js';
import { asDateTimeString, extractTimeZone } from 'src/utils/date.js';
import { verifyRecoveryEvidence } from 'src/utils/deletion-recovery.js';
import { findOrFail } from 'src/utils/misc.js';
import { applyResolvedIdentityMetadata } from 'src/utils/person-identity.js';
import { transformOcrBoundingBox } from 'src/utils/transform.js';

@Injectable()
export class AssetService extends BaseService {
  /** Keep request/transaction work bounded; larger explicit selections run in the durable queue. */
  private static readonly INLINE_PERMANENT_DELETION_LIMIT = 200;
  private static readonly BATCH_CHUNK_SIZE = 200;

  async getStatistics(auth: AuthDto, dto: AssetStatsDto) {
    if (dto.visibility === AssetVisibility.Locked) {
      requireElevatedPermission(auth);
    }

    const stats = await this.assetRepository.getStatistics(auth.user.id, dto);
    return mapStats(stats);
  }

  async get(auth: AuthDto, id: string, spaceId?: string): Promise<AssetResponseDto | SanitizedAssetResponseDto> {
    await this.requireAccess({ auth, permission: Permission.AssetRead, ids: [id] });

    const asset = await this.assetRepository.getById(id, {
      exifInfo: true,
      owner: true,
      faces: { person: true, viewingUserId: auth.user.id },
      stack: { assets: true },
      edits: true,
      tags: true,
    });

    if (!asset) {
      throw new BadRequestException('Asset not found');
    }

    if (auth.sharedLink && !auth.sharedLink.showExif) {
      return mapAsset(asset, { stripMetadata: true, withStack: true, auth });
    }

    const data = mapAsset(asset, { withStack: true, auth });

    if (auth.sharedLink) {
      delete data.owner;
    }

    if (auth.sharedLink) {
      data.people = [];
    } else if (spaceId) {
      const member = await this.sharedSpaceRepository.getMember(spaceId, auth.user.id);
      if (!member) {
        throw new ForbiddenException('Not a member of this space');
      }

      const hasSpaceAccess = await this.accessRepository.asset.checkSpaceAccessForSpace(
        auth.user.id,
        spaceId,
        new Set([id]),
      );
      if (hasSpaceAccess.size === 0 || !data.people) {
        data.people = [];
      } else {
        const globalPersonIds = data.people.map((p) => p.id);
        const spacePersonMap = await this.sharedSpaceRepository.findSpacePersonsByLinkedPersonIds(
          spaceId,
          globalPersonIds,
        );
        this.applySpacePeople(data, spacePersonMap);
        data.people = data.people.filter((p) => p.spacePersonId && !spacePersonMap.get(p.id)?.isHidden);
      }
    } else if (data.ownerId === auth.user.id) {
      // The owner is viewing their own asset with no space context. A name or birthday set in a
      // shared space is resolved at read time against the face identity and is never written back
      // to `person` (see PersonService.getById). Without overlaying that resolution here, the raw
      // person row carries a null birthDate and the asset detail view shows no age.
      await this.applyResolvedPersonMetadata(auth, data, asset.faces ?? []);
    } else {
      // No spaceId — try to find a space containing this asset for this user
      const spaceForAsset = await this.sharedSpaceRepository.findSpaceForAssetAndUser(id, auth.user.id);
      if (spaceForAsset) {
        const globalPersonIds = (data.people || []).map((p) => p.id);
        const spacePersonMap = await this.sharedSpaceRepository.findSpacePersonsByLinkedPersonIds(
          spaceForAsset.spaceId,
          globalPersonIds,
        );
        this.applySpacePeople(data, spacePersonMap);
        data.people = (data.people || []).filter((p) => p.spacePersonId && !spacePersonMap.get(p.id)?.isHidden);
        data.resolvedSpaceId = spaceForAsset.spaceId;
      } else {
        // #796: no space contains this asset for the viewer, so they reach it through an album
        // share or partner sharing. Read access to the asset carries read access to who is in it —
        // minus anyone the owner marked hidden, which must not leak off-box.
        data.people = (data.people || []).filter((person) => !person.isHidden);
      }
    }

    return data;
  }

  private async applyResolvedPersonMetadata(
    auth: AuthDto,
    data: AssetResponseDto,
    faces: ShallowDehydrateObject<AssetFace>[],
  ) {
    const people = data.people;
    if (!people?.length) {
      return;
    }

    const identityByPersonId = new Map<string, string>();
    for (const face of faces) {
      if (face.person?.personGroupId && face.person.identityId) {
        identityByPersonId.set(face.person.personGroupId, face.person.identityId);
      }
    }

    // Shared with PersonService.getFacesById, the sibling read path the Info panel uses for the
    // owner — the two have to resolve identically or the age appears on one surface only (#808).
    await applyResolvedIdentityMetadata({
      people,
      identityByPersonId,
      resolve: (identityId) => this.faceIdentityRepository.getResolvedPersonByIdentityId(auth.user.id, identityId),
    });
  }

  private applySpacePeople(data: AssetResponseDto, spacePersonMap: Map<string, LinkedSpacePerson>) {
    for (const person of data.people || []) {
      const spacePerson = spacePersonMap.get(person.id);
      if (!spacePerson) {
        continue;
      }

      person.spacePersonId = spacePerson.id;
      person.isHidden = spacePerson.isHidden;

      const name = spacePerson.name;
      if (name !== undefined) {
        person.name = name ?? '';
      }

      person.thumbnailPath = '';

      if (spacePerson.birthDate !== undefined) {
        person.birthDate = spacePerson.birthDate ?? null;
      }

      if (spacePerson.updatedAt !== undefined) {
        person.updatedAt = asDateTimeString(spacePerson.updatedAt);
      }

      if (spacePerson.type) {
        person.type = spacePerson.type;
      }
    }
  }

  async update(auth: AuthDto, id: string, dto: UpdateAssetDto): Promise<AssetResponseDto> {
    await this.requireAccess({ auth, permission: Permission.AssetUpdate, ids: [id] });

    // rbac-3: visibility AND livePhotoVideoId are owner-only structural writes (see updateAll). A space editor
    // holds AssetUpdate over other members' assets via checkSpaceEditAccess, but must not flip their visibility
    // (fleet-wide tombstone) or re-link their motion video. Reject if either is set on an asset the caller does
    // not own; other metadata (description/rating/…) stays editor-allowed. Runs BEFORE the livePhotoVideoId
    // link/unlink side-effects and the visibility transition helper below.
    if (dto.visibility !== undefined || dto.livePhotoVideoId !== undefined) {
      const ownedIds = await this.checkAccess({ auth, permission: Permission.AssetDelete, ids: [id] });
      if (!ownedIds.has(id)) {
        throw new ForbiddenException('Visibility and live-photo linkage can only be changed on assets you own');
      }
    }

    const { description, dateTimeOriginal, latitude, longitude, rating, ...rest } = dto;
    const repos = { asset: this.assetRepository, event: this.eventRepository };

    let previousMotion: { id: string } | null = null;
    if (rest.livePhotoVideoId) {
      await onBeforeLink(repos, { userId: auth.user.id, livePhotoVideoId: rest.livePhotoVideoId });
    } else if (rest.livePhotoVideoId === null) {
      const asset = await this.findOrFail(id);
      if (asset.livePhotoVideoId) {
        previousMotion = await onBeforeUnlink(repos, { livePhotoVideoId: asset.livePhotoVideoId });
      }
    }

    await this.updateExif({ id, description, dateTimeOriginal, latitude, longitude, rating });

    // correctness-8: capture the PRIOR visibility before the write so the transition helper can tell a
    // genuine boundary crossing from a no-op re-affirm (e.g. Hidden -> Hidden).
    let priorVisibility: AssetVisibility | undefined;
    if (dto.visibility !== undefined) {
      const priorAsset = await this.assetRepository.getById(id);
      priorVisibility = priorAsset?.visibility;
    }

    const asset = await this.assetRepository.update({ id, ...rest });

    if (previousMotion && asset) {
      await onAfterUnlink(repos, {
        userId: auth.user.id,
        livePhotoVideoId: previousMotion.id,
        visibility: asset.visibility,
      });
    }

    if (!asset) {
      throw new BadRequestException('Asset not found');
    }

    // security-4: the single-asset PUT previously wrote `visibility` straight through, skipping every
    // #757 transition side-effect the bulk path runs — member devices kept hidden/locked bytes forever and
    // Locked assets stayed in the owner's albums. Route it through the same helper so a single PUT is
    // byte-for-byte equivalent to a one-id bulk update. No-op for non-space assets (the emits match nothing).
    if (dto.visibility !== undefined) {
      await this.applyVisibilityTransitionSideEffects([id], dto.visibility, new Map([[id, priorVisibility]]));
    }

    return this.get(auth, id) as Promise<AssetResponseDto>;
  }

  // Motion-photo bypass: the live-photo/motion paths (asset.util onBeforeLink/onAfterUnlink,
  // metadata linkLivePhotos, metadata extraction-hide) flip a motion video's visibility directly and emit
  // AssetHide/AssetShow — but nothing routed those to the #757 space purge, so a motion video in a
  // space-linked library kept its bytes on member devices. AssetHide/AssetShow fire only on a genuine
  // Timeline↔Hidden crossing, so we run the same transition side-effects for the single asset.
  @OnEvent({ name: 'AssetHide' })
  async onAssetHide({ assetId }: ArgOf<'AssetHide'>): Promise<void> {
    // AssetHide fires only on Timeline→Hidden → seed a shareable prior so it registers as a crossing.
    await this.applyVisibilityTransitionSideEffects(
      [assetId],
      AssetVisibility.Hidden,
      new Map([[assetId, AssetVisibility.Timeline]]),
    );
  }

  @OnEvent({ name: 'AssetShow' })
  async onAssetShow({ assetId }: ArgOf<'AssetShow'>): Promise<void> {
    await this.applyVisibilityTransitionSideEffects(
      [assetId],
      AssetVisibility.Timeline,
      new Map([[assetId, AssetVisibility.Hidden]]),
    );
  }

  async updateAll(auth: AuthDto, dto: AssetBulkUpdateDto): Promise<void> {
    const {
      ids,
      isFavorite,
      visibility,
      dateTimeOriginal,
      latitude,
      longitude,
      rating,
      description,
      duplicateId,
      dateTimeRelative,
      timeZone,
    } = dto;
    await this.requireAccess({ auth, permission: Permission.AssetUpdate, ids });

    // rbac-3: `visibility` is destructive — flipping an asset to Locked/Hidden strips it from the owner's
    // albums (removeAssetsFromAll) and #757-tombstones it off every member device. AssetUpdate grants a space
    // EDITOR that power over OTHER members' direct+library assets (checkSpaceEditAccess), which would let an
    // editor wipe another member's asset fleet-wide. Restrict visibility to OWNED ids: reject the whole request
    // if visibility is set on any id the caller does not own. This guard MUST run before the write and the
    // applyVisibilityTransitionSideEffects cascade below, or the destructive side-effects fire before the guard.
    // AssetDelete == the pure owner arm (checkOwnerAccess, same hasElevatedPermission as the AssetUpdate gate's
    // isOwner sub-check); a library-backed asset owned by another user is correctly NOT returned as owned.
    if (visibility !== undefined) {
      const ownedIds = await this.checkAccess({ auth, permission: Permission.AssetDelete, ids });
      if (ownedIds.size !== new Set(ids).size) {
        throw new ForbiddenException('Visibility can only be changed on assets you own');
      }
    }

    const assetDto = omitBy({ isFavorite, visibility, duplicateId }, isUndefined);

    // When latitude/longitude are updated in bulk, reverse-geocode once so country/state/city
    // stay in sync across all selected assets. See updateExif() for the rationale.
    let geo: { country: string | null; state: string | null; city: string | null } | undefined;
    if (latitude !== undefined && longitude !== undefined) {
      geo = await this.mapRepository.reverseGeocode({ latitude, longitude });
    }

    const exifDto = omitBy(
      {
        latitude,
        longitude,
        rating,
        description,
        dateTimeOriginal,
        ...geo,
      },
      isUndefined,
    );

    if (Object.keys(exifDto).length > 0) {
      await this.assetRepository.updateAllExif(ids, exifDto);
    }

    const extractedTimeZone = extractTimeZone(dateTimeOriginal);

    if (
      (dateTimeRelative !== undefined && dateTimeRelative !== 0) ||
      timeZone !== undefined ||
      extractedTimeZone?.type === 'fixed'
    ) {
      await this.assetRepository.updateDateTimeOriginal(ids, dateTimeRelative, timeZone ?? extractedTimeZone?.name);
    }

    // correctness-8: capture PRIOR visibilities before the write so the transition helper can tell a
    // genuine boundary crossing from a no-op re-affirm (e.g. Hidden -> Hidden, Timeline -> Archive).
    const priorVisibilities = new Map<string, AssetVisibility>();
    if (visibility !== undefined) {
      const priorAssets = await this.assetRepository.getByIds(ids);
      for (const priorAsset of priorAssets) {
        priorVisibilities.set(priorAsset.id, priorAsset.visibility);
      }
    }

    if (Object.keys(assetDto).length > 0) {
      await this.assetRepository.updateAll(ids, assetDto);
    }

    if (visibility !== undefined) {
      await this.applyVisibilityTransitionSideEffects(ids, visibility, priorVisibilities);
    }

    await this.jobRepository.queueAll(ids.map((id) => ({ name: JobName.SidecarWrite, data: { id } })));
  }

  /**
   * Runs every #757 visibility-transition side-effect (removeAssetsFromAll on Locked + the direct/album/
   * library space purge/restore emits). Shared by updateAll (bulk), update (single) and the AssetHide/
   * AssetShow event handlers (motion photos).
   *
   * correctness-6 — NOT wrapped in a Kysely transaction: the UPDATE, removeAssetsFromAll and each emit run
   * on a DIFFERENT repository's own `this.db` handle, so a single `transaction()` would hit the
   * `this.db`-inside-`transaction()` pool deadlock (#595). Resilience instead comes from the purge being
   * UNCONDITIONAL-AND-IDEMPOTENT on a non-shareable next (M3): it no longer depends on the prior visibility
   * read before the write, so a retry that re-reads an already-Hidden/Locked asset (e.g. after a crash or a
   * failed emit) re-affirms the tombstone rather than silently no-op'ing. Re-running emits the same audit
   * rows harmlessly. A crash between the UPDATE and the emits therefore leaves a RECOVERABLE state (re-run
   * converges), not a corrupted one.
   */
  private async applyVisibilityTransitionSideEffects(
    ids: string[],
    nextVisibility: AssetVisibility,
    priorVisibilities: Map<string, AssetVisibility | undefined>,
  ): Promise<void> {
    const shareable = (v: AssetVisibility | undefined) =>
      v === AssetVisibility.Timeline || v === AssetVisibility.Archive;

    if (nextVisibility === AssetVisibility.Timeline || nextVisibility === AssetVisibility.Archive) {
      // Restore: only assets whose PRIOR was non-shareable (Hidden/Locked) cross back in. A shareable→
      // shareable move (e.g. Timeline↔Archive, unarchive re-affirm) is not a crossing → no emit.
      const restoreIds = ids.filter((id) => !shareable(priorVisibilities.get(id)));
      if (restoreIds.length > 0) {
        await this.sharedSpaceRepository.emitDirectAssetVisibilityRestore(restoreIds);
        await this.sharedSpaceRepository.emitAlbumAssetVisibilityRestore(restoreIds);
        // L4: the library ASSET ROW restore is automatic (the visibility UPDATE bumped asset.updateId),
        // but its EXIF is not — asset_exif.updateId is untouched by a visibility flip, so without this
        // emit a restored library asset would show empty EXIF forever on an already-synced member device.
        await this.sharedSpaceRepository.emitLibraryAssetVisibilityRestore(restoreIds);
      }
      return;
    }

    // nextVisibility is non-shareable (Hidden or Locked).
    // M-1: strip album membership UNCONDITIONALLY on Locked — do NOT gate on prior !== Locked. The old
    // "lock-once" gate was not retry-convergent: a crash between the visibility UPDATE and this strip left
    // the album_asset rows in place with no tombstone, and on retry priorVisibilities read Locked so the
    // strip was skipped FOREVER — a durable on-device leak, plus a silent re-share into the space when the
    // asset was later unlocked (the surviving album_asset rows were restored). Calling removeAssetsFromAll
    // on every id is idempotent: an already-stripped asset matches zero rows (a no-op), while a
    // crashed-first-attempt asset gets its surviving rows deleted and the album delete-audit trigger fires
    // the tombstone the crashed attempt never sent (delivered via SharedSpaceAlbumToAssetSync.getDeletes).
    // Keep the empty-batch guard (removeAssetsFromAll has none — an empty `IN ()` is invalid SQL), matching
    // the purge/restore branches in this method.
    if (nextVisibility === AssetVisibility.Locked && ids.length > 0) {
      await this.albumRepository.removeAssetsFromAll(ids);
    }

    // Purge: unconditional on every id whenever nextVisibility is non-shareable (M3, retry-convergent).
    // This branch already guarantees nextVisibility ∈ {Hidden, Locked}, so we don't need to know the prior
    // to decide whether to purge — a re-affirm (Hidden→Hidden, Locked→Locked) re-emits the same tombstone,
    // which is harmless (idempotent) and is exactly what lets a retry after a failed emit converge.
    const purgeIds = ids;
    if (purgeIds.length > 0) {
      await this.sharedSpaceRepository.emitDirectAssetVisibilityPurge(purgeIds);
      if (nextVisibility === AssetVisibility.Hidden) {
        // Locked's album removal is handled by removeAssetsFromAll above → no album tombstone for Locked.
        await this.sharedSpaceRepository.emitAlbumAssetVisibilityPurge(purgeIds);
      }
      await this.sharedSpaceRepository.emitLibraryAssetVisibilityPurge(purgeIds);
    }
  }

  async copy(
    auth: AuthDto,
    {
      sourceId,
      targetId,
      albums = true,
      sidecar = true,
      sharedLinks = true,
      stack = true,
      favorite = true,
    }: AssetCopyDto,
  ) {
    await this.requireAccess({ auth, permission: Permission.AssetCopy, ids: [sourceId, targetId] });
    const sourceAsset = await this.assetRepository.getForCopy(sourceId);
    const targetAsset = await this.assetRepository.getForCopy(targetId);

    if (!sourceAsset || !targetAsset) {
      throw new BadRequestException('Both assets must exist');
    }

    if (sourceId === targetId) {
      throw new BadRequestException('Source and target id must be distinct');
    }

    if (albums) {
      await this.albumRepository.copyAlbums({ sourceAssetId: sourceId, targetAssetId: targetId });
    }

    if (sharedLinks) {
      await this.sharedLinkAssetRepository.copySharedLinks({ sourceAssetId: sourceId, targetAssetId: targetId });
    }

    if (stack) {
      await this.copyStack({ sourceAsset, targetAsset });
    }

    if (favorite) {
      await this.assetRepository.update({ id: targetId, isFavorite: sourceAsset.isFavorite });
    }

    if (sidecar) {
      await this.copySidecar({ sourceAsset, targetAsset });
    }
  }

  private async copyStack({
    sourceAsset,
    targetAsset,
  }: {
    sourceAsset: { id: string; stackId: string | null };
    targetAsset: { id: string; stackId: string | null };
  }) {
    if (!sourceAsset.stackId) {
      return;
    }

    if (targetAsset.stackId) {
      await this.stackRepository.merge({ sourceId: sourceAsset.stackId, targetId: targetAsset.stackId });
      await this.stackRepository.delete(sourceAsset.stackId);
    } else {
      await this.assetRepository.update({ id: targetAsset.id, stackId: sourceAsset.stackId });
    }
  }

  private async copySidecar({
    sourceAsset,
    targetAsset,
  }: {
    sourceAsset: { files: AssetFile[] };
    targetAsset: { id: string; files: AssetFile[]; originalPath: string };
  }) {
    const { sidecarFile: sourceFile } = getAssetFiles(sourceAsset.files);
    if (!sourceFile?.path) {
      return;
    }

    // Safe-by-invariant: AssetService.copy rejects sourceId === targetId, so distinct
    // assets guarantee sourceFile.path !== targetSidecarPath.
    const targetSidecarPath = `${targetAsset.originalPath}.xmp`;

    const { localPath, cleanup } = await this.ensureLocalFile(sourceFile.path);
    try {
      if (isAbsolute(targetSidecarPath)) {
        this.storageCore.ensureFolders(targetSidecarPath);
        await this.storageRepository.copyFile(localPath, targetSidecarPath);
      } else {
        const backend = StorageService.resolveBackendForKey(targetSidecarPath);
        const stream = this.storageRepository.createPlainReadStream(localPath);
        await backend.put(targetSidecarPath, stream, { contentType: 'application/xml' });
      }
    } finally {
      await cleanup();
    }

    await this.assetRepository.upsertFile({
      assetId: targetAsset.id,
      path: targetSidecarPath,
      type: AssetFileType.Sidecar,
    });
    await this.jobRepository.queue({ name: JobName.AssetExtractMetadata, data: { id: targetAsset.id } });
  }

  @OnJob({ name: JobName.AssetDeleteCheck, queue: QueueName.BackgroundTask })
  async handleAssetDeletionCheck(): Promise<JobStatus> {
    // Retry only committed, owner-scoped intents. Unsealed legacy jobs are not
    // proof of consent and never enter this recovery path.
    for await (const receipt of this.assetRepository.streamPendingDeletions()) {
      await this.jobRepository.queue({
        name: JobName.AssetDelete,
        data: {
          id: receipt.assetId,
          deleteOnDisk: true,
          deletionId: receipt.assetId,
        },
      });
    }
    const { trash } = await this.getConfig({ withCache: false });
    if (!trash.enabled || !Number.isFinite(trash.days) || trash.days < 0) return JobStatus.Success;
    const cutoff = new Date(Date.now() - trash.days * 24 * 60 * 60 * 1000);
    for await (const asset of this.assetRepository.streamExpiredTrash(cutoff)) {
      const scope = asset.libraryId ?? 'managed';
      try {
        const policy =
          scope === 'managed'
            ? await this.ensureManagedStoragePolicy(asset.ownerId)
            : await this.assetRepository.getDeletionPolicy(asset.ownerId, scope);
        await this.checkCurrentPolicy(asset.ownerId, scope, policy);
        await this.assetRepository.preparePermanentDeletion(
          asset.id,
          asset.ownerId,
          (path, roots) => this.storageRepository.snapshotOriginal(path, roots),
          cutoff,
        );
        const targets = await this.assetRepository.getPermanentDeletionTargets(asset.id);
        for (const target of targets)
          await this.jobRepository.queue({
            name: JobName.AssetDelete,
            data: {
              id: target.assetId,
              deleteOnDisk: true,
              deletionId: target.assetId,
            },
          });
      } catch (error) {
        // A read-only/revoked library or a concurrent Restore remains intact.
        this.logger.warn(`Trash expiration deferred: ${deletionCode(error)}`);
      }
    }
    return JobStatus.Success;
  }

  @OnJob({ name: JobName.AssetDeleteBatch, queue: QueueName.BackgroundTask })
  async handleAssetDeletionBatch(job: JobOf<JobName.AssetDeleteBatch>): Promise<JobStatus> {
    const user = await this.userRepository.get(job.ownerId, {});
    if (!user) {
      this.logger.warn(`Skipping permanent deletion batch for missing owner ${job.ownerId}`);
      return JobStatus.Skipped;
    }

    // The queue item is the durable record of the user's explicit request. Disable
    // re-queuing here: each target has its own receipt and AssetDelete retry path.
    const results: PermanentDeletionResultDto[] = [];
    for (let start = 0; start < job.ids.length; start += AssetService.BATCH_CHUNK_SIZE) {
      results.push(
        ...(await this.permanentlyDelete(
          { user: user as AuthDto['user'] },
          job.ids.slice(start, start + AssetService.BATCH_CHUNK_SIZE),
          job.allowActive === true,
          false,
        )),
      );
    }
    const unresolved = results.filter((result) => result.state !== 'complete').length;
    if (unresolved > 0) {
      this.logger.warn(`Permanent deletion batch for ${job.ownerId} left ${unresolved} item(s) unresolved`);
    }
    return JobStatus.Success;
  }

  @OnJob({ name: JobName.AssetDelete, queue: QueueName.BackgroundTask })
  async handleAssetDeletion(job: JobOf<JobName.AssetDelete>): Promise<JobStatus> {
    const { id, deleteOnDisk } = job;
    if (job.trashedBefore !== undefined && Number.isNaN(new Date(job.trashedBefore).getTime())) {
      return JobStatus.Failed;
    }
    if (job.trashedBefore !== undefined) {
      // Installing this candidate is not approval for any old retention job,
      // including metadata-only jobs which could discard a Trash tombstone.
      return JobStatus.Skipped;
    }
    if (job.deletionReason === 'library' && (!job.libraryId || deleteOnDisk)) {
      return JobStatus.Failed;
    }
    if (deleteOnDisk && job.deletionId !== id) {
      return JobStatus.Skipped;
    }

    if (job.trashedBefore === undefined) {
      if (job.deletionReason === 'library' && (!job.libraryId || deleteOnDisk)) {
        return JobStatus.Failed;
      }
      const cleanup =
        job.deletionReason === 'motion'
          ? { reason: 'motion' as const }
          : job.deletionReason === 'library' && job.libraryId && !deleteOnDisk
            ? { reason: 'library' as const, libraryId: job.libraryId }
            : undefined;
      if (!(await this.assetRepository.claimDeletion(id, cleanup))) {
        return JobStatus.Skipped;
      }
    } else {
      const cutoff = new Date(job.trashedBefore);
      if (Number.isNaN(cutoff.getTime())) {
        return JobStatus.Failed;
      }
      if (!(await this.assetRepository.claimExpiredDeletion(id, cutoff))) {
        return JobStatus.Skipped;
      }
    }

    const asset = await this.assetJobRepository.getForAssetDeletion(id);

    if (!asset) {
      return JobStatus.Failed;
    }

    if (deleteOnDisk) {
      const receipt = await this.assetRepository.getDeletionReceipt(asset.ownerId, id);
      if (!receipt) return JobStatus.Skipped;
      try {
        // Finish a committed intent interrupted before hashing/publishing files.
        // Never manufacture an intent from an unsealed legacy queue payload.
        await this.assetRepository.preparePermanentDeletion(id, asset.ownerId, (path, roots) =>
          this.storageRepository.snapshotOriginal(path, roots),
        );
      } catch {
        return JobStatus.Failed;
      }
    }

    if (
      deleteOnDisk &&
      !(await this.assetRepository.removeAuthorizedOriginals(id, (file, recheck) =>
        this.storageRepository.unlinkOriginal(file, async () => {
          await recheck();
          await this.validateOwnerRootBoundaries(
            asset.ownerId,
            [file.root],
            [file.rootIdentity],
            asset.libraryId ?? 'managed',
            true,
          );
        }),
      ))
    ) {
      return JobStatus.Skipped;
    }

    if (asset.stack) {
      // asset.stack.assets only includes timeline visible assets and excludes the primary asset
      const remainingStackAssetIds = asset.stack.assets.map((a) => a.id).filter((assetId) => assetId !== id);

      // the primary survives unless it is the asset being deleted
      let remainingCount = remainingStackAssetIds.length;
      if (asset.stack.primaryAssetId !== id) {
        remainingCount++;
      }

      if (remainingCount < 2) {
        // 0 or 1 asset would remain: dissolve the stack so it does not linger as a single-asset stack
        await this.stackRepository.delete(asset.stack.id);
      } else if (asset.stack.primaryAssetId === id) {
        // the primary is being deleted but others remain: promote a new primary
        await this.stackRepository.update(asset.stack.id, {
          id: asset.stack.id,
          primaryAssetId: remainingStackAssetIds[0],
        });
      }
    }

    // Capture affected shared-space (spaceId, personId) pairs BEFORE the asset row and its
    // DB cascade (asset_face → shared_space_person_face) are deleted.  The onAssetDelete
    // handler in SharedSpaceService receives this data and recounts/cleans up after the delete.
    const affectedSpacePersons = await this.sharedSpaceRepository.getSpacePersonsForAsset(id);

    // The delete cascades into asset_face, which makes Postgres lock shared_space_person rows to
    // null out representativeFaceId. Those locks are taken in face order, so they can cycle against
    // a concurrent space-people recount. Re-drive the victim rather than lose the deletion (#864).
    try {
      if (!(await retryOnDeadlock(() => this.assetRepository.removeForDeletion(asset)))) {
        // Only the job which actually removes the row owns its file/events/quota
        // effects, even when competing jobs fetched the same deletion snapshot.
        return JobStatus.Skipped;
      }
    } catch (error) {
      if (!isDeadlockError(error)) {
        throw error;
      }

      // Still contended after the whole budget. The asset is already soft-deleted, so dropping it
      // here would leave it behind until the trash sweep runs days later. Re-queue instead: the
      // job goes to the back of the queue, by which point the delete storm has usually drained.
      this.logger.warn(`Re-queueing deletion of asset ${id}: still deadlocking after repeated retries`);
      await this.jobRepository.queue({ name: JobName.AssetDelete, data: job });
      return JobStatus.Skipped;
    }
    if (!asset.libraryId) {
      await this.userRepository.updateUsage(asset.ownerId, -(asset.exifInfo?.fileSizeInByte || 0));
    }

    await this.eventRepository.emit('AssetDelete', { assetId: id, userId: asset.ownerId, affectedSpacePersons });

    // delete the motion if it is not used by another asset
    if (asset.livePhotoVideoId) {
      const count = await this.assetRepository.getLivePhotoCount(asset.livePhotoVideoId);
      if (count === 0) {
        await this.jobRepository.queue({
          name: JobName.AssetDelete,
          data: {
            id: asset.livePhotoVideoId,
            deleteOnDisk,
            deletionReason: 'motion',
            deletionId: deleteOnDisk ? asset.livePhotoVideoId : undefined,
          },
        });
      }
    }

    const assetFiles = getAssetFiles(asset.files ?? []);
    const files = [
      assetFiles.thumbnailFile?.path,
      assetFiles.previewFile?.path,
      assetFiles.fullsizeFile?.path,
      assetFiles.editedFullsizeFile?.path,
      assetFiles.editedPreviewFile?.path,
      assetFiles.editedThumbnailFile?.path,
      assetFiles.encodedVideoFile?.path,
    ];

    // Originals/sidecar are handled above under the durable per-library authorization.
    // FileDelete receives derivatives only, including for legacy metadata-only cleanup.

    const derivatives = files.filter(Boolean);
    if (derivatives.length > 0) {
      await this.jobRepository.queue({ name: JobName.FileDelete, data: { files: derivatives } });
    }

    return JobStatus.Success;
  }

  async deleteAll(auth: AuthDto, dto: AssetBulkDeleteDto): Promise<void> {
    const { ids } = dto;
    const { trash } = await this.getConfig({ withCache: true });
    const force = dto.force || !trash.enabled;
    if (force) {
      const results = await this.permanentlyDelete(auth, ids, true);
      if (results.some((result) => result.state !== 'complete')) {
        throw new ConflictException(
          'Permanent deletion incomplete; inspect owner-scoped deletion status and retry only unresolved items.',
        );
      }
      return;
    }
    await this.requireAccess({ auth, permission: Permission.AssetDelete, ids });
    const changedIds = await this.assetRepository.markDeletionState(ids, {
      deletedAt: new Date(),
      status: force ? AssetStatus.Deleted : AssetStatus.Trashed,
    });
    if (changedIds.length > 0) {
      await this.eventRepository.emit(force ? 'AssetDeleteAll' : 'AssetTrashAll', {
        assetIds: changedIds,
        userId: auth.user.id,
      });
    }
  }

  async trashDeletionScopes(auth: AuthDto): Promise<TrashDeletionScopeDto[]> {
    const assets = await this.assetRepository.getOwnerTrash(auth.user.id);
    const counts = new Map<string, number>();
    for (const asset of assets) {
      const scope = asset.libraryId ?? 'managed';
      counts.set(scope, (counts.get(scope) ?? 0) + 1);
    }
    return Promise.all(
      [...counts].map(async ([scope, count]) => {
        const policy =
          scope === 'managed'
            ? await this.ensureManagedStoragePolicy(auth.user.id)
            : await this.assetRepository.getDeletionPolicy(auth.user.id, scope);
        let authorized = false;
        try {
          await this.checkCurrentPolicy(auth.user.id, scope, policy);
          authorized = true;
        } catch {
          /* blocked, no mutation */
        }
        return { scope, count, authorized };
      }),
    );
  }

  async emptyAuthorizedTrash(auth: AuthDto): Promise<{ count: number }> {
    const assets = await this.assetRepository.getOwnerTrash(auth.user.id);
    // Check every library before the first irreversible action. Empty Trash is not a retention grant.
    for (const scope of new Set(assets.map((asset) => asset.libraryId ?? 'managed'))) {
      const policy =
        scope === 'managed'
          ? await this.ensureManagedStoragePolicy(auth.user.id)
          : await this.assetRepository.getDeletionPolicy(auth.user.id, scope);
      try {
        await this.checkCurrentPolicy(auth.user.id, scope, policy);
      } catch (error) {
        throw new ConflictException(deletionCode(error));
      }
    }
    let count = 0;
    for (let start = 0; start < assets.length; start += 200) {
      const results = await this.permanentlyDelete(
        auth,
        assets.slice(start, start + 200).map(({ id }) => id),
      );
      count += results.filter((result) => result.state === 'complete').length;
      if (results.some((result) => result.state !== 'complete')) {
        throw new ConflictException(
          `Empty Trash incomplete; ${count} originals deleted. Remaining receipts are available for owner-scoped retry.`,
        );
      }
    }
    return { count };
  }

  async setDeletionPolicy(auth: AuthDto, dto: DeletionPolicyDto): Promise<void> {
    if (!auth.user.isAdmin) throw new ForbiddenException('Administrator verification required');
    if (dto.enabled) {
      throw new BadRequestException(
        dto.scope === 'managed'
          ? 'Managed deletion requires separate owner consent'
          : 'External deletion requires separate owner consent',
      );
    }
    const existing = await this.assetRepository.getDeletionPolicy(dto.ownerId, dto.scope);
    // Revocation never requires available storage/evidence; it cannot replace trusted preparation.
    if (!dto.enabled && existing && dto.recoveryProof === existing.recoveryProof) {
      await this.assetRepository.setDeletionPolicy(dto.ownerId, dto.scope, {
        enabled: false,
        roots: existing.roots,
        recoveryProof: existing.recoveryProof,
        authorizedBy: auth.user.id,
        rootIdentities: existing.rootIdentities,
        recoveryExpiresAt: existing.recoveryExpiresAt ? new Date(existing.recoveryExpiresAt) : undefined,
      });
      return;
    }
    await this.prepareDeletionPolicy(auth, dto);
  }

  private async prepareDeletionPolicy(auth: AuthDto, dto: DeletionPolicyDto): Promise<void> {
    const identities = await this.validateDeletionPolicy(dto);
    const evidence = await this.verifyEvidence(dto.recoveryProof, dto.ownerId, dto.scope, identities);
    await this.assetRepository.setDeletionPolicy(dto.ownerId, dto.scope, {
      enabled: false,
      roots: dto.roots,
      rootIdentities: identities,
      recoveryExpiresAt: new Date(evidence.expiresAt),
      recoveryProof: dto.recoveryProof,
      authorizedBy: auth.user.id,
    });
  }

  private async verifyEvidence(proof: string, owner: string, scope: string, identities: DeletionRootIdentity[]) {
    try {
      return await verifyRecoveryEvidence(proof, owner, scope, identities);
    } catch (error) {
      throw new ConflictException(deletionCode(error));
    }
  }

  private async validateDeletionPolicy(dto: DeletionPolicyDto): Promise<DeletionRootIdentity[]> {
    const library = dto.scope === 'managed' ? undefined : await this.libraryRepository.get(dto.scope);
    if (dto.scope !== 'managed' && (!library || library.ownerId !== dto.ownerId || library.deletedAt)) {
      throw new BadRequestException('Unknown owner/library scope');
    }
    const user = await this.userRepository.get(dto.ownerId, {});
    if (!user) throw new BadRequestException('Unknown owner');
    const allowed = library?.importPaths ?? [
      StorageCore.getFolderLocation(StorageFolder.Upload, dto.ownerId),
      StorageCore.getLibraryFolder(user),
    ];
    if (dto.roots.some((root) => !allowed.includes(root)))
      throw new BadRequestException('Root is not an existing owner library root');
    const others = await this.assetRepository.getDeletionRootsForOtherOwners(dto.ownerId);
    const otherRoots = [
      ...others.external,
      ...others.users.flatMap((other) => [
        StorageCore.getFolderLocation(StorageFolder.Upload, other.id),
        StorageCore.getLibraryFolder(other),
        StorageCore.getFolderLocation(StorageFolder.EncodedVideo, other.id),
      ]),
    ];
    try {
      return await this.storageRepository.validateDeletionRoots(dto.roots, otherRoots);
    } catch (error) {
      throw new ConflictException(deletionCode(error));
    }
  }

  async managedDeletionStatus(auth: AuthDto): Promise<ManagedDeletionStatusDto> {
    const policy = await this.assetRepository.getDeletionPolicy(auth.user.id, 'managed');
    let prepared = false;
    try {
      if (policy?.authorizationMode === 'storage') {
        await this.checkStoragePolicy(auth.user.id, 'managed', policy);
      } else {
        await this.ownerStorageRoots(auth.user.id, 'managed');
      }
      prepared = true;
    } catch {
      /* inaccessible/replaced roots never become ready */
    }
    return { enabled: policy?.enabled ?? true, prepared, canPrepare: false };
  }

  async libraryDeletionScopes(auth: AuthDto): Promise<TrashDeletionScopeDto[]> {
    const [libraries, assets] = await Promise.all([
      this.libraryRepository.getAll(),
      this.assetRepository.getOwnerTrash(auth.user.id),
    ]);
    return Promise.all(
      libraries
        .filter((library) => library.ownerId === auth.user.id && !library.deletedAt)
        .map(async (library) => {
          const status = await this.libraryDeletionStatus(auth, library.id);
          return {
            scope: library.id,
            name: library.name,
            count: assets.filter((asset) => asset.libraryId === library.id).length,
            authorized: status.enabled && status.prepared,
          };
        }),
    );
  }

  async libraryDeletionStatus(auth: AuthDto, scope: string): Promise<ManagedDeletionStatusDto> {
    const library = await this.libraryRepository.get(scope);
    if (!library || library.ownerId !== auth.user.id || library.deletedAt)
      throw new ForbiddenException('Unknown owner/library scope');
    const policy = await this.assetRepository.getDeletionPolicy(auth.user.id, scope);
    let prepared = false;
    try {
      if (policy?.authorizationMode === 'storage') await this.checkStoragePolicy(auth.user.id, scope, policy);
      else await this.ownerStorageRoots(auth.user.id, scope);
      prepared = true;
    } catch {
      /* unavailable/redirected roots never become writable */
    }
    return { enabled: !!policy?.enabled && policy.authorizedBy === auth.user.id, prepared, canPrepare: false };
  }

  async prepareLibraryDeletion(auth: AuthDto, scope: string, dto: PrepareManagedDeletionDto): Promise<void> {
    return this.prepareLibraryDeletionForOwner(auth, auth.user.id, scope, dto);
  }

  async prepareLibraryDeletionForOwner(
    auth: AuthDto,
    ownerId: string,
    scope: string,
    dto: PrepareManagedDeletionDto,
  ): Promise<void> {
    if (!auth.user.isAdmin) throw new ForbiddenException('Administrator verification required');
    const library = await this.libraryRepository.get(scope);
    if (!library || library.ownerId !== ownerId || library.deletedAt)
      throw new ForbiddenException('Unknown owner/library scope');
    await this.prepareDeletionPolicy(auth, {
      ownerId,
      scope,
      enabled: false,
      roots: library.importPaths,
      recoveryProof: dto.recoveryProof,
      verifiedExclusiveRoots: dto.verifiedExclusiveRoots,
    });
  }

  async setLibraryDeletionConsent(auth: AuthDto, scope: string, enabled: boolean): Promise<void> {
    const library = await this.libraryRepository.get(scope, true);
    if (!library || library.ownerId !== auth.user.id || (enabled && library.deletedAt))
      throw new ForbiddenException('Unknown owner/library scope');
    await this.configureStorageDeletion(auth.user.id, scope, enabled);
  }

  async prepareManagedDeletion(auth: AuthDto, dto: PrepareManagedDeletionDto): Promise<void> {
    return this.prepareManagedDeletionForOwner(auth, auth.user.id, dto);
  }

  async prepareManagedDeletionForOwner(auth: AuthDto, ownerId: string, dto: PrepareManagedDeletionDto): Promise<void> {
    if (!auth.user.isAdmin) throw new ForbiddenException('Administrator verification required');
    const user = await this.userRepository.get(ownerId, {});
    if (!user) throw new BadRequestException('Unknown owner');
    const allowed = [StorageCore.getFolderLocation(StorageFolder.Upload, user.id), StorageCore.getLibraryFolder(user)];
    const roots: string[] = [];
    for (const root of new Set(allowed)) if (await this.storageRepository.checkFileExists(root)) roots.push(root);
    if (roots.length === 0) throw new BadRequestException('No existing managed storage roots');
    await this.prepareDeletionPolicy(auth, {
      ownerId: user.id,
      scope: 'managed',
      roots,
      enabled: false,
      recoveryProof: dto.recoveryProof,
      verifiedExclusiveRoots: dto.verifiedExclusiveRoots,
    });
  }

  async setManagedDeletionConsent(auth: AuthDto, enabled: boolean): Promise<void> {
    await this.configureStorageDeletion(auth.user.id, 'managed', enabled);
  }

  private async ownerStorageRoots(ownerId: string, scope: string) {
    const user = await this.userRepository.get(ownerId, {});
    if (!user) throw new DeletionError('ASSET_NOT_OWNED');
    const library = scope === 'managed' ? undefined : await this.libraryRepository.get(scope);
    if (scope !== 'managed' && (!library || library.ownerId !== ownerId || library.deletedAt))
      throw new DeletionError('LIBRARY_DELETION_NOT_AUTHORIZED');
    const configured = library?.importPaths ?? [
      StorageCore.getFolderLocation(StorageFolder.Upload, ownerId),
      StorageCore.getLibraryFolder(user),
    ];
    const roots: string[] = [];
    for (const root of new Set(configured)) {
      if (await this.storageRepository.checkFileExists(root)) roots.push(root);
      else if (scope !== 'managed') throw new DeletionError('DELETION_ROOT_CHANGED');
    }
    if (roots.length === 0) throw new DeletionError('UNSUPPORTED_DELETION_SCOPE');
    const identities = await this.validateDeletionPolicy({
      ownerId,
      scope,
      roots,
      enabled: false,
      recoveryProof: '',
      verifiedExclusiveRoots: true,
    });
    await assertWritableDeletionRoots(identities);
    return { roots, identities };
  }

  private async configureStorageDeletion(ownerId: string, scope: string, enabled: boolean) {
    const policy = await this.assetRepository.getDeletionPolicy(ownerId, scope);
    try {
      const storage = enabled ? await this.ownerStorageRoots(ownerId, scope) : undefined;
      await this.assetRepository.setDeletionPolicy(ownerId, scope, {
        authorizationMode: 'storage',
        enabled,
        roots: storage?.roots ?? policy?.roots ?? [],
        rootIdentities: storage?.identities ?? policy?.rootIdentities ?? [],
        recoveryProof: '',
        recoveryExpiresAt: null,
        authorizedBy: ownerId,
      });
    } catch (error) {
      if (
        error instanceof BadRequestException ||
        error instanceof ForbiddenException ||
        error instanceof ConflictException
      )
        throw error;
      throw new ConflictException(deletionCode(error));
    }
  }

  private async ensureManagedStoragePolicy(ownerId: string) {
    let policy = await this.assetRepository.getDeletionPolicy(ownerId, 'managed');
    if (!policy) {
      const { roots, identities } = await this.ownerStorageRoots(ownerId, 'managed');
      policy = await this.assetRepository.createManagedStorageDeletionPolicy(ownerId, roots, identities);
    } else if (policy.authorizationMode !== 'storage' && policy.enabled) {
      // Carry forward consent only for the SAME persisted physical storage.
      // A legacy->storage transition must not silently authorize a replacement root.
      const current = await refreshStorageRootIdentities(policy.rootIdentities);
      await this.validateOwnerRootBoundaries(ownerId, policy.roots, current, 'managed');
      await assertWritableDeletionRoots(current);
      await this.assetRepository.setDeletionPolicy(ownerId, 'managed', {
        authorizationMode: 'storage',
        enabled: true,
        roots: policy.roots,
        rootIdentities: current,
        recoveryProof: '',
        recoveryExpiresAt: null,
        authorizedBy: ownerId,
      });
      policy = await this.assetRepository.getDeletionPolicy(ownerId, 'managed');
    }
    return policy;
  }

  private async checkStoragePolicy(
    owner: string,
    scope: string,
    policy: NonNullable<Awaited<ReturnType<typeof this.assetRepository.getDeletionPolicy>>>,
  ) {
    if (policy.authorizedBy !== owner || policy.rootIdentities.length === 0)
      throw new DeletionError('LIBRARY_DELETION_NOT_AUTHORIZED');
    const current = await refreshStorageRootIdentities(policy.rootIdentities);
    await this.validateOwnerRootBoundaries(owner, policy.roots, current, scope);
    await assertWritableDeletionRoots(current);
  }

  private async checkCurrentPolicy(
    owner: string,
    scope: string,
    policy: Awaited<ReturnType<typeof this.assetRepository.getDeletionPolicy>>,
  ) {
    if (!policy?.enabled || (scope !== 'managed' && policy.authorizedBy !== owner))
      throw new DeletionError('LIBRARY_DELETION_NOT_AUTHORIZED');
    if (policy.authorizationMode === 'storage') {
      await this.checkStoragePolicy(owner, scope, policy);
      return;
    }
    if (policy.rootIdentities.length === 0 || !policy.recoveryExpiresAt)
      throw new DeletionError('MANAGED_DELETION_PREPARATION_REQUIRED');
    if (new Date(policy.recoveryExpiresAt).getTime() <= Date.now())
      throw new DeletionError('DELETION_RECOVERY_EXPIRED');
    const current = await collectRootIdentities(policy.roots);
    if (
      current.length !== policy.rootIdentities.length ||
      current.some((r) => policy.rootIdentities.every((p) => !sameRootIdentity(r, p)))
    )
      throw new DeletionError('DELETION_ROOT_CHANGED');
    await this.validateOwnerRootBoundaries(owner, policy.roots, policy.rootIdentities, scope);
    await verifyRecoveryEvidence(policy.recoveryProof, owner, scope, current);
  }

  private async validateOwnerRootBoundaries(
    owner: string,
    roots: string[],
    bound: DeletionRootIdentity[],
    scope: string,
    allowMotionRoot = false,
  ) {
    let allowed: Set<string>;
    if (scope === 'managed') {
      const user = await this.userRepository.get(owner, {});
      if (!user) throw new DeletionError('ASSET_NOT_OWNED');
      allowed = new Set([
        StorageCore.getFolderLocation(StorageFolder.Upload, owner),
        StorageCore.getLibraryFolder(user),
        ...(allowMotionRoot ? [StorageCore.getFolderLocation(StorageFolder.EncodedVideo, owner)] : []),
      ]);
    } else {
      const library = await this.libraryRepository.get(scope);
      if (!library || library.ownerId !== owner || library.deletedAt)
        throw new DeletionError('LIBRARY_DELETION_NOT_AUTHORIZED');
      allowed = new Set([
        ...library.importPaths,
        ...(allowMotionRoot ? [StorageCore.getFolderLocation(StorageFolder.EncodedVideo, owner)] : []),
      ]);
    }
    if (roots.some((root) => !allowed.has(root))) throw new DeletionError('DELETION_ROOT_CHANGED');
    const others = await this.assetRepository.getDeletionRootsForOtherOwners(owner);
    const otherRoots = [
      ...others.external,
      ...others.users.flatMap((other) => [
        StorageCore.getFolderLocation(StorageFolder.Upload, other.id),
        StorageCore.getLibraryFolder(other),
        StorageCore.getFolderLocation(StorageFolder.EncodedVideo, other.id),
      ]),
    ];
    const current = await this.storageRepository.validateDeletionRoots(roots, otherRoots);
    if (
      current.length !== bound.length ||
      current.some((root) => bound.every((stored) => !sameRootIdentity(root, stored)))
    )
      throw new DeletionError('DELETION_ROOT_CHANGED');
  }

  async deletionPreflight(auth: AuthDto, ids: string[], allowActive = false): Promise<DeletionPreflightResultDto[]> {
    const results: DeletionPreflightResultDto[] = [];
    for (const id of new Set(ids)) {
      let scope: string | undefined;
      try {
        const receipt = await this.assetRepository.getDeletionReceipt(auth.user.id, id);
        if (!receipt) {
          try {
            await this.requireAccess({ auth, permission: Permission.AssetDelete, ids: [id] });
          } catch {
            throw new DeletionError('ASSET_NOT_OWNED');
          }
        }
        scope = await this.assetRepository.getDeletionScope(auth.user.id, id, allowActive);
        if (!scope) throw new DeletionError('ASSET_NOT_IN_TRASH');
        const policy =
          scope === 'managed'
            ? await this.ensureManagedStoragePolicy(auth.user.id)
            : await this.assetRepository.getDeletionPolicy(auth.user.id, scope);
        if (receipt?.state !== 'complete') await this.checkCurrentPolicy(auth.user.id, scope, policy);
        results.push({ id, scope, authorized: true });
      } catch (error) {
        results.push({
          id,
          scope,
          authorized: false,
          code: error instanceof ForbiddenException ? 'ASSET_NOT_OWNED' : deletionCode(error),
        });
      }
    }
    return results;
  }

  async deletionStatus(auth: AuthDto, id: string): Promise<PermanentDeletionResultDto> {
    const receipt = await this.assetRepository.getDeletionReceipt(auth.user.id, id);
    if (!receipt) {
      return { id, state: 'blocked', code: 'NO_AUTHORIZED_DELETION' };
    }
    const targets = await this.assetRepository.getPermanentDeletionTargets(receipt.operationId);
    const states = await Promise.all(
      targets.map(({ assetId }) => this.assetRepository.getDeletionReceipt(auth.user.id, assetId)),
    );
    const failed = states.find((item) => item?.state === 'failed');
    if (failed) {
      return { id, state: 'failed', code: failed.errorCode ?? 'PAIRED_DELETION_INCOMPLETE' };
    }
    return { id, state: states.every((item) => item?.state === 'complete') ? 'complete' : 'pending' };
  }

  async deletionBatchStatus(auth: AuthDto, batchId: string): Promise<PermanentDeletionBatchStatusDto> {
    const batch = await this.jobRepository.getAssetDeleteBatchJob(batchId);
    if (
      !batch ||
      batch.ownerId !== auth.user.id ||
      batch.id !== getAssetDeleteBatchJobId(batch.ownerId, batch.ids, batch.allowActive)
    ) {
      throw new ForbiddenException('Deletion batch is not available for this user');
    }

    const statuses = await Promise.all(batch.ids.map((id) => this.deletionStatus(auth, id)));
    const complete = statuses.filter((item) => item.state === 'complete').length;
    const failed = statuses.filter(
      (item) => item.state === 'failed' || (item.state === 'blocked' && ['complete', 'failed'].includes(batch.state)),
    ).length;
    const pending = statuses.length - complete - failed;
    const state =
      batch.state === 'cancelled'
        ? 'cancelled'
        : failed > 0 && pending === 0
          ? 'failed'
          : pending === 0
            ? 'complete'
            : batch.state === 'active'
              ? 'active'
              : 'pending';
    return { id: batch.id, state, total: statuses.length, processed: complete + failed, complete, failed, pending };
  }

  async permanentlyDelete(
    auth: AuthDto,
    ids: string[],
    allowActive = false,
    allowBatchQueue = true,
  ): Promise<PermanentDeletionResultDto[]> {
    const preflight = await this.deletionPreflight(auth, ids, allowActive);
    if (preflight.some((item) => !item.authorized)) {
      // No new journal, hashing, worker, or unlink before every scope is admitted.
      return Promise.all(
        preflight.map(async (item): Promise<PermanentDeletionResultDto> => {
          const receipt = await this.assetRepository.getDeletionReceipt(auth.user.id, item.id);
          return receipt?.state === 'complete'
            ? { id: item.id, state: 'complete', scope: item.scope }
            : { id: item.id, state: 'blocked', scope: item.scope, code: item.code ?? 'DELETION_BATCH_NOT_AUTHORIZED' };
        }),
      );
    }
    const uniqueIds = [...new Set(ids)];
    if (allowBatchQueue && uniqueIds.length > AssetService.INLINE_PERMANENT_DELETION_LIMIT) {
      await this.jobRepository.queue({
        name: JobName.AssetDeleteBatch,
        data: { ownerId: auth.user.id, ids: uniqueIds, allowActive },
      });
      return preflight.map((item) => ({
        id: item.id,
        scope: item.scope,
        state: 'pending' as const,
        code: 'DELETION_BATCH_QUEUED',
        batchId: getAssetDeleteBatchJobId(auth.user.id, uniqueIds, allowActive),
      }));
    }
    const results: PermanentDeletionResultDto[] = [];
    for (const id of uniqueIds) {
      try {
        const previous = await this.assetRepository.getDeletionReceipt(auth.user.id, id);
        if (!previous) {
          await this.requireAccess({ auth, permission: Permission.AssetDelete, ids: [id] });
        }
        const snapshot = (path: string, roots: DeletionRootIdentity[]) =>
          this.storageRepository.snapshotOriginal(path, roots);
        if (allowActive)
          await this.assetRepository.preparePermanentDeletion(id, auth.user.id, snapshot, undefined, true);
        else await this.assetRepository.preparePermanentDeletion(id, auth.user.id, snapshot);
        // Publish durable worker retries before inline completion. An interrupted
        // request can finish through the ordinary queue or receipt recovery sweep.
        const targets = await this.assetRepository.getPermanentDeletionTargets(id);
        for (const target of targets)
          await this.jobRepository.queue({
            name: JobName.AssetDelete,
            data: {
              id: target.assetId,
              deleteOnDisk: true,
              deletionId: target.assetId,
            },
          });
        // Existing AssetDelete lifecycle: one row remover owns all row effects.
        for (const target of targets) {
          const receipt = await this.assetRepository.getDeletionReceipt(auth.user.id, target.assetId);
          if (receipt?.state !== 'complete') {
            await this.handleAssetDeletion({ id: target.assetId, deleteOnDisk: true, deletionId: target.assetId });
          }
        }
        results.push({
          ...(await this.deletionStatus(auth, id)),
          scope: preflight.find((item) => item.id === id)?.scope,
        });
      } catch (error) {
        const receipt = await this.assetRepository.getDeletionReceipt(auth.user.id, id);
        results.push({
          ...(receipt
            ? await this.deletionStatus(auth, id)
            : { id, state: 'blocked' as const, code: deletionCode(error) }),
          scope: preflight.find((item) => item.id === id)?.scope,
        });
      }
    }
    return results;
  }

  async getMetadata(auth: AuthDto, id: string): Promise<AssetMetadataResponseDto[]> {
    await this.requireAccess({ auth, permission: Permission.AssetRead, ids: [id] });
    return this.assetRepository.getMetadata(id);
  }

  async getOcr(auth: AuthDto, id: string): Promise<AssetOcrResponseDto[]> {
    await this.requireAccess({ auth, permission: Permission.AssetRead, ids: [id] });
    const ocr = await this.ocrRepository.getByAssetId(id);
    const asset = await this.assetRepository.getForOcr(id);

    if (!asset) {
      throw new BadRequestException('Asset not found');
    }

    const dimensions = getDimensions({
      exifImageHeight: asset.exifImageHeight,
      exifImageWidth: asset.exifImageWidth,
      orientation: asset.orientation,
    });

    return ocr.map((item) => transformOcrBoundingBox(item, asset.edits, dimensions));
  }

  async upsertBulkMetadata(auth: AuthDto, dto: AssetMetadataBulkUpsertDto): Promise<AssetMetadataBulkResponseDto[]> {
    await this.requireAccess({ auth, permission: Permission.AssetUpdate, ids: dto.items.map((item) => item.assetId) });

    const uniqueKeys = new Set<string>();
    for (const item of dto.items) {
      const key = `(${item.assetId}, ${item.key})`;
      if (uniqueKeys.has(key)) {
        throw new BadRequestException(`Duplicate items are not allowed: "${key}"`);
      }

      uniqueKeys.add(key);
    }

    return this.assetRepository.upsertBulkMetadata(dto.items);
  }

  async upsertMetadata(auth: AuthDto, id: string, dto: AssetMetadataUpsertDto): Promise<AssetMetadataResponseDto[]> {
    await this.requireAccess({ auth, permission: Permission.AssetUpdate, ids: [id] });

    const uniqueKeys = new Set<string>();
    for (const { key } of dto.items) {
      if (uniqueKeys.has(key)) {
        throw new BadRequestException(`Duplicate items are not allowed: "${key}"`);
      }

      uniqueKeys.add(key);
    }

    return this.assetRepository.upsertMetadata(id, dto.items);
  }

  async getMetadataByKey(auth: AuthDto, id: string, key: string): Promise<AssetMetadataResponseDto> {
    await this.requireAccess({ auth, permission: Permission.AssetRead, ids: [id] });

    const item = await this.assetRepository.getMetadataByKey(id, key);
    if (!item) {
      throw new BadRequestException(`Metadata with key "${key}" not found for asset with id "${id}"`);
    }
    return item;
  }

  async deleteMetadataByKey(auth: AuthDto, id: string, key: string): Promise<void> {
    await this.requireAccess({ auth, permission: Permission.AssetUpdate, ids: [id] });
    return this.assetRepository.deleteMetadataByKey(id, key);
  }

  async deleteBulkMetadata(auth: AuthDto, dto: AssetMetadataBulkDeleteDto) {
    await this.requireAccess({ auth, permission: Permission.AssetUpdate, ids: dto.items.map((item) => item.assetId) });
    await this.assetRepository.deleteBulkMetadata(dto.items);
  }

  async run(auth: AuthDto, dto: AssetJobsDto) {
    await this.requireAccess({ auth, permission: Permission.AssetUpdate, ids: dto.assetIds });

    const jobs: JobItem[] = [];

    for (const id of dto.assetIds) {
      switch (dto.name) {
        case AssetJobName.REFRESH_FACES: {
          jobs.push({ name: JobName.AssetDetectFaces, data: { id } });
          break;
        }

        case AssetJobName.REFRESH_METADATA: {
          jobs.push({ name: JobName.AssetExtractMetadata, data: { id } });
          break;
        }

        case AssetJobName.REGENERATE_THUMBNAIL: {
          jobs.push({ name: JobName.AssetGenerateThumbnails, data: { id } });
          break;
        }

        case AssetJobName.TRANSCODE_VIDEO: {
          jobs.push({ name: JobName.AssetEncodeVideo, data: { id } });
          break;
        }
      }
    }

    await this.jobRepository.queueAll(jobs);
  }

  private findOrFail(id: string) {
    return findOrFail(() => this.assetRepository.getById(id), 'Asset');
  }

  private async updateExif(dto: {
    id: string;
    description?: string;
    dateTimeOriginal?: string;
    latitude?: number;
    longitude?: number;
    rating?: number | null;
  }) {
    const { id, description, dateTimeOriginal, latitude, longitude, rating } = dto;

    // When latitude/longitude are updated manually, reverse-geocode them so country/state/city
    // stay in sync. Otherwise the asset shows on the map (which only needs lat/lon) but is
    // missing from location-based filters and search (which scope by country/city).
    let geo: { country: string | null; state: string | null; city: string | null } | undefined;
    if (latitude !== undefined && longitude !== undefined) {
      geo = await this.mapRepository.reverseGeocode({ latitude, longitude });
    }

    const writes = omitBy(
      {
        description,
        dateTimeOriginal,
        timeZone: extractTimeZone(dateTimeOriginal)?.name,
        latitude,
        longitude,
        rating,
        ...geo,
      },
      isUndefined,
    );

    if (Object.keys(writes).length > 0) {
      await this.assetRepository.upsertExif({
        exif: updateLockedColumns({
          assetId: id,
          ...writes,
        }),
        lockedPropertiesBehavior: 'append',
      });
      await this.jobRepository.queue({ name: JobName.SidecarWrite, data: { id } });
    }
  }

  async getAssetEdits(auth: AuthDto, id: string): Promise<AssetEditsResponseDto> {
    await this.requireAccess({ auth, permission: Permission.AssetRead, ids: [id] });
    const edits = await this.assetEditRepository.getAll(id);

    return {
      assetId: id,
      edits,
    };
  }

  async editAsset(auth: AuthDto, id: string, dto: AssetEditsCreateDto): Promise<AssetEditsResponseDto> {
    await this.requireAccess({ auth, permission: Permission.AssetEditCreate, ids: [id] });

    const asset = await this.assetRepository.getForEdit(id);
    if (!asset) {
      throw new BadRequestException('Asset not found');
    }

    const edits = dto.edits as AssetEditActionItem[];
    const hasTrim = edits.some((e) => e.action === AssetEditAction.Trim);
    const hasSpatial = edits.some((e) =>
      [AssetEditAction.Crop, AssetEditAction.Rotate, AssetEditAction.Mirror].includes(e.action),
    );

    // Reject mixed spatial + trim edits
    if (hasTrim && hasSpatial) {
      throw new BadRequestException('Cannot combine trim with spatial edits');
    }

    if (hasTrim) {
      // Video trim validation
      if (asset.type !== AssetType.Video) {
        throw new BadRequestException('Trim is only supported for video assets');
      }

      if (asset.livePhotoVideoId) {
        throw new BadRequestException('Trimming live photos is not supported');
      }

      // Block external-library videos: absolute paths outside the media location.
      // S3-backed originals are relative keys, resolved through the storage backend.
      if (isAbsolute(asset.originalPath) && !StorageCore.isImmichPath(asset.originalPath)) {
        throw new BadRequestException('Video trimming is not available for external library videos');
      }

      // Audio-only file check. getProbeInput hands ffprobe an absolute path (disk) or a
      // presigned URL (S3) — it does NOT download the video, which matters here because
      // this runs inside the request.
      let probeResult: Awaited<ReturnType<typeof this.mediaRepository.probe>>;
      try {
        probeResult = await this.mediaRepository.probe(await this.getProbeInput(asset.originalPath));
      } catch {
        // Never surface or log the raw ffprobe error: for S3 originals getProbeInput yields a
        // presigned URL (a bearer credential) that ffprobe echoes in its stderr, which would
        // otherwise leak into error logs. Log only the asset id.
        this.logger.error(`Failed to probe video for trim (asset ${id})`);
        throw new BadRequestException('Unable to read video for trimming');
      }
      if (!probeResult.videoStreams || probeResult.videoStreams.length === 0) {
        throw new BadRequestException('Cannot trim audio-only files');
      }

      // When re-trimming, asset.duration reflects the previous trim.
      // Use originalDuration from the existing trim edit if available.
      const existingEdits = await this.assetEditRepository.getAll(id);
      const existingTrim = existingEdits.find((e) => e.action === AssetEditAction.Trim);
      const existingOriginalDuration = existingTrim
        ? (existingTrim.parameters as TrimParameters & { originalDuration?: number }).originalDuration
        : undefined;

      const durationSeconds = existingOriginalDuration ?? (asset.duration === null ? null : asset.duration / 1000);
      if (durationSeconds === null || durationSeconds <= 0) {
        throw new BadRequestException('Video duration is not available');
      }

      // Very short video check (against original duration)
      if (durationSeconds < 2) {
        throw new BadRequestException('Video is too short to trim (minimum 2 seconds)');
      }

      const trim = edits.find((e) => e.action === AssetEditAction.Trim)!;
      const { startTime, endTime } = trim.parameters as TrimParameters;

      if (endTime > durationSeconds) {
        throw new BadRequestException('End time exceeds video duration');
      }

      if (startTime === 0 && endTime >= durationSeconds && !existingTrim) {
        throw new BadRequestException('Trim must actually remove content');
      }

      // Enrich with originalDuration before storing (preserve original, not current trimmed)
      (trim.parameters as TrimParameters & { originalDuration: number }).originalDuration = durationSeconds;
    } else {
      // Existing image validation
      if (asset.type !== AssetType.Image) {
        throw new BadRequestException('Only images can be edited');
      }

      if (asset.livePhotoVideoId) {
        throw new BadRequestException('Editing live photos is not supported');
      }

      if (isPanorama(asset)) {
        throw new BadRequestException('Editing panorama images is not supported');
      }

      if (asset.originalPath?.toLowerCase().endsWith('.gif')) {
        throw new BadRequestException('Editing GIF images is not supported');
      }

      if (asset.originalPath?.toLowerCase().endsWith('.svg')) {
        throw new BadRequestException('Editing SVG images is not supported');
      }

      // Crop bounds validation
      const { width: assetWidth, height: assetHeight } = getDimensions(asset);
      if (!assetWidth || !assetHeight) {
        throw new BadRequestException('Asset dimensions are not available for editing');
      }

      const crop = edits.find((e) => e.action === AssetEditAction.Crop);
      if (crop) {
        if (edits[0].action !== AssetEditAction.Crop) {
          throw new BadRequestException('Crop action must be the first edit action');
        }

        const { x, y, width, height } = crop.parameters;
        if (x + width > assetWidth || y + height > assetHeight) {
          throw new BadRequestException('Crop parameters are out of bounds');
        }
      }
    }

    const newEdits = await this.assetEditRepository.replaceAll(id, edits);
    await this.jobRepository.queue({ name: JobName.AssetEditThumbnailGeneration, data: { id } });

    return {
      assetId: id,
      edits: newEdits,
    };
  }

  async removeAssetEdits(auth: AuthDto, id: string): Promise<void> {
    await this.requireAccess({ auth, permission: Permission.AssetEditDelete, ids: [id] });

    const asset = await this.assetRepository.getById(id);
    if (!asset) {
      throw new BadRequestException('Asset not found');
    }

    // Read existing edits to check for trim (need originalDuration for restore)
    const existingEdits = await this.assetEditRepository.getAll(id);
    const trimEdit = existingEdits.find((e) => e.action === AssetEditAction.Trim);
    if (trimEdit) {
      const params = trimEdit.parameters as TrimParameters & { originalDuration?: number };
      if (params.originalDuration) {
        const restoredDuration = Math.round(params.originalDuration * 1000);
        await this.assetRepository.update({ id, duration: restoredDuration });
      }
    }

    await this.assetEditRepository.replaceAll(id, []);
    await this.jobRepository.queue({ name: JobName.AssetEditThumbnailGeneration, data: { id } });
  }
}
