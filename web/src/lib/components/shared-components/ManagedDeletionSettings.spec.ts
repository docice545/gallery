import { managedDeletionStatus, prepareManagedDeletion, setManagedDeletionConsent } from '@immich/sdk';
import { modalManager } from '@immich/ui';
import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import ManagedDeletionSettings from './ManagedDeletionSettings.svelte';

vi.mock('@immich/sdk', async (original) => ({
  ...(await original()),
  managedDeletionStatus: vi.fn(),
  prepareManagedDeletion: vi.fn(),
  setManagedDeletionConsent: vi.fn(),
}));
beforeEach(() => {
  vi.clearAllMocks();
  vi.mocked(managedDeletionStatus).mockResolvedValue({ enabled: false, prepared: true, canPrepare: false });
  vi.mocked(setManagedDeletionConsent).mockResolvedValue(undefined as never);
  vi.mocked(prepareManagedDeletion).mockResolvedValue(undefined as never);
  vi.spyOn(modalManager, 'showDialog').mockResolvedValue(true);
});
const open = async () => {
  render(ManagedDeletionSettings);
  await fireEvent.click(screen.getByText('managed_deletion_title'));
  await waitFor(() => expect(screen.getByRole('button', { name: 'managed_deletion_enable' })).toBeInTheDocument());
};
describe('explicit owner managed consent', () => {
  it('requires confirmation and sends only the managed consent contract', async () => {
    await open();
    await fireEvent.click(screen.getByRole('button', { name: 'managed_deletion_enable' }));
    await waitFor(() =>
      expect(setManagedDeletionConsent).toHaveBeenCalledWith({
        managedDeletionConsentDto: { enabled: true, confirmed: true },
      }),
    );
    expect(modalManager.showDialog).toHaveBeenCalledWith({ prompt: 'managed_deletion_confirm' });
    expect(prepareManagedDeletion).not.toHaveBeenCalled();
    expect(screen.queryByRole('textbox')).not.toBeInTheDocument();
  });
  it('does not silently grant permission when confirmation is cancelled', async () => {
    vi.mocked(modalManager.showDialog).mockResolvedValue(false);
    await open();
    await fireEvent.click(screen.getByRole('button', { name: 'managed_deletion_enable' }));
    expect(setManagedDeletionConsent).not.toHaveBeenCalled();
  });
  it('cannot enable unprepared storage and explains the administrator prerequisite', async () => {
    vi.mocked(managedDeletionStatus).mockResolvedValue({ enabled: false, prepared: false, canPrepare: false });
    await open();
    expect(screen.getByRole('button', { name: 'managed_deletion_enable' })).toBeDisabled();
    expect(screen.getByText('managed_deletion_preparation_required')).toBeInTheDocument();
  });
  it('revokes permission without a destructive confirmation', async () => {
    vi.mocked(managedDeletionStatus).mockResolvedValue({ enabled: true, prepared: true, canPrepare: false });
    render(ManagedDeletionSettings);
    await fireEvent.click(screen.getByText('managed_deletion_title'));
    await waitFor(() => expect(screen.getByRole('button', { name: 'managed_deletion_disable' })).toBeInTheDocument());
    await fireEvent.click(screen.getByRole('button', { name: 'managed_deletion_disable' }));
    await waitFor(() =>
      expect(setManagedDeletionConsent).toHaveBeenCalledWith({
        managedDeletionConsentDto: { enabled: false, confirmed: true },
      }),
    );
    expect(modalManager.showDialog).not.toHaveBeenCalled();
  });
  it('requires supplied evidence and explicit administrator attestation before preparation', async () => {
    vi.mocked(managedDeletionStatus).mockResolvedValue({ enabled: false, prepared: false, canPrepare: true });
    await open();
    const prepare = screen.getByRole('button', { name: 'managed_deletion_prepare' });
    expect(prepare).toBeDisabled();
    await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'a'.repeat(64) } });
    expect(prepare).toBeDisabled();
    await fireEvent.click(screen.getByRole('checkbox'));
    await fireEvent.click(prepare);
    await waitFor(() =>
      expect(prepareManagedDeletion).toHaveBeenCalledWith({
        prepareManagedDeletionDto: {
          recoveryProof: 'a'.repeat(64),
          verifiedExclusiveRoots: true,
        },
      }),
    );
    expect(setManagedDeletionConsent).not.toHaveBeenCalled();
  });
  it('does not claim successful consent on a failed request', async () => {
    vi.mocked(setManagedDeletionConsent).mockRejectedValueOnce(new Error('timeout'));
    await open();
    await fireEvent.click(screen.getByRole('button', { name: 'managed_deletion_enable' }));
    await waitFor(() => expect(screen.getByRole('alert')).toBeInTheDocument());
    expect(screen.queryByText('managed_deletion_enabled')).not.toBeInTheDocument();
  });
});
