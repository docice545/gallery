import {
  libraryDeletionScopes,
  libraryDeletionStatus,
  setLibraryDeletionConsent,
  setManagedDeletionConsent,
} from '@immich/sdk';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ExternalDeletionSettings from './ExternalDeletionSettings.svelte';

vi.mock('@immich/sdk', async (original) => ({
  ...(await original()),
  libraryDeletionScopes: vi.fn(),
  libraryDeletionStatus: vi.fn(),
  setLibraryDeletionConsent: vi.fn(),
  setManagedDeletionConsent: vi.fn(),
}));
beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(libraryDeletionScopes).mockResolvedValue([
    { scope: 'own-library', name: 'My library', count: 0, authorized: true },
  ]);
  vi.mocked(libraryDeletionStatus).mockResolvedValue({ enabled: true, prepared: true, canPrepare: false });
  vi.mocked(setLibraryDeletionConsent).mockResolvedValue(undefined as never);
});
describe('external owner library selection in Trash', () => {
  it('includes empty own libraries for revocation without granting any consent on mount', async () => {
    render(ExternalDeletionSettings);
    await fireEvent.click(screen.getByText('external_deletion_title'));
    await waitFor(() => expect(screen.getByText('My library (own-library)')).toBeInTheDocument());
    expect(libraryDeletionScopes).toHaveBeenCalledOnce();
    expect(setLibraryDeletionConsent).not.toHaveBeenCalled();
    expect(setManagedDeletionConsent).not.toHaveBeenCalled();
    await fireEvent.click(screen.getByText('My library (own-library)'));
    await waitFor(() => expect(screen.getByRole('button', { name: 'managed_deletion_disable' })).toBeEnabled());
    await fireEvent.click(screen.getByRole('button', { name: 'managed_deletion_disable' }));
    await waitFor(() =>
      expect(setLibraryDeletionConsent).toHaveBeenCalledWith({
        id: 'own-library',
        managedDeletionConsentDto: { enabled: false, confirmed: true },
      }),
    );
  });
  it('empty list explains that no owned external library is available', async () => {
    vi.mocked(libraryDeletionScopes).mockResolvedValue([]);
    render(ExternalDeletionSettings);
    await fireEvent.click(screen.getByText('external_deletion_title'));
    await waitFor(() => expect(screen.getByText('external_deletion_empty')).toBeInTheDocument());
    expect(libraryDeletionStatus).not.toHaveBeenCalled();
  });
  it('failed discovery stays visibly failed and can be retried without mutation', async () => {
    vi.mocked(libraryDeletionScopes).mockRejectedValueOnce(new Error('offline')).mockResolvedValue([]);
    render(ExternalDeletionSettings);
    await fireEvent.click(screen.getByText('external_deletion_title'));
    await waitFor(() => expect(screen.getByRole('alert')).toBeInTheDocument());
    await fireEvent.click(screen.getByRole('button', { name: 'retry' }));
    await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument());
    expect(libraryDeletionScopes).toHaveBeenCalledTimes(2);
    expect(setLibraryDeletionConsent).not.toHaveBeenCalled();
  });
});
