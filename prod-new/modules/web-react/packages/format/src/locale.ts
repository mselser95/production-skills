// What the package learns from Intl, and how. The VALUE being formatted never enters Intl. Intl is asked only about
// fixed SAFE sample numbers (1, -1, 1.5, 10, 100, 1000, 10000, 1234567890123: literals, never the value) to learn the locale's symbols, grouping sizes and the placement
// of a currency or percent sign around the digits. Digits are always ASCII: every Intl object here is built with
// numberingSystem 'latn', whatever numbering the locale tag asks for ("ar-EG", "en-US-u-nu-arab").

export interface NumberSymbols {
  readonly group: string;
  readonly decimal: string;
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

const CACHE_LIMIT = 256;
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

const hasGroup = (parts: Intl.NumberFormatPart[]): boolean => parts.some((p) => p.type === 'group');

/**
 * Minimum grouping digits (1: group at `primary + 1` digits, 2: wait for one more, 3: wait for two more), learned from
 * samples whose DISPLAYED integer part has exactly 4 and then 5 digits. The percent style multiplies by 100, so its
 * samples are 10 and 100 (shown as 1000% and 10000%): asking percent about 1000 would show six digits and learn
 * "group" in locales (be, bg, es, et, hu) that group a four-digit percent only from five. Literal arguments only:
 * these are fixed samples, never the value being formatted.
 */
function minGrouping(auto: Intl.NumberFormat, percent: boolean): number {
  if (hasGroup(percent ? auto.formatToParts(10) : auto.formatToParts(1000))) return 1;
  if (hasGroup(percent ? auto.formatToParts(100) : auto.formatToParts(10000))) return 2;
  return 3;
}

/**
 * The separators and grouping of a locale, learned from Intl on safe samples. `style` selects WHICH Intl style is
 * asked: none = plain numbers; `{style: 'currency', currency, currencyDisplay}` or `{style: 'percent'}` = that style's
 * OWN separators, because CLDR defines currency and percent symbols apart from the plain-number ones in some locales
 * (fr-CH money uses "." for decimals, de-AT money groups with ".", en-CH money groups with ",").
 */
export function numberSymbols(locale: string, style: Intl.NumberFormatOptions = {}): NumberSymbols {
  return remember(symbolCache, locale + '|' + JSON.stringify(style), () => {
    const base: Intl.NumberFormatOptions = { ...style, numberingSystem: 'latn' };
    const always = new Intl.NumberFormat(locale, { ...base, useGrouping: true, minimumFractionDigits: 1, maximumFractionDigits: 1 });
    const auto = new Intl.NumberFormat(locale, base);
    const big = always.formatToParts(1234567890123);
    const pieces = big.filter((p) => p.type === 'integer').map((p) => p.value.length);
    const primary = pieces.length >= 2 ? (pieces[pieces.length - 1] ?? 0) : 0;
    const secondary = pieces.length >= 3 ? (pieces[pieces.length - 2] ?? primary) : primary;
    const part = (parts: Intl.NumberFormatPart[], type: string, fallback: string): string => parts.find((p) => p.type === type)?.value ?? fallback;
    return {
      group: part(big, 'group', ','),
      decimal: part(always.formatToParts(1.5), 'decimal', '.'),
      primary,
      secondary,
      minGrouping: minGrouping(auto, style.style === 'percent'),
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

/** The sign / unit placement for a plain, currency or percent style, from the formatted samples 1, -1 and +1: ALL
 * literal text around the number run, so a locale's bidi control characters before the minus sign are kept. */
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
