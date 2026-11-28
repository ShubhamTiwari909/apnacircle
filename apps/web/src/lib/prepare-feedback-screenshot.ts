export async function prepareFeedbackScreenshot(file: File): Promise<Blob> {
  if (file.size > 5 * 1024 * 1024 || !['image/png', 'image/jpeg', 'image/webp'].includes(file.type)) throw new Error('Invalid file');
  const image = await createImageBitmap(file);
  try {
    if (!image.width || !image.height || image.width * image.height > 30_000_000) throw new Error('Invalid dimensions');
    const scale = Math.min(1, 1440 / Math.max(image.width, image.height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(image.width * scale));
    canvas.height = Math.max(1, Math.round(image.height * scale));
    const context = canvas.getContext('2d', { alpha: false });
    if (!context) throw new Error('Image rendering unavailable');
    context.fillStyle = '#fff';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    const result = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, 'image/jpeg', 0.85));
    if (!result || result.type !== 'image/jpeg' || result.size > 1024 * 1024) throw new Error('Invalid encoded image');
    return result;
  } finally {
    image.close();
  }
}
