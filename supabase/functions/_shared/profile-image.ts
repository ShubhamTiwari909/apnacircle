import jpeg from 'npm:jpeg-js@0.4.4';

export const MAX_UPLOAD_BYTES = 5 * 1024 * 1024;
const DISPLAY_SIDE = 1080;

type Image = { data: Uint8Array; width: number; height: number };

export class InvalidPhoto extends Error {}

/** Accept the single-scan baseline JPEG produced by the browser. Reject all metadata
 * segments except a plain JFIF header, including EXIF, GPS, XMP, comments and trailing data. */
export function checkUploadJpeg(bytes: Uint8Array) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  if (bytes.length < 4 || bytes.length > MAX_UPLOAD_BYTES || view.getUint16(0) !== 0xffd8) {
    throw new InvalidPhoto('Invalid JPEG');
  }
  let width = 0;
  let height = 0;
  for (let offset = 2; offset + 4 <= bytes.length;) {
    if (bytes[offset] !== 0xff) break;
    const marker = bytes[offset + 1];
    const size = view.getUint16(offset + 2);
    const start = offset + 4;
    const end = offset + 2 + size;
    if (size < 2 || end > bytes.length) break;
    if (marker === 0xc0) {
      if (width || size < 11 || bytes[start] !== 8) break;
      height = view.getUint16(start + 1);
      width = view.getUint16(start + 3);
      if (width < 1 || height < 1 || Math.max(width, height) > DISPLAY_SIDE) {
        throw new InvalidPhoto('Invalid dimensions');
      }
    } else if (marker === 0xe0) {
      if (
        size !== 16 ||
        view.getUint32(start) !== 0x4a464946 ||
        bytes[start + 4] !== 0 ||
        bytes[end - 1] !== 0 ||
        bytes[end - 2] !== 0
      )
        break;
    } else if (marker === 0xda) {
      if (!width) break;
      for (let index = end; index + 1 < bytes.length; index++) {
        if (bytes[index] !== 0xff) continue;
        const next = bytes[++index];
        if (next === 0x00 || (next >= 0xd0 && next <= 0xd7)) continue;
        if (next === 0xd9 && index === bytes.length - 1) return { width, height };
        break;
      }
      break;
    } else if (marker !== 0xdb && marker !== 0xc4 && marker !== 0xdd) {
      break;
    }
    offset = end;
  }
  throw new InvalidPhoto('Unexpected JPEG structure or metadata');
}

/** Area-average resampling. Integer rectangular samples also handle panoramic photos. */
function resample(image: Image, width: number, height: number): Image {
  if (width === image.width && height === image.height) return image;
  const data = new Uint8Array(width * height * 4);
  for (let y = 0; y < height; y++) {
    const top = Math.floor((y * image.height) / height);
    const bottom = Math.max(top + 1, Math.floor(((y + 1) * image.height) / height));
    for (let x = 0; x < width; x++) {
      const left = Math.floor((x * image.width) / width);
      const right = Math.max(left + 1, Math.floor(((x + 1) * image.width) / width));
      let r = 0;
      let g = 0;
      let b = 0;
      for (let row = top; row < bottom; row++) {
        for (let col = left; col < right; col++) {
          const src = (row * image.width + col) * 4;
          r += image.data[src];
          g += image.data[src + 1];
          b += image.data[src + 2];
        }
      }
      const count = (bottom - top) * (right - left);
      const dst = (y * width + x) * 4;
      data[dst] = Math.round(r / count);
      data[dst + 1] = Math.round(g / count);
      data[dst + 2] = Math.round(b / count);
      data[dst + 3] = 255;
    }
  }
  return { data, width, height };
}

function resize(image: Image, side: number) {
  const factor = Math.min(1, side / Math.max(image.width, image.height));
  return resample(
    image,
    Math.max(1, Math.round(image.width * factor)),
    Math.max(1, Math.round(image.height * factor)),
  );
}

function encodeVariant(image: Image, side: number, byteLimit: number, quality: number) {
  const resized = resize(image, side);
  const preferred = jpeg.encode(resized, quality).data;
  if (preferred.length <= byteLimit) return preferred;
  const compact = jpeg.encode(resized, 52).data;
  if (compact.length <= byteLimit) return compact;
  return encodeVariant(resized, Math.floor(side / 2), byteLimit, 52);
}

/** 256-bit difference hash over adjacent luminance samples. */
export function photoDifferenceHash(image: Image): string {
  const sample = resample(image, 17, 16);
  const luminance = (index: number) =>
    299 * sample.data[index] + 587 * sample.data[index + 1] + 114 * sample.data[index + 2];
  let hash = '';
  for (let y = 0; y < 16; y++) {
    for (let x = 0; x < 16; x += 4) {
      let nibble = 0;
      for (let bit = 0; bit < 4; bit++) {
        const index = (y * 17 + x + bit) * 4;
        nibble = (nibble << 1) | Number(luminance(index) > luminance(index + 4));
      }
      hash += nibble.toString(16);
    }
  }
  return hash;
}

export function imageBase64(bytes: Uint8Array): string {
  let binary = '';
  for (let offset = 0; offset < bytes.length; offset += 8192) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 8192));
  }
  return btoa(binary);
}

export async function makePhotoVariants(bytes: Uint8Array) {
  const dimensions = checkUploadJpeg(bytes);
  let image: Image;
  try {
    image = jpeg.decode(bytes, {
      useTArray: true,
      tolerantDecoding: false,
      maxResolutionInMP: 2,
      maxMemoryUsageInMB: 64,
    });
  } catch {
    throw new InvalidPhoto('Invalid image data');
  }
  if (image.width !== dimensions.width || image.height !== dimensions.height) {
    throw new InvalidPhoto('Inconsistent dimensions');
  }

  const display = encodeVariant(image, DISPLAY_SIDE, 180 * 1024, 78);
  const thumb = encodeVariant(image, 320, 25 * 1024, 74);
  const placeholder = jpeg.encode(resize(image, 16), 30).data;
  const source = new Uint8Array(bytes);
  const digest = await crypto.subtle.digest('SHA-256', source);
  return {
    display,
    thumb,
    blur: `data:image/jpeg;base64,${imageBase64(placeholder)}`,
    phash: photoDifferenceHash(image),
    sha256: [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join(''),
  };
}

export async function readPhotoBody(request: Request): Promise<Uint8Array> {
  if (!request.body || Number(request.headers.get('content-length')) > MAX_UPLOAD_BYTES) {
    throw new InvalidPhoto('Invalid upload size');
  }
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      size += value.length;
      if (size > MAX_UPLOAD_BYTES) {
        await reader.cancel();
        throw new InvalidPhoto('Photo is larger than 5 MB');
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.length;
  }
  return bytes;
}
