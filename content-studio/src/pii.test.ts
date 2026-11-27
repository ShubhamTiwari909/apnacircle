import { describe, expect, it } from 'vitest';
import { assertNoPii, findPii } from './pii.js';

// Assembled at runtime so secret scanners do not mistake these test values for real credentials.
const fakeGoogleKey = ['AIza', 'SyA1234567890abcdefghijklmnopqrstuv'].join('');
const fakeGithubToken = ['ghp', '_abcdefghijklmnopqrstuvwxyz0123456789'].join('');

describe('personal data detection', () => {
  it.each([
    ['email', 'Contact asha@example.com for details', 'email address'],
    ['indian mobile', 'Call 98765 43210 after noon', 'phone number'],
    ['indian mobile +91', 'Reach me on +91-9876543210', 'phone number'],
    ['international phone', 'Dial +44 20 7946 0958', 'international phone number'],
    ['date of birth', 'Her DOB is on file', 'date of birth'],
    ['user id', 'user 3f2b8c1e-4d5a-4b6c-8d7e-9f0a1b2c3d4e joined', 'user id (uuid)'],
    ['handle', 'follow @asha_k for updates', 'social handle'],
    ['aadhaar-like', 'ID 1234 5678 9012', 'aadhaar-style number'],
    ['google key', `key ${fakeGoogleKey}`, 'api key or token'],
    ['github token', fakeGithubToken, 'api key or token'],
  ])('flags a %s', (_name, text, expected) => {
    expect(findPii(text)).toContain(expected);
  });

  it('allows ordinary public facts, dates and the emergency number', () => {
    const text = 'Company Garden is a public garden. Verified 2026-11-26. Dial 112 in an emergency. Open 6:00-18:00.';
    expect(findPii(text)).toEqual([]);
    expect(() => assertNoPii(text, 'test')).not.toThrow();
  });

  it('throws with the location when personal data is found', () => {
    expect(() => assertNoPii('mail me at a@b.co', 'the rendered prompt')).toThrow(/rendered prompt/);
  });
});
