import { Reflector } from '@nestjs/core';
import request from 'supertest';
import { MemoryController } from 'src/controllers/memory.controller.js';
import { Permission } from 'src/enum.js';
import { getAuthenticatedOptions } from 'src/middleware/auth.guard.js';
import { MemoryService } from 'src/services/memory.service.js';
import { MemorySuppressedException } from 'src/utils/memory-candidate.js';
import { errorDto } from 'test/medium/responses.js';
import { factory } from 'test/small.factory.js';
import { ControllerContext, controllerSetup, mockBaseService } from 'test/utils.js';

describe(MemoryController.name, () => {
  let ctx: ControllerContext;
  const service = mockBaseService(MemoryService);

  beforeAll(async () => {
    ctx = await controllerSetup(MemoryController, [{ provide: MemoryService, useValue: service }]);
    return () => ctx.close();
  });

  beforeEach(() => {
    service.resetAllMocks();
    ctx.reset();
  });

  describe.each([
    ['lifecycle', 'getLifecycle', 'getMemoryLifecycle'],
    ['rejections', 'getRejections', 'getMemoryRejections'],
  ] as const)('GET /memories/%s', (route, serviceMethod, controllerMethod) => {
    it('requires MemoryRead without shared-link authentication', () => {
      expect(getAuthenticatedOptions(new Reflector(), MemoryController.prototype[controllerMethod])).toMatchObject({
        permission: Permission.MemoryRead,
        sharedLink: false,
        public: false,
      });
    });

    it('routes before the by-id handler and defaults to a bounded snapshot', async () => {
      service[serviceMethod].mockResolvedValue({ items: [] });
      const { status, body } = await request(ctx.getHttpServer()).get(`/memories/${route}`);
      expect(status).toBe(200);
      expect(body).toEqual({ items: [] });
      expect(service[serviceMethod]).toHaveBeenCalledWith(undefined, { size: 100 });
      expect(service.get).not.toHaveBeenCalled();
    });

    it('coerces keyset pagination and strips owner and timestamp overrides', async () => {
      const after = factory.uuid();
      service[serviceMethod].mockResolvedValue({ items: [] });
      await request(ctx.getHttpServer())
        .get(`/memories/${route}`)
        .query({ after, size: 2, ownerId: factory.uuid(), since: '2020-01-01' });
      expect(service[serviceMethod]).toHaveBeenCalledWith(undefined, { after, size: 2 });
    });

    it.each([{ after: 'invalid' }, { size: 0 }, { size: 1001 }])('rejects invalid pagination %j', async (query) => {
      const { status } = await request(ctx.getHttpServer()).get(`/memories/${route}`).query(query);
      expect(status).toBe(400);
      expect(service[serviceMethod]).not.toHaveBeenCalled();
    });
  });

  describe('GET /memories', () => {
    it('should not require any parameters', async () => {
      await request(ctx.getHttpServer()).get('/memories').query({});
      expect(service.search).toHaveBeenCalled();
    });
  });

  describe('POST /memories', () => {
    it('returns a machine-readable suppression code while preserving HTTP 409 and the message', async () => {
      service.create.mockRejectedValue(new MemorySuppressedException());
      const { status, body } = await request(ctx.getHttpServer())
        .post('/memories')
        .send({ type: 'rule', data: { ruleId: 'gallery_ai_highlight' }, memoryAt: new Date().toISOString() });
      expect(status).toBe(409);
      expect(body).toEqual({
        message: 'A similar memory was hidden or deleted by the user',
        code: 'MEMORY_SUPPRESSED',
      });
    });

    it('should validate data when type is on this day', async () => {
      const { status, body } = await request(ctx.getHttpServer())
        .post('/memories')
        .send({
          type: 'on_this_day',
          data: {},
          memoryAt: new Date(2021).toISOString(),
        });

      expect(status).toBe(400);
      expect(body).toEqual(
        errorDto.validationError([
          { path: ['data', 'year'], message: 'Invalid input: expected number, received undefined' },
        ]),
      );
    });

    it('should accept showAt and hideAt', async () => {
      const { status } = await request(ctx.getHttpServer())
        .post('/memories')
        .send({
          type: 'on_this_day',
          data: { year: 2020 },
          memoryAt: new Date(2021).toISOString(),
          showAt: new Date(2022).toISOString(),
          hideAt: new Date(2023).toISOString(),
        });

      expect(status).toBe(201);
    });
  });

  describe('GET /memories/:id', () => {
    it('should require a valid id', async () => {
      const { status, body } = await request(ctx.getHttpServer()).get(`/memories/invalid`);
      expect(status).toBe(400);
      expect(body).toEqual(errorDto.validationError([{ path: ['id'], message: 'Invalid UUID' }]));
    });
  });

  describe('PUT /memories/:id', () => {
    it('should require a valid id', async () => {
      const { status, body } = await request(ctx.getHttpServer()).put(`/memories/invalid`);
      expect(status).toBe(400);
      expect(body).toEqual(
        errorDto.validationError([{ path: [], message: 'Invalid input: expected object, received undefined' }]),
      );
    });

    it('should require at least one field', async () => {
      const { status, body } = await request(ctx.getHttpServer()).put(`/memories/${factory.uuid()}`).send({});
      expect(status).toBe(400);
      expect(body).toEqual(
        errorDto.validationError([
          {
            path: [],
            message:
              'At least one of the following fields is required: isHidden, isSaved, seenAt, memoryAt, title, subtitle',
          },
        ]),
      );
    });

    it('reuses the update endpoint for permanent hide', async () => {
      const id = factory.uuid();
      await request(ctx.getHttpServer()).put(`/memories/${id}`).send({ isHidden: true });
      expect(service.update).toHaveBeenCalledWith(undefined, id, { isHidden: true });
    });

    it('rejects a client attempt to revive a permanently suppressed memory', async () => {
      const { status } = await request(ctx.getHttpServer())
        .put(`/memories/${factory.uuid()}`)
        .send({ isHidden: false });
      expect(status).toBe(400);
      expect(service.update).not.toHaveBeenCalled();
    });
  });

  describe('DELETE /memories/:id', () => {
    it('retains the upstream memory-only deletion route and 204 response', async () => {
      const id = factory.uuid();
      service.remove.mockResolvedValue();
      const { status } = await request(ctx.getHttpServer()).delete(`/memories/${id}`);
      expect(status).toBe(204);
      expect(service.remove).toHaveBeenCalledWith(undefined, id);
      expect(service.removeAssets).not.toHaveBeenCalled();
    });
  });

  describe('PUT /memories/:id/assets', () => {
    it('should require a valid id', async () => {
      const { status, body } = await request(ctx.getHttpServer()).put(`/memories/invalid/assets`).send({ ids: [] });
      expect(status).toBe(400);
      expect(body).toEqual(errorDto.validationError([{ path: ['id'], message: 'Invalid UUID' }]));
    });

    it('should require a valid asset id', async () => {
      const { status, body } = await request(ctx.getHttpServer())
        .put(`/memories/${factory.uuid()}/assets`)
        .send({ ids: ['invalid'] });
      expect(status).toBe(400);
      expect(body).toEqual(errorDto.validationError([{ path: ['ids', 0], message: 'Invalid UUID' }]));
    });
  });

  describe('DELETE /memories/:id/assets', () => {
    it('should require a valid id', async () => {
      const { status, body } = await request(ctx.getHttpServer()).delete(`/memories/invalid/assets`);
      expect(status).toBe(400);
      expect(body).toEqual(errorDto.validationError([{ path: ['id'], message: 'Invalid UUID' }]));
    });

    it('should require a valid asset id', async () => {
      const { status, body } = await request(ctx.getHttpServer())
        .delete(`/memories/${factory.uuid()}/assets`)
        .send({ ids: ['invalid'] });
      expect(status).toBe(400);
      expect(body).toEqual(errorDto.validationError([{ path: ['ids', 0], message: 'Invalid UUID' }]));
    });
  });
});
