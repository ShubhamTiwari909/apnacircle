/**
 * Personal-data and secret patterns. They run over every fact pack and over every rendered prompt,
 * so a prompt that would carry personal data or a credential is refused before it is sent.
 * Inputs are meant to be public, non-personal facts only (plan 7.6, rule 17.8).
 */
export const PII_PATTERNS: ReadonlyArray<{ name: string; regex: RegExp }> = [
  { name: 'email address', regex: /[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/ },
  { name: 'phone number', regex: /(?<!\d)(?:\+?91[\s-]?|0)?[6-9]\d{4}[\s-]?\d{5}(?!\d)/ },
  { name: 'international phone number', regex: /(?<![\d-])\+\d{1,3}[\s-]?\d[\d\s-]{7,}\d/ },
  { name: 'date of birth', regex: /\b(?:dob|d\.o\.b|date of birth|born on)\b/i },
  { name: 'user id (uuid)', regex: /\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b/i },
  { name: 'social handle', regex: /(?:^|[\s(])@[A-Za-z0-9_.]{3,}/ },
  { name: 'aadhaar-style number', regex: /(?<!\d)\d{4}\s\d{4}\s\d{4}(?!\d)/ },
  { name: 'api key or token', regex: /AIza[0-9A-Za-z_-]{20,}|\bsk-[A-Za-z0-9]{20,}|\bgh[pousr]_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\./ },
];

export function findPii(text: string): string[] {
  return PII_PATTERNS.filter(({ regex }) => regex.test(text)).map(({ name }) => name);
}

export function assertNoPii(text: string, where: string): void {
  const found = findPii(text);
  if (found.length > 0) {
    throw new Error(`Refusing to continue: possible personal data in ${where} (${found.join(', ')})`);
  }
}
