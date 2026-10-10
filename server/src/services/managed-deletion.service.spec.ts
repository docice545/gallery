import { ForbiddenException } from '@nestjs/common';
import { StorageCore } from 'src/cores/storage.core.js';
import { ManagedDeletionConsentDto, PrepareManagedDeletionDto } from 'src/dtos/asset-deletion.dto.js';
import { AssetService } from 'src/services/asset.service.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { userStub } from 'test/fixtures/user.stub.js';
import { newTestService } from 'test/utils.js';

const proof = 'a'.repeat(64);
const roots = ['/test/upload/owner'];
const preparedPolicy = {
  ownerId: authStub.user1.user.id,
  scope: 'managed',
  enabled: false,
  roots,
  recoveryProof: proof,
  authorizedBy: authStub.admin.user.id,
  updatedAt: new Date(),
};

describe('managed deletion authorization', () => {
  const { sut, mocks } = newTestService(AssetService);
  beforeEach(() => {
    vi.clearAllMocks();
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
  it('reports unprepared and disabled when no policy exists', async () => {
    mocks.asset.getDeletionPolicy.mockResolvedValue(undefined);
    expect(await sut.managedDeletionStatus(authStub.user1)).toEqual({
      enabled: false,
      prepared: false,
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
  it('prepares only the administrator own managed roots, and never grants consent', async () => {
    mocks.user.get.mockResolvedValue({ ...userStub.admin, id: authStub.admin.user.id });
    mocks.storage.checkFileExists.mockResolvedValue(true);
    await sut.prepareManagedDeletion(authStub.admin, { recoveryProof: proof, verifiedExclusiveRoots: true });
    expect(mocks.asset.setDeletionPolicy).toHaveBeenCalledWith(authStub.admin.user.id, 'managed', {
      enabled: false,
      roots: [...roots, '/test/library/owner'],
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
    ).rejects.toThrow('ROOT_SHARED');
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });
  it('enables only the current owner managed policy, revalidating prepared roots', async () => {
    mocks.asset.updateManagedDeletionConsent.mockImplementation(async (_owner, enabled, validate) => {
      if (enabled) await validate(roots, proof);
    });
    await sut.setManagedDeletionConsent(authStub.user1, true);
    expect(mocks.asset.updateManagedDeletionConsent).toHaveBeenCalledWith(
      authStub.user1.user.id,
      true,
      expect.any(Function),
    );
    expect(mocks.storage.validateDeletionRoots).toHaveBeenCalledWith(roots, []);
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });
  it('revalidates current ownership and never accepts substituted roots', async () => {
    mocks.asset.updateManagedDeletionConsent.mockImplementation(async (_owner, _enabled, validate) =>
      validate(['/wrong'], proof),
    );
    await expect(sut.setManagedDeletionConsent(authStub.user1, true)).rejects.toThrow(
      'Root is not an existing owner library root',
    );
  });
  it('revokes consent without requiring writable storage', async () => {
    mocks.asset.updateManagedDeletionConsent.mockResolvedValue();
    await sut.setManagedDeletionConsent(authStub.user1, false);
    expect(mocks.storage.validateDeletionRoots).not.toHaveBeenCalled();
  });
  it('preflights every scope before a mixed request and blocks the authorized items too', async () => {
    mocks.access.asset.checkOwnerAccess.mockImplementation((_owner, ids) => Promise.resolve(new Set(ids)));
    mocks.asset.getDeletionReceipt.mockResolvedValue(undefined);
    mocks.asset.getDeletionScope.mockImplementation((_owner, id) =>
      Promise.resolve(id === 'managed' ? 'managed' : 'external-library'),
    );
    mocks.asset.getDeletionPolicy.mockImplementation((_owner, scope) =>
      Promise.resolve(scope === 'managed' ? { ...preparedPolicy, enabled: true } : undefined),
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
  it('Empty Trash reports per-scope counts and refuses missing external consent before deletion', async () => {
    mocks.asset.getOwnerTrash.mockResolvedValue([
      { id: 'm', libraryId: null },
      { id: 'e', libraryId: 'external' },
    ]);
    mocks.asset.getDeletionPolicy.mockImplementation((_owner, scope) =>
      Promise.resolve(scope === 'managed' ? { ...preparedPolicy, enabled: true } : undefined),
    );
    expect(await sut.trashDeletionScopes(authStub.user1)).toEqual([
      { scope: 'managed', count: 1, authorized: true },
      { scope: 'external', count: 1, authorized: false },
    ]);
    await expect(sut.emptyAuthorizedTrash(authStub.user1)).rejects.toThrow('LIBRARY_DELETION_NOT_AUTHORIZED');
    expect(mocks.asset.preparePermanentDeletion).not.toHaveBeenCalled();
  });
});
