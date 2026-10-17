import request from 'supertest';
import { ServerController } from 'src/controllers/server.controller.js';
import { JobStatus, ReleaseChannel, SystemMetadataKey } from 'src/enum.js';
import { ServerService } from 'src/services/server.service.js';
import { SystemMetadataService } from 'src/services/system-metadata.service.js';
import { VersionService } from 'src/services/version.service.js';
import { ControllerContext, controllerSetup, mockBaseService, newTestService } from 'test/utils.js';

// This is the runtime manifest produced by both the official branding action and
// a custom Docker image built with BUILD_VERSION=5.7.1.
vitest.mock('node:fs', () => ({ readFileSync: () => JSON.stringify({ version: '5.7.1' }) }));

describe('Gallery release version reporting', () => {
  let ctx: ControllerContext;

  beforeAll(async () => {
    const { sut } = newTestService(VersionService);
    ctx = await controllerSetup(ServerController, [
      { provide: ServerService, useValue: mockBaseService(ServerService) },
      { provide: SystemMetadataService, useValue: mockBaseService(SystemMetadataService) },
      { provide: VersionService, useValue: sut },
    ]);
    return () => ctx.close();
  });

  it('returns the stamped release from the public server version endpoint', async () => {
    const { status, body } = await request(ctx.getHttpServer()).get('/server/version');
    expect(status).toBe(200);
    expect(body).toEqual({ major: 5, minor: 7, patch: 1, prerelease: null });
  });

  it('uses the same release in server information', async () => {
    const { sut, mocks } = newTestService(ServerService);
    mocks.serverInfo.getBuildVersions.mockResolvedValue({
      nodejs: '24',
      ffmpeg: '7',
      libvips: '8',
      exiftool: '13',
      imagemagick: '7',
    });
    await expect(sut.getAboutInfo()).resolves.toEqual(expect.objectContaining({ version: 'v5.7.1' }));
  });

  it('does not broadcast a newer release when the current and latest release match', async () => {
    const { sut, mocks } = newTestService(VersionService);
    mocks.systemMetadata.get.mockResolvedValue({ newVersionCheck: { enabled: true } });
    mocks.serverInfo.getLatestRelease.mockResolvedValue({ version: 'v5.7.1', published_at: '2026-10-04' });

    await expect(sut.handleVersionCheck()).resolves.toBe(JobStatus.Success);
    expect(mocks.systemMetadata.set).toHaveBeenCalledWith(SystemMetadataKey.VersionCheckState, {
      checkedAt: expect.any(String),
      releaseVersion: 'v5.7.1',
    });
    expect(mocks.websocket.clientBroadcast).not.toHaveBeenCalled();
  });

  it('marks the cached release as unavailable and reports the correct server version on login', async () => {
    const { sut, mocks } = newTestService(VersionService);
    mocks.systemMetadata.get
      .mockResolvedValueOnce({ newVersionCheck: { enabled: true, channel: ReleaseChannel.Stable } })
      .mockResolvedValueOnce({ checkedAt: '2026-10-04', releaseVersion: 'v5.7.1' });

    await sut.onWebsocketConnection({ userId: 'user' });

    expect(mocks.websocket.clientSend).toHaveBeenCalledWith('on_server_version', 'user', {
      major: 5,
      minor: 7,
      patch: 1,
      prerelease: null,
    });
    expect(mocks.websocket.clientSend).toHaveBeenCalledWith(
      'on_new_release',
      'user',
      expect.objectContaining({
        isAvailable: false,
        serverVersion: { major: 5, minor: 7, patch: 1, prerelease: null },
        releaseVersion: { major: 5, minor: 7, patch: 1, prerelease: null },
      }),
    );
  });

  it('keeps real newer releases visible', async () => {
    const { sut, mocks } = newTestService(VersionService);
    mocks.systemMetadata.get.mockResolvedValue({ newVersionCheck: { enabled: true } });
    mocks.serverInfo.getLatestRelease.mockResolvedValue({ version: 'v5.7.2', published_at: '2026-10-04' });

    await expect(sut.handleVersionCheck()).resolves.toBe(JobStatus.Success);
    expect(mocks.websocket.clientBroadcast).toHaveBeenCalledWith(
      'on_new_release',
      expect.objectContaining({
        isAvailable: true,
        releaseVersion: { major: 5, minor: 7, patch: 2, prerelease: null },
      }),
    );
  });
});
