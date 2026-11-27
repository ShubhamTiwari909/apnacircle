/* global document, window, createImageBitmap, fetch, URLSearchParams, FormData, Blob */
const manager = document.querySelector('[data-profile-photos]');
const MAX_BYTES = 5 * 1024 * 1024;
const MAX_SIDE = 1080;

// Canvas encoders can add their own ICC, EXIF, or Photoshop app segments.
async function stripJpegMetadata(jpeg, message) {
  const bytes = new Uint8Array(await jpeg.arrayBuffer());
  const chunks = [bytes.subarray(0, 2)];
  for (let offset = 2; offset + 4 <= bytes.length;) {
    if (bytes[offset] !== 0xff) break;
    const marker = bytes[offset + 1];
    const length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    const end = offset + 2 + length;
    if (length < 2 || end > bytes.length) break;
    if (marker === 0xda) {
      chunks.push(bytes.subarray(offset));
      return new Blob(chunks, { type: 'image/jpeg' });
    }
    if ((marker < 0xe0 || marker > 0xef) && marker !== 0xfe) {
      chunks.push(bytes.subarray(offset, end));
    }
    offset = end;
  }
  throw new Error(message);
}

async function preparePhoto(file, messages) {
  if (!file?.size) throw new Error(messages.invalid);
  if (file.size > MAX_BYTES) throw new Error(messages.size);
  const header = new Uint8Array(await file.slice(0, 12).arrayBuffer());
  const ascii = (start, end) => String.fromCharCode(...header.subarray(start, end));
  const isJpeg = header[0] === 0xff && header[1] === 0xd8 && header[2] === 0xff;
  const isPng = header[0] === 0x89 && ascii(1, 8) === 'PNG\r\n\x1a\n';
  const isWebp = ascii(0, 4) === 'RIFF' && ascii(8, 12) === 'WEBP';
  if (!isJpeg && !isPng && !isWebp) throw new Error(messages.invalid);

  const image = await createImageBitmap(file).catch(() => null);
  if (!image) throw new Error(messages.invalid);
  try {
    if (image.width * image.height > 50_000_000 || Math.max(image.width, image.height) > 12000) {
      throw new Error(messages.invalid);
    }
    const scale = Math.min(1, MAX_SIDE / Math.max(image.width, image.height));
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.round(image.width * scale));
    canvas.height = Math.max(1, Math.round(image.height * scale));
    const context = canvas.getContext('2d', { alpha: false });
    if (!context) throw new Error(messages.invalid);
    context.fillStyle = '#fff';
    context.fillRect(0, 0, canvas.width, canvas.height);
    context.drawImage(image, 0, 0, canvas.width, canvas.height);
    const jpeg = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', 0.9));
    if (!jpeg || jpeg.type !== 'image/jpeg') throw new Error(messages.invalid);
    return stripJpegMetadata(jpeg, messages.invalid);
  } finally {
    image.close();
  }
}

if (manager) {
  const form = manager.querySelector('[data-photo-upload]');
  const message = manager.querySelector('[data-photo-message]');
  const messages = JSON.parse(manager.dataset.messages);
  const buttons = [...manager.querySelectorAll('button')];

  async function mutate(button, progress, completed, perform) {
    buttons.forEach((control) => {
      control.disabled = true;
    });
    message.textContent = progress;
    button.setAttribute('aria-busy', 'true');
    try {
      const response = await perform();
      if (!response.ok) {
        const errors = {
          401: messages.session,
          403: messages.membership,
          409: messages.limit,
          422: messages.invalid,
        };
        throw new Error(errors[response.status] ?? messages.unavailable);
      }
      window.location.assign(`?${completed}=1`);
    } catch (error) {
      const known = Object.values(messages).includes(error?.message);
      message.textContent = known ? error.message : messages.unavailable;
      buttons.forEach((control) => {
        control.disabled = false;
      });
      button.removeAttribute('aria-busy');
    }
  }

  buttons.forEach((control) => {
    control.disabled = false;
  });
  form?.addEventListener('submit', (event) => {
    event.preventDefault();
    const values = new FormData(form);
    void mutate(form.querySelector('button'), messages.uploading, 'uploaded', async () => {
      const body = await preparePhoto(values.get('photo'), messages);
      const params = new URLSearchParams({ visibility: values.get('visibility') });
      return fetch(`${manager.dataset.endpoint}?${params}`, {
        method: 'POST',
        headers: { 'Content-Type': 'image/jpeg' },
        body,
      });
    });
  });

  for (const button of manager.querySelectorAll('[data-remove-photo]')) {
    button.addEventListener('click', () => {
      void mutate(button, messages.removing, 'removed', () =>
        fetch(
          `${manager.dataset.endpoint}?${new URLSearchParams({ id: button.dataset.removePhoto })}`,
          { method: 'DELETE' },
        ),
      );
    });
  }
}
