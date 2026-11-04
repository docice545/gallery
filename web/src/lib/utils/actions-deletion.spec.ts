import {
  deleteAssets as deleteBulk,
  deletionBatchStatus,
  deletionPreflight,
  deletionStatuses,
  getStack,
  restoreAssets,
  permanentDeletion,
  PermanentDeletionBatchState,
  State,
} from '@immich/sdk';
import { toastManager } from '@immich/ui';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { TimelineAsset } from '$lib/managers/timeline-manager/types';
import { assetFactory } from '@test-data/factories/asset-factory';
import { deleteAssets } from './actions';
import { handleError } from './handle-error';
import { toTimelineAsset } from './timeline-util';

const flags = vi.hoisted(() => ({ authorizedDeletion: true }));
vi.mock('@immich/sdk', async (original) => ({
  ...(await original()),
  deleteAssets: vi.fn(),
  deletionBatchStatus: vi.fn(),
  deletionStatuses: vi.fn(),
  permanentDeletion: vi.fn(),
  deletionPreflight: vi.fn(),
  getStack: vi.fn(),
  restoreAssets: vi.fn(),
}));
vi.mock('$lib/managers/feature-flags-manager.svelte', () => ({ featureFlagsManager: { valueOrUndefined: flags } }));
vi.mock('./handle-error', () => ({ handleError: vi.fn() }));
const assets = (count: number) => Array.from({ length: count }, (_, i) => ({ id: `asset-${i}` }) as TimelineAsset);

beforeEach(() => {
  vi.clearAllMocks();
  flags.authorizedDeletion = true;
  vi.mocked(deletionPreflight).mockImplementation(({ bulkIdsDto }) =>
    Promise.resolve(bulkIdsDto.ids.map((id) => ({ id, scope: 'managed', authorized: true }))),
  );
  vi.spyOn(toastManager, 'primary').mockImplementation(() => ({}) as never);
});
describe('explicit timeline stack deletion', () => {
  const selection = (count: number) => {
    const members = Array.from({ length: count }, (_, i) =>
      assetFactory.build({ id: `frame-${i}`, ownerId: 'owner', isTrashed: false }),
    );
    const cover = toTimelineAsset(members[0]);
    cover.stack = { id: 'stack', primaryAssetId: cover.id, assetCount: count };
    return { members, cover };
  };

  it.each([2, 3, 5])('trashes all %i active members of an explicitly selected cover', async (count) => {
    const { members, cover } = selection(count);
    vi.mocked(getStack).mockResolvedValue({ id: 'stack', primaryAssetId: cover.id, assets: members });
    const removed = vi.fn();
    await deleteAssets(false, removed, [cover], undefined, { includeStacks: true });
    expect(deleteBulk).toHaveBeenCalledWith({ assetBulkDeleteDto: { ids: members.map((a) => a.id), force: false } });
    expect(removed).toHaveBeenCalledWith(members.map((a) => a.id));
  });

  it('keeps viewer deletion limited to the selected cover without the timeline option', async () => {
    const { cover } = selection(3);
    await deleteAssets(false, vi.fn(), [cover]);
    expect(getStack).not.toHaveBeenCalled();
    expect(deleteBulk).toHaveBeenCalledWith({ assetBulkDeleteDto: { ids: [cover.id], force: false } });
  });

  it('deduplicates mixed selection and restores every member without duplicate timeline tiles', async () => {
    const { members, cover } = selection(3);
    vi.mocked(getStack).mockResolvedValue({ id: 'stack', primaryAssetId: cover.id, assets: members });
    const standalone = toTimelineAsset(assetFactory.build({ id: 'single', ownerId: 'owner' }));
    const undo = vi.fn();
    await deleteAssets(false, vi.fn(), [cover, standalone, cover], undo, { includeStacks: true });
    const ids = [...members.map((a) => a.id), 'single'];
    expect(deleteBulk).toHaveBeenCalledWith({ assetBulkDeleteDto: { ids, force: false } });
    const notification = vi.mocked(toastManager.primary).mock.calls.at(-1)![0] as {
      button: { onclick: () => Promise<void> };
    };
    await notification.button.onclick();
    expect(restoreAssets).toHaveBeenCalledWith({ bulkIdsDto: { ids } });
    expect(undo).toHaveBeenCalledWith([cover, standalone]);
  });

  it.each(['offline', 'foreign', 'stale'])('does not delete any selection if stack lookup is %s', async (failure) => {
    const { members, cover } = selection(3);
    if (failure === 'offline') {
      vi.mocked(getStack).mockRejectedValueOnce(new Error('offline'));
    } else {
      vi.mocked(getStack).mockResolvedValueOnce({
        id: 'stack',
        primaryAssetId: failure === 'stale' ? members[1].id : cover.id,
        assets: failure === 'foreign' ? [members[0], { ...members[1], ownerId: 'another-owner' }] : members,
      });
    }
    const removed = vi.fn();
    expect(await deleteAssets(false, removed, [cover], undefined, { includeStacks: true })).toBe(false);
    expect(deleteBulk).not.toHaveBeenCalled();
    expect(removed).not.toHaveBeenCalled();
  });
});
describe('permanent deletion acknowledgements', () => {
  it('removes only completed items; blocked/failed originals remain visible in Trash', async () => {
    vi.mocked(permanentDeletion).mockResolvedValue([
      { id: 'asset-0', state: State.Complete },
      { id: 'asset-1', state: State.Blocked, code: 'LIBRARY_DELETION_NOT_AUTHORIZED' },
    ]);
    const remove = vi.fn();
    await deleteAssets(true, remove, assets(2));
    expect(remove).toHaveBeenCalledWith(['asset-0']);
    expect(deleteBulk).not.toHaveBeenCalled();
  });
  it('retains prior confirmed batch if a later request times out', async () => {
    vi.mocked(permanentDeletion)
      .mockResolvedValueOnce(assets(5000).map(({ id }) => ({ id, state: State.Complete })))
      .mockRejectedValueOnce(new Error('timeout'));
    const remove = vi.fn();
    await deleteAssets(true, remove, assets(5001));
    expect(remove).toHaveBeenCalledTimes(1);
    expect(remove.mock.calls[0][0]).toHaveLength(5000);
    expect(handleError).toHaveBeenCalled();
  });
  it('polls a durable batch before removing completed assets', async () => {
    const ids = assets(201).map(({ id }) => id);
    vi.mocked(permanentDeletion).mockResolvedValue(ids.map((id) => ({ id, state: State.Pending, batchId: 'batch-1' })));
    vi.mocked(deletionBatchStatus)
      .mockResolvedValueOnce({
        id: 'batch-1',
        state: PermanentDeletionBatchState.Active,
        total: 201,
        processed: 0,
        complete: 0,
        failed: 0,
        pending: 201,
      })
      .mockResolvedValueOnce({
        id: 'batch-1',
        state: PermanentDeletionBatchState.Complete,
        total: 201,
        processed: 201,
        complete: 201,
        failed: 0,
        pending: 0,
      });
    vi.mocked(deletionStatuses).mockImplementation(({ bulkIdsDto }) =>
      Promise.resolve(bulkIdsDto.ids.map((id) => ({ id, state: State.Complete }))),
    );

    const remove = vi.fn();
    await deleteAssets(true, remove, assets(201));

    expect(deletionBatchStatus).toHaveBeenCalledTimes(2);
    expect(deletionStatuses).toHaveBeenCalledTimes(2);
    expect(remove).toHaveBeenCalledWith(ids);
  });
  it.each([
    [PermanentDeletionBatchState.Cancelled, false],
    [PermanentDeletionBatchState.Complete, true],
  ])('stops unsent work after cancellation (%s, cancelRequested=%s)', async (state, cancelRequested) => {
    vi.mocked(permanentDeletion).mockResolvedValue(
      assets(5000).map(({ id }) => ({ id, state: State.Pending, batchId: 'batch-1' })),
    );
    vi.mocked(deletionBatchStatus).mockResolvedValue({
      id: 'batch-1',
      state,
      cancelRequested,
      total: 5000,
      processed: 1,
      complete: 1,
      failed: 0,
      pending: 4999,
    });
    vi.mocked(deletionStatuses).mockImplementation(({ bulkIdsDto }) =>
      Promise.resolve(bulkIdsDto.ids.map((id) => ({ id, state: id === 'asset-0' ? State.Complete : State.Pending }))),
    );
    const remove = vi.fn();

    await expect(deleteAssets(true, remove, assets(5001))).resolves.toBe(false);

    expect(permanentDeletion).toHaveBeenCalledOnce();
    expect(remove).toHaveBeenCalledWith(['asset-0']);
  });
  it.each(['duplicate', 'missing', 'foreign'])('rejects %s acknowledgement without removing rows', async (kind) => {
    const result =
      kind === 'missing'
        ? []
        : [
            { id: 'asset-0', state: State.Complete },
            { id: kind === 'foreign' ? 'foreign' : 'asset-0', state: State.Complete },
          ];
    vi.mocked(permanentDeletion).mockResolvedValue(result);
    const remove = vi.fn();
    await deleteAssets(true, remove, assets(2));
    expect(remove).not.toHaveBeenCalled();
    expect(handleError).toHaveBeenCalled();
  });
  it('preflights the full selection across 200-item chunks before deleting anything', async () => {
    vi.mocked(deletionPreflight).mockImplementation(({ bulkIdsDto }) =>
      Promise.resolve(
        bulkIdsDto.ids.map((id) => ({
          id,
          scope: id === 'asset-400' ? 'external' : 'managed',
          authorized: id !== 'asset-400',
          code: id === 'asset-400' ? 'LIBRARY_DELETION_NOT_AUTHORIZED' : undefined,
        })),
      ),
    );
    const remove = vi.fn();
    await deleteAssets(true, remove, assets(401));
    expect(deletionPreflight).toHaveBeenCalledTimes(3);
    expect(permanentDeletion).not.toHaveBeenCalled();
    expect(remove).not.toHaveBeenCalled();
  });
  it('offline preflight never sends permanent deletion', async () => {
    vi.mocked(deletionPreflight).mockRejectedValueOnce(new Error('offline'));
    await deleteAssets(true, vi.fn(), assets(1));
    expect(permanentDeletion).not.toHaveBeenCalled();
    expect(handleError).toHaveBeenCalled();
  });
  it('stops unsent batches if authorization is revoked after preflight', async () => {
    vi.mocked(permanentDeletion)
      .mockResolvedValueOnce(assets(5000).map(({ id }) => ({ id, state: State.Complete })))
      .mockResolvedValueOnce(
        assets(1).map(() => ({
          id: 'asset-5000',
          scope: 'managed',
          state: State.Blocked,
          code: 'LIBRARY_DELETION_NOT_AUTHORIZED',
        })),
      );
    const remove = vi.fn();
    await deleteAssets(true, remove, assets(5001));
    expect(permanentDeletion).toHaveBeenCalledTimes(2);
    expect(remove.mock.calls[0][0]).toHaveLength(5000);
    expect(remove.mock.calls[1][0]).toEqual([]);
  });
  it('ordinary Trash continues using the existing soft-delete API', async () => {
    vi.mocked(deleteBulk).mockResolvedValue(undefined as never);
    const remove = vi.fn();
    await deleteAssets(false, remove, assets(1));
    expect(deleteBulk).toHaveBeenCalledWith({ assetBulkDeleteDto: { ids: ['asset-0'], force: false } });
    expect(permanentDeletion).not.toHaveBeenCalled();
    expect(remove).toHaveBeenCalledWith(['asset-0']);
  });
});
