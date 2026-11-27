import { describe, expect, it } from 'vitest';
import { assertSafeLine, assertSafeText, countWords, normaliseText, slugSchema } from './sanitise.js';
import { resolveInside } from './paths.js';

describe('slug allowlist', () => {
  it.each(['saharanpur-parks', 'a1', 'park-2'])('accepts %s', (slug) => {
    expect(slugSchema.safeParse(slug).success).toBe(true);
  });
  it.each(['../outside-project', 'Has-Caps', 'with space', 'trail-', '-lead', 'a/b', 'a..b', '', 'x'.repeat(81)])(
    'rejects %j',
    (slug) => {
      expect(slugSchema.safeParse(slug).success).toBe(false);
    },
  );
});

describe('path confinement', () => {
  it('resolves inside the root', () => {
    expect(resolveInside('/repo', 'content', 'articles', 'a.md')).toBe('/repo/content/articles/a.md');
  });
  it.each([['..', 'x'], ['/outside-project'], ['content', '..', '..', 'secrets']])('rejects %j', (...segments) => {
    expect(() => resolveInside('/repo', ...segments)).toThrow(/escapes/);
  });
});

describe('model output sanitising', () => {
  it.each([
    ['script tag', 'Hello <script>alert(1)</script>'],
    ['html tag', 'A <b>bold</b> claim'],
    ['comment', 'x <!-- hidden --> y'],
    ['image', 'See ![map](https://example.com/a.png)'],
    ['javascript link', '[click](javascript:alert(1))'],
    ['data link', '[click](data:text/html;base64,AAAA)'],
    ['http link', '[site](http://example.com)'],
    ['relative link', '[site](/admin)'],
    ['reference link', '[a]: https://example.com'],
    ['heading in body', 'Intro\n## Sneaky heading'],
  ])('rejects %s', (_name, text) => {
    expect(() => assertSafeText(text, 'body')).toThrow();
  });

  it('accepts prose, bullets and https links', () => {
    expect(() =>
      assertSafeText('Plain text.\n\n- one\n- two\n\nSee [the site](https://example.com/page).', 'body'),
    ).not.toThrow();
  });

  it('keeps titles to a single safe line', () => {
    expect(() => assertSafeLine('Two\nlines', 'title')).toThrow();
    expect(() => assertSafeLine('# Heading', 'title')).toThrow();
    expect(() => assertSafeLine('A fine title', 'title')).not.toThrow();
  });

  it('strips control and bidi characters and counts words', () => {
    expect(normaliseText('  a\u0000b‮c  ')).toBe('abc');
    expect(countWords('one two  three\nfour')).toBe(4);
  });
});
