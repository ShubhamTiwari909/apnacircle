// Staff authorisation (plan 7.3).
//
// A staff role lives in `app_metadata`, which only SQL or the service role can write; members can
// never influence it. It is NOT derived from trust_level: "Restricted" is the tier given to members
// who are being sanctioned, and L2 is an ordinary earned tier.
//
// Staff actions additionally require an MFA session (JWT `aal` = `aal2`). The caller must already
// have validated the token with `supabase.auth.getUser(token)`; this helper only reads claims.

export type StaffRole = 'moderator' | 'admin';

interface UserLike {
  app_metadata?: Record<string, unknown> | null;
}

export function staffRole(user: UserLike): StaffRole | null {
  const role = user.app_metadata?.role;
  return role === 'admin' || role === 'moderator' ? role : null;
}

function jwtClaims(token: string): Record<string, unknown> {
  try {
    const payload = token.split('.')[1] ?? '';
    const padded = payload.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (payload.length % 4)) % 4);
    return JSON.parse(atob(padded));
  } catch {
    return {};
  }
}

export function hasMfaSession(token: string): boolean {
  return jwtClaims(token).aal === 'aal2';
}

/** Staff role plus an MFA session. Use for every staff action except MFA enrolment itself. */
export function isStaff(user: UserLike, token: string, opts: { adminOnly?: boolean } = {}): boolean {
  const role = staffRole(user);
  if (role === null || (opts.adminOnly && role !== 'admin')) return false;
  return hasMfaSession(token);
}
