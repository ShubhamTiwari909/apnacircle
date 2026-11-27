import { describe, expect, it, vi } from 'vitest';
import { createPhotoAccess } from './profile-photo-access.js';

const read = { viewer: 'member-a', variant: 'thumb', review: false } as const;

describe('profile photo links', () => {
  it('authorizes in one batch, deduplicates IDs, and omits denied IDs and paths', async () => {
    const authorize = vi.fn(async () => [{ photo_id: 'photo-a', object_path: 'private/thumb.jpg' }]);
    const access = createPhotoAccess('test-service-key', authorize, () => 2000);
    const links = await access.issue(read, ['photo-a', 'photo-a', 'denied']);
    expect(authorize).toHaveBeenCalledExactlyOnceWith(read, ['photo-a', 'denied']);
    expect(links).toEqual([{ id: 'photo-a', url: expect.stringMatching(/^\?id=photo-a&variant=thumb&ticket=2300\.[a-f0-9]{64}$/) }]);
    expect(JSON.stringify(links)).not.toContain('private/thumb.jpg');
  });

  it('checks the current policy every time an issued link is used', async () => {
    let canView = true;
    const authorize = vi.fn(async () => canView ? [{ photo_id: 'photo-a', object_path: 'private/thumb.jpg' }] : []);
    const access = createPhotoAccess('test-service-key', authorize, () => 2000);
    const [link] = await access.issue(read, ['photo-a']);
    const ticket = new URLSearchParams(link!.url).get('ticket')!;
    await expect(access.redeem(read, 'photo-a', ticket)).resolves.toBe('private/thumb.jpg');
    canView = false;
    await expect(access.redeem(read, 'photo-a', ticket)).resolves.toBeNull();
    expect(authorize).toHaveBeenCalledTimes(3);
  });

  it('rejects a copied link, a changed variant, an elevated review scope and expiry before asking the DB', async () => {
    let now = 2000;
    const authorize = vi.fn(async () => [{ photo_id: 'photo-a', object_path: 'private/thumb.jpg' }]);
    const access = createPhotoAccess('test-service-key', authorize, () => now);
    const [link] = await access.issue(read, ['photo-a']);
    const ticket = new URLSearchParams(link!.url).get('ticket')!;
    await expect(access.redeem({ ...read, viewer: 'member-b' }, 'photo-a', ticket)).resolves.toBeNull();
    await expect(access.redeem({ ...read, variant: 'display' }, 'photo-a', ticket)).resolves.toBeNull();
    await expect(access.redeem({ ...read, review: true }, 'photo-a', ticket)).resolves.toBeNull();
    await expect(access.redeem(read, 'photo-b', ticket)).resolves.toBeNull();
    await expect(access.redeem(read, 'photo-a', ticket.replace('2300.', '2400.'))).resolves.toBeNull();
    now = 2300;
    await expect(access.redeem(read, 'photo-a', ticket)).resolves.toBeNull();
    expect(authorize).toHaveBeenCalledTimes(1);
  });
});
