// provenance: candidate; ttl: 2027-06-30; subject: no exported function throws at render time, whatever JS value any parameter holds
import { describe, expect, it } from 'vitest';
import { formatCalendarDate, formatDate, formatDecimal, formatMoney, formatNum, formatPercent, orPlaceholder, PLACEHOLDER } from '../src/index.ts';

const hostile = (what: string): never => {
  throw new Error('hostile ' + what);
};
const revoked = (() => {
  const r = Proxy.revocable({}, {});
  r.revoke();
  return r.proxy;
})();
/** Junk of every JS type (the value of ONE parameter at a time). */
const JUNK: readonly unknown[] = [
  undefined, null, true, false, 0, -0, 1, -1, 1.5, Number.NaN, Infinity, -Infinity, 2 ** 53, Number.MAX_VALUE, 10n, -(10n ** 40n),
  '', ' ', 'x', '1', '-1', '1.5', '1e5', 'en-US', 'USD', 'UTC', '2024-01-01', '2024-01-01T00:00:00Z', '9'.repeat(500), '\u0000', '\ud800',
  Symbol('s'), [], [1], ['en-US'], {}, { ok: true }, { ok: true, text: 1 }, { ok: false }, { ok: true, text: 'x' }, () => 1, class A {}, new Date(), new Date(Number.NaN),
  new Map(), /x/, Object.create(null), new Proxy({}, { get: () => hostile('get') }), revoked,
  { toString: () => hostile('toString') }, { valueOf: () => hostile('valueOf') }, { [Symbol.toPrimitive]: () => hostile('toPrimitive') },
  { get ok(): boolean { return hostile('ok'); } }, { ok: true, get text(): string { return hostile('text'); } },
];
const OPTION_KEYS = ['locale', 'timeZone', 'dateStyle', 'timeStyle', 'minFractionDigits', 'maxFractionDigits', 'rounding', 'signDisplay', 'grouping', 'currencyDisplay'];
const GOOD: Record<string, unknown> = { locale: 'en-US', timeZone: 'UTC', dateStyle: 'medium', timeStyle: 'medium', minFractionDigits: 0, maxFractionDigits: 2, rounding: 'half-up', signDisplay: 'auto', grouping: true, currencyDisplay: 'symbol' };
/** Option objects: every junk value as the object, every key set to every junk value, every key a throwing getter. */
function optionVariants(): unknown[] {
  const out: unknown[] = [...JUNK];
  for (const k of OPTION_KEYS) {
    for (const j of JUNK) out.push({ ...GOOD, [k]: j });
    out.push(Object.defineProperty({ ...GOOD }, k, { get: () => hostile('option ' + k), enumerable: true }));
  }
  out.push(new Proxy({ ...GOOD }, { get: () => hostile('proxy get') }), new Proxy({ ...GOOD }, { has: () => hostile('has'), ownKeys: () => hostile('ownKeys') }), revoked);
  return out;
}
const OPTS = optionVariants();

type Fn = (...a: unknown[]) => unknown;
interface Target { name: string; fn: Fn; good: unknown[] }
const TARGETS: Target[] = [
  { name: 'formatDecimal', fn: formatDecimal as Fn, good: ['1234.5', GOOD] },
  { name: 'formatNum', fn: formatNum as Fn, good: ['1234', GOOD] },
  { name: 'formatPercent', fn: formatPercent as Fn, good: ['0.1234', GOOD] },
  { name: 'formatMoney', fn: formatMoney as Fn, good: ['1234.5', 'USD', GOOD] },
  { name: 'formatDate', fn: formatDate as Fn, good: ['2024-01-01T00:00:00Z', GOOD] },
  { name: 'formatCalendarDate', fn: formatCalendarDate as Fn, good: ['2024-01-01', GOOD] },
];

describe('nothing here throws at render time', () => {
  const stats: Record<string, number> = {};
  it.each(TARGETS)('$name returns a FormatResult for junk in EVERY parameter, options included', ({ name, fn, good }) => {
    let calls = 0;
    const bad: string[] = [];
    for (let p = 0; p < good.length; p++) {
      const isOptions = p === good.length - 1;
      for (const j of isOptions ? OPTS : JUNK) {
        const args = good.slice();
        args[p] = j;
        calls++;
        try {
          const r = fn(...args) as { ok?: unknown; text?: unknown; reason?: unknown };
          const shaped = typeof r === 'object' && r !== null && ((r.ok === true && typeof r.text === 'string') || (r.ok === false && typeof r.reason === 'string'));
          if (!shaped) bad.push(`param ${p}: not a FormatResult`);
        } catch (e) {
          bad.push(`param ${p}: threw ${String(e).slice(0, 60)}`);
        }
      }
    }
    stats[name] = calls;
    expect(bad.slice(0, 5), `${name}: ${bad.length} failures in ${calls} calls`).toEqual([]);
    expect(calls).toBeGreaterThan(JUNK.length * good.length);
  });

  it('orPlaceholder: junk for the result and for the placeholder never throws and always returns a string', () => {
    let calls = 0;
    for (const r of JUNK) {
      for (const ph of [...JUNK, PLACEHOLDER]) {
        calls++;
        const out = orPlaceholder(r as never, ph as never);
        expect(typeof out).toBe('string');
      }
    }
    expect(calls).toBeGreaterThan(2000);
  });
  it('orPlaceholder: only {ok:true, text:string} shows text; a non-string placeholder falls back to the dash', () => {
    expect(orPlaceholder(null as never)).toBe(PLACEHOLDER);
    expect(orPlaceholder(undefined as never)).toBe(PLACEHOLDER);
    expect(orPlaceholder({ ok: true, text: 7 } as never)).toBe(PLACEHOLDER);
    expect(orPlaceholder({ ok: true, text: '1' })).toBe('1');
    expect(orPlaceholder({ ok: false, reason: 'empty' })).toBe(PLACEHOLDER);
    expect(orPlaceholder({ ok: false, reason: 'empty' }, 'n/a')).toBe('n/a');
    expect(orPlaceholder({ ok: false, reason: 'empty' }, 5 as never)).toBe(PLACEHOLDER);
  });

  describe('an options object that cannot be read is bad-options (each key is read once, inside a try)', () => {
    const throwing = new Proxy({}, { get: () => hostile('get') });
    const getter = Object.defineProperty({ timeZone: 'UTC' }, 'locale', { get: () => hostile('getter'), enumerable: true });
    const cases: [string, Fn, unknown[]][] = [
      ['formatDecimal', formatDecimal as Fn, ['1']],
      ['formatNum', formatNum as Fn, ['1']],
      ['formatPercent', formatPercent as Fn, ['0.1']],
      ['formatMoney', formatMoney as Fn, ['1', 'USD']],
      ['formatDate', formatDate as Fn, ['2024-01-01T00:00:00Z']],
      ['formatCalendarDate', formatCalendarDate as Fn, ['2024-01-01']],
    ];
    it.each(cases)('%s: a throwing Proxy, a throwing getter, a revoked Proxy and an array', (name, fn, lead) => {
      for (const o of [throwing, revoked, [], getter]) {
        expect(fn(...lead, o), name).toEqual({ ok: false, reason: 'bad-options' });
      }
    });
  });
});
