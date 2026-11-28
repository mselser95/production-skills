// provenance: candidate; ttl: 2027-06-30; subject: plain decimals keep the locale's full sign prefix, bidi control characters included; pinning: true
import { describe, expect, it } from 'vitest';
import { formatDecimal, formatNum } from '../src/index.ts';

const cps = (s: string): string => [...s].map((c) => c.codePointAt(0)?.toString(16)).join(' ');
const dec = (v: string, locale: string, signDisplay: 'auto' | 'always' = 'auto'): string => {
  const r = formatDecimal(v, { locale, maxFractionDigits: 3, signDisplay });
  return r.ok ? r.text : 'ERR:' + r.reason;
};

describe('plain decimals carry the locale sign prefix (RTL locales emit a bidi mark before the minus)', () => {
  it('ar-EG: U+200E then ASCII hyphen-minus; fa-IR: U+200E then U+2212 (exact code points)', () => {
    expect(cps(dec('-1234', 'ar-EG'))).toBe('200e 2d 31 2c 32 33 34');
    expect(cps(dec('-1234', 'fa-IR'))).toBe('200e 2212 31 2c 32 33 34');
  });
  it.each(['ar-EG', 'he-IL', 'ar-SA', 'ur-PK', 'fa-IR', 'en-US', 'de-DE', 'tr-TR'])('%s equals Intl for negative, positive and always-signed values', (locale) => {
    const bad: string[] = [];
    for (const signDisplay of ['auto', 'always'] as const) {
      const nf = new Intl.NumberFormat(locale, { numberingSystem: 'latn', maximumFractionDigits: 3, signDisplay: signDisplay === 'always' ? 'exceptZero' : 'auto' }); // zero never carries a sign here
      for (const v of ['0', '-0.5', '0.5', '-1234', '1234', '-1234567.891', '1234567.891']) {
        const got = dec(v, locale, signDisplay);
        const want = nf.format(v as never);
        if (got !== want) bad.push(`${locale} ${signDisplay} ${v}: package [${cps(got)}] intl [${cps(want)}]`);
      }
    }
    expect(bad).toEqual([]);
  });
  it('formatNum shares the same sign prefix', () => {
    const r = formatNum(-1234, { locale: 'ar-EG' });
    expect(r.ok ? cps(r.text) : r.reason).toBe('200e 2d 31 2c 32 33 34');
  });
});
