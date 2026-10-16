import request from 'supertest';
import { Permission, QueueName } from 'src/enum.js';
import { QueueController } from 'src/controllers/queue.controller.js';
import { QueueService } from 'src/services/queue.service.js';
import { ControllerContext, controllerSetup, mockBaseService } from 'test/utils.js';

describe(QueueController.name, () => {
  let ctx: ControllerContext;
  const service = mockBaseService(QueueService);

  beforeAll(async () => {
    ctx = await controllerSetup(QueueController, [{ provide: QueueService, useValue: service }]);
    return () => ctx.close();
  });

  beforeEach(() => {
    service.resetAllMocks();
    ctx.reset();
  });

  it.each([
    ['audit', '/queues/deletion-jobs/audit', 'auditHistoricalDeletionJobs', Permission.QueueJobRead],
    ['reconcile', '/queues/deletion-jobs/reconcile', 'reconcileHistoricalDeletionJobs', Permission.QueueJobDelete],
  ])('publishes the admin queue-job permission for %s', async (_name, route, method, permission) => {
    service[method as 'auditHistoricalDeletionJobs' | 'reconcileHistoricalDeletionJobs'].mockResolvedValue({
      queue: QueueName.BackgroundTask,
      olderThan: '2026-01-01T00:00:00.000Z',
      dryRun: true,
      scanned: 0,
      eligible: 0,
      removed: 0,
      records: [],
      removedJobIds: [],
    });

    const { status } = await request(ctx.getHttpServer())
      .post(route)
      .set('Authorization', 'Bearer token')
      .send({ olderThan: '2026-01-01T00:00:00.000Z' });

    expect(status).toBe(201);
    expect(ctx.authenticate).toHaveBeenCalledWith(
      expect.objectContaining({
        metadata: expect.objectContaining({ permission }),
      }),
    );
  });

  it('validates the cutoff as an ISO datetime before invoking the service', async () => {
    const { status } = await request(ctx.getHttpServer())
      .post('/queues/deletion-jobs/audit')
      .set('Authorization', 'Bearer token')
      .send({ olderThan: 'yesterday' });

    expect(status).toBe(400);
    expect(service.auditHistoricalDeletionJobs).not.toHaveBeenCalled();
  });
});
