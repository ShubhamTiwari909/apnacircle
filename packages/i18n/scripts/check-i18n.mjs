import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(__dirname, '../../..');
const enPath = path.join(__dirname, '../src/locales/en.json');
const webSrcDir = path.join(repoRoot, 'apps/web/src');

const en = JSON.parse(fs.readFileSync(enPath, 'utf8'));
const keys = Object.keys(en);

let hasError = false;

if (keys.length === 0) {
  console.error('ERROR: en.json has no keys');
  hasError = true;
}

for (const key of keys) {
  const val = en[key];
  if (typeof val !== 'string' || val.trim().length === 0) {
    console.error(`ERROR: i18n key "${key}" must be a non-empty string`);
    hasError = true;
  }
}

function collectFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const results = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      results.push(...collectFiles(full));
    } else if (/\.(astro|tsx|ts)$/.test(entry.name) && !entry.name.endsWith('.test.ts')) {
      results.push(full);
    }
  }
  return results;
}

const keyRefRegex = /\bt\(\s*['"]([a-zA-Z0-9_.]+)['"]/g;
const sourceDirs = [
  webSrcDir,
  path.join(repoRoot, 'packages/ui/src'),
];

for (const dir of sourceDirs) {
  for (const file of collectFiles(dir)) {
    const content = fs.readFileSync(file, 'utf8');
    let match;
    while ((match = keyRefRegex.exec(content)) !== null) {
      const refKey = match[1];
      if (!Object.prototype.hasOwnProperty.call(en, refKey)) {
        console.error(
          `ERROR: Missing i18n key "${refKey}" referenced in ${path.relative(repoRoot, file)}`,
        );
        hasError = true;
      }
    }
  }
}

if (hasError) {
  process.exit(1);
}

console.info(`[check:i18n] OK — ${keys.length} English catalogue keys verified.`);
