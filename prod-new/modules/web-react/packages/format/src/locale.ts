// What the package learns from Intl, and how. The VALUE being formatted never enters Intl. Intl is asked only about
// SAFE small integers (1, -1, 1000, 1234567890123) to learn the locale's symbols, grouping sizes and the placement
// of a currency or percent sign around the digits. Digits are always ASCII: every Intl object here is built with
// numberingSystem 'latn', whatever numbering the locale tag asks for ("ar-EG", "en-US-u-nu-arab").

export interface NumberSymbols {
  readonly group: string;
  readonly decimal: string;
  readonly minus: string;
  readonly plus: string;
  /** Size of the group next to the decimal point; 0 = the locale does not group. */
  readonly primary: number;
  /** Size of every further group (2 in en-IN, where 1234567 is 12,34,567). */
  readonly secondary: number;
  /** 1: group as soon as there are `primary + 1` digits; 2: the locale waits for one more digit (es, pt-PT, pl). */
  readonly minGrouping: number;
}

/** What a formatted 1 / -1 / +1 looks like around its digits: the text before and after the number run. */
export interface Template {
  readonly prefix: string;
  readonly suffix: string;
}
export interface Templates {
  readonly pos: Template;
  readonly neg: Template;
  readonly plus: Template;
}

const CACHE_LIMIT = 64;
function remember<T>(cache: Map<string, T>, key: string, make: () => T): T {
  const hit = cache.get(key);
  if (hit !== undefined) return hit;
  const made = make();
  if (cache.size >= CACHE_LIMIT) cache.clear();
  cache.set(key, made);
  return made;
}

/** True when `locale` is a well-formed tag the engine really supports. An unsupported tag is NOT allowed to fall
 * back to the ambient default locale: that would make the output depend on the machine. */
export function isSupportedLocale(locale: unknown): locale is string {
  if (typeof locale !== 'string' || locale.length === 0 || locale.length > 64) return false;
  try {
    return Intl.NumberFormat.supportedLocalesOf([locale]).length === 1 && Intl.DateTimeFormat.supportedLocalesOf([locale]).length === 1;
  } catch {
    return false;
  }
}

const symbolCache = new Map<string, NumberSymbols>();

export function numberSymbols(locale: string): NumberSymbols {
  return remember(symbolCache, locale, () => {
    const always = new Intl.NumberFormat(locale, { numberingSystem: 'latn', useGrouping: true, maximumFractionDigits: 1 });
    const auto = new Intl.NumberFormat(locale, { numberingSystem: 'latn' });
    const big = always.formatToParts(1234567890123);
    const pieces = big.filter((p) => p.type === 'integer').map((p) => p.value.length);
    const primary = pieces.length >= 2 ? (pieces[pieces.length - 1] ?? 0) : 0;
    const secondary = pieces.length >= 3 ? (pieces[pieces.length - 2] ?? primary) : primary;
    const part = (parts: Intl.NumberFormatPart[], type: string, fallback: string): string => parts.find((p) => p.type === type)?.value ?? fallback;
    return {
      group: part(big, 'group', ','),
      decimal: part(always.formatToParts(1.5), 'decimal', '.'),
      minus: part(always.formatToParts(-1), 'minusSign', '-'),
      plus: part(new Intl.NumberFormat(locale, { numberingSystem: 'latn', signDisplay: 'always' }).formatToParts(1), 'plusSign', '+'),
      primary,
      secondary,
      minGrouping: auto.formatToParts(1000).some((p) => p.type === 'group') ? 1 : 2,
    };
  });
}

/** Insert the group separator into an integer digit string by the locale's grouping sizes. */
export function groupDigits(int: string, s: NumberSymbols): string {
  if (s.primary === 0 || int.length < s.primary + s.minGrouping) return int;
  const groups: string[] = [];
  let end = int.length;
  let size = s.primary;
  while (end > 0) {
    const start = Math.max(0, end - size);
    groups.unshift(int.slice(start, end));
    end = start;
    size = s.secondary;
  }
  return groups.join(s.group);
}

const NUMERIC = new Set(['integer', 'group', 'decimal', 'fraction']);

function templateOf(parts: Intl.NumberFormatPart[]): Template {
  const first = parts.findIndex((p) => NUMERIC.has(p.type));
  let last = -1;
  parts.forEach((p, i) => {
    if (NUMERIC.has(p.type)) last = i;
  });
  const join = (xs: Intl.NumberFormatPart[]): string => xs.map((p) => p.value).join('');
  return { prefix: join(parts.slice(0, Math.max(first, 0))), suffix: join(parts.slice(last + 1)) };
}

const templateCache = new Map<string, Templates>();

/** The sign / unit placement for a currency or percent style, from the formatted samples 1, -1 and +1. */
export function learnTemplates(locale: string, options: Intl.NumberFormatOptions): Templates {
  return remember(templateCache, locale + '|' + JSON.stringify(options), () => {
    const base: Intl.NumberFormatOptions = { ...options, numberingSystem: 'latn' };
    return {
      pos: templateOf(new Intl.NumberFormat(locale, base).formatToParts(1)),
      neg: templateOf(new Intl.NumberFormat(locale, base).formatToParts(-1)),
      plus: templateOf(new Intl.NumberFormat(locale, { ...base, signDisplay: 'always' }).formatToParts(1)),
    };
  });
}
