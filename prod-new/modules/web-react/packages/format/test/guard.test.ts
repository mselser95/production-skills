// provenance: candidate; ttl: 2027-06-30; subject: the package source contains no float-based number formatting
import { readFileSync, readdirSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

// The package owns this guard for its OWN src/. The app-wide rule (no toFixed / toLocaleString / ad-hoc money outside
// this package) is the web app's eslint configuration, not this test. A line that must use one of these carries the
// marker `format-guard-allow: <reason>`; there is none today.
export const FORBIDDEN: readonly [string, RegExp][] = [
  ['toFixed(', /\.toFixed\(/],
  ['toPrecision(', /\.toPrecision\(/],
  ['toExponential(', /\.toExponential\(/],
  ['toLocaleString(', /\.toLocaleString\(/],
  ['parseFloat(', /\bparseFloat\(/],
  ['parseInt(', /\bparseInt\(/],
  ['Number(', /\bNumber\(/],
  ['Math.round(', /\bMath\.round\(/],
];

export function scan(source: string): string[] {
  const hits: string[] = [];
  source.split('\n').forEach((line, i) => {
    const t = line.trim();
    if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*') || line.includes('format-guard-allow:')) return;
    for (const [name, rx] of FORBIDDEN) if (rx.test(line)) hits.push(`${i + 1}: ${name}`);
  });
  return hits;
}

describe('the source contains no float-based formatting', () => {
  const dir = new URL('../src/', import.meta.url);
  const files = readdirSync(dir).filter((f) => f.endsWith('.ts'));
  it('there are source files to scan (control)', () => {
    expect(files.length).toBeGreaterThanOrEqual(8);
  });
  it.each(files)('%s has no forbidden call', (f) => {
    expect(scan(readFileSync(new URL(f, dir), 'utf8'))).toEqual([]);
  });
  it('the scanner finds each pattern, honours the allow marker and skips comments (control)', () => {
    expect(FORBIDDEN.length).toBe(8);
    expect(scan('const a = x.toFixed(2);')).toEqual(['1: toFixed(']);
    expect(scan('const a = Number(x);')).toEqual(['1: Number(']);
    expect(scan('const a = parseFloat(x);')).toEqual(['1: parseFloat(']);
    expect(scan('const a = Math.round(x);')).toEqual(['1: Math.round(']);
    expect(scan('const a = x.toLocaleString("en");')).toEqual(['1: toLocaleString(']);
    expect(scan('const a = Number.isSafeInteger(x);')).toEqual([]);
    expect(scan('const a = x.toFixed(2); // format-guard-allow: test')).toEqual([]);
    expect(scan('// x.toFixed(2)\n * Number(x)')).toEqual([]);
  });
});
