import { StorageCore } from 'src/cores/storage.core.js';
import { ImmichWorker, JobName, JobStatus, StorageFolder } from 'src/enum.js';
import { AssetService } from 'src/services/asset.service.js';
import { QueueService } from 'src/services/queue.service.js';
import { StorageService } from 'src/services/storage.service.js';
import { makeStream, newTestService } from 'test/utils.js';

class CleanupProbe extends StorageService {
  cleanup(paths: string[], referenced: (path: string) => Promise<boolean>) {
    return this.deleteDisposableFiles({ files: paths }, referenced);
  }
}

describe('sealed deletion recovery and shared disposable cleanup', () => {
  afterEach(() => vi.restoreAllMocks());

  it('bootstrap replays sealed receipts independently of retention configuration', async () => {
    const { sut, mocks } = newTestService(QueueService);
    mocks.config.getWorker.mockReturnValue(ImmichWorker.Microservices);
    await sut.onBootstrap();
    expect(mocks.job.queue).toHaveBeenCalledWith({ name: JobName.AssetDeleteCheck, data: { resumeOnly: true } });
    expect(mocks.job.startWorkers).toHaveBeenCalled();
    expect(mocks.job.startWorkers.mock.invocationCallOrder[0]).toBeLessThan(
      mocks.job.queue.mock.invocationCallOrder[0],
    );
  });

  it('the API process does not duplicate the sealed-deletion bootstrap sweep', async () => {
    const { sut, mocks } = newTestService(QueueService);
    mocks.config.getWorker.mockReturnValue(ImmichWorker.Api);
    await sut.onBootstrap();
    expect(mocks.job.queue).not.toHaveBeenCalled();
  });

  it('resume-only recovery never creates new expiration decisions', async () => {
    const { sut, mocks } = newTestService(AssetService);
    mocks.asset.streamPendingDeletions.mockReturnValue(
      makeStream([{ assetId: 'sealed-copy', operationId: 'sealed-copy', ownerId: 'owner', scope: 'managed' }]),
    );
    expect(await sut.handleAssetDeletionCheck({ resumeOnly: true })).toBe(JobStatus.Success);
    expect(mocks.job.queue).toHaveBeenCalledWith({
      name: JobName.AssetDelete,
      data: { id: 'sealed-copy', deleteOnDisk: true, deletionId: 'sealed-copy' },
    });
    expect(mocks.asset.streamExpiredTrash).not.toHaveBeenCalled();
    expect(mocks.asset.preparePermanentDeletion).not.toHaveBeenCalled();
  });

  it('uses the transaction-bound reference checker instead of opening another repository query', async () => {
    const { sut, mocks } = newTestService(CleanupProbe);
    const path = `${StorageCore.getBaseFolder(StorageFolder.Thumbnails)}/synthetic.jpg`;
    const referenced = vi.fn().mockResolvedValue(false);
    expect(await sut.cleanup([path], referenced)).toBe(JobStatus.Success);
    expect(referenced).toHaveBeenCalledWith(path);
    expect(mocks.asset.isOriginalReferenced).not.toHaveBeenCalled();
    expect(mocks.storage.unlink).toHaveBeenCalledWith(path);
  });

  it('never bypasses an original or shared-file reference', async () => {
    const { sut, mocks } = newTestService(CleanupProbe);
    const path = `${StorageCore.getBaseFolder(StorageFolder.Thumbnails)}/protected.jpg`;
    expect(await sut.cleanup([path], () => Promise.resolve(true))).toBe(JobStatus.Failed);
    expect(mocks.storage.unlink).not.toHaveBeenCalled();
  });

  it('continues independent disposable files and treats an already-removed file as idempotent', async () => {
    const { sut, mocks } = newTestService(CleanupProbe);
    const root = StorageCore.getBaseFolder(StorageFolder.Thumbnails);
    mocks.storage.unlink.mockRejectedValueOnce(Object.assign(new Error('already removed'), { code: 'ENOENT' }));
    expect(await sut.cleanup([`${root}/a.jpg`, `${root}/b.jpg`], () => Promise.resolve(false))).toBe(JobStatus.Success);
    expect(mocks.storage.unlink).toHaveBeenCalledTimes(2);
  });
});
