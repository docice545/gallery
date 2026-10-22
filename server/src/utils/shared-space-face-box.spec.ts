import { AssetEditAction } from 'src/dtos/editing.dto.js';
import { convertFaceBoxToOriginalImageSpace } from 'src/utils/asset.util.js';

describe('shared-space face box compatibility', () => {
  it('keeps unedited preview coordinates and dimensions unchanged', () => {
    expect(
      convertFaceBoxToOriginalImageSpace(
        { x: 10, y: 20, width: 30, height: 40, imageWidth: 100, imageHeight: 200 },
        { width: 100, height: 200 },
      ),
    ).toEqual({ topLeft: { x: 10, y: 20 }, bottomRight: { x: 40, y: 60 }, imageWidth: 100, imageHeight: 200 });
  });
  it('maps a box on a clockwise-rotated preview back to the original coordinates', () => {
    const box = convertFaceBoxToOriginalImageSpace(
      { x: 120, y: 20, width: 50, height: 40, imageWidth: 200, imageHeight: 400 },
      {
        width: 200,
        height: 400,
        edits: [{ action: AssetEditAction.Rotate, parameters: { angle: 90 } }],
        exifInfo: { exifImageWidth: 400, exifImageHeight: 200, orientation: '1' },
      },
    );
    expect(box.topLeft.x).toBeCloseTo(20, 8);
    expect(box.topLeft.y).toBeCloseTo(30, 8);
    expect(box.bottomRight.x).toBeCloseTo(60, 8);
    expect(box.bottomRight.y).toBeCloseTo(80, 8);
    expect([box.imageWidth, box.imageHeight]).toEqual([400, 200]);
  });
  it('refuses edited assets whose original dimensions cannot be verified', () => {
    expect(() =>
      convertFaceBoxToOriginalImageSpace(
        { x: 0, y: 0, width: 10, height: 10, imageWidth: 100, imageHeight: 100 },
        { width: 100, height: 100, edits: [{ action: AssetEditAction.Rotate, parameters: { angle: 90 } }] },
      ),
    ).toThrow('Asset does not have valid dimensions');
  });
});
