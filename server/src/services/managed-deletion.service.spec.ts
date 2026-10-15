import { ForbiddenException } from '@nestjs/common';
import { StorageCore } from 'src/cores/storage.core.js';
import { ManagedDeletionConsentDto, PrepareManagedDeletionDto } from 'src/dtos/asset-deletion.dto.js';
import { AssetService } from 'src/services/asset.service.js';
import * as deletionRoots from 'src/utils/authorized-deletion.js';
import * as recovery from 'src/utils/deletion-recovery.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { userStub } from 'test/fixtures/user.stub.js';
import { newTestService } from 'test/utils.js';

// Recovery-proof cryptographic and filesystem validation has its own focused suite. These
// service tests isolate authorization and consent routing, so the verifier is a valid-proof
// boundary here rather than a second copy of the evidence fixture.
vi.mock('src/utils/recovery-evidence.js', () => ({
  verifyRecoveryProof: vi.fn().mockResolvedValue(undefined),
}));

const proof = 'a'.repeat(64);
const roots = ['/test/upload/owner'];
const rootIdentities = roots.map((path) => ({
  path,
  device: '1',
  inode: '2',
  mountId: '3',
  mountNamespace: 'mnt:[1]',
  mountType: 'ext4',
  mountSource: '/dev/test',
  mountRoot: '/',
  mountTarget: '/test',
}));
const expiresAt = new Date(Date.now() + 3_600_000);
const preparedPolicy = {
  ownerId: authStub.user1.user.id,
  scope: 'managed',
  authorizationMode: 'recovery' as const,
  enabled: false,
  roots,
  rootIdentities,
  recoveryExpiresAt: expiresAt,
  recoveryProof: proof,
  authorizedBy: authStub.admin.user.id,
  updatedAt: new Date(),
};

describe('managed deletion authorization', () => {
  const { sut, mocks } = newTestService(AssetService);
  beforeEach(() => {
    vi.clearAllMocks();
    vi.spyOn(recovery, 'verifyRecoveryEvidence').mockResolvedValue({
      digest: proof,
      expiresAt: expiresAt.toISOString(),
    });
    vi.spyOn(deletionRoots, 'collectRootIdentities').mockResolvedValue(rootIdentities);
    vi.spyOn(deletionRoots, 'refreshStorageRootIdentities').mockResolvedValue(rootIdentities);
    vi.spyOn(deletionRoots, 'assertWritableDeletionRoots').mockResolvedValue();
    mocks.storage.checkFileExists.mockImplementation((path) => Promise.resolve(path === roots[0]));
    mocks.storage.validateDeletionRoots.mockResolvedValue(rootIdentities);
    mocks.asset.getDeletionRootsForOtherOwners.mockResolvedValue({ external: [], users: [] });
    mocks.user.get.mockResolvedValue(userStub.user1);
    vi.spyOn(StorageCore, 'getFolderLocation').mockReturnValue(roots[0]);
    vi.spyOn(StorageCore, 'getLibraryFolder').mockReturnValue('/test/library/owner');
  });
  afterEach(() => vi.restoreAllMocks());

  it('rejects consent without explicit confirmation and preparation without recovery attestation', () => {
    expect(ManagedDeletionConsentDto.schema.safeParse({ enabled: true }).success).toBe(false);
    expect(ManagedDeletionConsentDto.schema.safeParse({ enabled: true, confirmed: false }).success).toBe(false);
    expect(
      PrepareManagedDeletionDto.schema.safeParse({ recoveryProof: proof, verifiedExclusiveRoots: false }).success,
    ).toBe(false);
    expect(
      PrepareManagedDeletionDto.schema.safeParse({ recoveryProof: 'invented', verifiedExclusiveRoots: true }).success,
    ).toBe(false);
  });
  it('accepts the signed-envelope digest emitted by release authorization tooling', () => {
    expect(
      PrepareManagedDeletionDto.schema.safeParse({ recoveryProof: proof, verifiedExclusiveRoots: true }).success,
    ).toBe(true);
  });
  it('reports ordinary managed deletion ready without administrator preparation', async () => {
    mocks.asset.getDeletionPolicy.mockResolvedValue(undefined);
    expect(await sut.managedDeletionStatus(authStub.user1)).toEqual({
      enabled: true,
      prepared: true,
      canPrepare: false,
    });
  });
  it('does not reveal roots or recovery evidence to the status caller', async () => {
    mocks.asset.getDeletionPolicy.mockResolvedValue(preparedPolicy);
    expect(await sut.managedDeletionStatus(authStub.user1)).toEqual({
      enabled: false,
      prepared: true,
      canPrepare: false,
    });
  });
  it('forbids non-administrator preparation before any filesystem or policy work', async () => {
    await expect(
      sut.prepareManagedDeletion(authStub.user1, { recoveryProof: proof, verifiedExclusiveRoots: true }),
    ).rejects.toBeInstanceOf(ForbiddenException);
    expect(mocks.storage.validateDeletionRoots).not.toHaveBeenCalled();
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });
  it('does not let administrator preparation substitute for managed owner consent', async () => {
    await expect(
      sut.setDeletionPolicy(authStub.admin, {
        ownerId: authStub.user1.user.id,
        scope: 'managed',
        enabled: true,
        roots,
        recoveryProof: proof,
        verifiedExclusiveRoots: true,
      }),
    ).rejects.toThrow('Managed deletion requires separate owner consent');
    expect(mocks.asset.getDeletionPolicy).not.toHaveBeenCalled();
    expect(mocks.storage.validateDeletionRoots).not.toHaveBeenCalled();
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });
  it('prepares only the administrator own managed roots, and never grants consent', async () => {
    mocks.user.get.mockResolvedValue({ ...userStub.admin, id: authStub.admin.user.id });
    mocks.storage.checkFileExists.mockResolvedValue(true);
    await sut.prepareManagedDeletion(authStub.admin, { recoveryProof: proof, verifiedExclusiveRoots: true });
    expect(mocks.asset.setDeletionPolicy).toHaveBeenCalledWith(authStub.admin.user.id, 'managed', {
      enabled: false,
      roots: [...roots, '/test/library/owner'],
      rootIdentities,
      recoveryExpiresAt: expiresAt,
      recoveryProof: proof,
      authorizedBy: authStub.admin.user.id,
    });
    expect(mocks.storage.validateDeletionRoots).toHaveBeenCalled();
  });
  it('does not prepare missing storage roots', async () => {
    mocks.storage.checkFileExists.mockResolvedValue(false);
    await expect(
      sut.prepareManagedDeletion(authStub.admin, { recoveryProof: proof, verifiedExclusiveRoots: true }),
    ).rejects.toThrow();
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });
  it('does not prepare roots rejected by canonical ownership validation', async () => {
    mocks.storage.checkFileExists.mockResolvedValue(true);
    mocks.storage.validateDeletionRoots.mockRejectedValueOnce(new Error('ROOT_SHARED'));
    await expect(
      sut.prepareManagedDeletion(authStub.admin, { recoveryProof: proof, verifiedExclusiveRoots: true }),
    ).rejects.toThrow('ORIGINAL_DELETE_FAILED');
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });
  it('never reauthorizes replaced physical roots during a legacy managed grant upgrade', async () => {
    mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set(['asset']));
    mocks.asset.getDeletionReceipt.mockResolvedValue(undefined);
    mocks.asset.getDeletionScope.mockResolvedValue('managed');
    mocks.asset.getDeletionPolicy.mockResolvedValue({ ...preparedPolicy, enabled: true });
    vi.mocked(deletionRoots.refreshStorageRootIdentities).mockRejectedValue(
      new deletionRoots.DeletionError('DELETION_ROOT_CHANGED'),
    );
    expect(await sut.permanentlyDelete(authStub.user1, ['asset'])).toEqual([
      { id: 'asset', scope: 'managed', state: 'blocked', code: 'DELETION_ROOT_CHANGED' },
    ]);
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
    expect(mocks.asset.preparePermanentDeletion).not.toHaveBeenCalled();
  });
  it('configures only the current owner managed storage without recovery evidence', async () => {
    mocks.asset.getDeletionPolicy.mockResolvedValue(undefined);
    await sut.setManagedDeletionConsent(authStub.user1, true);
    expect(mocks.asset.setDeletionPolicy).toHaveBeenCalledWith(
      authStub.user1.user.id,
      'managed',
      expect.objectContaining({
        enabled: true,
        authorizationMode: 'storage',
        recoveryProof: '',
        recoveryExpiresAt: null,
        roots,
        authorizedBy: authStub.user1.user.id,
      }),
    );
    expect(recovery.verifyRecoveryEvidence).not.toHaveBeenCalled();
    expect(mocks.asset.updateLibraryDeletionConsent).not.toHaveBeenCalled();
  });
  it('rejects unavailable managed roots without fabricating authorization', async () => {
    mocks.storage.checkFileExists.mockResolvedValue(false);
    await expect(sut.setManagedDeletionConsent(authStub.user1, true)).rejects.toThrow('UNSUPPORTED_DELETION_SCOPE');
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });
  it('revokes consent without requiring writable storage', async () => {
    mocks.asset.getDeletionPolicy.mockResolvedValue(preparedPolicy);
    await sut.setManagedDeletionConsent(authStub.user1, false);
    expect(mocks.asset.setDeletionPolicy).toHaveBeenCalledWith(
      authStub.user1.user.id,
      'managed',
      expect.objectContaining({ enabled: false, authorizationMode: 'storage' }),
    );
    expect(mocks.storage.validateDeletionRoots).not.toHaveBeenCalled();
  });
  it('preflights every scope before a mixed request and blocks the authorized items too', async () => {
    mocks.access.asset.checkOwnerAccess.mockImplementation((_owner, ids) => Promise.resolve(new Set(ids)));
    mocks.asset.getDeletionReceipt.mockResolvedValue(undefined);
    mocks.asset.getDeletionScope.mockImplementation((_owner, id) =>
      Promise.resolve(id === 'managed' ? 'managed' : 'external-library'),
    );
    mocks.asset.getDeletionPolicy.mockImplementation((_owner, scope) =>
      Promise.resolve(
        scope === 'managed'
          ? { ...preparedPolicy, authorizationMode: 'storage', authorizedBy: authStub.user1.user.id, enabled: true }
          : undefined,
      ),
    );
    expect(await sut.permanentlyDelete(authStub.user1, ['managed', 'external'])).toEqual([
      { id: 'managed', scope: 'managed', state: 'blocked', code: 'DELETION_BATCH_NOT_AUTHORIZED' },
      { id: 'external', scope: 'external-library', state: 'blocked', code: 'LIBRARY_DELETION_NOT_AUTHORIZED' },
    ]);
    expect(mocks.asset.preparePermanentDeletion).not.toHaveBeenCalled();
    expect(mocks.storage.snapshotOriginal).not.toHaveBeenCalled();
  });
  it('does not leak the scope of assets belonging to another owner', async () => {
    mocks.access.asset.checkOwnerAccess.mockResolvedValue(new Set());
    mocks.asset.getDeletionReceipt.mockResolvedValue(undefined);
    const [result] = await sut.deletionPreflight(authStub.user1, ['foreign']);
    expect(result.authorized).toBe(false);
    expect(result.scope).toBeUndefined();
    expect(mocks.asset.getDeletionScope).not.toHaveBeenCalled();
  });
  it('blocks a previously prepared scope if another owner root now aliases its storage', async () => {
    mocks.access.asset.checkOwnerAccess.mockImplementation((_owner, ids) => Promise.resolve(new Set(ids)));
    mocks.asset.getDeletionReceipt.mockResolvedValue(undefined);
    mocks.asset.getDeletionScope.mockResolvedValue('managed');
    mocks.asset.getDeletionPolicy.mockResolvedValue({
      ...preparedPolicy,
      authorizationMode: 'storage',
      authorizedBy: authStub.user1.user.id,
      enabled: true,
    });
    mocks.storage.validateDeletionRoots.mockRejectedValueOnce(
      new deletionRoots.DeletionError('OVERLAPPING_OWNER_ROOTS'),
    );
    expect(await sut.permanentlyDelete(authStub.user1, ['asset'])).toEqual([
      { id: 'asset', scope: 'managed', state: 'blocked', code: 'OVERLAPPING_OWNER_ROOTS' },
    ]);
    expect(mocks.asset.preparePermanentDeletion).not.toHaveBeenCalled();
    expect(mocks.storage.snapshotOriginal).not.toHaveBeenCalled();
  });
  it('Empty Trash reports per-scope counts and refuses missing external consent before deletion', async () => {
    mocks.asset.getOwnerTrash.mockResolvedValue([
      { id: 'm', libraryId: null },
      { id: 'e', libraryId: 'external' },
    ]);
    mocks.asset.getDeletionPolicy.mockImplementation((_owner, scope) =>
      Promise.resolve(
        scope === 'managed'
          ? { ...preparedPolicy, authorizationMode: 'storage', authorizedBy: authStub.user1.user.id, enabled: true }
          : undefined,
      ),
    );
    expect(await sut.trashDeletionScopes(authStub.user1)).toEqual([
      { scope: 'managed', count: 1, authorized: true },
      { scope: 'external', count: 1, authorized: false },
    ]);
    await expect(sut.emptyAuthorizedTrash(authStub.user1)).rejects.toThrow('LIBRARY_DELETION_NOT_AUTHORIZED');
    expect(mocks.asset.preparePermanentDeletion).not.toHaveBeenCalled();
  });
});
