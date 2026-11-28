// provenance: candidate; ttl: 2027-06-30; subject: formatMoney currency digits, placement, negative style, validation; pinning: true
import { describe, expect, it } from 'vitest';
import { formatMoney } from '../src/index.ts';
import type { FormatResult, MoneyOptions } from '../src/index.ts';

const text = (r: FormatResult): string => (r.ok ? r.text : 'ERR:' + r.reason);
const money = (a: string, c: string, o: Partial<MoneyOptions> = {}): string => text(formatMoney(a, c, { locale: 'en-US', ...o }));

describe('currency fraction digits come from the currency', () => {
  it('USD 2, JPY 0, KWD 3, EUR 2', () => {
    expect(money('1234.5', 'USD')).toBe('$1,234.50');
    expect(money('1234.5', 'JPY')).toBe('\u00a51,235');
    expect(money('1.2345', 'KWD')).toBe('KWD\u00a01.235');
    expect(money('1234.5', 'EUR')).toBe('\u20ac1,234.50');
  });
  it('JPY has no decimal separator at all and KWD has exactly three digits', () => {
    expect(money('1234567.891', 'JPY')).not.toContain('.');
    expect(money('7', 'KWD')).toMatch(/7\.000$/);
    expect(money('7', 'JPY')).toMatch(/7$/);
  });
});

describe('rounding and negative zero', () => {
  it.each([
    ['9.995', '$10.00'],
    ['0.005', '$0.01'],
    ['-0.004', '$0.00'],
    ['-0.005', '-$0.01'],
    ['-1234.5', '-$1,234.50'],
    ['0', '$0.00'],
    ['-0', '$0.00'],
  ])('USD %s -> %s', (a, want) => expect(money(a, 'USD')).toBe(want));
  it('half-even is selectable', () => {
    expect(money('0.005', 'USD', { rounding: 'half-even' })).toBe('$0.00');
    expect(money('0.015', 'USD', { rounding: 'half-even' })).toBe('$0.02');
  });
  it('signDisplay always', () => {
    expect(money('5', 'USD', { signDisplay: 'always' })).toBe('+$5.00');
    expect(money('0', 'USD', { signDisplay: 'always' })).toBe('$0.00');
    expect(money('-5', 'USD', { signDisplay: 'always' })).toBe('-$5.00');
  });
});

describe('placement is the locale own', () => {
  it('de-DE and fr-FR put the euro after the digits behind U+00A0', () => {
    expect(money('1234.5', 'EUR', { locale: 'de-DE' })).toBe('1.234,50\u00a0\u20ac');
    expect(money('-1234.5', 'EUR', { locale: 'de-DE' })).toBe('-1.234,50\u00a0\u20ac');
    expect(money('1234.5', 'EUR', { locale: 'fr-FR' })).toBe('1\u202f234,50\u00a0\u20ac');
  });
  it('en-IN groups in lakhs', () => {
    expect(money('1234567.891', 'INR', { locale: 'en-IN' })).toBe('\u20b912,34,567.89');
  });
  it('currencyDisplay code', () => {
    expect(money('1', 'USD', { currencyDisplay: 'code' })).toBe('USD\u00a01.00');
  });
  it('agrees with Intl (string input is exact there) across locales and currencies, negative style included', () => {
    const cases: [string, string][] = [['en-US', 'USD'], ['de-DE', 'EUR'], ['fr-FR', 'EUR'], ['en-IN', 'INR'], ['es-AR', 'ARS'], ['nl-NL', 'EUR'], ['ja-JP', 'JPY'], ['sv-SE', 'SEK'], ['en-US', 'KWD'], ['pt-BR', 'BRL'], ['de-CH', 'CHF']];
    for (const [locale, currency] of cases) {
      const nf = new Intl.NumberFormat(locale, { style: 'currency', currency, numberingSystem: 'latn' });
      const digits = nf.resolvedOptions().maximumFractionDigits ?? 0;
      for (const a of ['1', '-1', '1234.5', '-1234.5', '1234567', '-1234567.25']) {
        // values with at most `digits` fraction digits, so Intl rounds nothing either
        const frac = a.split('.')[1] ?? '';
        if (frac.length > digits) continue;
        expect(money(a, currency, { locale }), `${locale} ${currency} ${a}`).toBe(nf.format(a as never));
      }
    }
  });
});

describe('validation', () => {
  it.each(['usd', 'US', 'USDD', '', 'U$D', '123', ' USD', 'USD ', 'Usd', '\u0661\u0662\u0663'])('currency %j is bad-currency', (c) => {
    expect(money('1', c)).toBe('ERR:bad-currency');
  });
  it('an unknown but well-formed code is shown as the code, with 2 digits', () => {
    expect(money('1', 'ZZZ')).toBe('ZZZ\u00a01.00');
  });
  it('non-string currency', () => {
    expect(money('1', undefined as never)).toBe('ERR:bad-currency');
  });
  it.each(['1e3', 'NaN', '', ' 1', '1.', '.5', '1,000', '\u0661'])('amount %j is refused', (a) => {
    expect(money(a, 'USD')).toMatch(/^ERR:(not-a-decimal|empty)$/);
  });
  it('options and locale errors, in order', () => {
    expect(money('1', 'USD', { currencyDisplay: 'name' as never })).toBe('ERR:bad-options');
    expect(money('1', 'USD', { rounding: 'x' as never })).toBe('ERR:bad-options');
    expect(text(formatMoney('1', 'USD', undefined as never))).toBe('ERR:bad-options');
    expect(money('1', 'usd', { locale: 'tlh' })).toBe('ERR:bad-locale');
    expect(money('x', 'usd')).toBe('ERR:bad-currency');
  });
  it('a 10 000 digit amount is too-long', () => {
    expect(money('1'.repeat(10_000), 'USD')).toBe('ERR:too-long');
  });
});

// CLDR defines CURRENCY separators apart from the plain-number ones in some locales: the package must learn them
// from the currency style, not borrow the plain-number symbols. Exact code points, ICU/CLDR of the pinned node.
describe('currency separators are the currency style own (code points)', () => {
  const cps = (s: string): string => [...s].map((c) => c.codePointAt(0)?.toString(16)).join(' ');
  it.each([
    ['fr-CH', 'CHF', '-1\'234\'567.50 CHF', '2d 31 27 32 33 34 27 35 36 37 2e 35 30 a0 43 48 46'],
    ['de-AT', 'EUR', '-€ 1.234.567,50', '2d 20ac a0 31 2e 32 33 34 2e 35 36 37 2c 35 30'],
    ['en-CH', 'EUR', '-€1,234,567.50', '2d 20ac 31 2c 32 33 34 2c 35 36 37 2e 35 30'],
    ['de-CH', 'CHF', 'CHF-1\'234\'567.50', '43 48 46 2d 31 27 32 33 34 27 35 36 37 2e 35 30'],
    ['de-LI', 'CHF', '-CHF 1\'234\'567.50', '2d 43 48 46 a0 31 27 32 33 34 27 35 36 37 2e 35 30'],
    ['de-DE', 'EUR', '-1.234.567,50 €', '2d 31 2e 32 33 34 2e 35 36 37 2c 35 30 a0 20ac'],
  ])('%s %s of -1234567.5', (locale, currency, want, codes) => {
    const got = money('-1234567.5', currency, { locale });
    expect(got).toBe(want);
    expect(cps(got)).toBe(codes);
  });
});

describe('formatMoney equals Intl across 33 locales x 5 currencies x 3 displays (safe values only)', () => {
  const locales = 'en-US en-GB en-IN en-CH de-DE de-AT de-CH de-LI fr-FR fr-CH fr-BE fr-CA es-ES es-AR es-MX pt-BR pt-PT it-IT it-CH nl-NL nl-BE sv-SE nb-NO da-DK fi-FI pl-PL cs-CZ hu-HU ru-RU tr-TR ja-JP ko-KR zh-CN'.split(' ');
  const currencies = ['USD', 'EUR', 'CHF', 'JPY', 'KWD'];
  const displays = ['symbol', 'narrowSymbol', 'code'] as const;
  // integers and 2-decimal values below 1e12: exactly representable, so Intl is a trustworthy reference
  const values = ['0', '5', '-5', '999', '1000', '-1000', '12345', '-1234567.5', '1234567.25', '999999999999', '0.5', '-0.5', '1234.56'];
  it('the matrix is as large as claimed (control)', () => {
    expect(locales.length).toBe(33);
    expect(locales.length * currencies.length * displays.length * values.length).toBeGreaterThanOrEqual(6000);
  });
  it('no mismatch', () => {
    const bad: string[] = [];
    for (const locale of locales) {
      for (const currency of currencies) {
        for (const currencyDisplay of displays) {
          const nf = new Intl.NumberFormat(locale, { style: 'currency', currency, currencyDisplay, numberingSystem: 'latn', roundingMode: 'halfExpand' });
          const digits = nf.resolvedOptions().maximumFractionDigits ?? 0;
          for (const v of values) {
            const frac = v.split('.')[1] ?? '';
            if (frac.length > digits) continue; // Intl would round: not a like-for-like comparison
            const want = nf.format(v as never);
            const got = money(v, currency, { locale, currencyDisplay });
            if (got !== want) bad.push(`${locale} ${currency} ${currencyDisplay} ${v}: package ${JSON.stringify(got)} [${[...got].map((c) => c.codePointAt(0)?.toString(16)).join(' ')}] intl ${JSON.stringify(want)} [${[...want].map((c) => c.codePointAt(0)?.toString(16)).join(' ')}]`);
          }
        }
      }
    }
    expect(bad.slice(0, 10), `${bad.length} mismatches`).toEqual([]);
  });
});
