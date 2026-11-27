import { z } from 'zod';

export const SLUG_PATTERN = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
export const MAX_SLUG_LENGTH = 80;

export const slugSchema = z.string().max(MAX_SLUG_LENGTH).regex(SLUG_PATTERN);

const RAW_HTML = /<\/?[a-zA-Z!][^>]*>|<!--/;
const DANGEROUS_URL = /(?:javascript|data|vbscript|file):/i;
const MARKDOWN_LINK = /\]\(\s*<?([^)\s>]*)/g;
const MARKDOWN_IMAGE = /!\[/;
const REFERENCE_LINK = /^\s*\[[^\]]+\]:\s*\S+/m;
const HEADING_LINE = /^\s{0,3}#{1,6}\s/m;
// Stripping control and bidi-override characters is the whole point of this pattern.
const CONTROL_CHARS = new RegExp(
  // eslint-disable-next-line no-control-regex
  '[\\u0000-\\u0008\\u000B\\u000C\\u000E-\\u001F\\u007F\\u200B-\\u200F\\u202A-\\u202E\\u2066-\\u2069]',
  'g',
);

export function normaliseText(text: string): string {
  return text.replace(CONTROL_CHARS, '').replace(/\r\n?/g, '\n').trim();
}

export function countWords(text: string): number {
  const words = text.trim().match(/\S+/g);
  return words ? words.length : 0;
}

/** Throw if `text` could carry markup or an unsafe link. `field` names the offender in the error. */
export function assertSafeText(text: string, field: string, opts: { allowHeadings?: boolean } = {}): void {
  if (RAW_HTML.test(text)) throw new Error(`${field}: raw HTML is not allowed`);
  if (MARKDOWN_IMAGE.test(text)) throw new Error(`${field}: images are not allowed in drafts`);
  if (REFERENCE_LINK.test(text)) throw new Error(`${field}: reference-style links are not allowed`);
  if (DANGEROUS_URL.test(text.replace(/https?:\/\//gi, ''))) {
    throw new Error(`${field}: javascript:, data: and file: URLs are not allowed`);
  }
  for (const match of text.matchAll(MARKDOWN_LINK)) {
    const url = match[1] ?? '';
    if (!/^https:\/\/[^\s]+$/i.test(url)) throw new Error(`${field}: links must be absolute https URLs`);
  }
  if (!opts.allowHeadings && HEADING_LINE.test(text)) {
    throw new Error(`${field}: headings inside body text are not allowed`);
  }
}

/** Single-line text such as titles and headings: no newlines, no leading Markdown structure. */
export function assertSafeLine(text: string, field: string): void {
  if (/\n/.test(text)) throw new Error(`${field}: must be a single line`);
  if (/^\s*[#>]/.test(text)) throw new Error(`${field}: must not start with # or >`);
  assertSafeText(text, field);
}
