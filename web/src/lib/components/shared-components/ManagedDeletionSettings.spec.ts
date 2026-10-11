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
  isHttpError: (error: unknown) => !!(error as { __http?: boolean })?.__http,
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
  it('can revoke existing consent even when signed evidence is no longer prepared', async () => {
    vi.mocked(managedDeletionStatus).mockResolvedValue({ enabled: true, prepared: false, canPrepare: false });
    render(ManagedDeletionSettings);
    await fireEvent.click(screen.getByText('managed_deletion_title'));
    await waitFor(() => expect(screen.getByRole('button', { name: 'managed_deletion_disable' })).toBeEnabled());
    expect(screen.getByText('managed_deletion_preparation_required')).toBeInTheDocument();
    expect(screen.queryByText('managed_deletion_enabled')).not.toBeInTheDocument();
    await fireEvent.click(screen.getByRole('button', { name: 'managed_deletion_disable' }));
    await waitFor(() => expect(setManagedDeletionConsent).toHaveBeenCalledOnce());
    expect(modalManager.showDialog).not.toHaveBeenCalled();
  });
  it('refreshes expired preparation after a consent rejection while preserving the localized error', async () => {
    vi.mocked(managedDeletionStatus)
      .mockResolvedValueOnce({ enabled: false, prepared: true, canPrepare: false })
      .mockResolvedValue({ enabled: false, prepared: false, canPrepare: false });
    vi.mocked(setManagedDeletionConsent).mockRejectedValueOnce({
      __http: true,
      data: { message: 'DELETION_RECOVERY_EXPIRED', error: 'Conflict', statusCode: 409 },
    });
    await open();
    await fireEvent.click(screen.getByRole('button', { name: 'managed_deletion_enable' }));
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('managed_deletion_recovery_expired'));
    expect(screen.getByText('managed_deletion_preparation_required')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'managed_deletion_enable' })).toBeDisabled();
    expect(managedDeletionStatus).toHaveBeenCalledTimes(2);
    expect(setManagedDeletionConsent).toHaveBeenCalledOnce();
  });
  it.each([
    ['DELETION_RECOVERY_UNAVAILABLE', 'managed_deletion_recovery_missing'],
    ['DELETION_RECOVERY_INVALID', 'managed_deletion_recovery_invalid'],
    ['DELETION_RECOVERY_EXPIRED', 'managed_deletion_recovery_expired'],
    ['DELETION_RECOVERY_SCOPE_MISMATCH', 'managed_deletion_recovery_scope_mismatch'],
    ['DELETION_ROOT_CHANGED', 'managed_deletion_roots_changed'],
    ['OVERLAPPING_OWNER_ROOTS', 'managed_deletion_roots_changed'],
    ['UNSUPPORTED_DELETION_FILESYSTEM', 'managed_deletion_roots_changed'],
    ['DELETION_QUARANTINE_CONFLICT', 'managed_deletion_roots_changed'],
  ])('shows localized guidance for %s without granting consent', async (code, key) => {
    vi.mocked(managedDeletionStatus).mockResolvedValue({ enabled: false, prepared: false, canPrepare: true });
    vi.mocked(prepareManagedDeletion).mockRejectedValueOnce({
      __http: true,
      data: JSON.stringify({ message: code, error: 'Conflict', statusCode: 409 }),
    });
    await open();
    expect(screen.getByText('managed_deletion_recovery_help')).toBeInTheDocument();
    await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'a'.repeat(64) } });
    await fireEvent.click(screen.getByRole('checkbox'));
    await fireEvent.click(screen.getByRole('button', { name: 'managed_deletion_prepare' }));
    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent(key));
    expect(screen.getByRole('alert')).not.toHaveTextContent(code);
    expect(screen.getByRole('button', { name: 'managed_deletion_enable' })).toBeDisabled();
    expect(setManagedDeletionConsent).not.toHaveBeenCalled();
  });
});
