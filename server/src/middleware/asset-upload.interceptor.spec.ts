import { CallHandler, ExecutionContext, GoneException } from '@nestjs/common';
import { lastValueFrom, of } from 'rxjs';
import { AssetMediaStatus } from 'src/dtos/asset-media-response.dto.js';
import { ImmichHeader } from 'src/enum.js';
import { AssetUploadInterceptor } from 'src/middleware/asset-upload.interceptor.js';
import { AssetMediaService } from 'src/services/asset-media.service.js';
import { authStub } from 'test/fixtures/auth.stub.js';
import { newTestService } from 'test/utils.js';

describe(AssetUploadInterceptor.name, () => {
  it('retains the installed-client HTTP 200 duplicate shape for a verified External object', async () => {
    const { sut: service } = newTestService(AssetMediaService);
    const lookup = vi.spyOn(service, 'getUploadAssetIdByChecksum').mockResolvedValue({
      id: 'real-external-id',
      status: AssetMediaStatus.DUPLICATE,
      duplicateId: null,
    });
    const status = vi.fn();
    const request = { user: authStub.admin, headers: { [ImmichHeader.Checksum]: 'content-sha1' } };
    const context = {
      switchToHttp: () => ({ getRequest: () => request, getResponse: () => ({ status }) }),
    } as ExecutionContext;
    const next = { handle: vi.fn(() => of('multipart')) } as unknown as CallHandler;
    const response = await new AssetUploadInterceptor(service).intercept(context, next);
    await expect(lastValueFrom(response)).resolves.toEqual({
      status: AssetMediaStatus.DUPLICATE,
      id: 'real-external-id',
    });
    expect(lookup).toHaveBeenCalledWith(authStub.admin, 'content-sha1');
    expect(status).toHaveBeenCalledExactlyOnceWith(200);
    expect(next.handle).not.toHaveBeenCalled();
  });

  it('keeps a headerless old client on the normal multipart admission path', async () => {
    const { sut: service } = newTestService(AssetMediaService);
    const status = vi.fn();
    const context = {
      switchToHttp: () => ({
        getRequest: () => ({ user: authStub.admin, headers: {} }),
        getResponse: () => ({ status }),
      }),
    } as ExecutionContext;
    const next = { handle: vi.fn(() => of('multipart')) } as unknown as CallHandler;
    await expect(lastValueFrom(await new AssetUploadInterceptor(service).intercept(context, next))).resolves.toBe(
      'multipart',
    );
    expect(next.handle).toHaveBeenCalledExactlyOnceWith();
    expect(status).not.toHaveBeenCalled();
  });

  it('propagates deletion and unexpected errors without acknowledging backup', async () => {
    const { sut: service } = newTestService(AssetMediaService);
    const denied = new GoneException('permanently deleted');
    vi.spyOn(service, 'getUploadAssetIdByChecksum').mockRejectedValue(denied);
    const status = vi.fn();
    const context = {
      switchToHttp: () => ({
        getRequest: () => ({ user: authStub.admin, headers: { [ImmichHeader.Checksum]: 'checksum' } }),
        getResponse: () => ({ status }),
      }),
    } as ExecutionContext;
    const next = { handle: vi.fn() } as unknown as CallHandler;
    await expect(new AssetUploadInterceptor(service).intercept(context, next)).rejects.toBe(denied);
    expect(status).not.toHaveBeenCalled();
    expect(next.handle).not.toHaveBeenCalled();
  });
});
