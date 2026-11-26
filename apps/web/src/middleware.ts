import { defineMiddleware } from 'astro:middleware';
import { getSecurityHeaders } from './lib/security-headers.js';

export const onRequest = defineMiddleware(async (context, next) => {
  const response = await next();
  const headers = getSecurityHeaders(context.url.pathname);

  for (const [key, value] of Object.entries(headers)) {
    response.headers.set(key, value);
  }

  return response;
});
