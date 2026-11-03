import {
  AssetTypeEnum,
  deleteAssets,
  getStack,
  restoreAssets,
  type AssetResponseDto,
  type StackResponseDto,
} from '@immich/sdk';
import { toastManager } from '@immich/ui';
import { cleanup, fireEvent, waitFor } from '@testing-library/svelte';
import { tick } from 'svelte';
import { authManager } from '$lib/managers/auth-manager.svelte';
import { eventManager } from '$lib/managers/event-manager.svelte';
import { navigateToAsset } from '$lib/utils/asset-utils';
import { handleError } from '$lib/utils/handle-error';
import { renderWithTooltips } from '$tests/helpers';
import { assetFactory } from '@test-data/factories/asset-factory';
import { preferencesFactory } from '@test-data/factories/preferences-factory';
import { userAdminFactory } from '@test-data/factories/user-factory';
import AssetViewer from './AssetViewer.svelte';

vi.mock('@immich/sdk', async (original) => ({
  ...(await original()),
  deleteAssets: vi.fn(),
  getStack: vi.fn(),
  restoreAssets: vi.fn(),
}));
vi.mock('$lib/managers/feature-flags-manager.svelte', () => ({
  featureFlagsManager: { value: { trash: true }, valueOrUndefined: { authorizedDeletion: false } },
}));
vi.mock('$lib/utils/asset-utils', async (original) => ({ ...(await original()), navigateToAsset: vi.fn() }));
vi.mock('$lib/utils/handle-error', () => ({ handleError: vi.fn() }));
vi.mock('$lib/stores/ocr.svelte', () => ({
  ocrManager: { clear: vi.fn(), getAssetOcr: vi.fn(), hasOcrData: false, showOverlay: false },
}));
vi.mock('$lib/stores/face.svelte', () => ({ faceManager: { clear: vi.fn(), getAssetFaces: vi.fn() } }));
vi.mock('./PreloadManager.svelte', () => ({
  preloadManager: {
    initializePreloads: vi.fn(),
    updateAfterNavigation: vi.fn(),
    destroy: vi.fn(),
    cancelBeforeNavigation: vi.fn(),
  },
}));
vi.mock('./AssetViewerNavBar.svelte', async () => {
  const { default: component } = await import('./__test__/deletion-navbar.stub.svelte');
  return { default: component };
});
vi.mock('../assets/thumbnail/Thumbnail.svelte', async () => {
  const { default: component } = await import('./__test__/deletion-thumbnail.stub.svelte');
  return { default: component };
});
vi.mock('./PhotoViewer.svelte', async () => {
  const { default: component } = await import('@test-data/mocks/noop-component.svelte');
  return { default: component };
});

const makeStack = (assets: AssetResponseDto[], id = 'stack-1'): StackResponseDto => ({
  id,
  primaryAssetId: assets[0].id,
  assets,
});

const makeFrames = (count = 3, stackId = 'stack-1') =>
  Array.from({ length: count }, (_, index) =>
    assetFactory.build({
      id: `${stackId}-frame-${index}`,
      type: AssetTypeEnum.Image,
      livePhotoVideoId: null,
      ownerId: 'owner',
      isTrashed: false,
      stack: { id: stackId, primaryAssetId: `${stackId}-frame-0`, assetCount: count },
    }),
  );

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

describe('AssetViewer confirmed frame deletion', () => {
  beforeEach(() => {
    vi.clearAllMocks();
    authManager.setUser(userAdminFactory.build({ id: 'owner' }));
    authManager.setPreferences(preferencesFactory.build({ cast: { gCastEnabled: false } }));
    vi.spyOn(toastManager, 'primary').mockImplementation(() => ({}) as never);
    vi.mocked(navigateToAsset).mockImplementation((asset) => Promise.resolve(!!asset));
  });

  afterEach(() => {
    cleanup();
    authManager.reset();
    vi.restoreAllMocks();
  });

  it('advances within a stack from 3 to 2 to 1 frames and clears the singleton strip', async () => {
    const frames = makeFrames();
    let remaining = [...frames];
    vi.mocked(getStack).mockImplementation(() => Promise.resolve(makeStack(remaining)));
    vi.mocked(deleteAssets).mockImplementation(({ assetBulkDeleteDto }) => {
      remaining = remaining.filter(({ id }) => !assetBulkDeleteDto.ids.includes(id));
      return Promise.resolve(undefined as never);
    });
    const onAction = vi.fn();
    const view = renderWithTooltips(AssetViewer, { cursor: { current: frames[0] }, withStacked: true, onAction });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));

    await fireEvent.click(view.getByLabelText('delete'));
    await waitFor(() => expect(view.getByTestId('viewed-frame')).toHaveTextContent(frames[1].id));
    expect(view.getByTestId('stack-size')).toHaveTextContent('2');
    expect(view.queryByTestId(`stack-frame-${frames[0].id}`)).not.toBeInTheDocument();
    expect(navigateToAsset).not.toHaveBeenCalled();

    await waitFor(() => expect(view.getByLabelText('delete')).not.toBeDisabled());
    await fireEvent.click(view.getByLabelText('delete'));
    await waitFor(() => expect(view.getByTestId('viewed-frame')).toHaveTextContent(frames[2].id));
    expect(view.queryByTestId('stack-size')).not.toBeInTheDocument();
    expect(view.container.querySelector('#stack-slideshow')).not.toBeInTheDocument();
    expect(onAction).toHaveBeenLastCalledWith(
      expect.objectContaining({
        stackHandled: true,
        stack: null,
        replacementAsset: expect.objectContaining({ id: frames[2].id, stack: null }),
      }),
    );
  });

  it('uses the acknowledged frame id after selection changes during deletion', async () => {
    const frames = makeFrames();
    vi.mocked(getStack).mockResolvedValue(makeStack(frames));
    const pending = deferred<never>();
    vi.mocked(deleteAssets).mockReturnValue(pending.promise);
    const emit = vi.spyOn(eventManager, 'emit');
    const view = renderWithTooltips(AssetViewer, { cursor: { current: frames[0] }, withStacked: true });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));
    await fireEvent.click(view.getByLabelText('delete'));
    await fireEvent.click(view.getByTestId(`stack-frame-${frames[1].id}`));
    await fireEvent.mouseEnter(view.getByTestId(`stack-frame-${frames[2].id}`));
    pending.resolve(undefined as never);
    await waitFor(() => expect(emit).toHaveBeenCalledWith('AssetsDelete', [frames[0].id]));
    expect(view.getByTestId('viewed-frame')).toHaveTextContent(frames[1].id);
  });

  it('updates the selected frame for stack keyboard navigation with a plain cursor prop', async () => {
    const frames = makeFrames();
    vi.mocked(getStack).mockResolvedValue(makeStack(frames));
    const view = renderWithTooltips(AssetViewer, { cursor: { current: frames[0] }, withStacked: true });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));
    await fireEvent.keyDown(document, { key: 'ArrowDown' });
    await waitFor(() => expect(view.getByTestId('viewed-frame')).toHaveTextContent(frames[1].id));
  });

  it('deduplicates a websocket removal and its later local acknowledgement', async () => {
    const frames = makeFrames();
    vi.mocked(getStack).mockResolvedValue(makeStack(frames));
    const pending = deferred<never>();
    vi.mocked(deleteAssets).mockReturnValue(pending.promise);
    const onAction = vi.fn();
    const view = renderWithTooltips(AssetViewer, { cursor: { current: frames[0] }, withStacked: true, onAction });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));
    await fireEvent.click(view.getByLabelText('delete'));
    eventManager.emit('AssetsDelete', [frames[0].id]);
    await waitFor(() => expect(view.getByTestId('viewed-frame')).toHaveTextContent(frames[1].id));
    pending.resolve(undefined as never);
    await waitFor(() => expect(view.getByLabelText('delete')).not.toBeDisabled());
    expect(onAction).toHaveBeenCalledOnce();
    expect(view.getByTestId('viewed-frame')).toHaveTextContent(frames[1].id);
  });

  it('keeps deletion disabled until a duplicate websocket reconciliation has finished', async () => {
    const frames = makeFrames();
    const refreshedStack = deferred<StackResponseDto>();
    const deletion = deferred<never>();
    vi.mocked(getStack).mockResolvedValueOnce(makeStack(frames)).mockReturnValue(refreshedStack.promise);
    vi.mocked(deleteAssets).mockReturnValue(deletion.promise);
    const view = renderWithTooltips(AssetViewer, { cursor: { current: frames[0] }, withStacked: true });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));
    await fireEvent.click(view.getByLabelText('delete'));
    eventManager.emit('AssetsDelete', [frames[0].id]);
    deletion.resolve(undefined as never);
    await waitFor(() => expect(toastManager.primary).toHaveBeenCalled());
    await tick();
    await tick();
    expect(view.getByLabelText('delete')).toBeDisabled();
    refreshedStack.resolve(makeStack(frames.slice(1)));
    await waitFor(() => expect(view.getByLabelText('delete')).not.toBeDisabled());
  });

  it('ignores a stale getStack response after navigation to another stack', async () => {
    const first = makeFrames();
    const second = makeFrames(2, 'stack-2');
    const pending = deferred<StackResponseDto>();
    vi.mocked(getStack).mockImplementation(({ id }) =>
      id === 'stack-1' ? pending.promise : Promise.resolve(makeStack(second, 'stack-2')),
    );
    const view = renderWithTooltips(AssetViewer, { cursor: { current: first[0] }, withStacked: true });
    await waitFor(() => expect(getStack).toHaveBeenCalledWith({ id: 'stack-1' }));
    await view.rerender({
      component: AssetViewer,
      componentProps: { cursor: { current: second[0] }, withStacked: true },
    } as never);
    await waitFor(() => expect(view.getByTestId(`stack-frame-${second[0].id}`)).toBeInTheDocument());
    pending.resolve(makeStack(first));
    await tick();
    await tick();
    await waitFor(() => expect(view.getByTestId(`stack-frame-${second[1].id}`)).toBeInTheDocument());
    expect(view.queryByTestId(`stack-frame-${first[0].id}`)).not.toBeInTheDocument();
  });

  it('advances or closes once when all visible stack frames are removed', async () => {
    const frames = makeFrames();
    vi.mocked(getStack).mockResolvedValue(makeStack(frames));
    const onClose = vi.fn();
    const view = renderWithTooltips(AssetViewer, { cursor: { current: frames[0] }, withStacked: true, onClose });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));
    eventManager.emit(
      'AssetsDelete',
      frames.map(({ id }) => id),
    );
    await waitFor(() => expect(onClose).toHaveBeenCalledOnce());
    eventManager.emit(
      'AssetsDelete',
      frames.map(({ id }) => id),
    );
    expect(onClose).toHaveBeenCalledOnce();
    expect(view.container.querySelector('#stack-slideshow')).not.toBeInTheDocument();
  });

  it('shows the restored frame and stack again after the Trash toast Undo', async () => {
    const frames = makeFrames();
    let remaining = [...frames];
    vi.mocked(getStack).mockImplementation(() => Promise.resolve(makeStack(remaining)));
    vi.mocked(deleteAssets).mockImplementation(({ assetBulkDeleteDto }) => {
      remaining = remaining.filter(({ id }) => !assetBulkDeleteDto.ids.includes(id));
      return Promise.resolve(undefined as never);
    });
    vi.mocked(restoreAssets).mockImplementation(() => {
      remaining = [...frames];
      return Promise.resolve({ count: 1 });
    });
    const onUndoDelete = vi.fn(async () => {
      await view.rerender({
        component: AssetViewer,
        componentProps: { cursor: { current: { ...frames[0] } }, withStacked: true, onUndoDelete },
      } as never);
    });
    const view = renderWithTooltips(AssetViewer, {
      cursor: { current: frames[0] },
      withStacked: true,
      onUndoDelete,
    });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));

    await fireEvent.click(view.getByLabelText('delete'));
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('2'));
    const toast = vi.mocked(toastManager.primary).mock.calls.at(-1)?.[0] as {
      button?: { onclick: () => Promise<void> };
    };
    expect(toast.button).toBeDefined();
    await toast.button!.onclick();

    await waitFor(() => expect(onUndoDelete).toHaveBeenCalledOnce());
    expect(restoreAssets).toHaveBeenCalledWith({ bulkIdsDto: { ids: [frames[0].id] } });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));
    expect(view.getByTestId('viewed-frame')).toHaveTextContent(frames[0].id);
    expect(view.getByTestId(`stack-frame-${frames[0].id}`)).toBeInTheDocument();
  });

  it('keeps selection and stack state when the deletion API fails', async () => {
    const frames = makeFrames();
    vi.mocked(getStack).mockResolvedValue(makeStack(frames));
    vi.mocked(deleteAssets).mockRejectedValue(new Error('offline'));
    const onAction = vi.fn();
    const view = renderWithTooltips(AssetViewer, { cursor: { current: frames[0] }, withStacked: true, onAction });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));
    await fireEvent.click(view.getByLabelText('delete'));
    await waitFor(() => expect(handleError).toHaveBeenCalled());
    expect(view.getByTestId('viewed-frame')).toHaveTextContent(frames[0].id);
    expect(view.getByTestId('stack-size')).toHaveTextContent('3');
    expect(onAction).not.toHaveBeenCalled();
    expect(navigateToAsset).not.toHaveBeenCalled();
  });

  it('uses the authoritative promoted primary while keeping the next selected frame', async () => {
    const frames = makeFrames();
    const survivingStack = { ...makeStack(frames.slice(1)), primaryAssetId: frames[2].id };
    vi.mocked(getStack).mockResolvedValueOnce(makeStack(frames)).mockResolvedValue(survivingStack);
    vi.mocked(deleteAssets).mockResolvedValue(undefined as never);
    const onAction = vi.fn();
    const view = renderWithTooltips(AssetViewer, { cursor: { current: frames[0] }, withStacked: true, onAction });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));
    await fireEvent.click(view.getByLabelText('delete'));
    await waitFor(() =>
      expect(onAction).toHaveBeenCalledWith(
        expect.objectContaining({
          replacementAsset: expect.objectContaining({ id: frames[2].id }),
          stack: expect.objectContaining({ primaryAssetId: frames[2].id }),
        }),
      ),
    );
    expect(view.getByTestId('viewed-frame')).toHaveTextContent(frames[1].id);
  });

  it('selects the previous frame when deleting the last frame in stack order', async () => {
    const frames = makeFrames();
    vi.mocked(getStack)
      .mockResolvedValueOnce(makeStack(frames))
      .mockResolvedValue(makeStack(frames.slice(0, 2)));
    vi.mocked(deleteAssets).mockResolvedValue(undefined as never);
    const view = renderWithTooltips(AssetViewer, { cursor: { current: frames[2] }, withStacked: true });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));
    await fireEvent.click(view.getByLabelText('delete'));
    await waitFor(() => expect(view.getByTestId('viewed-frame')).toHaveTextContent(frames[1].id));
  });

  it('finishes the final standalone frame in the same stack deletion workflow', async () => {
    const frames = makeFrames();
    let remaining = [...frames];
    vi.mocked(getStack).mockImplementation(() => Promise.resolve(makeStack(remaining)));
    vi.mocked(deleteAssets).mockImplementation(({ assetBulkDeleteDto }) => {
      remaining = remaining.filter(({ id }) => !assetBulkDeleteDto.ids.includes(id));
      return Promise.resolve(undefined as never);
    });
    const onClose = vi.fn();
    const view = renderWithTooltips(AssetViewer, { cursor: { current: frames[0] }, withStacked: true, onClose });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));
    for (const frame of frames) {
      await waitFor(() => expect(view.getByTestId('viewed-frame')).toHaveTextContent(frame.id));
      await waitFor(() => expect(view.getByLabelText('delete')).not.toBeDisabled());
      await fireEvent.click(view.getByLabelText('delete'));
    }
    await waitFor(() => expect(onClose).toHaveBeenCalledOnce());
  });

  it('reconciles deletion before the initial stack request has completed', async () => {
    const frames = makeFrames();
    const initial = deferred<StackResponseDto>();
    vi.mocked(getStack)
      .mockReturnValueOnce(initial.promise)
      .mockResolvedValue(makeStack(frames.slice(1)));
    vi.mocked(deleteAssets).mockResolvedValue(undefined as never);
    const view = renderWithTooltips(AssetViewer, { cursor: { current: frames[0] }, withStacked: true });
    await waitFor(() => expect(getStack).toHaveBeenCalledOnce());
    await fireEvent.click(view.getByLabelText('delete'));
    await waitFor(() => expect(view.getByTestId('viewed-frame')).toHaveTextContent(frames[1].id));
    initial.resolve(makeStack(frames));
    await tick();
    await tick();
    expect(view.queryByTestId(`stack-frame-${frames[0].id}`)).not.toBeInTheDocument();
  });

  it('keeps another stack selected when an earlier deletion acknowledgement arrives', async () => {
    const first = makeFrames();
    const second = makeFrames(2, 'stack-2');
    const pending = deferred<never>();
    vi.mocked(getStack).mockImplementation(({ id }) =>
      Promise.resolve(makeStack(id === 'stack-1' ? first : second, id)),
    );
    vi.mocked(deleteAssets).mockReturnValue(pending.promise);
    const onAction = vi.fn();
    const view = renderWithTooltips(AssetViewer, { cursor: { current: first[0] }, withStacked: true, onAction });
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('3'));
    await fireEvent.click(view.getByLabelText('delete'));
    await view.rerender({
      component: AssetViewer,
      componentProps: { cursor: { current: second[0] }, withStacked: true, onAction },
    } as never);
    await waitFor(() => expect(view.getByTestId('stack-size')).toHaveTextContent('2'));
    pending.resolve(undefined as never);
    await waitFor(() => expect(onAction).toHaveBeenCalled());
    expect(onAction.mock.calls[0][0]).toMatchObject({
      stackHandled: true,
      replacementAsset: expect.objectContaining({ id: first[1].id }),
    });
    expect(view.getByTestId('viewed-frame')).toHaveTextContent(second[0].id);
    expect(view.getByTestId(`stack-frame-${second[1].id}`)).toBeInTheDocument();
    expect(navigateToAsset).not.toHaveBeenCalled();
  });
});
