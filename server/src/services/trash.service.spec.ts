import { BadRequestException } from '@nestjs/common';
import { JobName, JobStatus } from 'src/enum.js';
import { TrashService } from 'src/services/trash.service.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { ServiceMocks, newTestService } from 'test/utils.js';

async function* makeAssetIdStream(count: number): AsyncIterableIterator<{ id: string }> {
  for (let i = 0; i < count; i++) {
    await Promise.resolve();
    yield { id: `asset-${i + 1}` };
  }
}

describe(TrashService.name, () => {
  let sut: TrashService;
  let mocks: ServiceMocks;

  it('should work', () => {
    expect(sut).toBeDefined();
  });

  beforeEach(() => {
    ({ sut, mocks } = newTestService(TrashService));
    mocks.duplicateRepository.deleteConflictingTombstones.mockResolvedValue(void 0 as any);
    mocks.duplicateRepository.deleteConflictingTombstonesForUser.mockResolvedValue(void 0 as any);
  });

  describe('restoreAssets', () => {
    it('should require asset restore access for all ids', async () => {
      await expect(
        sut.restoreAssets(authStub.user1, {
          ids: ['asset-1'],
        }),
      ).rejects.toBeInstanceOf(BadRequestException);
    });

    it('should handle an empty list', async () => {
      await expect(sut.restoreAssets(authStub.user1, { ids: [] })).resolves.toEqual({ count: 0 });
      expect(mocks.access.asset.checkOwnerAccess).not.toHaveBeenCalled();
    });

    it('should restore a batch of assets', async () => {
      mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set(['asset1', 'asset2']));
      mocks.trash.restoreAll.mockResolvedValue(['asset1', 'asset2']);

      await sut.restoreAssets(authStub.user1, { ids: ['asset1', 'asset2'] });

      expect(mocks.trash.restoreAll).toHaveBeenCalledWith(['asset1', 'asset2']);
      expect(mocks.job.queue.mock.calls).toEqual([]);
    });

    it('should clean up conflicting tombstones on restore', async () => {
      mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set(['asset1', 'asset2']));
      mocks.trash.restoreAll.mockResolvedValue(['asset1', 'asset2']);

      await sut.restoreAssets(authStub.user1, { ids: ['asset1', 'asset2'] });

      expect(mocks.duplicateRepository.deleteConflictingTombstones).toHaveBeenCalledWith('user-id', [
        'asset1',
        'asset2',
      ]);
    });
  });

  it('reports and emits only assets actually restored when expiry raced the batch', async () => {
    mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set(['expired', 'restorable']));
    mocks.trash.restoreAll.mockResolvedValue(['restorable']);
    await expect(sut.restoreAssets(authStub.user1, { ids: ['expired', 'restorable'] })).resolves.toEqual({ count: 1 });
    expect(mocks.event.emit).toHaveBeenCalledWith('AssetRestoreAll', { assetIds: ['restorable'], userId: 'user-id' });
    expect(mocks.duplicateRepository.deleteConflictingTombstones).toHaveBeenCalledWith('user-id', ['restorable']);
  });

  it('does not announce a restoration when no row could be restored', async () => {
    mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set(['expired']));
    mocks.trash.restoreAll.mockResolvedValue([]);
    await expect(sut.restoreAssets(authStub.user1, { ids: ['expired'] })).resolves.toEqual({ count: 0 });
    expect(mocks.event.emit).not.toHaveBeenCalled();
    expect(mocks.duplicateRepository.deleteConflictingTombstones).not.toHaveBeenCalled();
  });

  describe('restore', () => {
    it('should handle an empty trash', async () => {
      mocks.trash.getDeletedIds.mockResolvedValue(makeAssetIdStream(0));
      mocks.trash.restore.mockResolvedValue(0);
      await expect(sut.restore(authStub.user1)).resolves.toEqual({ count: 0 });
      expect(mocks.trash.restore).toHaveBeenCalledWith('user-id');
    });

    it('should restore', async () => {
      mocks.trash.getDeletedIds.mockResolvedValue(makeAssetIdStream(1));
      mocks.trash.restore.mockResolvedValue(1);
      await expect(sut.restore(authStub.user1)).resolves.toEqual({ count: 1 });
      expect(mocks.trash.restore).toHaveBeenCalledWith('user-id');
    });

    it('should clean up conflicting tombstones for user on restore', async () => {
      mocks.trash.restore.mockResolvedValue(3);
      await sut.restore(authStub.user1);
      expect(mocks.duplicateRepository.deleteConflictingTombstonesForUser).toHaveBeenCalledWith('user-id');
    });

    it('should skip tombstone cleanup when nothing restored', async () => {
      mocks.trash.restore.mockResolvedValue(0);
      await sut.restore(authStub.user1);
      expect(mocks.duplicateRepository.deleteConflictingTombstonesForUser).not.toHaveBeenCalled();
    });
  });

  describe('empty', () => {
    it('refuses the obsolete unscoped entry point without changing Trash or queues', async () => {
      await expect(sut.empty(authStub.user1)).rejects.toHaveProperty('status', 409);
      expect(mocks.trash.empty).not.toHaveBeenCalled();
      expect(mocks.job.queue).not.toHaveBeenCalled();
    });
  });

  describe('onAssetsDelete', () => {
    it('should queue the empty trash job', async () => {
      await expect(sut.onAssetsDelete()).resolves.toBeUndefined();
      expect(mocks.job.queue).toHaveBeenCalledWith({ name: JobName.AssetEmptyTrash, data: {} });
    });
  });

  describe('handleQueueEmptyTrash', () => {
    it.each([1, 1001])('never activates legacy disk deletion for %s rows', async (count) => {
      mocks.trash.getDeletedIds.mockReturnValue(makeAssetIdStream(count));
      await expect(sut.handleEmptyTrash()).resolves.toEqual(JobStatus.Skipped);
      expect(mocks.trash.getDeletedIds).not.toHaveBeenCalled();
      expect(mocks.job.queueAll).not.toHaveBeenCalled();
    });
  });
});
