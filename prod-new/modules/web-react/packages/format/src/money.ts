import { parseDecimal } from './grammar.ts';
import { isSupportedLocale, learnTemplates, numberSymbols } from './locale.ts';
import { applyTemplate, renderBody, resolveFraction } from './number.ts';
import type { Resolved } from './number.ts';
import { failWith, okText, readOptions } from './types.ts';
import type { FormatResult, RoundingMode, SignDisplay } from './types.ts';

export interface MoneyOptions {
  /** BCP 47 tag, REQUIRED. */
  readonly locale: string;
  /** Default `half-up`. */
  readonly rounding?: RoundingMode;
  /** Default `auto`. */
  readonly signDisplay?: SignDisplay;
  /** Default `symbol`. */
  readonly currencyDisplay?: 'symbol' | 'narrowSymbol' | 'code';
}

const CURRENCY = /^[A-Z]{3}$/;
const DISPLAYS: readonly string[] = ['symbol', 'narrowSymbol', 'code'];

/**
 * Format an amount (decimal string, same grammar as formatDecimal) in an ISO 4217 currency. The currency must be
 * three upper-case ASCII letters (`bad-currency` otherwise); the fraction digits are the currency's own, from Intl
 * (USD 2, JPY 0, KWD 3), the amount is rounded to them. Symbol placement and the negative pattern are the locale's
 * own, learned from Intl samples (en-US "-$1.00", de-DE "-1,00 \u20ac"); there is ONE negative style, the locale's minus
 * pattern: never accounting parentheses. Zero after rounding carries no sign ("-0.004" USD -> "$0.00").
 */
export function formatMoney(amount: string, currency: string, opts: MoneyOptions): FormatResult {
  const options = readOptions<MoneyOptions>(opts, ['locale', 'rounding', 'signDisplay', 'currencyDisplay']);
  if (options === undefined) return failWith('bad-options');
  const display = options.currencyDisplay ?? 'symbol';
  const base = resolveFraction({ locale: '', rounding: options.rounding ?? 'half-up', signDisplay: options.signDisplay ?? 'auto' }, 0, 0);
  if (base === undefined || !DISPLAYS.includes(display)) return failWith('bad-options');
  if (!isSupportedLocale(options.locale)) return failWith('bad-locale');
  if (typeof currency !== 'string' || !CURRENCY.test(currency)) return failWith('bad-currency');
  const p = parseDecimal(amount);
  if (!p.ok) return failWith(p.reason);
  const style: Intl.NumberFormatOptions = { style: 'currency', currency, currencyDisplay: display, numberingSystem: 'latn' };
  const resolved = new Intl.NumberFormat(options.locale, style).resolvedOptions();
  const digits = resolved.maximumFractionDigits;
  if (digits === undefined) return failWith('bad-currency');
  const r: Resolved = { ...base, min: digits, max: digits };
  const body = renderBody(p.value, r, numberSymbols(options.locale, style), true);
  return okText(applyTemplate(learnTemplates(options.locale, style), p.value, body, r.sign));
}
