import { ConflictException, UnauthorizedException } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import request from 'supertest';
import { TrashController } from 'src/controllers/trash.controller.js';
import { Permission } from 'src/enum.js';
import { getAuthenticatedOptions } from 'src/middleware/auth.guard.js';
import { AssetService } from 'src/services/asset.service.js';
import { TrashService } from 'src/services/trash.service.js';
import { factory } from 'test/small.factory.js';
import { ControllerContext, controllerSetup, mockBaseService } from 'test/utils.js';

describe(TrashController.name, () => {
  let ctx: ControllerContext;
  const service = mockBaseService(TrashService);
  const assets = mockBaseService(AssetService);

  beforeAll(async () => {
    ctx = await controllerSetup(TrashController, [
      { provide: TrashService, useValue: service },
      { provide: AssetService, useValue: assets },
    ]);
    return () => ctx.close();
  });

  beforeEach(() => {
    service.resetAllMocks();
    assets.resetAllMocks();
    ctx.reset();
  });

  describe('POST /trash/empty upstream contract', () => {
    it('requires asset-delete authentication and does not permit shared-link access', () => {
      expect(getAuthenticatedOptions(new Reflector(), TrashController.prototype.emptyTrash)).toMatchObject({
        permission: Permission.AssetDelete,
        public: false,
        sharedLink: false,
      });
    });

    it.each([0, 3])('accepts the original no-body request and returns only count=%s', async (count) => {
      const auth = factory.auth();
      ctx.authenticate.mockResolvedValue(auth);
      assets.emptyAuthorizedTrash.mockResolvedValue({ count });

      const { status, body } = await request(ctx.getHttpServer()).post('/trash/empty');

      expect(status).toBe(200);
      expect(body).toEqual({ count });
      expect(assets.emptyAuthorizedTrash).toHaveBeenCalledExactlyOnceWith(auth);
      expect(service.empty).not.toHaveBeenCalled();
      expect(service.handleEmptyTrash).not.toHaveBeenCalled();
    });

    it('returns the protected scope rejection without falling back to a legacy worker', async () => {
      const auth = factory.auth();
      ctx.authenticate.mockResolvedValue(auth);
      assets.emptyAuthorizedTrash.mockRejectedValue(new ConflictException('LIBRARY_DELETION_NOT_AUTHORIZED'));

      const { status, body } = await request(ctx.getHttpServer()).post('/trash/empty');

      expect(status).toBe(409);
      expect(body.message).toBe('LIBRARY_DELETION_NOT_AUTHORIZED');
      expect(assets.emptyAuthorizedTrash).toHaveBeenCalledExactlyOnceWith(auth);
      expect(service.empty).not.toHaveBeenCalled();
      expect(service.handleEmptyTrash).not.toHaveBeenCalled();
    });

    it('rejects unauthenticated requests before any permanent deletion', async () => {
      ctx.authenticate.mockRejectedValue(new UnauthorizedException());

      const { status } = await request(ctx.getHttpServer()).post('/trash/empty');

      expect(status).toBe(401);
      expect(assets.emptyAuthorizedTrash).not.toHaveBeenCalled();
      expect(service.empty).not.toHaveBeenCalled();
    });
  });

  describe('POST /trash/restore/assets', () => {
    it('should require asset ids', async () => {
      const { status, body } = await request(ctx.getHttpServer()).post('/trash/restore/assets').send({});

      expect(status).toBe(400);
      expect(body).toEqual(
        factory.responses.validationError([
          { path: ['ids'], message: 'Invalid input: expected array, received undefined' },
        ]),
      );
      expect(service.restoreAssets).not.toHaveBeenCalled();
    });

    it('should require valid asset ids', async () => {
      const { status, body } = await request(ctx.getHttpServer())
        .post('/trash/restore/assets')
        .send({ ids: ['invalid'] });

      expect(status).toBe(400);
      expect(body).toEqual(factory.responses.validationError([{ path: ['ids', 0], message: 'Invalid UUID' }]));
      expect(service.restoreAssets).not.toHaveBeenCalled();
    });
  });
});
