import { AssetFileType, JobStatus } from 'src/enum.js';
import { MetadataService } from 'src/services/metadata.service.js';
import { AssetFactory } from 'test/factories/asset.factory.js';
import { getForSidecarWrite } from 'test/mappers.js';
import { newTestService } from 'test/utils.js';

it('never combines stale null rating with locks belonging to a newer manual rating', async () => {
  const { sut, mocks } = newTestService(MetadataService);
  const asset = AssetFactory.from().file({ type: AssetFileType.Sidecar }).exif({ rating: null }).build();
  mocks.assetJob.getForSidecarWriteJob.mockResolvedValue(structuredClone(getForSidecarWrite(asset)));
  // Simulate the manual update committing after the value snapshot was read.
  mocks.assetJob.getLockedPropertiesForMetadataExtraction.mockImplementation(() => {
    asset.exifInfo.rating = 3;
    return Promise.resolve(['rating']);
  });
  mocks.assetJob.writeSidecar.mockImplementation(
    async (_, write) => (await write(structuredClone(getForSidecarWrite(asset)))) !== undefined,
  );
  await expect(sut.handleSidecarWrite({ id: asset.id })).resolves.toBe(JobStatus.Skipped);
  expect(mocks.metadata.writeTags).not.toHaveBeenCalledWith(asset.files[0].path, { Rating: 0 });
  expect(mocks.assetJob.getLockedPropertiesForMetadataExtraction).not.toHaveBeenCalled();
  asset.exifInfo.rating = 3;
  asset.exifInfo.lockedProperties = ['rating'];
  await expect(sut.handleSidecarWrite({ id: asset.id })).resolves.toBe(JobStatus.Success);
  expect(mocks.metadata.writeTags).toHaveBeenCalledWith(asset.files[0].path, { Rating: 3 });
});
