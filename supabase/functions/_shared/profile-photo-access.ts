export const PHOTO_LINK_TTL_SECONDS = 300;
export const PHOTO_BATCH_LIMIT = 20;

export type PhotoVariant = 'thumb' | 'display';

interface PhotoRead {
  viewer: string;
  variant: PhotoVariant;
  review: boolean;
}

interface AuthorizedPhoto {
  photo_id: string;
  object_path: string;
}

type AuthorizeReads = (read: PhotoRead, ids: string[]) => Promise<AuthorizedPhoto[]>;

const encoder = new TextEncoder();
const ticketPattern = /^([1-9]\d{0,11})\.([0-9a-f]{64})$/;

export function createPhotoAccess(
  serviceKey: string,
  authorizeReads: AuthorizeReads,
  now = () => Math.floor(Date.now() / 1000),
) {
  // Domain-separate the signing key from the credential used to access Storage.
  const signingKey = crypto.subtle
    .importKey('raw', encoder.encode(serviceKey), 'HKDF', false, ['deriveKey'])
    .then((input) =>
      crypto.subtle.deriveKey(
        {
          name: 'HKDF',
          hash: 'SHA-256',
          salt: new Uint8Array(),
          info: encoder.encode('apnacircle/profile-photo-links/v1'),
        },
        input,
        { name: 'HMAC', hash: 'SHA-256' },
        false,
        ['sign', 'verify'],
      ),
    );

  function claims(read: PhotoRead, id: string, expires: number) {
    return encoder.encode(JSON.stringify([read.viewer, id, read.variant, read.review, expires]));
  }

  return {
    async issue(read: PhotoRead, ids: string[]) {
      const authorized = await authorizeReads(read, [...new Set(ids)]);
      const expires = now() + PHOTO_LINK_TTL_SECONDS;
      return Promise.all(
        authorized.map(async ({ photo_id: id }) => {
          const bytes = await crypto.subtle.sign(
            'HMAC',
            await signingKey,
            claims(read, id, expires),
          );
          const signature = Array.from(new Uint8Array(bytes), (byte) =>
            byte.toString(16).padStart(2, '0'),
          ).join('');
          const query = new URLSearchParams({
            id,
            variant: read.variant,
            ticket: `${expires}.${signature}`,
          });
          if (read.review) query.set('review', '1');
          return { id, url: `?${query}` };
        }),
      );
    },

    async redeem(read: PhotoRead, id: string, ticket: string) {
      const parts = ticketPattern.exec(ticket);
      if (!parts) return null;
      const [, expiration, signature] = parts;
      const expires = Number(expiration);
      if (expires <= now()) return null;
      const bytes = Uint8Array.from({ length: 32 }, (_, index) =>
        Number.parseInt(signature.slice(index * 2, index * 2 + 2), 16),
      );
      const valid = await crypto.subtle.verify(
        'HMAC',
        await signingKey,
        bytes,
        claims(read, id, expires),
      );
      if (!valid) return null;
      const [photo] = await authorizeReads(read, [id]);
      return photo?.photo_id === id ? photo.object_path : null;
    },
  };
}
