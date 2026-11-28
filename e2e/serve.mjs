import { Buffer } from 'node:buffer';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname } from 'node:path';
import { URL } from 'node:url';
import { installProviders, origin, providerResponse } from './providers.mjs';

const output = new URL('../apps/web/.vercel/output/', import.meta.url);
const vercel = JSON.parse(await readFile(new URL('../apps/web/vercel.json', import.meta.url), 'utf8'));
const staticHeaders = Object.fromEntries(vercel.headers[0].headers.map(({ key, value }) => [key, value]));
const renderFunction = new URL('functions/_render.func/', output);
const { handler } = JSON.parse(await readFile(new URL('.vc-config.json', renderFunction), 'utf8'));

installProviders();
const { default: app } = await import(new URL(handler, renderFunction).href);
const { Request, Response } = globalThis;
const mime = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.ico': 'image/vnd.microsoft.icon',
  '.png': 'image/png', '.xml': 'application/xml', '.txt': 'text/plain',
};

async function readStatic(pathname) {
  const file = extname(pathname) ? pathname : pathname.replace(/\/$/, '') + '/index.html';
  try {
    const content = await readFile(new URL('static' + file, output));
    return new Response(content, { headers: { ...staticHeaders, 'Content-Type': mime[extname(file)] ?? 'application/octet-stream' } });
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return null;
  }
}

createServer(async (incoming, outgoing) => {
  try {
    const chunks = [];
    for await (const chunk of incoming) chunks.push(chunk);
    const url = new URL(incoming.url, origin);
    const request = new Request(url, {
      method: incoming.method, headers: incoming.headers,
      body: chunks.length ? Buffer.concat(chunks) : undefined,
    });
    const fixture = await providerResponse(request);
    const staticFile = !fixture && request.method === 'GET' ? await readStatic(url.pathname) : null;
    const response = fixture ?? staticFile ?? await app.fetch(request);
    const headers = Object.fromEntries(response.headers);
    headers['set-cookie'] = response.headers.getSetCookie();
    outgoing.writeHead(response.status, headers).end(Buffer.from(await response.arrayBuffer()));
  } catch (error) {
    console.error(error);
    outgoing.writeHead(500).end();
  }
}).listen(4173, '127.0.0.1');
