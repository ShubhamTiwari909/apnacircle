export interface TurnstileVerificationResult {
  success: boolean;
  errorCodes?: string[];
}

export type FetchLike = typeof fetch;

export async function verifyTurnstileToken(
  token: string,
  secretKey: string | undefined,
  remoteIp?: string | null,
  fetchFn: FetchLike = fetch,
): Promise<TurnstileVerificationResult> {
  if (!secretKey || !token) {
    return { success: false, errorCodes: ['missing-input-secret-or-response'] };
  }

  const formData = new URLSearchParams();
  formData.set('secret', secretKey);
  formData.set('response', token);
  if (remoteIp) {
    formData.set('remoteip', remoteIp);
  }

  try {
    const response = await fetchFn('https://challenges.cloudflare.com/turnstile/v0/siteverify', {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: formData.toString(),
    });

    if (!response.ok) {
      return { success: false, errorCodes: [`http-${response.status}`] };
    }

    const data = (await response.json()) as {
      success?: boolean;
      'error-codes'?: string[];
    };

    return {
      success: data.success === true,
      ...(data['error-codes'] ? { errorCodes: data['error-codes'] } : {}),
    };
  } catch {
    return { success: false, errorCodes: ['verification-network-error'] };
  }
}
