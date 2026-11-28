// provenance: candidate; ttl: 2027-06-30; subject: every count the README states about the Intl cross-check lists equals the lists in the test files
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const read = (name: string): string => readFileSync(new URL('../' + name, import.meta.url), 'utf8');
const words = (src: string, re: RegExp): string[] => {
  const m = re.exec(src);
  if (m?.[1] === undefined) throw new Error(`pattern ${re} not found`);
  return m[1].split(' ');
};

describe('the README states no count the tests could silently falsify', () => {
  const readme = read('README.md');
  const money = read('test/money.test.ts');
  const percent = read('test/percent.test.ts');
  it('the money matrix: locales x currencies x displays equals the lists in test/money.test.ts', () => {
    const m = /(\d+) locales x (\d+) currencies x (\d+) displays for money/.exec(readme);
    expect(m, 'README sentence').not.toBeNull();
    const locales = words(money, /const locales = '([^']+)'\.split\(' '\)/);
    const currencies = /const currencies = \[([^\]]+)\]/.exec(money)?.[1]?.split(',') ?? [];
    const displays = /const displays = \[([^\]]+)\]/.exec(money)?.[1]?.split(',') ?? [];
    expect([Number(m?.[1]), Number(m?.[2]), Number(m?.[3])]).toEqual([locales.length, currencies.length, displays.length]);
  });
  it('the percent list: the number in "(N today)" equals the list in test/percent.test.ts (the one the vitest title counts)', () => {
    const m = /locales listed in `test\/percent\.test\.ts` \((\d+) today\)/.exec(readme);
    expect(m, 'README sentence').not.toBeNull();
    const list = words(percent, /const locales = \('([^']+)'\)\.split\(' '\)/);
    expect(Number(m?.[1])).toBe(list.length);
    expect(list.length).toBeGreaterThan(30);
    // "1 to 9 digits" is the loop bound of that test
    expect(readme).toContain('displayed integer parts of 1 to 9 digits');
    expect(percent).toMatch(/for \(let n = 1; n <= 9; n\+\+\)/);
  });
  it('no other "<number> locales / currencies / displays / tests / calls" appears in the README (a new count must be pinned here)', () => {
    const found = [...readme.matchAll(/\b(\d+)\s+(locales?|currenc(?:y|ies)|displays?|tests?|calls?)\b/g)].map((x) => `${x[1]} ${x[2]}`);
    expect(found).toEqual(['33 locales', '5 currencies', '3 displays']);
  });
});
