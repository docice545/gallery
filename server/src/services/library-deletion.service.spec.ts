import { ForbiddenException } from '@nestjs/common';
import { AssetService } from 'src/services/asset.service.js';
import * as roots from 'src/utils/authorized-deletion.js';
import * as recovery from 'src/utils/deletion-recovery.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { userStub } from 'test/fixtures/user.stub.js';
import { newTestService } from 'test/utils.js';

const scope = 'a55e67c9-e435-4f04-ab10-d37c8c33800f';
const path = '/disposable/owner/external';
const proof = 'b'.repeat(64);
const identities = [
  {
    path,
    device: '1',
    inode: '2',
    mountId: '3',
    mountNamespace: 'mnt:[1]',
    mountType: 'nfs4',
    mountSource: 'synthetic:/volume/owner',
    mountRoot: '/',
    mountTarget: path,
  },
];
const expiresAt = new Date(Date.now() + 3_600_000);
const library = {
  id: scope,
  ownerId: authStub.user1.user.id,
  name: 'Disposable external',
  deletedAt: null,
  importPaths: [path],
  exclusionPatterns: [],
  createdAt: new Date(0),
  updatedAt: new Date(0),
  refreshedAt: null,
  createId: scope,
  updateId: scope,
};
const policy = {
  ownerId: library.ownerId,
  scope,
  enabled: false,
  roots: [path],
  rootIdentities: identities,
  recoveryProof: proof,
  recoveryExpiresAt: expiresAt,
  authorizedBy: authStub.admin.user.id,
  updatedAt: new Date(),
};

describe('external library owner consent reuses the verified deletion lifecycle', () => {
  const { sut, mocks } = newTestService(AssetService);
  beforeEach(() => {
    vi.resetAllMocks();
    mocks.library.get.mockResolvedValue(library);
    mocks.user.get.mockResolvedValue(userStub.user1);
    mocks.asset.getDeletionPolicy.mockResolvedValue(policy);
    mocks.asset.getDeletionRootsForOtherOwners.mockResolvedValue({ external: [], users: [] });
    mocks.storage.validateDeletionRoots.mockResolvedValue(identities);
    vi.spyOn(roots, 'collectRootIdentities').mockResolvedValue(identities);
    vi.spyOn(recovery, 'verifyRecoveryEvidence').mockResolvedValue({
      digest: proof,
      expiresAt: expiresAt.toISOString(),
    });
  });
  afterEach(() => vi.restoreAllMocks());

  it('administrator preparation cannot grant external owner consent', async () => {
    await expect(
      sut.setDeletionPolicy(authStub.admin, {
        ownerId: library.ownerId,
        scope,
        enabled: true,
        roots: [path],
        recoveryProof: proof,
        verifiedExclusiveRoots: true,
      }),
    ).rejects.toThrow('External deletion requires separate owner consent');
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });
  it('rejects non-admin preparation without touching storage', async () => {
    await expect(
      sut.prepareLibraryDeletion(authStub.user1, scope, {
        recoveryProof: proof,
        verifiedExclusiveRoots: true,
      }),
    ).rejects.toBeInstanceOf(ForbiddenException);
    expect(mocks.storage.validateDeletionRoots).not.toHaveBeenCalled();
  });
  it('prepares verified roots without enabling deletion', async () => {
    mocks.asset.getDeletionPolicy.mockResolvedValue(undefined);
    mocks.library.get.mockResolvedValue({ ...library, ownerId: authStub.admin.user.id });
    await sut.prepareLibraryDeletion(authStub.admin, scope, { recoveryProof: proof, verifiedExclusiveRoots: true });
    expect(recovery.verifyRecoveryEvidence).toHaveBeenCalledWith(proof, authStub.admin.user.id, scope, identities);
    expect(mocks.asset.setDeletionPolicy).toHaveBeenCalledWith(
      authStub.admin.user.id,
      scope,
      expect.objectContaining({ enabled: false, roots: [path], rootIdentities: identities, recoveryProof: proof }),
    );
  });
  it('reports verified preparation without revealing filesystem paths or evidence', async () => {
    expect(await sut.libraryDeletionStatus(authStub.user1, scope)).toEqual({
      enabled: false,
      prepared: true,
      canPrepare: false,
    });
  });
  it('does not treat another administrator enabled flag as owner consent', async () => {
    mocks.asset.getDeletionPolicy.mockResolvedValue({ ...policy, enabled: true });
    expect(await sut.libraryDeletionStatus(authStub.user1, scope)).toMatchObject({ enabled: false });
  });
  it('does not advertise preparation with an expired persisted policy', async () => {
    mocks.asset.getDeletionPolicy.mockResolvedValue({ ...policy, recoveryExpiresAt: new Date(0) });
    expect(await sut.libraryDeletionStatus(authStub.user1, scope)).toMatchObject({ prepared: false });
    expect(recovery.verifyRecoveryEvidence).not.toHaveBeenCalled();
  });
  it('owner consent revalidates the exact library scope and never changes managed authorization', async () => {
    mocks.asset.updateLibraryDeletionConsent.mockImplementation(async (_owner, _scope, enabled, validate) => {
      if (enabled) await validate([path], proof, identities);
    });
    await sut.setLibraryDeletionConsent(authStub.user1, scope, true);
    expect(mocks.asset.updateLibraryDeletionConsent).toHaveBeenCalledWith(
      library.ownerId,
      scope,
      true,
      expect.any(Function),
    );
    expect(recovery.verifyRecoveryEvidence).toHaveBeenCalledWith(proof, library.ownerId, scope, identities);
    expect(mocks.asset.updateManagedDeletionConsent).not.toHaveBeenCalled();
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });
  it('never accepts roots outside current library importPaths', async () => {
    mocks.asset.updateLibraryDeletionConsent.mockImplementation(async (_owner, _scope, _enabled, validate) =>
      validate(['/unapproved'], proof, identities),
    );
    await expect(sut.setLibraryDeletionConsent(authStub.user1, scope, true)).rejects.toThrow(
      'Root is not an existing owner library root',
    );
  });
  it('rejects expired signed evidence before consent can commit', async () => {
    vi.mocked(recovery.verifyRecoveryEvidence).mockRejectedValue(new roots.DeletionError('DELETION_RECOVERY_EXPIRED'));
    mocks.asset.updateLibraryDeletionConsent.mockImplementation(async (_owner, _scope, _enabled, validate) =>
      validate([path], proof, identities),
    );
    await expect(sut.setLibraryDeletionConsent(authStub.user1, scope, true)).rejects.toThrow(
      'DELETION_RECOVERY_EXPIRED',
    );
  });
  it('revocation requires no recovery verification or filesystem availability', async () => {
    await sut.setLibraryDeletionConsent(authStub.user1, scope, false);
    expect(mocks.asset.updateLibraryDeletionConsent).toHaveBeenCalledWith(
      library.ownerId,
      scope,
      false,
      expect.any(Function),
    );
    expect(mocks.storage.validateDeletionRoots).not.toHaveBeenCalled();
    expect(recovery.verifyRecoveryEvidence).not.toHaveBeenCalled();
  });
  it.each(['status', 'enable', 'revoke'])('another owner cannot perform %s', async (action) => {
    mocks.library.get.mockResolvedValue({ ...library, ownerId: authStub.admin.user.id });
    const request =
      action === 'status'
        ? sut.libraryDeletionStatus(authStub.user1, scope)
        : sut.setLibraryDeletionConsent(authStub.user1, scope, action === 'enable');
    await expect(request).rejects.toBeInstanceOf(ForbiddenException);
    expect(mocks.asset.getDeletionPolicy).not.toHaveBeenCalled();
    expect(mocks.asset.updateLibraryDeletionConsent).not.toHaveBeenCalled();
  });
  it('lists only owned libraries, including empty ones for later revocation', async () => {
    mocks.library.getAll.mockResolvedValue([library, { ...library, id: 'foreign', ownerId: authStub.admin.user.id }]);
    mocks.asset.getOwnerTrash.mockResolvedValue([]);
    expect(await sut.libraryDeletionScopes(authStub.user1)).toEqual([
      { scope, name: library.name, count: 0, authorized: false },
    ]);
  });
});
