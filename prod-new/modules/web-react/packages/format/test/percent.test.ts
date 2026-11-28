// provenance: candidate; ttl: 2027-06-30; subject: formatPercent shift by string arithmetic, rounding, patterns; pinning: true
import { describe, expect, it } from 'vitest';
import { formatPercent } from '../src/index.ts';
import type { FormatResult, FractionOptions } from '../src/index.ts';

const text = (r: FormatResult): string => (r.ok ? r.text : 'ERR:' + r.reason);
const pct = (v: string, o: Partial<FractionOptions> = {}): string => text(formatPercent(v, { locale: 'en-US', ...o }));

describe('formatPercent', () => {
  it.each([
    ['0.1234', '12.34%'],
    ['0.12345', '12.35%'],
    ['1', '100%'],
    ['0', '0%'],
    ['12', '1,200%'],
    ['0.005', '0.5%'],
    ['0.00005', '0.01%'],
    ['0.000049', '0%'],
    ['-0.1234', '-12.34%'],
    ['-0.00004', '0%'],
    ['-0', '0%'],
    ['0.995', '99.5%'],
    ['0.99995', '100%'],
    ['1.5', '150%'],
    ['123456789012345678901234567890', '12,345,678,901,234,567,890,123,456,789,000%'],
    ['0.123456789012345678', '12.35%'],
  ])('%s -> %s', (v, want) => expect(pct(v)).toBe(want));
  it('digit options and rounding', () => {
    expect(pct('0.5', { minFractionDigits: 2, maxFractionDigits: 2 })).toBe('50.00%');
    expect(pct('0.125', { maxFractionDigits: 0 })).toBe('13%');
    expect(pct('0.125', { maxFractionDigits: 0, rounding: 'half-even' })).toBe('12%');
    expect(pct('0.12999', { maxFractionDigits: 0, rounding: 'trunc' })).toBe('12%');
    expect(pct('0.995', { maxFractionDigits: 0 })).toBe('100%');
  });
  it('signDisplay always', () => {
    expect(pct('0.1', { signDisplay: 'always' })).toBe('+10%');
    expect(pct('0', { signDisplay: 'always' })).toBe('0%');
  });
  it('the percent sign and spacing are the locale own', () => {
    expect(pct('0.1234', { locale: 'de-DE' })).toBe('12,34\u00a0%');
    expect(pct('0.1234', { locale: 'fr-FR' })).toBe('12,34\u00a0%');
    expect(pct('0.1234', { locale: 'tr-TR' })).toBe('%12,34');
    expect(pct('-0.1234', { locale: 'tr-TR' })).toBe('-%12,34');
  });
  it('agrees with Intl on exactly representable ratios', () => {
    for (const locale of ['en-US', 'de-DE', 'fr-FR', 'tr-TR', 'ar-EG', 'en-IN']) {
      const nf = new Intl.NumberFormat(locale, { style: 'percent', numberingSystem: 'latn', maximumFractionDigits: 2 });
      for (const v of ['0.5', '-0.5', '0.1234', '1', '12.5', '0.0001']) expect(pct(v, { locale }), `${locale} ${v}`).toBe(nf.format(v as never));
    }
  });
  it.each(['1e-2', '12%', 'NaN', '', ' 0.1', '.1', '1.', '0,5'])('invalid ratio %j', (v) => {
    expect(pct(v)).toMatch(/^ERR:(not-a-decimal|empty)$/);
  });
  it('bad options / locale / too long', () => {
    expect(pct('0.1', { maxFractionDigits: 99 })).toBe('ERR:bad-options');
    expect(pct('0.1', { locale: 'tlh' })).toBe('ERR:bad-locale');
    expect(pct('1'.repeat(500))).toBe('ERR:too-long');
    expect(text(formatPercent('1', undefined as never))).toBe('ERR:bad-options');
  });
});
