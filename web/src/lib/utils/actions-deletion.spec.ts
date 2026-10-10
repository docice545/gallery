import { deleteAssets as deleteBulk, permanentDeletion } from '@immich/sdk';
import { toastManager } from '@immich/ui';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { TimelineAsset } from '$lib/managers/timeline-manager/types';
import { deleteAssets } from './actions';
import { handleError } from './handle-error';

const flags = vi.hoisted(() => ({ authorizedDeletion: true }));
vi.mock('@immich/sdk', async (original) => ({
  ...(await original()),
  deleteAssets: vi.fn(),
  permanentDeletion: vi.fn(),
}));
vi.mock('$lib/managers/feature-flags-manager.svelte', () => ({ featureFlagsManager: { valueOrUndefined: flags } }));
vi.mock('./handle-error', () => ({ handleError: vi.fn() }));
const assets = (count: number) => Array.from({ length: count }, (_, i) => ({ id: `asset-${i}` }) as TimelineAsset);

beforeEach(() => {
  vi.clearAllMocks();
  flags.authorizedDeletion = true;
  vi.spyOn(toastManager, 'primary').mockImplementation(() => ({}) as never);
});
describe('permanent deletion acknowledgements', () => {
  it('removes only completed items; blocked/failed originals remain visible in Trash', async () => {
    vi.mocked(permanentDeletion).mockResolvedValue([
      { id: 'asset-0', state: 'complete' },
      { id: 'asset-1', state: 'blocked', code: 'LIBRARY_DELETION_NOT_AUTHORIZED' },
    ]);
    const remove = vi.fn();
    await deleteAssets(true, remove, assets(2));
    expect(remove).toHaveBeenCalledWith(['asset-0']);
    expect(deleteBulk).not.toHaveBeenCalled();
  });
  it('retains prior confirmed batch if a later request times out', async () => {
    vi.mocked(permanentDeletion)
      .mockResolvedValueOnce(assets(200).map(({ id }) => ({ id, state: 'complete' })))
      .mockRejectedValueOnce(new Error('timeout'));
    const remove = vi.fn();
    await deleteAssets(true, remove, assets(201));
    expect(remove).toHaveBeenCalledTimes(1);
    expect(remove.mock.calls[0][0]).toHaveLength(200);
    expect(handleError).toHaveBeenCalled();
  });
  it.each(['duplicate', 'missing', 'foreign'])('rejects %s acknowledgement without removing rows', async (kind) => {
    const result =
      kind === 'missing'
        ? []
        : [
            { id: 'asset-0', state: 'complete' as const },
            { id: kind === 'foreign' ? 'foreign' : 'asset-0', state: 'complete' as const },
          ];
    vi.mocked(permanentDeletion).mockResolvedValue(result);
    const remove = vi.fn();
    await deleteAssets(true, remove, assets(2));
    expect(remove).not.toHaveBeenCalled();
    expect(handleError).toHaveBeenCalled();
  });
  it('ordinary Trash continues using the existing soft-delete API', async () => {
    vi.mocked(deleteBulk).mockResolvedValue();
    const remove = vi.fn();
    await deleteAssets(false, remove, assets(1));
    expect(deleteBulk).toHaveBeenCalledWith({ assetBulkDeleteDto: { ids: ['asset-0'], force: false } });
    expect(permanentDeletion).not.toHaveBeenCalled();
    expect(remove).toHaveBeenCalledWith(['asset-0']);
  });
});
