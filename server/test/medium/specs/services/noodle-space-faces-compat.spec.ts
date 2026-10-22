import { Kysely } from 'kysely';
import { SharedSpaceRole } from 'src/enum.js';
import { AccessRepository } from 'src/repositories/access.repository.js';
import { AssetRepository } from 'src/repositories/asset.repository.js';
import { DatabaseRepository } from 'src/repositories/database.repository.js';
import { FaceIdentityRepository } from 'src/repositories/face-identity.repository.js';
import { FacePersonVerdictRepository } from 'src/repositories/face-person-verdict.repository.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { PersonRepository } from 'src/repositories/person.repository.js';
import { SharedSpaceRepository } from 'src/repositories/shared-space.repository.js';
import { DB } from 'src/schema/index.js';
import { SharedSpaceService } from 'src/services/shared-space.service.js';
import { newMediumService } from 'test/medium.factory.js';
import { getKyselyDB } from 'test/utils.js';

let db: Kysely<DB>;
beforeAll(async () => {
  db = await getKyselyDB();
});
afterAll(async () => {
  await db?.destroy();
});
const setup = async () => {
  const { sut, ctx } = newMediumService(SharedSpaceService, {
    database: db,
    real: [
      SharedSpaceRepository,
      AssetRepository,
      AccessRepository,
      DatabaseRepository,
      FaceIdentityRepository,
      FacePersonVerdictRepository,
      PersonRepository,
    ],
    mock: [LoggingRepository],
  });
  const { auth, user } = await ctx.newSyncAuthUser();
  const { auth: viewer, user: viewerUser } = await ctx.newSyncAuthUser();
  const { space } = await ctx.newSharedSpace({ createdById: user.id });
  await ctx.newSharedSpaceMember({ spaceId: space.id, userId: user.id, role: SharedSpaceRole.Owner });
  await ctx.newSharedSpaceMember({ spaceId: space.id, userId: viewerUser.id, role: SharedSpaceRole.Viewer });
  const { asset } = await ctx.newAsset({ ownerId: user.id, width: 100, height: 100 });
  await ctx.newSharedSpaceAsset({ spaceId: space.id, assetId: asset.id, addedById: user.id });
  return { sut, ctx, auth, user, viewer, space, asset };
};

it('creates a person and draws/reads/deletes a face without deleting the asset', async () => {
  const { sut, auth, space, asset } = await setup();
  const person = await sut.createSpacePerson(auth, space.id, { name: 'Synthetic' });
  const face = await sut.createSpaceAssetFace(auth, space.id, asset.id, {
    x: 10,
    y: 20,
    width: 30,
    height: 40,
    imageWidth: 100,
    imageHeight: 100,
    spacePersonId: person.id,
  });
  expect(face.isEditorDrawn).toBe(true);
  expect(await sut.getSpaceAssetFaces(auth, space.id, asset.id)).toContainEqual(
    expect.objectContaining({ id: face.id, spacePersonId: person.id }),
  );
  await sut.deleteSpaceAssetFace(auth, space.id, face.id);
  expect(await db.selectFrom('asset_face').select('id').where('id', '=', face.id).executeTakeFirst()).toBeUndefined();
  expect(await db.selectFrom('asset').select('id').where('id', '=', asset.id).executeTakeFirst()).toBeDefined();
});

it('refuses viewers and foreign-space assets/persons before any face mutation', async () => {
  const { sut, ctx, auth, viewer, space, asset } = await setup();
  await expect(sut.createSpacePerson(viewer, space.id, { name: 'Denied' })).rejects.toThrow('Insufficient role');
  await expect(sut.getSpaceAssetFaces(viewer, space.id, asset.id)).rejects.toThrow('Insufficient role');
  const person = await sut.createSpacePerson(auth, space.id, { name: 'Allowed' });
  const { asset: outside } = await ctx.newAsset({ ownerId: auth.user.id });
  await expect(
    sut.createSpaceAssetFace(auth, space.id, outside.id, {
      x: 0,
      y: 0,
      width: 10,
      height: 10,
      imageWidth: 100,
      imageHeight: 100,
      spacePersonId: person.id,
    }),
  ).rejects.toThrow('Asset not found');
});

it('never deletes detected or owner-drawn legacy faces (createdBy NULL)', async () => {
  const { sut, ctx, auth, space, asset } = await setup();
  const { assetFace } = await ctx.newAssetFace({ assetId: asset.id });
  await expect(sut.deleteSpaceAssetFace(auth, space.id, assetFace.id)).rejects.toThrow('Face not found');
  expect(
    await db.selectFrom('asset_face').select('id').where('id', '=', assetFace.id).executeTakeFirst(),
  ).toBeDefined();
});

it('attach/detach are idempotent and maintain projection counts', async () => {
  const { sut, ctx, auth, space, asset } = await setup();
  const { assetFace } = await ctx.newAssetFace({ assetId: asset.id });
  const person = await sut.createSpacePerson(auth, space.id, { name: 'Named' });
  expect(await sut.attachFaceToSpacePerson(auth, space.id, person.id, assetFace.id)).toBe(true);
  expect(await sut.attachFaceToSpacePerson(auth, space.id, person.id, assetFace.id)).toBe(true);
  // Upstream's acted reports an accepted identity/verdict write; idempotency is the persisted effect.
  expect(
    await db.selectFrom('shared_space_person_face').select('assetFaceId').where('personId', '=', person.id).execute(),
  ).toHaveLength(1);
  expect(await sut.detachFaceFromSpacePerson(auth, space.id, person.id, assetFace.id)).toBe(true);
  expect(await sut.detachFaceFromSpacePerson(auth, space.id, person.id, assetFace.id)).toBe(true);
  expect(
    await db.selectFrom('shared_space_person_face').select('assetFaceId').where('personId', '=', person.id).execute(),
  ).toEqual([]);
});

it('rolls back the new face if identity/projection linking fails mid-transaction', async () => {
  const { sut, ctx, auth, space, asset } = await setup();
  const person = await sut.createSpacePerson(auth, space.id, { name: 'Synthetic' });
  const mock = vi
    .spyOn(ctx.get(SharedSpaceRepository), 'addPersonFaces')
    .mockRejectedValueOnce(new Error('injected linkage failure'));
  await expect(
    sut.createSpaceAssetFace(auth, space.id, asset.id, {
      x: 0,
      y: 0,
      width: 10,
      height: 10,
      imageWidth: 100,
      imageHeight: 100,
      spacePersonId: person.id,
    }),
  ).rejects.toThrow('injected linkage failure');
  mock.mockRestore();
  expect(await db.selectFrom('asset_face').select('id').where('assetId', '=', asset.id).execute()).toEqual([]);
});

it('refuses drawing on a reachable non-member owners asset', async () => {
  const { sut, ctx, auth, space } = await setup();
  const { user: outsider } = await ctx.newSyncAuthUser();
  const { asset } = await ctx.newAsset({ ownerId: outsider.id, width: 100, height: 100 });
  await ctx.newSharedSpaceAsset({ spaceId: space.id, assetId: asset.id, addedById: auth.user.id });
  const person = await sut.createSpacePerson(auth, space.id, { name: 'Synthetic' });
  await expect(
    sut.createSpaceAssetFace(auth, space.id, asset.id, {
      x: 0,
      y: 0,
      width: 10,
      height: 10,
      imageWidth: 100,
      imageHeight: 100,
      spacePersonId: person.id,
    }),
  ).rejects.toThrow('members of this space');
  expect(await db.selectFrom('asset_face').select('id').where('assetId', '=', asset.id).execute()).toEqual([]);
});
