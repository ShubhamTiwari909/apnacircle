import path from 'node:path';

/** Resolve `segments` under `root`; throws if the result would leave `root`. */
export function resolveInside(root: string, ...segments: string[]): string {
  const base = path.resolve(root);
  const target = path.resolve(base, ...segments);
  if (target !== base && !target.startsWith(base + path.sep)) {
    throw new Error(`Path escapes the allowed directory: ${segments.join('/')}`);
  }
  return target;
}

export const SAFE_NAME = /^[a-z0-9][a-z0-9-]{0,79}$/;
