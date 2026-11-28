// provenance: candidate; ttl: 2027-06-30; subject: a known option name is read only as an OWN property (enumerable or not); an inherited one is absent
import { describe, expect, it } from 'vitest';
import { formatDecimal, formatNum, formatPercent } from '../src/index.ts';

describe('options are a plain record: known names are read from own properties only', () => {
  it('an inherited maxFractionDigits is ignored (treated as absent)', () => {
    const proto = { maxFractionDigits: 0 };
    const inherited = Object.create(proto) as Record<string, unknown>;
    inherited.locale = 'en-US';
    expect(formatDecimal('1.2345', inherited as never)).toEqual({ ok: true, text: '1.235' });
    expect(formatDecimal('1.2345', { locale: 'en-US', maxFractionDigits: 0 })).toEqual({ ok: true, text: '1' }); // control: own is honoured
  });
  it('an inherited locale is ignored: the options have no locale', () => {
    const inherited = Object.create({ locale: 'en-US' }) as Record<string, unknown>;
    expect(formatNum(1, inherited as never)).toEqual({ ok: false, reason: 'bad-locale' });
  });
  it('an own NON-enumerable known key is honoured', () => {
    const o: Record<string, unknown> = { locale: 'en-US' };
    Object.defineProperty(o, 'maxFractionDigits', { value: 0, enumerable: false });
    expect(formatDecimal('1.2345', o as never)).toEqual({ ok: true, text: '1' });
  });
  it('Object.create(null) with own keys works, and a class instance with own fields works', () => {
    const o = Object.create(null) as Record<string, unknown>;
    o.locale = 'de-DE';
    o.maxFractionDigits = 1;
    expect(formatPercent('0.12345', o as never)).toEqual({ ok: true, text: '12,3\u00a0%' });
    class Opts { locale = 'en-US'; maxFractionDigits = 1; }
    expect(formatDecimal('1.2345', new Opts() as never)).toEqual({ ok: true, text: '1.2' });
  });
  it('own accessors are read exactly once (the read-once contract still holds)', () => {
    let reads = 0;
    const o = { locale: 'en-US', get maxFractionDigits() { return ++reads; } };
    formatDecimal('1.2345', o as never);
    expect(reads).toBe(1);
  });
});
