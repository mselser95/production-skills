// provenance: candidate; ttl: 2027-06-30; subject: every count the README states about the Intl cross-check lists equals the lists in the test files
import { readFileSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

const read = (name: string): string => readFileSync(new URL('../' + name, import.meta.url), 'utf8');
const words = (src: string, re: RegExp): string[] => {
  const m = re.exec(src);
  if (m?.[1] === undefined) throw new Error(`pattern ${re} not found`);
  return m[1].split(' ');
};

const STEMS = ['locale', 'currenc', 'display', 'language'];
const NUMBER_WORDS = new Set(['one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety', 'hundred']);
export const OWNED_PREFIX = 'Cross-check sizes:';

/** Sentences of `text` that put a number (digits or a number word, within two words either side) next to a stem. */
export function countClaims(text: string): string[] {
  const out: string[] = [];
  for (const para of text.split(/\n\s*\n/)) {
    for (const sentence of para.replace(/\s*\n\s*/g, ' ').split(/(?<=[.!?])\s+(?=[A-Z`(*])/)) {
      const words = sentence.toLowerCase().split(/[^a-z0-9]+/).filter((w) => w !== '');
      const hit = words.some((w, j) => STEMS.some((st) => w.startsWith(st)) && [-2, -1, 1, 2].some((d) => {
        const x = words[j + d];
        return x !== undefined && (/^[0-9]+$/.test(x) || NUMBER_WORDS.has(x));
      }));
      if (hit) out.push(sentence.slice(0, 90));
    }
  }
  return out;
}

/** The README text with the one line this test owns taken out, and that line. */
export function splitOwned(readme: string): { rest: string; owned: string[] } {
  const lines = readme.split('\n');
  return { rest: lines.filter((l) => !l.startsWith(OWNED_PREFIX)).join('\n'), owned: lines.filter((l) => l.startsWith(OWNED_PREFIX)) };
}

describe('the README states no count the tests could silently falsify', () => {
  const readme = read('README.md');
  const money = read('test/money.test.ts');
  const percent = read('test/percent.test.ts');
  const locales = words(money, /const locales = '([^']+)'\.split\(' '\)/);
  const currencies = /const currencies = \[([^\]]+)\]/.exec(money)?.[1]?.split(',') ?? [];
  const displays = /const displays = \[([^\]]+)\]/.exec(money)?.[1]?.split(',') ?? [];
  const percentLocales = words(percent, /const locales = \('([^']+)'\)\.split\(' '\)/);
  const line = (l: number, c: number, d: number, p: number): string => `${OWNED_PREFIX} money ${l} locales x ${c} currencies x ${d} displays; percent ${p} locales.`;
  it('the owned line "Cross-check sizes:" is the only place a size is stated, and it equals the lists in test/money.test.ts and test/percent.test.ts', () => {
    const { owned } = splitOwned(readme);
    expect(owned).toEqual([line(locales.length, currencies.length, displays.length, percentLocales.length)]);
    expect(percentLocales.length).toBeGreaterThan(30);
    // "1 to 9 digits" is the loop bound of the percent test
    expect(readme).toContain('displayed integer parts of 1 to 9 digits');
    expect(percent).toMatch(/for \(let n = 1; n <= 9; n\+\+\)/);
  });
  it('anywhere else a number (digits or a number word, within two words) next to locale / currenc / display / language is a finding', () => {
    expect(countClaims(splitOwned(readme).rest)).toEqual([]);
  });
  it('the claim detector sees the forms the owned line replaces, and not plain prose (control)', () => {
    for (const bad of ['It covers 65 locales.', 'It covers sixty-five locales.', 'A 65-locale matrix.', 'Uses 65 CLDR locales.', 'Locales: 65.', 'Spans 65 languages.', 'The 65 Locales matter.', 'We check five currencies.', 'a displayed 4-digit sample']) {
      expect(countClaims(bad), bad).toHaveLength(1);
    }
    for (const fine of ['Every locale is learned from Intl.', 'The locale is required.', 'It formats 1234.5 in the locale of the caller.']) expect(countClaims(fine), fine).toEqual([]);
    expect(splitOwned(`a\n${line(1, 2, 3, 4)}\nb`).rest).toBe('a\nb');
  });
  it('no "<number> tests / calls" appears in the README either', () => {
    expect([...readme.matchAll(/\b(\d+)\s+(tests?|calls?)\b/g)].map((x) => x[0])).toEqual([]);
  });
});
