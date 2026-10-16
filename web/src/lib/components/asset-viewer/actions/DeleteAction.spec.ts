import {
  deleteAssets as deleteBulk,
  deletionPreflight,
  permanentDeletion,
  State,
  type AssetResponseDto,
} from '@immich/sdk';
import { modalManager, toastManager } from '@immich/ui';
import '@testing-library/jest-dom';
import { fireEvent, waitFor } from '@testing-library/svelte';
import { AssetAction } from '$lib/constants';
import { renderWithTooltips } from '$tests/helpers';
import { assetFactory } from '@test-data/factories/asset-factory';
import DeleteAction from './DeleteAction.svelte';

vi.mock(import('$lib/managers/feature-flags-manager.svelte'), () => {
  return {
    featureFlagsManager: {
      init: vi.fn(),
      loadFeatureFlags: vi.fn(),
      value: { trash: true },
      valueOrUndefined: { authorizedDeletion: true },
    } as unknown as typeof import('$lib/managers/feature-flags-manager.svelte').featureFlagsManager,
  };
});
vi.mock('@immich/sdk', async (original) => ({
  ...(await original()),
  deleteAssets: vi.fn(),
  deletionPreflight: vi.fn(),
  permanentDeletion: vi.fn(),
}));

let asset: AssetResponseDto;

describe('DeleteAction component', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(modalManager, 'show').mockResolvedValue(true as never);
    vi.spyOn(toastManager, 'primary').mockImplementation(() => ({}) as never);
    vi.mocked(deletionPreflight).mockImplementation(({ bulkIdsDto }) =>
      Promise.resolve(bulkIdsDto.ids.map((id) => ({ id, scope: 'managed', authorized: true }))),
    );
  });
  describe('given an asset which is not trashed yet', () => {
    beforeEach(() => {
      asset = assetFactory.build({ isTrashed: false });
    });

    it('displays a button to move the asset to the trash bin', () => {
      const { getByLabelText, queryByTitle } = renderWithTooltips(DeleteAction, {
        asset,
        onAction: vi.fn(),
        preAction: vi.fn(),
      });
      expect(getByLabelText('delete')).toBeInTheDocument();
      expect(queryByTitle('deletePermanently')).toBeNull();
    });

    it('keeps the existing soft-delete API for ordinary Trash', async () => {
      vi.mocked(deleteBulk).mockResolvedValue(undefined as never);
      const onAction = vi.fn();
      const { getByLabelText } = renderWithTooltips(DeleteAction, { asset, onAction, preAction: vi.fn() });

      await fireEvent.click(getByLabelText('delete'));
      await waitFor(() => expect(onAction).toHaveBeenCalledWith(expect.objectContaining({ type: AssetAction.TRASH })));

      expect(deleteBulk).toHaveBeenCalledWith({ assetBulkDeleteDto: { ids: [asset.id], force: false } });
      expect(permanentDeletion).not.toHaveBeenCalled();
    });
  });

  describe('but if the asset is already trashed', () => {
    beforeEach(() => {
      asset = assetFactory.build({ isTrashed: true });
    });

    it('displays a button to permanently delete the asset', () => {
      const { getByLabelText, queryByTitle } = renderWithTooltips(DeleteAction, {
        asset,
        onAction: vi.fn(),
        preAction: vi.fn(),
      });
      expect(getByLabelText('permanently_delete')).toBeInTheDocument();
      expect(queryByTitle('delete')).toBeNull();
    });

    it('waits for physical completion before notifying the viewer and prevents duplicate clicks', async () => {
      let complete!: (result: Awaited<ReturnType<typeof permanentDeletion>>) => void;
      vi.mocked(permanentDeletion).mockImplementation(
        () =>
          new Promise((resolve) => {
            complete = resolve;
          }),
      );
      const onAction = vi.fn();
      const { getByLabelText } = renderWithTooltips(DeleteAction, { asset, onAction, preAction: vi.fn() });
      const button = getByLabelText('permanently_delete');

      await fireEvent.click(button);
      await waitFor(() => expect(permanentDeletion).toHaveBeenCalledOnce());
      expect(button).toBeDisabled();
      expect(onAction).not.toHaveBeenCalled();
      await fireEvent.click(button);
      expect(permanentDeletion).toHaveBeenCalledOnce();

      complete([{ id: asset.id, state: State.Complete }]);
      await waitFor(() => expect(onAction).toHaveBeenCalledWith(expect.objectContaining({ type: AssetAction.DELETE })));
      expect(deleteBulk).not.toHaveBeenCalled();
    });

    it('keeps the asset visible when deletion is incomplete', async () => {
      vi.mocked(permanentDeletion).mockResolvedValue([{ id: asset.id, state: State.Failed }]);
      const onAction = vi.fn();
      const { getByLabelText } = renderWithTooltips(DeleteAction, { asset, onAction, preAction: vi.fn() });

      await fireEvent.click(getByLabelText('permanently_delete'));
      await waitFor(() => expect(toastManager.primary).toHaveBeenCalled());

      expect(onAction).not.toHaveBeenCalled();
      expect(deleteBulk).not.toHaveBeenCalled();
    });

    it('sends no deletion request when the user cancels confirmation', async () => {
      vi.mocked(modalManager.show).mockResolvedValueOnce(false as never);
      const onAction = vi.fn();
      const { getByLabelText } = renderWithTooltips(DeleteAction, { asset, onAction, preAction: vi.fn() });

      await fireEvent.click(getByLabelText('permanently_delete'));
      await waitFor(() => expect(getByLabelText('permanently_delete')).not.toBeDisabled());

      expect(permanentDeletion).not.toHaveBeenCalled();
      expect(deleteBulk).not.toHaveBeenCalled();
      expect(onAction).not.toHaveBeenCalled();
    });
  });
});
