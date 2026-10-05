import { exiftool } from 'exiftool-vendored';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import sharp from 'sharp';
import { InpaintingError, MagicEraserRepository } from 'src/repositories/magic-eraser.repository.js';

const mask = { strokes: [{ points: [{ x: 0.5, y: 0.5 }], radius: 0.1, erase: false }] };

describe(MagicEraserRepository.name, () => {
  const sut = new MagicEraserRepository();
  let directory: string;
  let image: string;
  let original: Buffer;
  let fetchMock: ReturnType<typeof vi.fn>;

  beforeEach(async () => {
    directory = await mkdtemp(join(tmpdir(), 'eraser-repo-test-'));
    image = join(directory, 'original.jpg');
    original = await sharp({ create: { width: 30, height: 20, channels: 3, background: '#123456' } })
      .jpeg()
      .toBuffer();
    await writeFile(image, original);
    vi.stubEnv('GALLERY_INPAINTING_URL', 'http://gallery-inpainting:8000');
    vi.stubEnv('GALLERY_INPAINTING_TOKEN', 'unit-test-private-token');
    fetchMock = vi.fn();
    vi.stubGlobal('fetch', fetchMock);
  });

  afterEach(async () => {
    await rm(directory, { recursive: true, force: true });
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
    vi.restoreAllMocks();
  });

  afterAll(async () => {
    await exiftool.end();
  });

  it.each([
    { url: '', token: 'token' },
    { url: 'http://private/', token: '' },
    { url: 'ftp://private/', token: 'token' },
    { url: 'http://user:password@private/', token: 'token' },
  ])('requires an explicit private URL and bearer token %o', async ({ url, token }) => {
    vi.stubEnv('GALLERY_INPAINTING_URL', url);
    vi.stubEnv('GALLERY_INPAINTING_TOKEN', token);
    expect(await sut.isAvailable()).toBe(false);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it('checks a ready Big-LaMa sidecar with a short timeout and rejects redirects', async () => {
    fetchMock.mockResolvedValue(Response.json({ ready: true, engine: 'big-lama' }));
    expect(await sut.isAvailable()).toBe(true);
    expect(fetchMock).toHaveBeenCalledWith(
      new URL('http://gallery-inpainting:8000/health'),
      expect.objectContaining({
        headers: { Authorization: 'Bearer unit-test-private-token' },
        redirect: 'error',
        signal: expect.any(AbortSignal),
      }),
    );
  });

  it.each([
    { ready: false, engine: 'big-lama' },
    { ready: true, engine: 'other-model' },
  ])('does not claim availability for a missing or different model %o', async (health) => {
    fetchMock.mockResolvedValue(Response.json(health));
    expect(await sut.isAvailable()).toBe(false);
  });

  it('normalizes source orientation without changing the source bytes', async () => {
    const rotated = await sharp(original).withMetadata({ orientation: 6 }).jpeg().toBuffer();
    await writeFile(image, rotated);
    const output = join(directory, 'normalized.jpg');
    expect(await sut.normalize(image, output)).toEqual({ width: 20, height: 30 });
    const metadata = await sharp(output).metadata();
    expect(metadata.orientation).toBeUndefined();
    expect(await readFile(image)).toEqual(rotated);
  });

  it('rejects animated/unsupported images instead of silently editing a single frame', async () => {
    const output = join(directory, 'result.jpg');
    await writeFile(image, '<svg xmlns="http://www.w3.org/2000/svg" width="50" height="50"></svg>');
    await expect(sut.normalize(image, output)).rejects.toThrow(InpaintingError);
  });

  it('bounds both original/result editor previews to 1600 pixels', async () => {
    await sharp({ create: { width: 3000, height: 1800, channels: 3, background: 'white' } })
      .jpeg()
      .toFile(image);
    const preview = await sut.preview(image);
    expect(await sharp(preview).metadata()).toMatchObject({ width: 1600, height: 960 });
    const path = join(directory, 'preview.jpg');
    await sut.writePreview(image, path);
    expect(await sharp(await sut.readPreview(path)).metadata()).toMatchObject({ width: 1600, height: 960 });
  });

  it('streams a full-size original and normalized mask JSON only to the configured authenticated service', async () => {
    fetchMock.mockResolvedValue(new Response(new Uint8Array(original), { headers: { 'content-type': 'image/jpeg' } }));
    const output = join(directory, 'result.jpg');
    const controller = new AbortController();
    await sut.inpaint('job-uuid', image, output, mask, controller.signal);
    const [url, request] = fetchMock.mock.calls[0];
    expect(url.toString()).toBe('http://gallery-inpainting:8000/inpaint');
    expect(request.headers).toEqual({ Authorization: 'Bearer unit-test-private-token' });
    expect(request.redirect).toBe('error');
    expect(request.body.get('mask')).toBe(JSON.stringify(mask));
    expect(request.body.get('jobId')).toBe('job-uuid');
    expect(request.body.get('image').type).toBe('image/jpeg');
    expect(await readFile(output)).toEqual(original);
  });

  it.each([
    { status: 429, code: 'busy' },
    { status: 422, code: 'invalid' },
    { status: 503, code: 'unavailable' },
    { status: 500, code: 'processing_failed' },
  ])('returns only a safe error code for sidecar failure %o', async ({ status, code }) => {
    fetchMock.mockResolvedValue(new Response('private backend error paths', { status }));
    await expect(
      sut.inpaint('id', image, join(directory, 'output.jpg'), mask, new AbortController().signal),
    ).rejects.toMatchObject({ code });
  });

  it('rejects a server result with different dimensions', async () => {
    const other = await sharp({ create: { width: 5, height: 5, channels: 3, background: 'white' } })
      .jpeg()
      .toBuffer();
    fetchMock.mockResolvedValue(new Response(new Uint8Array(other), { headers: { 'content-type': 'image/jpeg' } }));
    await expect(
      sut.inpaint('id', image, join(directory, 'result.jpg'), mask, new AbortController().signal),
    ).rejects.toMatchObject({ code: 'processing_failed' });
  });

  it('passes independent cancellation to the streamed response', async () => {
    const controller = new AbortController();
    fetchMock.mockImplementation((_url, request) => {
      controller.abort();
      expect(request.signal.aborted).toBe(true);
      throw new DOMException('Aborted', 'AbortError');
    });
    await expect(sut.inpaint('id', image, join(directory, 'result.jpg'), mask, controller.signal)).rejects.toThrow(
      'Aborted',
    );
  });

  it('authenticates explicit cancellation without following redirects', async () => {
    fetchMock.mockResolvedValue(new Response(null, { status: 204 }));
    await sut.cancel('job-id');
    expect(fetchMock).toHaveBeenCalledWith(
      new URL('http://gallery-inpainting:8000/jobs/job-id'),
      expect.objectContaining({
        method: 'DELETE',
        redirect: 'error',
        headers: { Authorization: 'Bearer unit-test-private-token' },
      }),
    );
  });

  it('writes orientation/capture timezone/camera metadata, never motion or stale face identifiers', async () => {
    const output = join(directory, 'copy.jpg');
    await writeFile(output, original);
    await sut.writeCopyMetadata(
      output,
      {
        dateTimeOriginal: new Date('2020-02-03T10:20:30Z'),
        timeZone: 'UTC+3',
        make: 'Samsung',
        model: 'camera',
        latitude: -20.25,
        longitude: 30.5,
        description: 'photo',
      },
      new Date(),
    );
    const tags = await exiftool.read(output);
    expect(tags.Orientation).toBe(1);
    expect(tags.OffsetTimeOriginal).toBe('+03:00');
    expect(tags.DateTimeOriginal?.toString()).toBe('2020-02-03T13:20:30+03:00');
    expect(tags.Make).toBe('Samsung');
    expect(tags.GPSLatitude).toBe(-20.25);
    expect(tags.GPSLongitude).toBe(30.5);
    expect(tags).not.toHaveProperty('ContentIdentifier');
    expect(tags).not.toHaveProperty('MotionPhoto');
    expect(tags).not.toHaveProperty('RegionInfo');
    expect(await readFile(image)).toEqual(original);
  });
});
