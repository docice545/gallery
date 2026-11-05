import { ConflictException, NotFoundException, ServiceUnavailableException } from '@nestjs/common';
import { createHash, randomUUID } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { mkdtemp, readFile, readdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetMediaStatus } from 'src/dtos/asset-media-response.dto.js';
import { AssetType, AssetVisibility, ImmichWorker } from 'src/enum.js';
import { InpaintingError } from 'src/repositories/magic-eraser.repository.js';
import { MagicEraserService } from 'src/services/magic-eraser.service.js';
import { AssetExifFactory } from 'test/factories/asset-exif.factory.js';
import { AssetFactory } from 'test/factories/asset.factory.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { getForAsset } from 'test/mappers.js';
import { ServiceMocks, newTestService } from 'test/utils.js';

const mask = { strokes: [{ points: [{ x: 0.5, y: 0.4 }], radius: 0.05, erase: false }] };
type Internals = { lane: Promise<unknown>; jobs: Map<string, { expiresAt: number }> };

describe(MagicEraserService.name, () => {
  let sut: MagicEraserService;
  let mocks: ServiceMocks;
  let root: string;
  let asset: ReturnType<typeof AssetFactory.create>;
  const eraser = {
    isAvailable: vi.fn(),
    createDirectory: vi.fn(),
    normalize: vi.fn(),
    preview: vi.fn(),
    inpaint: vi.fn(),
    cancel: vi.fn(),
    removeDirectory: vi.fn(),
    cleanOrphans: vi.fn(),
    writeCopyMetadata: vi.fn(),
    writePreview: vi.fn(),
    readPreview: vi.fn(),
  };
  const mediaUpload = { uploadAsset: vi.fn() };
  const finish = () => (sut as unknown as Internals).lane;

  beforeEach(async () => {
    vi.resetAllMocks();
    root = await mkdtemp(join(tmpdir(), 'eraser-service-test-'));
    ({ sut, mocks } = newTestService(MagicEraserService));
    StorageCore.setMediaLocation(root);
    Object.assign(sut, {
      eraser,
      mediaUpload,
      storageCore: { ensureFolders: (path: string) => mkdirSync(dirname(path), { recursive: true }) },
    });
    asset = AssetFactory.create({
      ownerId: authStub.admin.user.id,
      originalPath: join(root, 'server-original.jpg'),
      livePhotoVideoId: randomUUID(),
      stackId: randomUUID(),
    });
    asset.exifInfo = AssetExifFactory.create({
      assetId: asset.id,
      dateTimeOriginal: new Date('2020-02-03T10:20:30Z'),
      timeZone: 'UTC+3',
      livePhotoCID: 'original-pair',
    });
    await writeFile(asset.originalPath, 'NAS original unchanged');
    mocks.asset.getById.mockResolvedValue(getForAsset(asset));
    mocks.access.asset.checkOwnerAccess.mockImplementation((_owner, ids) => Promise.resolve(new Set(ids)));
    mocks.crypto.randomUUID.mockImplementation(randomUUID);
    mocks.crypto.hashFile.mockImplementation(async (path) =>
      createHash('sha1')
        .update(await readFile(path))
        .digest(),
    );
    eraser.isAvailable.mockResolvedValue(true);
    eraser.createDirectory.mockImplementation(() => mkdtemp(join(root, 'session-')));
    eraser.normalize.mockImplementation(async (_input, output) => {
      await writeFile(output, 'upright jpeg');
      return { width: 400, height: 300 };
    });
    eraser.inpaint.mockImplementation(async (_id, _input, output) => {
      await writeFile(output, 'AI still result');
    });
    eraser.preview.mockResolvedValue(Buffer.from('bounded preview'));
    eraser.writePreview.mockImplementation(async (_source, output) => {
      await writeFile(output, 'small preview');
    });
    eraser.readPreview.mockImplementation(readFile);
    eraser.removeDirectory.mockImplementation((directory) => rm(directory, { recursive: true, force: true }));
    eraser.cancel.mockResolvedValue(undefined);
    eraser.cleanOrphans.mockResolvedValue(undefined);
    eraser.writeCopyMetadata.mockResolvedValue(undefined);
    mediaUpload.uploadAsset.mockResolvedValue({ id: randomUUID(), status: AssetMediaStatus.CREATED });
  });

  afterEach(async () => {
    vi.useRealTimers();
    await sut.onModuleDestroy();
    await rm(root, { recursive: true, force: true });
    vi.restoreAllMocks();
  });

  it('is disabled when the private sidecar is unavailable', async () => {
    eraser.isAvailable.mockResolvedValue(false);
    expect(await sut.capabilities(authStub.admin, asset.id)).toMatchObject({
      enabled: false,
      saveCopyOnly: true,
      model: 'big-lama',
    });
    await expect(sut.create(authStub.admin, asset.id, mask)).rejects.toThrow(ServiceUnavailableException);
    expect(eraser.normalize).not.toHaveBeenCalled();
  });

  it('rejects another owner even when read access exists', async () => {
    mocks.asset.getById.mockResolvedValue({ ...getForAsset(asset), ownerId: randomUUID() });
    await expect(sut.capabilities(authStub.admin, asset.id)).rejects.toThrow(NotFoundException);
    expect(eraser.isAvailable).not.toHaveBeenCalled();
  });

  it('enforces the existing owner/elevated edit permission', async () => {
    mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set());
    await expect(sut.create(authStub.admin, asset.id, mask)).rejects.toThrow('asset.edit.create');
    expect(eraser.inpaint).not.toHaveBeenCalled();
  });

  it.each([{ type: AssetType.Video }, { deletedAt: new Date() }, { isOffline: true }])(
    'rejects unsupported/unavailable source %o',
    async (change) => {
      mocks.asset.getById.mockResolvedValue({ ...getForAsset(asset), ...change });
      await expect(sut.create(authStub.admin, asset.id, mask)).rejects.toThrow();
      expect(eraser.inpaint).not.toHaveBeenCalled();
    },
  );

  it('reads a server-only original directly and returns a bounded oriented preview', async () => {
    const response = await sut.source(authStub.admin, asset.id);
    expect(response.contentType).toBe('image/jpeg');
    expect(eraser.normalize).toHaveBeenCalledWith(asset.originalPath, expect.stringContaining('original.jpg'));
    expect(eraser.removeDirectory).toHaveBeenCalledOnce();
    expect(mediaUpload.uploadAsset).not.toHaveBeenCalled();
  });

  it('releases S3 temporary original even if directory creation fails', async () => {
    const cleanup = vi.fn().mockResolvedValue(undefined);
    Object.assign(sut, { ensureLocalFile: vi.fn().mockResolvedValue({ localPath: '/private-s3-original', cleanup }) });
    eraser.createDirectory.mockRejectedValue(new Error('disk full'));
    await expect(sut.source(authStub.admin, asset.id)).rejects.toThrow('disk full');
    expect(cleanup).toHaveBeenCalledOnce();
  });

  it('still removes editor directory when S3 cleanup rejects', async () => {
    Object.assign(sut, {
      ensureLocalFile: vi
        .fn()
        .mockResolvedValue({ localPath: '/s3-original', cleanup: vi.fn().mockRejectedValue(new Error('gone')) }),
    });
    await sut.source(authStub.admin, asset.id);
    expect(eraser.removeDirectory).toHaveBeenCalledOnce();
  });

  it('reserves source normalization so concurrent previews cannot decode many originals', async () => {
    const gate = Promise.withResolvers<void>();
    eraser.normalize.mockImplementationOnce(() => gate.promise);
    const first = sut.source(authStub.admin, asset.id);
    await vi.waitFor(() => expect(eraser.normalize).toHaveBeenCalledOnce());
    await expect(sut.source(authStub.admin, asset.id)).rejects.toThrow(ConflictException);
    gate.resolve();
    await first;
  });

  it('saves a separate still with the save date and source camera metadata, without stack/live linkage', async () => {
    const savedAt = new Date('2026-11-02T23:55:12.345Z');
    vi.useFakeTimers({ toFake: ['Date'] });
    vi.setSystemTime(new Date('2026-11-02T23:50:00Z'));
    const job = await sut.create(authStub.admin, asset.id, mask);
    expect(job.status).toBe('queued');
    await finish();
    expect(await sut.status(authStub.admin, asset.id, job.id)).toMatchObject({ status: 'ready' });
    vi.setSystemTime(savedAt);
    const response = await sut.save(authStub.admin, asset.id, job.id, { timeZoneOffsetMinutes: -600 });
    vi.useRealTimers();
    expect(response.status).toBe(AssetMediaStatus.CREATED);
    const [, dto, file] = mediaUpload.uploadAsset.mock.calls[0];
    expect(dto.fileCreatedAt).toEqual(savedAt);
    expect(dto.fileModifiedAt).toEqual(savedAt);
    expect(eraser.writeCopyMetadata).toHaveBeenCalledWith(
      expect.any(String),
      expect.objectContaining({ make: asset.exifInfo.make, timeZone: 'UTC+3' }),
      savedAt,
      -600,
    );
    expect(asset.exifInfo.dateTimeOriginal).toEqual(new Date('2020-02-03T10:20:30Z'));
    expect(dto.filename).toMatch(/-magic-eraser\.jpg$/);
    expect(dto.metadata[0]).toMatchObject({
      key: 'gallery.magicEraser',
      value: { sourceAssetId: asset.id, stillOnly: true },
    });
    expect(dto.livePhotoVideoId).toBeUndefined();
    expect(dto.stackId).toBeUndefined();
    expect(file.originalPath).toContain(join(root, 'upload', authStub.admin.user.id));
    expect(await readFile(file.originalPath, 'utf8')).toBe('AI still result');
    expect(await readFile(asset.originalPath, 'utf8')).toBe('NAS original unchanged');
    expect(mocks.asset.update).toHaveBeenCalledExactlyOnceWith({
      id: response.id,
      localDateTime: new Date('2026-11-02T13:55:12.345Z'),
    });
    expect(mocks.assetEdit.replaceAll).not.toHaveBeenCalled();
  });

  it('coalesces simultaneous Save and returns the same saved response on retry', async () => {
    const job = await sut.create(authStub.admin, asset.id, mask);
    await finish();
    const [first, second] = await Promise.all([
      sut.save(authStub.admin, asset.id, job.id),
      sut.save(authStub.admin, asset.id, job.id),
    ]);
    expect(second).toEqual(first);
    expect(await sut.save(authStub.admin, asset.id, job.id)).toEqual(first);
    expect(mediaUpload.uploadAsset).toHaveBeenCalledOnce();
    expect(eraser.writeCopyMetadata).toHaveBeenCalledOnce();
    expect(eraser.writeCopyMetadata.mock.calls[0][3]).toBe(0);
  });

  it.each([AssetVisibility.Locked, AssetVisibility.Hidden, AssetVisibility.Archive])(
    'preserves source %s visibility on the new still copy',
    async (visibility) => {
      asset.visibility = visibility;
      mocks.asset.getById.mockResolvedValue(getForAsset(asset));
      const job = await sut.create(authStub.admin, asset.id, mask);
      await finish();
      await sut.save(authStub.admin, asset.id, job.id);
      expect(mediaUpload.uploadAsset.mock.calls[0][1]).toMatchObject({
        visibility,
        metadata: [{ key: 'gallery.magicEraser', value: { sourceTimeZone: 'UTC+3' } }],
      });
    },
  );

  it('retains the created ID and retries only date finalization after a database failure', async () => {
    mocks.asset.update.mockRejectedValueOnce(new Error('synthetic date update failure'));
    const job = await sut.create(authStub.admin, asset.id, mask);
    await finish();
    await expect(sut.save(authStub.admin, asset.id, job.id, { timeZoneOffsetMinutes: 180 })).rejects.toThrow(
      'date update failure',
    );
    const response = await mediaUpload.uploadAsset.mock.results[0].value;
    expect(await sut.status(authStub.admin, asset.id, job.id)).toMatchObject({ status: 'saved', assetId: response.id });
    expect(await sut.cancel(authStub.admin, asset.id, job.id)).toMatchObject({ status: 'saved' });
    expect(await sut.save(authStub.admin, asset.id, job.id, { timeZoneOffsetMinutes: -600 })).toEqual(response);
    expect(mediaUpload.uploadAsset).toHaveBeenCalledOnce();
    expect(eraser.writeCopyMetadata).toHaveBeenCalledOnce();
    expect(mocks.asset.update).toHaveBeenCalledTimes(2);
    expect(mocks.asset.update.mock.calls[0]).toEqual(mocks.asset.update.mock.calls[1]);
    expect(eraser.cancel).not.toHaveBeenCalled();
  });

  it('coalesces concurrent retries while a committed copy awaits date finalization', async () => {
    const gate = Promise.withResolvers<undefined>();
    mocks.asset.update.mockImplementationOnce(() => gate.promise);
    const job = await sut.create(authStub.admin, asset.id, mask);
    await finish();
    const first = sut.save(authStub.admin, asset.id, job.id);
    await vi.waitFor(() => expect(mocks.asset.update).toHaveBeenCalledOnce());
    let settled = false;
    const second = sut.save(authStub.admin, asset.id, job.id).then((response) => {
      settled = true;
      return response;
    });
    await new Promise((resolve) => setImmediate(resolve));
    expect(settled).toBe(false);
    gate.resolve(undefined);
    const [a, b] = await Promise.all([first, second]);
    expect(b).toEqual(a);
    expect(mediaUpload.uploadAsset).toHaveBeenCalledOnce();
    expect(mocks.asset.update).toHaveBeenCalledOnce();
  });

  it('surfaces upload/quota failure, keeps the result, and retries with stable bytes on a fresh staging path', async () => {
    vi.useFakeTimers({ toFake: ['Date'] });
    const savedAt = new Date('2026-11-02T23:55:12.345Z');
    vi.setSystemTime(savedAt);
    mediaUpload.uploadAsset.mockRejectedValueOnce(new Error('Quota has been exceeded!'));
    const duplicate = { id: randomUUID(), status: AssetMediaStatus.DUPLICATE };
    mediaUpload.uploadAsset.mockResolvedValueOnce(duplicate);
    const job = await sut.create(authStub.admin, asset.id, mask);
    await finish();
    await expect(sut.save(authStub.admin, asset.id, job.id, { timeZoneOffsetMinutes: 330 })).rejects.toThrow('Quota');
    expect(await sut.status(authStub.admin, asset.id, job.id)).toMatchObject({ status: 'ready' });
    vi.setSystemTime(new Date('2026-11-03T00:05:00Z'));
    expect(await sut.save(authStub.admin, asset.id, job.id, { timeZoneOffsetMinutes: -600 })).toEqual(duplicate);
    vi.useRealTimers();
    const first = mediaUpload.uploadAsset.mock.calls[0][2];
    const second = mediaUpload.uploadAsset.mock.calls[1][2];
    expect(first.originalPath).not.toEqual(second.originalPath);
    expect(first.checksum).toEqual(second.checksum);
    expect(eraser.writeCopyMetadata).toHaveBeenCalledOnce();
    expect(eraser.writeCopyMetadata).toHaveBeenCalledWith(
      expect.any(String),
      expect.objectContaining({ make: asset.exifInfo.make, timeZone: 'UTC+3' }),
      savedAt,
      330,
    );
    expect(mocks.asset.update).not.toHaveBeenCalled();
    expect(mediaUpload.uploadAsset.mock.calls.map((call) => call[1].fileCreatedAt)).toEqual([savedAt, savedAt]);
    expect(mediaUpload.uploadAsset.mock.calls.map((call) => call[1].fileModifiedAt)).toEqual([savedAt, savedAt]);
  });

  it('removes staging file when checksum preparation fails before upload', async () => {
    mocks.crypto.hashFile.mockRejectedValue(new Error('read failed'));
    const job = await sut.create(authStub.admin, asset.id, mask);
    await finish();
    await expect(sut.save(authStub.admin, asset.id, job.id)).rejects.toThrow('read failed');
    expect(mediaUpload.uploadAsset).not.toHaveBeenCalled();
    expect(await readdir(join(root, 'upload'), { recursive: true })).not.toContain(expect.stringMatching(/\.jpg$/));
  });

  it('rejects cancellation during a native save and reports the actual save outcome', async () => {
    let release!: () => void;
    mediaUpload.uploadAsset.mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          release = () => resolve({ id: randomUUID(), status: AssetMediaStatus.CREATED });
        }),
    );
    const job = await sut.create(authStub.admin, asset.id, mask);
    await finish();
    const saving = sut.save(authStub.admin, asset.id, job.id);
    await vi.waitFor(() => expect(mediaUpload.uploadAsset).toHaveBeenCalledOnce());
    await expect(sut.cancel(authStub.admin, asset.id, job.id)).rejects.toThrow('being saved');
    release();
    await saving;
    expect(await sut.status(authStub.admin, asset.id, job.id)).toMatchObject({ status: 'saved' });
  });

  it('marks a failed inference with a safe error code and cleans private resources', async () => {
    eraser.inpaint.mockRejectedValue(new InpaintingError('busy'));
    const job = await sut.create(authStub.admin, asset.id, mask);
    await finish();
    expect(await sut.status(authStub.admin, asset.id, job.id)).toEqual({
      id: job.id,
      status: 'failed',
      errorCode: 'busy',
    });
    expect(eraser.removeDirectory).toHaveBeenCalledOnce();
    await expect(sut.save(authStub.admin, asset.id, job.id)).rejects.toThrow('not ready');
  });

  it('discards late inference after cancellation and never saves it', async () => {
    const gate = Promise.withResolvers<void>();
    eraser.inpaint.mockImplementationOnce(() => gate.promise);
    const job = await sut.create(authStub.admin, asset.id, mask);
    await vi.waitFor(() => expect(eraser.inpaint).toHaveBeenCalledOnce());
    expect(await sut.cancel(authStub.admin, asset.id, job.id)).toMatchObject({ status: 'cancelled' });
    expect(eraser.inpaint.mock.calls[0][4].aborted).toBe(true);
    gate.resolve();
    await finish();
    expect(await sut.status(authStub.admin, asset.id, job.id)).toMatchObject({ status: 'cancelled' });
    expect(eraser.writePreview).not.toHaveBeenCalled();
    expect(eraser.removeDirectory).toHaveBeenCalledOnce();
  });

  it('limits one active request per user and does not start another heavy job', async () => {
    const gate = Promise.withResolvers<void>();
    eraser.inpaint.mockImplementationOnce(() => gate.promise);
    await sut.create(authStub.admin, asset.id, mask);
    await vi.waitFor(() => expect(eraser.inpaint).toHaveBeenCalledOnce());
    await expect(sut.create(authStub.admin, asset.id, mask)).rejects.toThrow('queue is full');
    gate.resolve();
    await finish();
  });

  it('never reads another asset job and removes expired editing sessions', async () => {
    const job = await sut.create(authStub.admin, asset.id, mask);
    await finish();
    mocks.asset.getById.mockResolvedValue({ ...getForAsset(asset), id: randomUUID() });
    await expect(sut.status(authStub.admin, randomUUID(), job.id)).rejects.toThrow(NotFoundException);
    mocks.asset.getById.mockResolvedValue(getForAsset(asset));
    (sut as unknown as Internals).jobs.get(job.id)!.expiresAt = Date.now() - 1;
    await expect(sut.status(authStub.admin, asset.id, job.id)).rejects.toThrow(NotFoundException);
    expect(eraser.removeDirectory).toHaveBeenCalledOnce();
  });

  it('result preview only reads the pre-generated bounded file', async () => {
    const job = await sut.create(authStub.admin, asset.id, mask);
    await finish();
    const response = await sut.preview(authStub.admin, asset.id, job.id);
    expect(response.length).toBe('small preview'.length);
    expect(eraser.preview).not.toHaveBeenCalled();
    expect(eraser.writePreview).toHaveBeenCalledOnce();
    expect(eraser.readPreview).toHaveBeenCalledOnce();
    await sut.status(authStub.admin, asset.id, job.id);
    await sut.status(authStub.admin, asset.id, job.id);
    expect(eraser.cleanOrphans).toHaveBeenCalledOnce();
  });

  it('prunes cancelled tombstones so normal repeated edits do not permanently fill admission', async () => {
    for (let index = 0; index < 16; index++) {
      const job = await sut.create(authStub.admin, asset.id, mask);
      await finish();
      await sut.cancel(authStub.admin, asset.id, job.id);
    }
    const next = await sut.create(authStub.admin, asset.id, mask);
    await finish();
    expect(await sut.status(authStub.admin, asset.id, next.id)).toMatchObject({ status: 'ready' });
  });

  it('does not let the microservices worker collect API editing directories', () => {
    mocks.config.getWorker.mockReturnValue(ImmichWorker.Microservices);
    const interval = vi.spyOn(globalThis, 'setInterval');
    sut.onModuleInit();
    expect(interval).not.toHaveBeenCalled();
  });

  it('releases a server-side S3 original after successful processing and never sends its storage URL', async () => {
    const cleanup = vi.fn().mockResolvedValue(undefined);
    Object.assign(sut, { ensureLocalFile: vi.fn().mockResolvedValue({ localPath: '/private-s3-copy.jpg', cleanup }) });
    const job = await sut.create(authStub.admin, asset.id, mask);
    await finish();
    expect(eraser.normalize).toHaveBeenCalledWith('/private-s3-copy.jpg', expect.any(String));
    expect(eraser.inpaint.mock.calls[0][1]).toContain('original.jpg');
    expect(cleanup).toHaveBeenCalledOnce();
    expect(await sut.status(authStub.admin, asset.id, job.id)).toMatchObject({ status: 'ready' });
  });

  it('discards a ready result when cancellation arrives during S3 temporary cleanup', async () => {
    const gate = Promise.withResolvers<void>();
    const cleanup = vi.fn(() => gate.promise);
    Object.assign(sut, { ensureLocalFile: vi.fn().mockResolvedValue({ localPath: '/private-s3-copy.jpg', cleanup }) });
    const job = await sut.create(authStub.admin, asset.id, mask);
    await vi.waitFor(() => expect(cleanup).toHaveBeenCalledOnce());
    await sut.cancel(authStub.admin, asset.id, job.id);
    gate.resolve();
    await finish();
    expect(eraser.removeDirectory).toHaveBeenCalledOnce();
    expect(await sut.status(authStub.admin, asset.id, job.id)).toMatchObject({ status: 'cancelled' });
  });
});
