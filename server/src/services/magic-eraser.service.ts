import {
  BadRequestException,
  ConflictException,
  Inject,
  Injectable,
  NotFoundException,
  OnModuleDestroy,
  OnModuleInit,
  ServiceUnavailableException,
} from '@nestjs/common';
import { copyFile, rm, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { Readable } from 'node:stream';
import sanitize from 'sanitize-filename';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetMediaResponseDto } from 'src/dtos/asset-media-response.dto.js';
import { AuthDto } from 'src/dtos/auth.dto.js';
import {
  MAGIC_ERASER_LIMITS,
  MagicEraserCapabilitiesDto,
  MagicEraserCreateDto,
  MagicEraserJobResponseDto,
} from 'src/dtos/magic-eraser.dto.js';
import { AssetType, CacheControl, ImmichWorker, Permission, StorageFolder } from 'src/enum.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import {
  InpaintingError,
  MAGIC_ERASER_TTL_MS,
  MagicEraserRepository,
} from 'src/repositories/magic-eraser.repository.js';
import { AssetMediaService } from 'src/services/asset-media.service.js';
import { BaseService } from 'src/services/base.service.js';
import { ImmichStreamResponse } from 'src/utils/file.js';

type Source = NonNullable<Awaited<ReturnType<AssetRepository['getById']>>>;
type Job = MagicEraserJobResponseDto & {
  ownerId: string;
  source: Source;
  controller: AbortController;
  expiresAt: number;
  directory?: string;
  result?: string;
  previewPath?: string;
  metadataWritten?: boolean;
  uploadResponse?: AssetMediaResponseDto;
  savePromise?: Promise<AssetMediaResponseDto>;
};

/** Ephemeral editing sessions on one API process, with one bounded preparation/inference lane. */
@Injectable()
export class MagicEraserService extends BaseService implements OnModuleInit, OnModuleDestroy {
  @Inject(MagicEraserRepository) private eraser!: MagicEraserRepository;
  @Inject(AssetMediaService) private mediaUpload!: AssetMediaService;
  private jobs = new Map<string, Job>();
  private pending = new Set<Job>();
  private lane: Promise<unknown> = Promise.resolve();
  private preparingSource = false;
  private lastOrphanSweep = 0;
  private timer?: ReturnType<typeof setInterval>;

  onModuleInit() {
    if (this.worker !== ImmichWorker.Api) {
      return;
    }
    this.timer = setInterval(() => {
      void this.cleanup().catch(() => {});
    }, 60_000);
    this.timer.unref();
  }

  async onModuleDestroy() {
    clearInterval(this.timer);
    for (const job of this.jobs.values()) {
      if (job.savePromise) {
        continue;
      }
      job.status = 'cancelled';
      job.controller.abort();
      await this.eraser.cancel(job.id);
    }
    await this.lane;
    await Promise.allSettled(
      this.jobs
        .values()
        .filter((job) => !!job.savePromise)
        .map((job) => job.savePromise!),
    );
    await Promise.allSettled(
      this.jobs
        .values()
        .filter((job) => !!job.directory)
        .map((job) => this.eraser.removeDirectory(job.directory!)),
    );
  }

  private async sourceAsset(auth: AuthDto, id: string) {
    await this.requireAccess({ auth, permission: Permission.AssetEditGet, ids: [id] });
    const asset = await this.assetRepository.getById(id, { exifInfo: true });
    if (!asset || asset.ownerId !== auth.user.id || asset.deletedAt || asset.isOffline) {
      throw new NotFoundException('Photo not found');
    }
    if (asset.type !== AssetType.Image) {
      throw new BadRequestException('Magic Eraser supports still images only');
    }
    return asset;
  }

  async capabilities(auth: AuthDto, id: string): Promise<MagicEraserCapabilitiesDto> {
    await this.sourceAsset(auth, id);
    return { enabled: await this.eraser.isAvailable(), model: 'big-lama', ...MAGIC_ERASER_LIMITS, saveCopyOnly: true };
  }

  async source(auth: AuthDto, id: string) {
    const asset = await this.sourceAsset(auth, id);
    if (!(await this.eraser.isAvailable())) {
      throw new ServiceUnavailableException('Magic Eraser is unavailable');
    }
    // Reject rather than queue repeated preview reads behind expensive jobs.
    if (this.preparingSource || this.jobs.values().some((job) => ['queued', 'processing'].includes(job.status))) {
      throw new ConflictException('Magic Eraser is busy');
    }
    this.preparingSource = true;
    const prepared = this.lane
      .catch(() => {})
      .then(async () => {
        let directory: string | undefined;
        const local = await this.ensureLocalFile(asset.originalPath);
        try {
          directory = await this.eraser.createDirectory();
          const normalized = join(directory, 'original.jpg');
          await this.eraser.normalize(local.localPath, normalized);
          return this.image(await this.eraser.preview(normalized));
        } finally {
          await Promise.allSettled([local.cleanup(), directory && this.eraser.removeDirectory(directory)]);
        }
      });
    this.lane = prepared.catch(() => {});
    try {
      return await prepared;
    } finally {
      this.preparingSource = false;
    }
  }

  async create(auth: AuthDto, id: string, dto: MagicEraserCreateDto) {
    await this.requireAccess({ auth, permission: Permission.AssetEditCreate, ids: [id] });
    const source = await this.sourceAsset(auth, id);
    await this.cleanup();
    if (!(await this.eraser.isAvailable())) {
      throw new ServiceUnavailableException('Magic Eraser is unavailable');
    }
    if (this.jobs.size >= 16) {
      for (const [oldId, oldJob] of this.jobs) {
        if (
          !['cancelled', 'failed', 'saved'].includes(oldJob.status) ||
          this.pending.has(oldJob) ||
          oldJob.savePromise
        ) {
          continue;
        }
        this.jobs.delete(oldId);
        if (oldJob.directory) {
          await this.eraser.removeDirectory(oldJob.directory);
        }
      }
    }
    const ownActive = this.jobs
      .values()
      .some((job) => ['queued', 'processing'].includes(job.status) && job.ownerId === auth.user.id);
    if (this.pending.size >= 4 || ownActive || this.jobs.size >= 16) {
      throw new ConflictException('Magic Eraser queue is full');
    }
    const job: Job = {
      id: this.cryptoRepository.randomUUID(),
      status: 'queued',
      ownerId: auth.user.id,
      source,
      controller: new AbortController(),
      expiresAt: Date.now() + MAGIC_ERASER_TTL_MS,
    };
    this.jobs.set(job.id, job);
    this.pending.add(job);
    this.lane = this.lane
      .catch(() => {})
      .then(() => this.process(job, dto))
      .finally(() => {
        this.pending.delete(job);
      });
    return this.response(job);
  }

  private async process(job: Job, dto: MagicEraserCreateDto) {
    if (job.controller.signal.aborted) {
      return;
    }
    job.status = 'processing';
    let local: { localPath: string; cleanup: () => Promise<void> } | undefined;
    try {
      local = await this.ensureLocalFile(job.source.originalPath);
      if (job.controller.signal.aborted) {
        return;
      }
      job.directory = await this.eraser.createDirectory();
      const input = join(job.directory, 'original.jpg');
      const result = join(job.directory, 'result.jpg');
      await this.eraser.normalize(local.localPath, input);
      if (job.controller.signal.aborted) {
        return;
      }
      await this.eraser.inpaint(job.id, input, result, dto, job.controller.signal);
      if (!job.controller.signal.aborted) {
        const preview = join(job.directory, 'preview.jpg');
        await this.eraser.writePreview(result, preview);
        if (job.controller.signal.aborted) {
          return;
        }
        job.result = result;
        job.previewPath = preview;
        job.status = 'ready';
        job.expiresAt = Date.now() + MAGIC_ERASER_TTL_MS;
      }
    } catch (error) {
      if (!job.controller.signal.aborted) {
        job.status = 'failed';
        job.errorCode = error instanceof InpaintingError ? error.code : 'processing_failed';
      }
    } finally {
      await local?.cleanup().catch(() => {});
      // A cancellation can arrive during S3 cleanup after the result becomes ready.
      // Check again after that await so a discarded result is removed promptly.
      if (job.directory && !['ready', 'saved'].includes(job.status)) {
        await this.eraser.removeDirectory(job.directory).catch(() => {});
        job.directory = undefined;
      }
    }
  }

  private response(job: Job): MagicEraserJobResponseDto {
    return {
      id: job.id,
      status: job.status,
      ...(job.assetId && { assetId: job.assetId }),
      ...(job.errorCode && { errorCode: job.errorCode }),
    };
  }

  private async getJob(auth: AuthDto, id: string, jobId: string) {
    await this.sourceAsset(auth, id);
    await this.cleanup();
    const job = this.jobs.get(jobId);
    if (!job || job.ownerId !== auth.user.id || job.source.id !== id) {
      throw new NotFoundException('Editing session expired or not found');
    }
    return job;
  }

  async status(auth: AuthDto, id: string, jobId: string) {
    return this.response(await this.getJob(auth, id, jobId));
  }

  async preview(auth: AuthDto, id: string, jobId: string) {
    const job = await this.getJob(auth, id, jobId);
    if (!job.previewPath || !['ready', 'saved'].includes(job.status)) {
      throw new ConflictException('Result is not ready');
    }
    // Full-resolution decoding was already serialized with inference; HTTP reads only the small preview.
    return this.image(await this.eraser.readPreview(job.previewPath));
  }

  private image(bytes: Buffer) {
    return new ImmichStreamResponse({
      stream: Readable.from(bytes),
      length: bytes.length,
      contentType: 'image/jpeg',
      cacheControl: CacheControl.PrivateWithoutCache,
    });
  }

  async cancel(auth: AuthDto, id: string, jobId: string) {
    const job = await this.getJob(auth, id, jobId);
    if (job.savePromise) {
      throw new ConflictException('Copy is being saved');
    }
    if (job.status === 'saved') {
      return this.response(job);
    }
    const wasActive = this.pending.has(job);
    job.status = 'cancelled';
    job.controller.abort();
    await this.eraser.cancel(jobId);
    if (!wasActive && job.directory) {
      await this.eraser.removeDirectory(job.directory);
      job.directory = undefined;
    }
    return this.response(job);
  }

  async save(auth: AuthDto, id: string, jobId: string): Promise<AssetMediaResponseDto> {
    const job = await this.getJob(auth, id, jobId);
    if (job.uploadResponse) {
      return job.uploadResponse;
    }
    if (job.savePromise) {
      return job.savePromise;
    }
    if (job.status !== 'ready' || !job.result) {
      throw new ConflictException('Result is not ready');
    }
    job.savePromise = this.saveCopy(auth, job);
    try {
      return await job.savePromise;
    } finally {
      job.savePromise = undefined;
    }
  }

  private async saveCopy(auth: AuthDto, job: Job) {
    const source = job.source;
    const date = new Date(source.exifInfo?.dateTimeOriginal ?? source.fileCreatedAt);
    if (!job.metadataWritten) {
      await this.eraser.writeCopyMetadata(job.result!, { ...source.exifInfo, dateTimeOriginal: date }, date);
      job.metadataWritten = true;
    }
    // New staging path per attempt avoids a delayed upload-error cleanup deleting a retry.
    // Bytes/metadata remain stable, so the normal checksum constraint deduplicates lost responses.
    const uuid = this.cryptoRepository.randomUUID();
    const path = StorageCore.getNestedPath(StorageFolder.Upload, auth.user.id, `${uuid}.jpg`);
    this.storageCore.ensureFolders(path);
    const filename = `${sanitize(source.originalFileName.replace(/\.[^.]*$/, '')).slice(0, 160) || 'photo'}-magic-eraser.jpg`;
    let file;
    try {
      await copyFile(job.result!, path);
      const details = await stat(path);
      file = {
        uuid,
        originalPath: path,
        originalName: filename,
        checksum: await this.cryptoRepository.hashFile(path),
        size: details.size,
      };
    } catch (error) {
      await rm(path, { force: true });
      throw error;
    }
    const response = await this.mediaUpload.uploadAsset(
      auth,
      {
        fileCreatedAt: date,
        fileModifiedAt: source.fileModifiedAt,
        filename,
        visibility: source.visibility,
        metadata: [
          {
            key: 'gallery.magicEraser',
            value: {
              sourceAssetId: source.id,
              sourceTimeZone: source.exifInfo?.timeZone ?? null,
              model: 'big-lama',
              jobId: job.id,
              stillOnly: true,
            },
          },
        ],
      },
      file,
    );
    job.uploadResponse = response;
    job.assetId = response.id;
    job.status = 'saved';
    return response;
  }

  private async cleanup() {
    for (const [id, job] of this.jobs) {
      if (job.expiresAt >= Date.now() || job.savePromise) {
        continue;
      }
      const wasProcessing = this.pending.has(job);
      job.status = 'cancelled';
      job.controller.abort();
      this.jobs.delete(id);
      await this.eraser.cancel(id);
      if (!wasProcessing && job.directory) {
        await this.eraser.removeDirectory(job.directory);
      }
    }
    if (Date.now() - this.lastOrphanSweep >= 60_000) {
      // Status polling must not scan the whole temp directory each second. Reserve
      // the sweep synchronously; concurrent polls reuse the same maintenance budget.
      this.lastOrphanSweep = Date.now();
      await this.eraser
        .cleanOrphans(
          new Set(
            this.jobs
              .values()
              .filter((job) => !!job.directory)
              .map((job) => job.directory!),
          ),
        )
        .catch(() => {});
    }
  }
}
