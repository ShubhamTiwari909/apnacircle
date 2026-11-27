import { describe, expect, it } from 'vitest';
import { hasMfaSession, isStaff, tokenIssuedAt } from './staff.ts';

const b64 = (o: unknown) => btoa(JSON.stringify(o)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const token = (claims: Record<string, unknown>) => `${b64({ alg: 'none' })}.${b64(claims)}.sig`;

describe('staff token helpers', () => {
  it('reads issue time and the MFA level from the token claims', () => {
    expect(tokenIssuedAt(token({ iat: 1700000000 }))).toBe(1700000000);
    expect(tokenIssuedAt(token({}))).toBeNull();
    expect(tokenIssuedAt('garbage')).toBeNull();
    expect(hasMfaSession(token({ aal: 'aal2' }))).toBe(true);
    expect(hasMfaSession(token({ aal: 'aal1' }))).toBe(false);
  });

  it('requires a staff role and an MFA session, and admin for admin-only actions', () => {
    const mod = { app_metadata: { role: 'moderator' } };
    const admin = { app_metadata: { role: 'admin' } };
    const mfa = token({ aal: 'aal2' });
    expect(isStaff(mod, mfa)).toBe(true);
    expect(isStaff(mod, mfa, { adminOnly: true })).toBe(false);
    expect(isStaff(admin, mfa, { adminOnly: true })).toBe(true);
    expect(isStaff(admin, token({ aal: 'aal1' }))).toBe(false);
    expect(isStaff({ app_metadata: {} }, mfa)).toBe(false);
  });
});
