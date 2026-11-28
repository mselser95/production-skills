import { parseDecimal } from './grammar.ts';
import type { Decimal } from './grammar.ts';
import { isSupportedLocale, learnTemplates, numberSymbols } from './locale.ts';
import { applyTemplate, renderBody, resolveFraction } from './number.ts';
import type { FractionOptions } from './number.ts';
import { failWith, okText } from './types.ts';
import type { FormatResult } from './types.ts';

/** Move the decimal point two places right by string arithmetic: 0.1234 -> 12.34, 1 -> 100, 0.005 -> 0.5. */
export function shiftTwo(d: Decimal): Decimal {
  const frac = d.frac.length < 2 ? d.frac + '0'.repeat(2 - d.frac.length) : d.frac;
  const int = (d.int + frac.slice(0, 2)).replace(/^0+(?=[0-9])/, '');
  return { negative: d.negative, int, frac: frac.slice(2) };
}

/**
 * Format a RATIO decimal string as a percentage: "0.1234" -> "12.34%". The shift is string arithmetic, then the
 * formatDecimal rules apply to the shifted value (rounding, negative zero). Defaults: minFractionDigits 0,
 * maxFractionDigits 2. The percent sign and its spacing are the locale's own (en-US "12.34%", de-DE "12,34 %"
 * with U+00A0, tr-TR "%12,34").
 */
export function formatPercent(ratio: string, options: FractionOptions): FormatResult {
  const r = resolveFraction(options, 0, 2);
  if (r === undefined) return failWith('bad-options');
  if (!isSupportedLocale(options.locale)) return failWith('bad-locale');
  const p = parseDecimal(ratio);
  if (!p.ok) return failWith(p.reason);
  const shifted = shiftTwo(p.value);
  const body = renderBody(shifted, r, numberSymbols(options.locale), true);
  return okText(applyTemplate(learnTemplates(options.locale, { style: 'percent' }), shifted, body, r.sign));
}
