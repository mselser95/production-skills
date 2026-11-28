import { parseDecimal, parseInteger } from './grammar.ts';
import type { Decimal, Parsed } from './grammar.ts';
import { groupDigits, isSupportedLocale, numberSymbols } from './locale.ts';
import type { NumberSymbols, Template, Templates } from './locale.ts';
import { fitFraction, isZero, roundMagnitude } from './round.ts';
import { MAX_FRACTION_DIGITS, failWith, okText } from './types.ts';
import type { FormatResult, RoundingMode, SignDisplay } from './types.ts';

export interface FractionOptions {
  /** BCP 47 tag, REQUIRED: there is no ambient default locale. An unsupported tag is `bad-locale`. */
  readonly locale: string;
  readonly minFractionDigits?: number;
  readonly maxFractionDigits?: number;
  /** Default `half-up`. */
  readonly rounding?: RoundingMode;
  /** Default `auto`. */
  readonly signDisplay?: SignDisplay;
}
export interface DecimalOptions extends FractionOptions {
  /** Group the integer digits (default true). */
  readonly grouping?: boolean;
}

const MODES: readonly string[] = ['half-up', 'half-even', 'trunc'];
const SIGNS: readonly string[] = ['auto', 'always'];

export interface Resolved {
  readonly min: number;
  readonly max: number;
  readonly mode: RoundingMode;
  readonly sign: SignDisplay;
}

const validDigits = (n: number): boolean => Number.isInteger(n) && n >= 0 && n <= MAX_FRACTION_DIGITS;

/** The common option checks and defaults; `undefined` means `bad-options`. */
export function resolveFraction(o: FractionOptions, defMin: number, defMax: number): Resolved | undefined {
  if (typeof o !== 'object' || o === null) return undefined;
  const { minFractionDigits: gmin, maxFractionDigits: gmax } = o;
  if (gmin !== undefined && !validDigits(gmin)) return undefined;
  if (gmax !== undefined && !validDigits(gmax)) return undefined;
  const min = gmin ?? Math.min(defMin, gmax ?? defMax);
  const max = gmax ?? Math.max(defMax, min);
  if (min > max) return undefined;
  const mode = o.rounding ?? 'half-up';
  const sign = o.signDisplay ?? 'auto';
  if (!MODES.includes(mode) || !SIGNS.includes(sign)) return undefined;
  return { min, max, mode, sign };
}

export interface Body {
  readonly text: string;
  readonly zero: boolean;
}

/** Round, fit the fraction, group and join: the digits of a value, no sign. ASCII digits, the locale's separators. */
export function renderBody(d: Decimal, r: Resolved, sym: NumberSymbols, grouping: boolean): Body {
  const m = roundMagnitude(d.int, d.frac, r.max, r.mode);
  const frac = fitFraction(m.frac, r.min);
  const int = grouping ? groupDigits(m.int, sym) : m.int;
  return { text: frac.length > 0 ? int + sym.decimal + frac : int, zero: isZero(m) };
}

/** Which sign a rendered body carries: zero never does. */
export function signOf(d: Decimal, body: Body, sign: SignDisplay): 'minus' | 'plus' | 'none' {
  if (body.zero) return 'none';
  if (d.negative) return 'minus';
  return sign === 'always' ? 'plus' : 'none';
}

/** Wrap a body in the locale's own currency or percent pattern for its sign. */
export function applyTemplate(t: Templates, d: Decimal, body: Body, sign: SignDisplay): string {
  const which = signOf(d, body, sign);
  const tpl: Template = which === 'minus' ? t.neg : which === 'plus' ? t.plus : t.pos;
  return tpl.prefix + body.text + tpl.suffix;
}

function withParsed(p: Parsed, locale: unknown, r: Resolved | undefined, run: (d: Decimal, r: Resolved, sym: NumberSymbols) => string): FormatResult {
  if (r === undefined) return failWith('bad-options');
  if (!isSupportedLocale(locale)) return failWith('bad-locale');
  if (!p.ok) return failWith(p.reason);
  return okText(run(p.value, r, numberSymbols(locale)));
}

function plain(d: Decimal, r: Resolved, sym: NumberSymbols, grouping: boolean): string {
  const body = renderBody(d, r, sym, grouping);
  const which = signOf(d, body, r.sign);
  return (which === 'minus' ? sym.minus : which === 'plus' ? sym.plus : '') + body.text;
}

/**
 * Format a decimal string. Grammar: `-?(0|[1-9][0-9]*)(\.[0-9]+)?`, at most MAX_INPUT_LENGTH characters.
 * Defaults: minFractionDigits 0, maxFractionDigits 3 (min and max follow each other like Intl's), rounding
 * `half-up`, grouping on. Negative zero: a value that rounds to zero is shown WITHOUT a sign ("-0.004" -> "0.00").
 * Checks run in this order: options, locale, value.
 */
export function formatDecimal(value: string, options: DecimalOptions): FormatResult {
  const r = resolveFraction(options, 0, 3);
  return withParsed(parseDecimal(value), options?.locale, r, (d, rr, sym) => plain(d, rr, sym, options.grouping ?? true));
}

export interface NumOptions {
  readonly locale: string;
  readonly signDisplay?: SignDisplay;
  readonly grouping?: boolean;
}

/**
 * Format a COUNT (an integer): a decimal string with no fraction, a bigint, or a number that is a safe integer.
 * Any other number (fractional, NaN, Infinity, beyond 2^53 - 1) is `not-an-integer`; use a string or bigint.
 */
export function formatNum(value: string | bigint | number, options: NumOptions): FormatResult {
  let text: unknown = value;
  if (typeof value === 'bigint') text = value.toString();
  else if (typeof value === 'number') text = Number.isSafeInteger(value) ? String(value) : undefined;
  const p = parseInteger(text);
  const r = resolveFraction({ locale: options?.locale ?? '', minFractionDigits: 0, maxFractionDigits: 0, ...(options?.signDisplay === undefined ? {} : { signDisplay: options.signDisplay }) }, 0, 0);
  return withParsed(p, options?.locale, r, (d, rr, sym) => plain(d, rr, sym, options.grouping ?? true));
}
