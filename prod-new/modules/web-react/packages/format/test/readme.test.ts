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
const NUMBER_WORDS = new Set(['one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve', 'thirteen', 'fourteen', 'fifteen', 'sixteen', 'seventeen', 'eighteen', 'nineteen', 'twenty', 'thirty', 'forty', 'fifty', 'sixty', 'seventy', 'eighty', 'ninety', 'hundred', 'dozen', 'dozens', 'score']);
export const WINDOW = 4;
export const OWNED_PREFIX = 'Cross-check sizes:';

/** A word: letters and digits, joined into ONE word by hyphens and dots (`hand-picked`, `65-locale`, `locales/65.json` is two). */
const WORD = /[A-Za-z0-9]+(?:[-.][A-Za-z0-9]+)*/g;
const parts = (w: string): string[] => w.split(/[-.]/).filter((x) => x !== '');
/** A version such as `v1.2` or `78.3` inside a word is not a count: it is removed before the number test. A WHOLE-word decimal is judged by `decimalIsCount`. */
const isNumberWord = (w: string): boolean => parts(w.replace(/\d+(?:\.\d+)+/g, '')).some((x) => /^[0-9]+$/.test(x) || NUMBER_WORDS.has(x));
const isStemWord = (w: string): boolean => parts(w).some((x) => STEMS.some((st) => x.startsWith(st)));

/** Sentences of `text` that put a number (digits or a number word) within WINDOW words either side of a stem. */
export function countClaims(text: string): string[] {
  const out: string[] = [];
  for (const para of text.split(/\n\s*\n/)) {
    for (const sentence of para.replace(/\s*\n\s*/g, ' ').split(/(?<=[.!?])\s+(?=[A-Z`(*])/)) {
      const original = sentence.match(WORD) ?? [];
      const words = original.map((w) => w.toLowerCase());
      /** A whole-word decimal (`65.0`) is a count when the NEXT word is a stem (`65.0 locales`) and the word before it is not a name (`ICU 78.3`, `Node 26.7`: capitalised) or `v` / `version`; else a version or a sample value. */
      const decimalIsCount = (j: number): boolean => {
        const before = original[j - 1];
        const isName = before !== undefined && (/^[A-Z]/.test(before) || ['v', 'version'].includes(before.toLowerCase()));
        const after = words[j + 1];
        return after !== undefined && isStemWord(after) && !isName;
      };
      const numberAt = (j: number): boolean => {
        const w = words[j];
        if (w === undefined) return false;
        return /^\d+(?:\.\d+)+$/.test(w) ? decimalIsCount(j) : isNumberWord(w);
      };
      const offsets = Array.from({ length: 2 * WINDOW }, (_, k) => (k < WINDOW ? k - WINDOW : k - WINDOW + 1));
      const hit = words.some((w, j) => isStemWord(w) && (isNumberWord(w) || offsets.some((d) => numberAt(j + d))));
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
    expect(readme).toContain('x integer parts of 1 to 9 digits as shown on screen');
    expect(percent).toMatch(/for \(let n = 1; n <= 9; n\+\+\)/);
  });
  it('anywhere else a number (digits or a number word, within four words) next to locale / currenc / display / language is a finding', () => {
    expect(countClaims(splitOwned(readme).rest)).toEqual([]);
  });
  it('the claim detector sees the forms the owned line replaces, and not plain prose (control)', () => {
    for (const bad of ['It covers 65 locales.', 'It covers sixty-five locales.', 'A 65-locale matrix.', 'Uses 65 CLDR locales.', 'Locales: 65.', 'Spans 65 languages.', 'The 65 Locales matter.', 'We check five currencies.', 'a displayed 4-digit sample', 'We pin 65 hand-picked locales.', 'It uses 65 tested CLDR locales.', 'About a dozen locales are checked.', 'See locales/65.json for the list.', 'A score of locales.', 'It checks 65.0 locales.', 'Pnpm 10.34.3 and 12 locales are used.']) {
      expect(countClaims(bad), bad).toHaveLength(1);
    }
    for (const fine of ['Every locale is learned from Intl.', 'The locale is required.', 'It formats 1234.5 in the locale of the caller.', 'ICU 78.3 locale data is pinned.', 'Version 3 of the format is stable and the caller then simply passes the locale.']) expect(countClaims(fine), fine).toEqual([]);
    // a decimal is a version only after a capitalised name or `v` / `version`; only the 12 makes the last sentence a finding
    for (const fine of ['Pnpm 10.34.3 and the locales are fine.', 'Node 26.7 locales data is pinned.', 'See version 1.2 locale data.', 'Needs v2.5 currency data.']) expect(countClaims(fine), fine).toEqual([]);
    expect(countClaims('Pnpm 10.34.3 and 12 locales')).toHaveLength(1);
    expect(countClaims('Pnpm 10.34.3 and the 12 locales')).toHaveLength(1);
    expect(countClaims('pnpm 10.34.3 and the locales')).toEqual([]);
    expect(splitOwned(`a\n${line(1, 2, 3, 4)}\nb`).rest).toBe('a\nb');
  });
  it('no "<number> tests / calls" appears in the README either', () => {
    expect([...readme.matchAll(/\b(\d+)\s+(tests?|calls?)\b/g)].map((x) => x[0])).toEqual([]);
  });
});
