import { Reflector } from '@nestjs/core';
import request from 'supertest';
import { MagicEraserController } from 'src/controllers/magic-eraser.controller.js';
import { AssetMediaStatus } from 'src/dtos/asset-media-response.dto.js';
import { MagicEraserCreateDto, MagicEraserSaveDto } from 'src/dtos/magic-eraser.dto.js';
import { LoggingRepository } from 'src/repositories/logging.repository.js';
import { MagicEraserService } from 'src/services/magic-eraser.service.js';
import { factory } from 'test/small.factory.js';
import { ControllerContext, controllerSetup, mockBaseService } from 'test/utils.js';

describe(MagicEraserController.name, () => {
  let ctx: ControllerContext;
  const service = mockBaseService(MagicEraserService);
  const mask = { strokes: [{ points: [{ x: 0.5, y: 0.5 }], radius: 0.05, erase: false }] };

  beforeAll(async () => {
    ctx = await controllerSetup(MagicEraserController, [
      { provide: MagicEraserService, useValue: service },
      { provide: LoggingRepository, useValue: { error: vi.fn(), setContext: vi.fn(), debug: vi.fn() } },
    ]);
    return () => ctx.close();
  });

  beforeEach(() => {
    ctx.reset();
    service.resetAllMocks();
  });

  it('accepts a bounded normalized stroke mask, never an uploaded source or arbitrary server path', async () => {
    const id = factory.uuid();
    service.create.mockResolvedValue({ id: factory.uuid(), status: 'queued' });
    const response = await request(ctx.getHttpServer())
      .post(`/assets/${id}/magic-eraser`)
      .send({ ...mask, originalPath: '/etc/passwd' });
    expect(response.status).toBe(202);
    expect(service.create).toHaveBeenCalledWith(undefined, id, mask);
  });

  it.each([
    { strokes: [] },
    { strokes: [{ ...mask.strokes[0], radius: 0 }] },
    { strokes: [{ ...mask.strokes[0], radius: 0.3 }] },
    { strokes: [{ ...mask.strokes[0], erase: true }] },
    { strokes: [{ ...mask.strokes[0], points: [{ x: -1, y: 0.5 }] }] },
    { strokes: [{ ...mask.strokes[0], points: Array.from({ length: 1025 }, () => ({ x: 0.5, y: 0.5 })) }] },
    { strokes: Array.from({ length: 65 }, () => mask.strokes[0]) },
  ])('rejects invalid or excessive instructions', async (input) => {
    const response = await request(ctx.getHttpServer()).post(`/assets/${factory.uuid()}/magic-eraser`).send(input);
    expect(response.status).toBe(400);
    expect(service.create).not.toHaveBeenCalled();
  });

  it('bounds the total mask points independently of the test HTTP parser body limit', () => {
    const input = {
      strokes: Array.from({ length: 9 }, () => ({
        ...mask.strokes[0],
        points: Array.from({ length: 1024 }, () => ({ x: 0.5, y: 0.5 })),
      })),
    };
    expect(MagicEraserCreateDto.schema.safeParse(input).success).toBe(false);
  });

  it('validates asset and job IDs on all authenticated routes', async () => {
    const responses = await Promise.all([
      request(ctx.getHttpServer()).get('/assets/invalid/magic-eraser/capabilities'),
      request(ctx.getHttpServer()).get(`/assets/${factory.uuid()}/magic-eraser/invalid`),
      request(ctx.getHttpServer()).post(`/assets/${factory.uuid()}/magic-eraser/invalid/save`),
    ]);
    expect(responses.map((response) => response.status)).toEqual([400, 400, 400]);
  });

  it('returns saved asset ID through the normal upload response', async () => {
    const id = factory.uuid();
    const jobId = factory.uuid();
    service.save.mockResolvedValue({ id: factory.uuid(), status: AssetMediaStatus.CREATED });
    const response = await request(ctx.getHttpServer()).post(`/assets/${id}/magic-eraser/${jobId}/save`);
    expect(response.status).toBe(201);
    expect(response.body.status).toBe('created');
    expect(service.save).toHaveBeenCalledWith(undefined, id, jobId, {});
  });

  it('documents the save body as optional for existing bodyless clients', () => {
    const parameters = new Reflector().get<unknown[]>(
      'swagger/apiParameters',
      MagicEraserController.prototype.saveMagicEraserCopy,
    );
    expect(parameters).toEqual(
      expect.arrayContaining([expect.objectContaining({ in: 'body', type: MagicEraserSaveDto, required: false })]),
    );
  });

  it('accepts the current device offset without accepting a client-selected save timestamp', async () => {
    const id = factory.uuid();
    const jobId = factory.uuid();
    service.save.mockResolvedValue({ id: factory.uuid(), status: AssetMediaStatus.CREATED });
    const response = await request(ctx.getHttpServer())
      .post(`/assets/${id}/magic-eraser/${jobId}/save`)
      .send({ timeZoneOffsetMinutes: 330, savedAt: '2020-01-01T00:00:00Z' });
    expect(response.status).toBe(201);
    expect(service.save).toHaveBeenCalledWith(undefined, id, jobId, { timeZoneOffsetMinutes: 330 });
  });

  it.each([-841, -721, -720, 841, 1, 1.5, '180', null])(
    'rejects an invalid save offset %s',
    async (timeZoneOffsetMinutes) => {
      const response = await request(ctx.getHttpServer())
        .post(`/assets/${factory.uuid()}/magic-eraser/${factory.uuid()}/save`)
        .send({ timeZoneOffsetMinutes });
      expect(response.status).toBe(400);
      expect(service.save).not.toHaveBeenCalled();
    },
  );
});
