import { ForbiddenException } from '@nestjs/common';
import { StorageCore } from 'src/cores/storage.core.js';
import { AssetService } from 'src/services/asset.service.js';
import * as deletion from 'src/utils/authorized-deletion.js';
import * as recovery from 'src/utils/deletion-recovery.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { userStub } from 'test/fixtures/user.stub.js';
import { newTestService } from 'test/utils.js';

const ownerId = authStub.user1.user.id;
const libraryId = 'a55e67c9-e435-4f04-ab10-d37c8c33800f';
const path = '/disposable/owner/photos';
const proof = 'b'.repeat(64);
const dto = { recoveryProof: proof, verifiedExclusiveRoots: true as const };
const identities = [
  {
    path,
    device: '1',
    inode: '2',
    mountId: '3',
    mountNamespace: 'mnt:[synthetic]',
    mountType: 'nfs',
    mountSource: 'synthetic:/volume/owner',
    mountRoot: '/',
    mountTarget: path,
  },
];
const expiresAt = new Date(Date.now() + 3_600_000);
const library = {
  id: libraryId,
  ownerId,
  name: 'Disposable library',
  deletedAt: null,
  importPaths: [path],
  exclusionPatterns: [],
  createdAt: new Date(0),
  updatedAt: new Date(0),
  refreshedAt: null,
  createId: libraryId,
  updateId: libraryId,
};

describe.each(['managed', 'external'] as const)('administrator %s preparation for another owner', (kind) => {
  const { sut, mocks } = newTestService(AssetService);
  const scope = kind === 'managed' ? 'managed' : libraryId;
  const prepare = (auth = authStub.admin, owner = ownerId) =>
    kind === 'managed'
      ? sut.prepareManagedDeletionForOwner(auth, owner, dto)
      : sut.prepareLibraryDeletionForOwner(auth, owner, libraryId, dto);

  beforeEach(() => {
    vi.resetAllMocks();
    mocks.user.get.mockResolvedValue(userStub.user1);
    mocks.library.get.mockResolvedValue(library);
    mocks.storage.checkFileExists.mockResolvedValue(true);
    mocks.storage.validateDeletionRoots.mockResolvedValue(identities);
    mocks.asset.getDeletionRootsForOtherOwners.mockResolvedValue({ external: [], users: [] });
    vi.spyOn(StorageCore, 'getFolderLocation').mockReturnValue(path);
    vi.spyOn(StorageCore, 'getLibraryFolder').mockReturnValue(path);
    vi.spyOn(recovery, 'verifyRecoveryEvidence').mockResolvedValue({
      digest: proof,
      expiresAt: expiresAt.toISOString(),
    });
  });
  afterEach(() => vi.restoreAllMocks());

  it.each([1, 2, 3])('prepares owner %i using their roots and evidence, never enabling deletion', async (index) => {
    const owner = `00000000-0000-4000-8000-00000000000${index}`;
    const user = { ...userStub.user1, id: owner };
    mocks.user.get.mockResolvedValue(user);
    mocks.library.get.mockResolvedValue({ ...library, ownerId: owner });
    await prepare(authStub.admin, owner);
    expect(mocks.user.get).toHaveBeenCalledWith(owner, {});
    if (kind === 'managed') {
      expect(StorageCore.getFolderLocation).toHaveBeenCalledWith(expect.anything(), owner);
      expect(StorageCore.getLibraryFolder).toHaveBeenCalledWith(user);
    }
    expect(mocks.asset.getDeletionRootsForOtherOwners).toHaveBeenCalledWith(owner);
    expect(recovery.verifyRecoveryEvidence).toHaveBeenCalledWith(proof, owner, scope, identities);
    expect(mocks.asset.setDeletionPolicy).toHaveBeenCalledExactlyOnceWith(owner, scope, {
      enabled: false,
      roots: [path],
      rootIdentities: identities,
      recoveryProof: proof,
      recoveryExpiresAt: expiresAt,
      authorizedBy: authStub.admin.user.id,
    });
    expect(mocks.asset.updateManagedDeletionConsent).not.toHaveBeenCalled();
    expect(mocks.asset.updateLibraryDeletionConsent).not.toHaveBeenCalled();
    expect(mocks.asset.preparePermanentDeletion).not.toHaveBeenCalled();
    expect(mocks.storage.snapshotOriginal).not.toHaveBeenCalled();
    expect(mocks.storage.unlinkOriginal).not.toHaveBeenCalled();
    expect(mocks.job.queue).not.toHaveBeenCalled();
  });

  it.each([ownerId, authStub.admin.user.id])(
    'rejects non-admin preparation for owner %s before reads',
    async (owner) => {
      await expect(prepare(authStub.user1, owner)).rejects.toBeInstanceOf(ForbiddenException);
      expect(mocks.user.get).not.toHaveBeenCalled();
      expect(mocks.library.get).not.toHaveBeenCalled();
      expect(mocks.storage.validateDeletionRoots).not.toHaveBeenCalled();
      expect(recovery.verifyRecoveryEvidence).not.toHaveBeenCalled();
      expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
    },
  );

  it('rejects a missing target owner', async () => {
    mocks.user.get.mockResolvedValue(undefined);
    await expect(prepare()).rejects.toThrow('Unknown owner');
    expect(mocks.storage.validateDeletionRoots).not.toHaveBeenCalled();
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });

  it.each(['DELETION_RECOVERY_EXPIRED', 'DELETION_RECOVERY_INVALID', 'DELETION_ROOT_CHANGED'])(
    'revalidates signed proof and rejects %s even when a previous policy has the same proof',
    async (code) => {
      mocks.asset.getDeletionPolicy.mockResolvedValue({
        ownerId,
        scope,
        enabled: true,
        roots: [path],
        rootIdentities: identities,
        recoveryProof: proof,
        recoveryExpiresAt: new Date(0),
        authorizedBy: ownerId,
        updatedAt: new Date(0),
      });
      vi.mocked(recovery.verifyRecoveryEvidence).mockRejectedValue(new deletion.DeletionError(code));
      await expect(prepare()).rejects.toThrow(code);
      expect(recovery.verifyRecoveryEvidence).toHaveBeenCalledWith(proof, ownerId, scope, identities);
      expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
    },
  );

  it('rejects root replacement before reading recovery evidence or storing a policy', async () => {
    mocks.storage.validateDeletionRoots.mockRejectedValue(new deletion.DeletionError('DELETION_ROOT_CHANGED'));
    await expect(prepare()).rejects.toThrow('DELETION_ROOT_CHANGED');
    expect(recovery.verifyRecoveryEvidence).not.toHaveBeenCalled();
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });

  it('checks changed NFS identity against the signed owner/scope proof', async () => {
    const changed = [{ ...identities[0], mountId: '4', mountSource: 'other:/volume', mountNamespace: 'mnt:[other]' }];
    mocks.storage.validateDeletionRoots.mockResolvedValue(changed);
    vi.mocked(recovery.verifyRecoveryEvidence).mockRejectedValue(new deletion.DeletionError('DELETION_ROOT_CHANGED'));
    await expect(prepare()).rejects.toThrow('DELETION_ROOT_CHANGED');
    expect(recovery.verifyRecoveryEvidence).toHaveBeenCalledWith(proof, ownerId, scope, changed);
    expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
  });

  it('preparation never lets the administrator consent for the target owner', async () => {
    await prepare();
    if (kind === 'external') {
      await expect(sut.setLibraryDeletionConsent(authStub.admin, libraryId, true)).rejects.toBeInstanceOf(
        ForbiddenException,
      );
      expect(mocks.asset.updateLibraryDeletionConsent).not.toHaveBeenCalled();
    } else {
      await sut.setManagedDeletionConsent(authStub.admin, true);
      expect(mocks.asset.updateManagedDeletionConsent).toHaveBeenCalledWith(
        authStub.admin.user.id,
        true,
        expect.any(Function),
      );
      expect(mocks.asset.updateManagedDeletionConsent).not.toHaveBeenCalledWith(
        ownerId,
        expect.anything(),
        expect.anything(),
      );
    }
  });

  if (kind === 'external') {
    it.each([undefined, { ...library, ownerId: authStub.admin.user.id }, { ...library, deletedAt: new Date() }])(
      'rejects a missing, foreign-owner or deleted library',
      async (value) => {
        mocks.library.get.mockResolvedValue(value);
        await expect(prepare()).rejects.toBeInstanceOf(ForbiddenException);
        expect(mocks.user.get).not.toHaveBeenCalled();
        expect(mocks.storage.validateDeletionRoots).not.toHaveBeenCalled();
        expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
      },
    );

    it('rejects import roots changed between library lookup and validation', async () => {
      mocks.library.get
        .mockResolvedValueOnce(library)
        .mockResolvedValueOnce({ ...library, importPaths: ['/other/root'] });
      await expect(prepare()).rejects.toThrow('Root is not an existing owner library root');
      expect(recovery.verifyRecoveryEvidence).not.toHaveBeenCalled();
      expect(mocks.asset.setDeletionPolicy).not.toHaveBeenCalled();
    });
  }
});
