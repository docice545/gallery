import request from 'supertest';
import { TrashController } from 'src/controllers/trash.controller.js';
import { AssetService } from 'src/services/asset.service.js';
import { TrashService } from 'src/services/trash.service.js';
import { authStub } from 'test/fixtures/auth.stub.js';
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

  describe('POST /trash/empty', () => {
    it('preserves the original client response contract', async () => {
      const response = { count: 3 };
      assets.emptyAuthorizedTrash.mockResolvedValue(response);
      ctx.authenticate.mockResolvedValue(authStub.user1);

      const { status, body } = await request(ctx.getHttpServer()).post('/trash/empty');

      expect(status).toBe(200);
      expect(body).toEqual(response);
      expect(assets.emptyAuthorizedTrash).toHaveBeenCalledExactlyOnceWith(authStub.user1);
    });
  });
});
