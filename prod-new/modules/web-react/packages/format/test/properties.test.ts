// provenance: candidate; ttl: 2027-06-30; subject: formatDecimal / formatPercent properties against an independent BigInt oracle
import fc from 'fast-check';
import { describe, expect, it } from 'vitest';
import { formatDecimal, formatPercent } from '../src/index.ts';
import type { RoundingMode } from '../src/index.ts';

// Fixed seed, fixed run count: a failure is reproducible and the suite stays well under a few seconds.
const SEED = 20261128;
const RUNS = 800;
const cfg = { seed: SEED, numRuns: RUNS };

interface Loc {
  readonly tag: string;
  readonly group: string;
  readonly dec: string;
  readonly primary: number;
  readonly secondary: number;
  readonly pct: string; // text between the digits and the end, for a positive percent
}
// Hard-coded from the CLDR patterns, NOT learned from Intl, so the oracle shares nothing with the implementation.
const LOCS: readonly Loc[] = [
  { tag: 'en-US', group: ',', dec: '.', primary: 3, secondary: 3, pct: '%' },
  { tag: 'en-IN', group: ',', dec: '.', primary: 3, secondary: 2, pct: '%' },
  { tag: 'de-DE', group: '.', dec: ',', primary: 3, secondary: 3, pct: '\u00a0%' },
  { tag: 'fr-FR', group: '\u202f', dec: ',', primary: 3, secondary: 3, pct: '\u00a0%' },
];
const US = LOCS[0] as Loc;

// ---- generators: up to 30 integer digits and 18 fraction digits, biased towards ties and carries
const digit = fc.oneof(fc.integer({ min: 0, max: 9 }), fc.constantFrom(0, 5, 9));
const decimal = fc
  .record({
    neg: fc.boolean(),
    int: fc.array(digit, { minLength: 1, maxLength: 30 }),
    frac: fc.array(digit, { minLength: 0, maxLength: 18 }),
  })
  .map(({ neg, int, frac }) => (neg ? '-' : '') + BigInt(int.join('')).toString() + (frac.length > 0 ? '.' + frac.join('') : ''));
const mode = fc.constantFrom<RoundingMode>('half-up', 'half-even', 'trunc');
const digitsRange = fc.integer({ min: 0, max: 20 });
const opts = fc.record({ a: digitsRange, b: digitsRange, mode, loc: fc.constantFrom(...LOCS) }).map(({ a, b, mode: m, loc }) => ({ min: Math.min(a, b), max: Math.max(a, b), mode: m, loc }));
const scale = (s: string): number => s.split('.')[1]?.length ?? 0;

// ---- the oracle: scale to an integer, round with BigInt, lay out by hand
function oracle(input: string, min: number, max: number, m: RoundingMode, loc: Loc): string {
  const neg = input.startsWith('-');
  const [ip = '', fp = ''] = input.replace('-', '').split('.');
  let n = BigInt(ip + fp);
  let sc = fp.length;
  if (sc > max) {
    const div = 10n ** BigInt(sc - max);
    let q = n / div;
    const twice = 2n * (n % div);
    const up = m === 'trunc' ? false : twice > div || (twice === div && (m === 'half-up' || q % 2n === 1n));
    if (up) q += 1n;
    n = q;
    sc = max;
  }
  const s = n.toString().padStart(sc + 1, '0');
  let int = s.slice(0, s.length - sc);
  let frac = s.slice(s.length - sc);
  while (frac.length > min && frac.endsWith('0')) frac = frac.slice(0, -1);
  while (frac.length < min) frac += '0';
  const groups: string[] = [];
  let size = loc.primary;
  while (int.length > size) {
    groups.unshift(int.slice(-size));
    int = int.slice(0, -size);
    size = loc.secondary;
  }
  groups.unshift(int);
  const body = groups.join(loc.group) + (frac.length > 0 ? loc.dec + frac : '');
  return (neg && n !== 0n ? '-' : '') + body;
}

const run = (v: string, o: { min: number; max: number; mode: RoundingMode; loc: Loc }): string => {
  const r = formatDecimal(v, { locale: o.loc.tag, minFractionDigits: o.min, maxFractionDigits: o.max, rounding: o.mode });
  if (!r.ok) throw new Error('unexpected ' + r.reason + ' for ' + v);
  return r.text;
};
/** Back to an ASCII decimal string in the en-US shape. */
const plain = (out: string, loc: Loc): string => out.split(loc.group).join('').replace(loc.dec, '.');

// ---- an independent comparison of two ASCII decimal strings
function cmp(a: string, b: string): number {
  const sa = a.startsWith('-') ? -1 : 1;
  const sb = b.startsWith('-') ? -1 : 1;
  const [ai = '', af = ''] = a.replace('-', '').split('.');
  const [bi = '', bf = ''] = b.replace('-', '').split('.');
  const w = Math.max(af.length, bf.length);
  const ma = ai + af.padEnd(w, '0');
  const mb = bi + bf.padEnd(w, '0');
  const zeroA = /^0*$/.test(ma);
  const zeroB = /^0*$/.test(mb);
  const effA = zeroA ? 0 : sa;
  const effB = zeroB ? 0 : sb;
  if (effA !== effB) return effA < effB ? -1 : 1;
  const mag = ma.length !== mb.length ? (ma.length < mb.length ? -1 : 1) : ma < mb ? -1 : ma > mb ? 1 : 0;
  return effA < 0 ? -mag : mag;
}
const asBig = (s: string, w: number): bigint => {
  const [i = '', f = ''] = s.replace('-', '').split('.');
  const v = BigInt(i + f.padEnd(w, '0'));
  return s.startsWith('-') ? -v : v;
};

describe('properties of formatDecimal', () => {
  it('the comparator itself is sound (control for the monotonicity property)', () => {
    expect(cmp('-1', '1')).toBe(-1);
    expect(cmp('1.5', '1.25')).toBe(1);
    expect(cmp('-1.5', '-1.25')).toBe(-1);
    expect(cmp('-0.00', '0')).toBe(0);
    expect(cmp('10', '9')).toBe(1);
  });

  it('1. no NaN, Infinity or exponent letter ever appears', () => {
    fc.assert(
      fc.property(decimal, opts, (v, o) => {
        expect(run(v, o)).not.toMatch(/NaN|Infinity|[eE]/);
      }),
      cfg,
    );
  });

  it('2. digits round-trip: with the input scale kept, stripping separators gives back the input (up to 30+18 digits)', () => {
    fc.assert(
      fc.property(decimal, fc.constantFrom(...LOCS), (v, loc) => {
        const out = run(v, { min: scale(v), max: scale(v), mode: 'half-up', loc });
        const want = /^-0(\.0*)?$/.test(v) ? v.slice(1) : v;
        expect(plain(out, loc)).toBe(want);
      }),
      cfg,
    );
  });

  it('3a. rounding is monotone: a <= b implies rounded(a) <= rounded(b)', () => {
    fc.assert(
      fc.property(decimal, decimal, opts, (x, y, o) => {
        const w = Math.max(scale(x), scale(y));
        const [a, b] = asBig(x, w) <= asBig(y, w) ? [x, y] : [y, x];
        expect(cmp(plain(run(a, o), o.loc), plain(run(b, o), o.loc))).toBeLessThanOrEqual(0);
      }),
      cfg,
    );
  });

  it('3b. rounding is idempotent', () => {
    fc.assert(
      fc.property(decimal, opts, (v, o) => {
        const once = run(v, o);
        expect(run(plain(once, o.loc), o)).toBe(once);
      }),
      cfg,
    );
  });

  it('4. the result equals an independent BigInt oracle (4 locales, 3 modes, random digit bounds)', () => {
    fc.assert(
      fc.property(decimal, opts, (v, o) => {
        expect(run(v, o)).toBe(oracle(v, o.min, o.max, o.mode, o.loc));
      }),
      cfg,
    );
  });

  it('4b. the oracle agrees with hand-checked ties (control: it is not the implementation echoed back)', () => {
    expect(oracle('0.125', 2, 2, 'half-up', US)).toBe('0.13');
    expect(oracle('0.125', 2, 2, 'half-even', US)).toBe('0.12');
    expect(oracle('0.135', 2, 2, 'half-even', US)).toBe('0.14');
    expect(oracle('-0.004', 2, 2, 'half-up', US)).toBe('0.00');
    expect(oracle('99999.995', 2, 2, 'half-up', US)).toBe('100,000.00');
  });

  it('5. sign symmetry: format(-x) is "-" + format(x), except that zero has no sign', () => {
    fc.assert(
      fc.property(decimal, opts, (v, o) => {
        const x = v.replace('-', '');
        const pos = run(x, o);
        const neg = run('-' + x, o);
        expect(neg).toBe(/[1-9]/.test(pos) ? '-' + pos : pos);
      }),
      cfg,
    );
  });

  it('6. formatPercent(x) equals the decimal shifted two places, formatted, plus the percent pattern', () => {
    fc.assert(
      fc.property(decimal, opts, (v, o) => {
        const neg = v.startsWith('-');
        const [ip = '', fp = ''] = v.replace('-', '').split('.');
        const digits = fp.length < 2 ? ip + fp + '0'.repeat(2 - fp.length) : ip + fp;
        const sc = Math.max(fp.length - 2, 0);
        const s = BigInt(digits).toString().padStart(sc + 1, '0');
        const shifted = (neg ? '-' : '') + s.slice(0, s.length - sc) + (sc > 0 ? '.' + s.slice(s.length - sc) : '');
        const want = oracle(shifted, o.min, o.max, o.mode, o.loc);
        const r = formatPercent(v, { locale: o.loc.tag, minFractionDigits: o.min, maxFractionDigits: o.max, rounding: o.mode });
        expect(r.ok && r.text).toBe(want.startsWith('-') ? '-' + want.slice(1) + o.loc.pct : want + o.loc.pct);
      }),
      cfg,
    );
  });
});
