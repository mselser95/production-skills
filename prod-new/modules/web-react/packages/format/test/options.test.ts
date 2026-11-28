// provenance: candidate; ttl: 2027-06-30; subject: every option is read exactly once; an unknown option key is bad-options; formatNum without options is bad-options
import { describe, expect, it } from 'vitest';
import { formatCalendarDate, formatDate, formatDecimal, formatMoney, formatNum, formatPercent } from '../src/index.ts';

type Fn = (...a: unknown[]) => unknown;
interface Target {
  readonly name: string;
  readonly fn: Fn;
  readonly lead: unknown[];
  /** option -> [first read, second read]: both valid, and different, so a second read changes the output. */
  readonly keys: Record<string, [unknown, unknown]>;
}
const TARGETS: Target[] = [
  { name: 'formatDecimal', fn: formatDecimal as Fn, lead: ['1234.5678'], keys: { locale: ['de-DE', 'en-US'], minFractionDigits: [1, 0], maxFractionDigits: [2, 3], rounding: ['trunc', 'half-up'], signDisplay: ['always', 'auto'], grouping: [false, true] } },
  { name: 'formatNum', fn: formatNum as Fn, lead: ['1234567'], keys: { locale: ['de-DE', 'en-US'], signDisplay: ['always', 'auto'], grouping: [false, true] } },
  { name: 'formatPercent', fn: formatPercent as Fn, lead: ['0.12345'], keys: { locale: ['de-DE', 'en-US'], minFractionDigits: [1, 0], maxFractionDigits: [3, 2], rounding: ['trunc', 'half-up'], signDisplay: ['always', 'auto'] } },
  { name: 'formatMoney', fn: formatMoney as Fn, lead: ['1234.5', 'USD'], keys: { locale: ['de-DE', 'en-US'], rounding: ['trunc', 'half-up'], signDisplay: ['always', 'auto'], currencyDisplay: ['code', 'symbol'] } },
  { name: 'formatDate', fn: formatDate as Fn, lead: ['2026-11-27T12:34:56Z'], keys: { locale: ['de-DE', 'en-US'], timeZone: ['Asia/Kolkata', 'UTC'], dateStyle: ['short', 'full'], timeStyle: ['short', 'full'] } },
  { name: 'formatCalendarDate', fn: formatCalendarDate as Fn, lead: ['2026-11-27'], keys: { locale: ['de-DE', 'en-US'], dateStyle: ['short', 'full'] } },
];

describe('each option is read exactly once (README: "each option is read once, inside a try")', () => {
  it.each(TARGETS)('$name: reads every option once and the output follows the FIRST read', ({ fn, lead, keys }) => {
    const reads: Record<string, number> = {};
    const counting: Record<string, unknown> = {};
    const firstOnly: Record<string, unknown> = {};
    for (const [k, [first, second]] of Object.entries(keys)) {
      reads[k] = 0;
      firstOnly[k] = first;
      Object.defineProperty(counting, k, { enumerable: true, get: () => (++reads[k]! === 1 ? first : second) });
    }
    const got = fn(...lead, counting);
    expect(reads, 'reads per option').toEqual(Object.fromEntries(Object.keys(keys).map((k) => [k, 1])));
    expect(got).toEqual(fn(...lead, firstOnly));
    expect((got as { ok: boolean }).ok, 'the first values are a valid call').toBe(true);
    // control: the SECOND values really give another answer, so a second read would be visible
    const secondOnly = Object.fromEntries(Object.entries(keys).map(([k, [, s]]) => [k, s]));
    expect(fn(...lead, secondOnly)).not.toEqual(got);
  });
});

describe('an unknown option key is bad-options, never ignored', () => {
  const bad = { ok: false, reason: 'bad-options' };
  it.each(TARGETS)('$name: a typo or a foreign key fails; every known key alone is fine', ({ fn, lead, keys }) => {
    const good = Object.fromEntries(Object.entries(keys).map(([k, [f]]) => [k, f]));
    expect((fn(...lead, good) as { ok: boolean }).ok).toBe(true);
    for (const typo of ['maximumFractionDigits', 'maxFractionDigit', 'Locale', 'locales', 'style', 'currency', 'timezone', 'extra']) {
      expect(fn(...lead, { ...good, [typo]: 1 }), typo).toEqual(bad);
    }
    expect(fn(...lead, { ...good, nothing: undefined }), 'a typo key with value undefined').toEqual(bad);
    for (const k of Object.keys(keys)) {
      const without = { ...good };
      delete without[k];
      expect(fn(...lead, { ...without, [k + 's']: good[k] }), k + 's').toEqual(bad);
    }
  });
  it('a key that belongs to another formatter is unknown here', () => {
    expect(formatDecimal('1', { locale: 'en-US', timeZone: 'UTC' } as never)).toEqual(bad);
    expect(formatMoney('1', 'USD', { locale: 'en-US', grouping: true } as never)).toEqual(bad);
    expect(formatNum(1, { locale: 'en-US', maxFractionDigits: 2 } as never)).toEqual(bad);
  });
});

describe('formatNum without an options object answers like the other formatters', () => {
  it('undefined and null options are bad-options; an object without a locale is bad-locale', () => {
    expect(formatNum(1, undefined as never)).toEqual({ ok: false, reason: 'bad-options' });
    expect(formatNum(1, null as never)).toEqual({ ok: false, reason: 'bad-options' });
    expect(formatNum(1, {} as never)).toEqual({ ok: false, reason: 'bad-locale' });
    for (const [fn, lead] of [[formatDecimal, ['1']], [formatPercent, ['0.1']], [formatMoney, ['1', 'USD']], [formatDate, ['2026-11-27T12:34:56Z']], [formatCalendarDate, ['2026-11-27']]] as [Fn, unknown[]][]) {
      expect(fn(...lead, undefined), fn.name).toEqual({ ok: false, reason: 'bad-options' });
    }
  });
});

describe('junk in every option of a call that carries ONLY the known keys still never throws', () => {
  // test/robust.test.ts sends a superset of keys, which a formatter now refuses early; this sweep keeps the deeper paths covered
  const JUNK: unknown[] = [undefined, null, true, 0, -1, 1.5, Number.NaN, 10n, '', 'x', 'en-US', [], {}, Symbol('s'), () => 1, new Date(Number.NaN), { toString: () => { throw new Error('boom'); } }];
  it.each(TARGETS)('$name', ({ fn, lead, keys }) => {
    const good = Object.fromEntries(Object.entries(keys).map(([k, [f]]) => [k, f]));
    let calls = 0;
    for (const k of Object.keys(keys)) {
      for (const j of JUNK) {
        calls++;
        const r = fn(...lead, { ...good, [k]: j }) as { ok?: unknown; text?: unknown; reason?: unknown };
        expect(typeof r === 'object' && r !== null && (r.ok === true ? typeof r.text === 'string' : typeof r.reason === 'string'), `${k}=${String(typeof j)}`).toBe(true);
      }
    }
    expect(calls).toBe(Object.keys(keys).length * JUNK.length);
  });
});
