import { Buffer } from 'node:buffer';
import jpeg from 'jpeg-js';

export const MAX_SCREENSHOT_BYTES = 1024 * 1024;
export async function sanitizeFeedbackScreenshot(file: File): Promise<string | null> {
  if (file.type !== 'image/jpeg' || !file.size || file.size > MAX_SCREENSHOT_BYTES) return null;
  try {
    const bytes = Buffer.from(await file.arrayBuffer());
    if (bytes[0] !== 0xff || bytes[1] !== 0xd8 || bytes[2] !== 0xff) return null;
    const image = jpeg.decode(bytes, {
      useTArray: true, tolerantDecoding: false, maxResolutionInMP: 2.1, maxMemoryUsageInMB: 32,
    });
    if (image.width > 1440 || image.height > 1440 || image.width < 1 || image.height < 1) return null;
    const encoded = jpeg.encode({ ...image, data: Buffer.from(image.data) }, 83).data;
    return encoded.byteLength <= MAX_SCREENSHOT_BYTES ? encoded.toString('base64') : null;
  } catch {
    return null;
  }
}
