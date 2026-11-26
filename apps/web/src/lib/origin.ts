export function isAllowedOrigin(
  requestOrigin: string | null,
  expectedOrigin: string,
  configuredSiteUrl?: string,
): boolean {
  if (!requestOrigin) {
    return false;
  }

  if (requestOrigin === expectedOrigin) {
    return true;
  }

  if (configuredSiteUrl) {
    try {
      return requestOrigin === new URL(configuredSiteUrl).origin;
    } catch {
      return false;
    }
  }

  return false;
}
