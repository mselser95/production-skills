// provenance: candidate; ttl: 2027-06-30; subject: minimum grouping 3 (group only from six digits, the `ee` locales) for decimal, percent and money; pinning: true
import { describe, expect, it } from 'vitest';
import { formatDecimal, formatMoney, formatPercent } from '../src/index.ts';
import type { FormatResult } from '../src/index.ts';

const text = (r: FormatResult): string => (r.ok ? r.text : 'ERR:' + r.reason);
const latn = { numberingSystem: 'latn', roundingMode: 'halfExpand' } as const;

// `ee` groups an integer part only from SIX digits (CLDR minimumGroupingDigits 3): 12345 stays whole, 123,456 is grouped.
describe('minimum grouping 3 (the ee locales)', () => {
  it.each(['ee-GH', 'ee'])('%s decimal, percent and money at 4, 5 and 6 displayed digits: pinned, and equal to Intl', (locale) => {
    const dec = new Intl.NumberFormat(locale, { ...latn, minimumFractionDigits: 0, maximumFractionDigits: 2 });
    const pct = new Intl.NumberFormat(locale, { ...latn, style: 'percent', minimumFractionDigits: 0, maximumFractionDigits: 2 });
    const mon = new Intl.NumberFormat(locale, { ...latn, style: 'currency', currency: 'USD' });
    for (const v of ['1234', '12345', '123456', '-123456', '1234567.5']) {
      expect(text(formatDecimal(v, { locale })), `decimal ${v}`).toBe(dec.format(v as never));
      expect(text(formatMoney(v, 'USD', { locale })), `money ${v}`).toBe(mon.format(v as never));
    }
    for (const r of ['12.34', '123.45', '1234.56', '-1234.56']) {
      expect(text(formatPercent(r, { locale })), `percent ${r}`).toBe(pct.format(r as never));
    }
    // the pins: no group separator at 4 and 5 digits, one at 6
    expect(text(formatDecimal('12345', { locale }))).not.toMatch(/[,.   ]/);
    expect(text(formatDecimal('123456', { locale }))).toBe('123,456');
    expect(text(formatPercent('123.45', { locale }))).not.toMatch(/\d[,.   ]\d/);
    expect(text(formatPercent('1234.56', { locale }))).toMatch(/^123,456%/);
  });
});
