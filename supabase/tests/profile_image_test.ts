import jpeg from 'npm:jpeg-js@0.4.4';
import {
  checkUploadJpeg,
  InvalidPhoto,
  makePhotoVariants,
  MAX_UPLOAD_BYTES,
  photoDifferenceHash,
  readPhotoBody,
} from '../functions/_shared/profile-image.ts';
import { screenPhoto } from '../functions/_shared/photo-screening.ts';

function assert(test: unknown, message: string): asserts test {
  if (!test) throw new Error(message);
}

function sample(width: number, height: number) {
  const data = new Uint8Array(width * height * 4);
  for (let index = 0; index < width * height; index++) {
    const shade = 255 - Math.floor(((index % width) * 255) / width);
    data.set([shade, shade, shade, 255], index * 4);
  }
  return { data, width, height };
}

Deno.test('creates both capped JPEG variants and a metadata-free placeholder', async () => {
  const original = jpeg.encode(sample(1080, 720), 75).data;
  const result = await makePhotoVariants(original);
  const display = checkUploadJpeg(result.display);
  const thumb = checkUploadJpeg(result.thumb);
  const placeholder = Uint8Array.from(atob(result.blur.split(',')[1]), (byte) =>
    byte.charCodeAt(0),
  );
  assert(
    display.width === 1080 && result.display.length <= 180 * 1024,
    'display dimensions and size',
  );
  assert(thumb.width === 320 && result.thumb.length <= 25 * 1024, 'thumbnail dimensions and size');
  assert(checkUploadJpeg(placeholder).width === 16, 'placeholder dimensions');
  assert(
    result.phash === photoDifferenceHash(sample(510, 340)),
    'perceptual hash survives a rescale',
  );
  assert(result.sha256.length === 64, 'legacy exact fingerprint');
});

Deno.test('rejects misleading MIME bytes, embedded EXIF and oversized dimensions', () => {
  const original = jpeg.encode(sample(48, 48), 70).data;
  const exif = [0xff, 0xe1, 0, 14, 69, 120, 105, 102, 0, 0, 71, 80, 83, 0, 0, 0];
  const metadata = Uint8Array.from([...original.subarray(0, 2), ...exif, ...original.subarray(2)]);
  const malformed = [
    new TextEncoder().encode('<svg></svg>'),
    metadata,
    Uint8Array.from([...original, 0x41]),
    jpeg.encode(sample(1081, 1), 70).data,
  ];

  for (const bytes of malformed) {
    try {
      checkUploadJpeg(bytes);
      throw new Error('Invalid input accepted');
    } catch (error) {
      assert(error instanceof InvalidPhoto, 'upload must be rejected before decoding');
    }
  }
});

Deno.test('enforces the stream limit without trusting Content-Length', async () => {
  const request = new Request('http://localhost', {
    method: 'POST',
    body: new Uint8Array(MAX_UPLOAD_BYTES + 1),
  });
  try {
    await readPhotoBody(request);
    throw new Error('Oversized stream accepted');
  } catch (error) {
    assert(error instanceof InvalidPhoto, 'oversized stream must be rejected');
  }
});

Deno.test('screening flags likely results and rejects missing results', async () => {
  const thumbnail = new Uint8Array([1, 2, 3]);
  const fakeFetch: typeof fetch = async (url, init) => {
    assert(url === 'https://vision.googleapis.com/v1/images:annotate', 'fixed screening endpoint');
    const payload = JSON.parse(String(init?.body));
    assert(payload.requests[0].image.content === 'AQID', 'only the encoded thumbnail is sent');
    return Response.json({
      responses: [
        { safeSearchAnnotation: { adult: 'LIKELY', violence: 'UNLIKELY', racy: 'UNLIKELY' } },
      ],
    });
  };
  assert(
    (await screenPhoto(thumbnail, 'test-key', fakeFetch)) === 'flagged',
    'likely result enters the priority queue',
  );
  let rejected = false;
  try {
    await screenPhoto(thumbnail, 'test-key', async () =>
      Response.json({ responses: [{ error: {} }] }),
    );
  } catch {
    rejected = true;
  }
  assert(rejected, 'a missing screening response cannot clear an image');
});
