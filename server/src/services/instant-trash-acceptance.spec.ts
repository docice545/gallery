import { ConflictException } from '@nestjs/common';
import { AssetController } from 'src/controllers/asset.controller.js';
import { PermanentDeletionDto } from 'src/dtos/asset-deletion.dto.js';
import { JobName } from 'src/enum.js';
import { AssetService } from 'src/services/asset.service.js';
import { TrashService } from 'src/services/trash.service.js';
import { DeletionError } from 'src/utils/authorized-deletion.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { newTestService } from 'test/utils.js';

const id = '00000000-0000-4000-8000-000000000029';
const motionId = '00000000-0000-4000-8000-000000000030';
const receipt = (assetId = id, operationId = id) => ({
  assetId,
  operationId,
  scope: 'managed',
  state: 'preparing' as const,
  errorCode: null,
});

describe('Build29 irreversible Trash acceptance', () => {
  it('keeps the existing completion API default and makes acceptance an explicit opt-in', async () => {
    const { sut } = newTestService(AssetService);
    const controller = new AssetController(sut);
    const old = vi.spyOn(sut, 'permanentlyDelete').mockResolvedValue([{ id, state: 'complete' }]);
    const accept = vi
      .spyOn(sut, 'acceptPermanentDeletion')
      .mockResolvedValue([{ id, state: 'pending', accepted: true }]);
    await controller.permanentDeletion(authStub.user1, { ids: [id], confirmed: true });
    expect(old).toHaveBeenCalledExactlyOnceWith(authStub.user1, [id]);
    expect(accept).not.toHaveBeenCalled();
    const dto = PermanentDeletionDto.schema.parse({ ids: [id], confirmed: true, acceptOnly: true });
    await controller.permanentDeletion(authStub.user1, dto);
    expect(accept).toHaveBeenCalledExactlyOnceWith(authStub.user1, [id]);
    expect(PermanentDeletionDto.schema.safeParse({ ids: [id], confirmed: false, acceptOnly: true }).success).toBe(
      false,
    );
    expect(PermanentDeletionDto.schema.safeParse({ ids: [id], confirmed: true, acceptOnly: false }).success).toBe(
      false,
    );
  });

  it('commits every still/motion intent before publishing workers and does no inline file work', async () => {
    const { sut, mocks } = newTestService(AssetService);
    const calls: string[] = [];
    mocks.asset.getDeletionReceipts.mockResolvedValue([]);
    vi.spyOn(sut, 'deletionPreflight').mockResolvedValue([{ id, scope: 'managed', authorized: true }]);
    mocks.asset.acceptPermanentDeletion.mockImplementation(() => {
      calls.push('committed');
      return Promise.resolve([receipt(), receipt(motionId)]);
    });
    mocks.job.queueAll.mockImplementation(() => {
      calls.push('published');
      return Promise.resolve();
    });
    const worker = vi.spyOn(sut, 'handleAssetDeletion');

    await expect(sut.acceptPermanentDeletion(authStub.user1, [id, id])).resolves.toEqual([
      { id, scope: 'managed', state: 'pending', accepted: true },
    ]);
    expect(mocks.asset.acceptPermanentDeletion).toHaveBeenCalledExactlyOnceWith([id], authStub.user1.user.id);
    expect(calls).toEqual(['committed', 'published']);
    expect(mocks.job.queueAll).toHaveBeenCalledExactlyOnceWith([
      { name: JobName.AssetDelete, data: { id, deleteOnDisk: true, deletionId: id } },
      { name: JobName.AssetDelete, data: { id: motionId, deleteOnDisk: true, deletionId: motionId } },
    ]);
    expect(worker).not.toHaveBeenCalled();
    expect(mocks.storage.snapshotOriginal).not.toHaveBeenCalled();
    expect(mocks.storage.unlinkOriginal).not.toHaveBeenCalled();
    expect(mocks.asset.removeForDeletion).not.toHaveBeenCalled();
  });

  it('keeps the accepted ACK when Redis publication fails after PostgreSQL commit', async () => {
    const { sut, mocks } = newTestService(AssetService);
    mocks.asset.getDeletionReceipts.mockResolvedValue([]);
    vi.spyOn(sut, 'deletionPreflight').mockResolvedValue([{ id, authorized: true }]);
    mocks.asset.acceptPermanentDeletion.mockResolvedValue([receipt()]);
    mocks.job.queueAll.mockRejectedValue(new Error('isolated Redis outage'));
    await expect(sut.acceptPermanentDeletion(authStub.user1, [id])).resolves.toMatchObject([
      { id, accepted: true, state: 'pending' },
    ]);
    expect(mocks.asset.removeForDeletion).not.toHaveBeenCalled();
  });

  it('returns the committed ACK without waiting for an unresolved Redis publication', async () => {
    const { sut, mocks } = newTestService(AssetService);
    const publication = Promise.withResolvers<void>();
    mocks.asset.getDeletionReceipts.mockResolvedValue([]);
    vi.spyOn(sut, 'deletionPreflight').mockResolvedValue([{ id, authorized: true }]);
    mocks.asset.acceptPermanentDeletion.mockResolvedValue([receipt()]);
    mocks.job.queueAll.mockReturnValue(publication.promise);
    await expect(sut.acceptPermanentDeletion(authStub.user1, [id])).resolves.toMatchObject([
      { id, accepted: true, state: 'pending' },
    ]);
    expect(mocks.asset.removeForDeletion).not.toHaveBeenCalled();
    publication.resolve();
  });

  it('rejects a failed atomic decision before scheduling any worker or claiming acceptance', async () => {
    const { sut, mocks } = newTestService(AssetService);
    mocks.asset.getDeletionReceipts.mockResolvedValue([]);
    vi.spyOn(sut, 'deletionPreflight').mockResolvedValue([{ id, authorized: true }]);
    mocks.asset.acceptPermanentDeletion.mockRejectedValue(new DeletionError('ASSET_NOT_IN_TRASH'));
    await expect(sut.acceptPermanentDeletion(authStub.user1, [id])).rejects.toBeInstanceOf(ConflictException);
    expect(mocks.job.queueAll).not.toHaveBeenCalled();
  });

  it('does not accept any fresh member when preflight rejects one member', async () => {
    const { sut, mocks } = newTestService(AssetService);
    mocks.asset.getDeletionReceipts.mockResolvedValue([]);
    vi.spyOn(sut, 'deletionPreflight').mockResolvedValue([
      { id, authorized: true },
      { id: motionId, authorized: false, code: 'ASSET_NOT_OWNED' },
    ]);
    await expect(sut.acceptPermanentDeletion(authStub.user1, [id, motionId])).resolves.toEqual([
      { id, state: 'blocked', code: 'DELETION_BATCH_NOT_AUTHORIZED', scope: undefined },
      { id: motionId, state: 'blocked', code: 'ASSET_NOT_OWNED', scope: undefined },
    ]);
    expect(mocks.asset.acceptPermanentDeletion).not.toHaveBeenCalled();
    expect(mocks.job.queueAll).not.toHaveBeenCalled();
  });

  it('reconciles an accepted request independently of current filesystem availability', async () => {
    const { sut, mocks } = newTestService(AssetService);
    mocks.asset.getDeletionReceipt.mockResolvedValue(receipt());
    mocks.asset.getDeletionScope.mockResolvedValue('managed');
    await expect(sut.deletionPreflight(authStub.user1, [id])).resolves.toEqual([
      { id, scope: 'managed', authorized: true, code: 'DELETION_ALREADY_ACCEPTED' },
    ]);
    expect(mocks.asset.getDeletionPolicy).not.toHaveBeenCalled();
    expect(mocks.storage.snapshotOriginal).not.toHaveBeenCalled();
  });

  it('reports failed/background derivative cleanup as accepted and non-restorable after a lost response', async () => {
    const { sut, mocks } = newTestService(AssetService);
    mocks.asset.getDeletionReceipt.mockResolvedValue({
      ...receipt(),
      state: 'files-removed',
      errorCode: 'DERIVATIVE_CLEANUP_FAILED',
    });
    mocks.asset.getPermanentDeletionTargets.mockResolvedValue([{ assetId: id }]);
    await expect(sut.deletionStatus(authStub.user1, id)).resolves.toEqual({
      id,
      accepted: true,
      state: 'failed',
      code: 'DERIVATIVE_CLEANUP_FAILED',
    });
  });

  it('never confuses an absent receipt with queued batch acceptance', async () => {
    const { sut, mocks } = newTestService(AssetService);
    mocks.asset.getDeletionReceipt.mockResolvedValue(undefined);
    await expect(sut.deletionStatus(authStub.user1, id)).resolves.toEqual({
      id,
      state: 'blocked',
      code: 'NO_AUTHORIZED_DELETION',
    });
  });

  it('rejects a direct restore request when the transaction finds an irreversible receipt', async () => {
    const { sut, mocks } = newTestService(TrashService);
    mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set([id]));
    mocks.trash.restoreAll.mockRejectedValue(new DeletionError('ASSET_PERMANENTLY_DELETED'));
    await expect(sut.restoreAssets(authStub.user1, { ids: [id] })).rejects.toMatchObject({ status: 409 });
    expect(mocks.trash.restoreAll).toHaveBeenCalledWith([id], authStub.user1.user.id);
    expect(mocks.event.emit).not.toHaveBeenCalled();
  });
});
