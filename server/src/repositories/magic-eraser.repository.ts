import { Injectable } from '@nestjs/common';
import { exiftool } from 'exiftool-vendored';
import { DateTime } from 'luxon';
import { createWriteStream, openAsBlob } from 'node:fs';
import { mkdtemp, readFile, readdir, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import sharp from 'sharp';
import type { ReadableStream } from 'node:stream/web';
import { Exif } from 'src/database.js';
import { MAGIC_ERASER_LIMITS, MagicEraserCreateDto } from 'src/dtos/magic-eraser.dto.js';

const PREFIX = 'gallery-magic-eraser-';
const MAX_BYTES = 64 * 1024 * 1024;
export const MAGIC_ERASER_TTL_MS = 60 * 60 * 1000;
type CopyExif = Partial<
  Pick<
    Exif,
    | 'dateTimeOriginal'
    | 'timeZone'
    | 'make'
    | 'model'
    | 'lensModel'
    | 'fNumber'
    | 'focalLength'
    | 'iso'
    | 'latitude'
    | 'longitude'
    | 'description'
  >
>;

export class InpaintingError extends Error {
  constructor(public readonly code: 'unavailable' | 'invalid' | 'busy' | 'processing_failed') {
    super(code);
  }
}

/** Private, optional sidecar adapter; never substitutes for Gallery's existing ML service. */
@Injectable()
export class MagicEraserRepository {
  private config() {
    const url = process.env.GALLERY_INPAINTING_URL;
    const token = process.env.GALLERY_INPAINTING_TOKEN;
    if (!url || !token || !/^https?:\/\//.test(url)) {
      return;
    }
    try {
      const base = new URL(url.endsWith('/') ? url : `${url}/`);
      if (base.username || base.password || base.search || base.hash) {
        return;
      }
      return { base, token };
    } catch {
      return;
    }
  }

  async isAvailable() {
    const config = this.config();
    if (!config) {
      return false;
    }
    try {
      const response = await fetch(new URL('health', config.base), {
        headers: { Authorization: `Bearer ${config.token}` },
        signal: AbortSignal.timeout(2000),
        redirect: 'error',
      });
      if (!response.ok) {
        return false;
      }
      const body = (await response.json()) as { ready?: boolean; engine?: string };
      return body.ready === true && body.engine === 'big-lama';
    } catch {
      return false;
    }
  }

  createDirectory() {
    return mkdtemp(join(tmpdir(), PREFIX));
  }

  async normalize(source: string, output: string) {
    const image = sharp(source, { limitInputPixels: MAGIC_ERASER_LIMITS.maxPixels, failOn: 'error' });
    const metadata = await image.metadata();
    if ((metadata.pages ?? 1) > 1 || !['jpeg', 'png', 'webp', 'heif', 'tiff', 'avif'].includes(metadata.format ?? '')) {
      throw new InpaintingError('invalid');
    }
    const result = await image
      .autoOrient()
      .flatten({ background: '#ffffff' })
      .toColourspace('srgb')
      .jpeg({ quality: 96 })
      .toFile(output);
    if (result.size > MAX_BYTES || result.width * result.height > MAGIC_ERASER_LIMITS.maxPixels) {
      throw new InpaintingError('invalid');
    }
    return { width: result.width, height: result.height };
  }

  preview(source: string) {
    return sharp(source, { limitInputPixels: MAGIC_ERASER_LIMITS.maxPixels })
      .resize({ width: 1600, height: 1600, fit: 'inside', withoutEnlargement: true })
      .jpeg({ quality: 85 })
      .toBuffer();
  }

  async writePreview(source: string, output: string) {
    await sharp(source, { limitInputPixels: MAGIC_ERASER_LIMITS.maxPixels })
      .resize({ width: 1600, height: 1600, fit: 'inside', withoutEnlargement: true })
      .jpeg({ quality: 85 })
      .toFile(output);
  }

  readPreview(path: string) {
    return readFile(path);
  }

  async writeCopyMetadata(output: string, exif: CopyExif, date: Date) {
    let capture = DateTime.fromJSDate(exif.dateTimeOriginal ?? date, { zone: exif.timeZone ?? 'UTC' });
    if (!capture.isValid) {
      capture = DateTime.fromJSDate(exif.dateTimeOriginal ?? date, { zone: 'UTC' });
    }
    // Deliberate allowlist: pairing identifiers, embedded motion, old face regions,
    // source orientation and thumbnails must not describe the new still image.
    await exiftool.write(
      output,
      {
        DateTimeOriginal: capture.toFormat('yyyy:MM:dd HH:mm:ss'),
        OffsetTimeOriginal: capture.toFormat('ZZ'),
        'Orientation#': 1,
        ColorSpace: 1,
        Make: exif.make ?? undefined,
        Model: exif.model ?? undefined,
        LensModel: exif.lensModel ?? undefined,
        FNumber: exif.fNumber ?? undefined,
        FocalLength: exif.focalLength ?? undefined,
        ISO: exif.iso ?? undefined,
        GPSLatitude: exif.latitude ?? undefined,
        GPSLongitude: exif.longitude ?? undefined,
        ImageDescription: exif.description || undefined,
        Software: 'Photos Magic Eraser (Big-LaMa)',
      },
      { writeArgs: ['-overwrite_original'] },
    );
  }

  async inpaint(id: string, input: string, output: string, mask: MagicEraserCreateDto, signal: AbortSignal) {
    const config = this.config();
    if (!config) {
      throw new InpaintingError('unavailable');
    }
    const form = new FormData();
    form.append('image', await openAsBlob(input, { type: 'image/jpeg' }), 'original.jpg');
    form.append('mask', JSON.stringify(mask));
    form.append('jobId', id);
    const combinedSignal = AbortSignal.any([signal, AbortSignal.timeout(20 * 60 * 1000)]);
    const response = await fetch(new URL('inpaint', config.base), {
      method: 'POST',
      headers: { Authorization: `Bearer ${config.token}` },
      body: form,
      signal: combinedSignal,
      redirect: 'error',
    });
    if (!response.ok || !response.body || response.headers.get('content-type')?.split(';', 1)[0] !== 'image/jpeg') {
      await response.body?.cancel();
      throw new InpaintingError(
        response.status === 429
          ? 'busy'
          : response.status === 422
            ? 'invalid'
            : response.status === 503
              ? 'unavailable'
              : 'processing_failed',
      );
    }
    let bytes = 0;
    const limit = new Transform({
      transform(chunk: Buffer, _encoding, callback) {
        bytes += chunk.length;
        callback(bytes > MAX_BYTES ? new InpaintingError('processing_failed') : null, chunk);
      },
    });
    await pipeline(
      Readable.fromWeb(response.body as unknown as ReadableStream),
      limit,
      createWriteStream(output, { flags: 'wx' }),
      {
        signal: combinedSignal,
      },
    );
    const [before, after] = await Promise.all([
      sharp(input, { limitInputPixels: MAGIC_ERASER_LIMITS.maxPixels }).metadata(),
      sharp(output, { limitInputPixels: MAGIC_ERASER_LIMITS.maxPixels }).metadata(),
    ]);
    if (after.format !== 'jpeg' || after.width !== before.width || after.height !== before.height) {
      throw new InpaintingError('processing_failed');
    }
  }

  async cancel(id: string) {
    const config = this.config();
    if (!config) {
      return;
    }
    try {
      await fetch(new URL(`jobs/${id}`, config.base), {
        method: 'DELETE',
        headers: { Authorization: `Bearer ${config.token}` },
        signal: AbortSignal.timeout(2000),
        redirect: 'error',
      });
    } catch {
      // The inference slot remains owned by the sidecar until its worker exits.
    }
  }

  removeDirectory(directory: string) {
    return rm(directory, { recursive: true, force: true });
  }

  async cleanOrphans(active: Set<string>) {
    for (const entry of await readdir(tmpdir(), { withFileTypes: true })) {
      if (!entry.isDirectory() || !entry.name.startsWith(PREFIX)) {
        continue;
      }
      const directory = join(tmpdir(), entry.name);
      try {
        const details = await stat(directory);
        if (!active.has(directory) && details.mtimeMs < Date.now() - MAGIC_ERASER_TTL_MS) {
          await this.removeDirectory(directory);
        }
      } catch (error) {
        if (!(error instanceof Error && 'code' in error && error.code === 'ENOENT')) {
          throw error;
        }
      }
    }
  }
}
