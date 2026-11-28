// provenance: candidate; ttl: 2027-06-30; subject: formatDecimal grammar, rounding, negative zero, locales, result type; pinning: true
import { describe, expect, it } from 'vitest';
import { MAX_INPUT_LENGTH, PLACEHOLDER, formatDecimal, orPlaceholder } from '../src/index.ts';
import type { DecimalOptions, FormatError, FormatResult } from '../src/index.ts';

const text = (r: FormatResult): string => (r.ok ? r.text : 'ERR:' + r.reason);
const fmt = (v: string, o: Partial<DecimalOptions> & { locale?: string } = {}): string => text(formatDecimal(v, { locale: 'en-US', ...o }));

describe('rounding, carry and the three modes (en-US)', () => {
  const two = { minFractionDigits: 2, maxFractionDigits: 2 };
  it.each([
    ['9.995', '10.00'],
    ['9.994', '9.99'],
    ['0.005', '0.01'],
    ['0.004', '0.00'],
    ['999.9999', '1,000.00'],
    ['99999999999999999999999999.999', '100,000,000,000,000,000,000,000,000.00'],
    ['0.0049999999999999999999', '0.00'],
    ['0.0050000000000000000001', '0.01'],
    ['1', '1.00'],
    ['1.5', '1.50'],
  ])('half-up default %s -> %s', (v, want) => {
    expect(fmt(v, two)).toBe(want);
  });
  it('a carry through every digit grows the integer part', () => {
    expect(fmt('99.995', two)).toBe('100.00');
    expect(fmt('9', { maxFractionDigits: 0 })).toBe('9');
    expect(fmt('99.5', { maxFractionDigits: 0 })).toBe('100');
  });
  it.each([
    ['0.005', 'half-up', '0.01'],
    ['0.005', 'half-even', '0.00'],
    ['0.015', 'half-even', '0.02'],
    ['0.025', 'half-even', '0.02'],
    ['0.025', 'half-up', '0.03'],
    ['0.0250001', 'half-even', '0.03'],
    ['0.029', 'trunc', '0.02'],
    ['2.999', 'trunc', '2.99'],
  ] as const)('%s with %s -> %s', (v, rounding, want) => {
    expect(fmt(v, { ...two, rounding })).toBe(want);
  });
  it.each([
    ['2.5', 'half-up', '3'],
    ['2.5', 'half-even', '2'],
    ['3.5', 'half-even', '4'],
    ['0.5', 'half-even', '0'],
    ['1.5', 'half-even', '2'],
    ['-2.5', 'half-up', '-3'],
    ['-2.5', 'half-even', '-2'],
    ['-2.9', 'trunc', '-2'],
  ] as const)('to an integer: %s with %s -> %s', (v, rounding, want) => {
    expect(fmt(v, { maxFractionDigits: 0, rounding })).toBe(want);
  });
});

describe('negative zero: a value that rounds to zero carries no sign', () => {
  const two = { minFractionDigits: 2, maxFractionDigits: 2 };
  it.each([
    ['-0.004', '0.00'],
    ['-0', '0.00'],
    ['-0.00', '0.00'],
    ['-0.005', '-0.01'],
    ['-0.0049', '0.00'],
    ['-0.01', '-0.01'],
  ])('%s -> %s', (v, want) => expect(fmt(v, two)).toBe(want));
  it('half-even and trunc that reach zero drop the sign too', () => {
    expect(fmt('-0.005', { ...two, rounding: 'half-even' })).toBe('0.00');
    expect(fmt('-0.999', { maxFractionDigits: 0, rounding: 'trunc' })).toBe('0');
  });
  it('signDisplay always: plus for positive, nothing for zero, minus for negative', () => {
    const always = { signDisplay: 'always' } as const;
    expect(fmt('5', always)).toBe('+5');
    expect(fmt('0', always)).toBe('0');
    expect(fmt('0.0001', { ...always, maxFractionDigits: 2 })).toBe('0');
    expect(fmt('-0.0001', { ...always, maxFractionDigits: 2 })).toBe('0');
    expect(fmt('-5', always)).toBe('-5');
  });
});

describe('fraction digit defaults and bounds', () => {
  it('defaults are min 0 / max 3', () => {
    expect(fmt('1234.5678')).toBe('1,234.568');
    expect(fmt('1.2300')).toBe('1.23');
    expect(fmt('1.000')).toBe('1');
  });
  it('min alone raises max; max alone lowers min', () => {
    expect(fmt('1.5', { minFractionDigits: 2 })).toBe('1.50');
    expect(fmt('1.2345', { minFractionDigits: 5 })).toBe('1.23450');
    expect(fmt('1.2345', { maxFractionDigits: 1 })).toBe('1.2');
  });
  it('a 30-digit integer and 18 fraction digits survive exactly', () => {
    expect(fmt('123456789012345678901234567890.123456789012345678', { minFractionDigits: 18, maxFractionDigits: 18 })).toBe(
      '123,456,789,012,345,678,901,234,567,890.123456789012345678',
    );
  });
  it('grouping can be turned off', () => {
    expect(fmt('1234567.5', { grouping: false })).toBe('1234567.5');
  });
  it.each<[Partial<DecimalOptions>]>([
    [{ minFractionDigits: -1 }],
    [{ maxFractionDigits: 37 }],
    [{ maxFractionDigits: 1.5 }],
    [{ maxFractionDigits: Number.NaN }],
    [{ minFractionDigits: 3, maxFractionDigits: 2 }],
    [{ rounding: 'floor' as never }],
    [{ signDisplay: 'never' as never }],
  ])('bad options %j', (o) => expect(fmt('1', o)).toBe('ERR:bad-options'));
  it('a missing options object is bad-options, not a throw', () => {
    expect(text(formatDecimal('1', undefined as never))).toBe('ERR:bad-options');
    expect(text(formatDecimal('1', null as never))).toBe('ERR:bad-options');
  });
});

describe('grouping and symbols by locale; digits are always ASCII', () => {
  const big = '1234567.891';
  it.each([
    ['en-US', '1,234,567.891'],
    ['de-DE', '1.234.567,891'],
    ['fr-FR', '1\u202f234\u202f567,891'],
    ['en-IN', '12,34,567.891'],
    ['es-AR', '1.234.567,891'],
  ])('%s', (locale, want) => expect(fmt(big, { locale })).toBe(want));
  it('fr-FR groups with U+202F and the decimal mark is a comma (exact code points)', () => {
    const out = fmt('1234.5', { locale: 'fr-FR' });
    expect([...out].map((c) => c.codePointAt(0))).toEqual([0x31, 0x202f, 0x32, 0x33, 0x34, 0x2c, 0x35]);
  });
  it('en-IN: secondary groups of 2 (lakh, crore)', () => {
    expect(fmt('100000', { locale: 'en-IN' })).toBe('1,00,000');
    expect(fmt('123456789', { locale: 'en-IN' })).toBe('12,34,56,789');
    expect(fmt('999', { locale: 'en-IN' })).toBe('999');
    expect(fmt('1000', { locale: 'en-IN' })).toBe('1,000');
  });
  it('a locale whose minimum grouping is 2 does not group four digits (es-ES) but groups five', () => {
    expect(fmt('1234', { locale: 'es-ES' })).toBe('1234');
    expect(fmt('12345', { locale: 'es-ES' })).toBe('12.345');
  });
  it('es-AR groups four digits like Intl does', () => {
    expect(fmt('1234', { locale: 'es-AR' })).toBe(new Intl.NumberFormat('es-AR', { numberingSystem: 'latn' }).format(1234));
  });
  it('the locale minus sign is used (sv-SE: U+2212)', () => {
    expect(fmt('-5', { locale: 'sv-SE' })).toBe('\u22125');
    expect(fmt('-5', { locale: 'en-US' })).toBe('-5');
  });
  it.each(['ar-EG', 'ar-EG-u-nu-arab', 'en-US-u-nu-arab', 'fa-IR', 'hi-IN-u-nu-deva', 'bn-BD'])('%s still prints ASCII digits', (locale) => {
    const out = fmt('1234567.891', { locale });
    expect(out).not.toMatch(/^ERR/);
    for (const ch of out.match(/\p{Nd}/gu) ?? []) expect(ch).toMatch(/[0-9]/);
    expect(out.match(/[0-9]/g)?.join('')).toBe('1234567891');
  });
  it('agrees with Intl on values Intl can format exactly, for a spread of locales', () => {
    const locales = ['en-US', 'de-DE', 'fr-FR', 'en-IN', 'es-AR', 'es-ES', 'ja-JP', 'pt-BR', 'pt-PT', 'de-CH', 'sv-SE', 'ru-RU', 'pl-PL'];
    const values = ['0', '5', '-5', '999', '1000', '-1000', '12345', '123456', '1234567', '123456789', '12345.5', '-0.5', '1234.25'];
    for (const locale of locales) {
      const nf = new Intl.NumberFormat(locale, { numberingSystem: 'latn', maximumFractionDigits: 3 });
      for (const v of values) expect(fmt(v, { locale }), `${locale} ${v}`).toBe(nf.format(v as never));
    }
  });
  it.each(['', 'xx-invalid-tag-!!', 'en_US', 'tlh', ' en-US', 'e'.repeat(80)])('unsupported or malformed locale %j is bad-locale, never the ambient default', (locale) => {
    expect(fmt('1', { locale })).toBe('ERR:bad-locale');
  });
  it('a missing locale is bad-locale', () => {
    expect(text(formatDecimal('1', {} as never))).toBe('ERR:bad-locale');
  });
});

describe('invalid input is a typed error, never a guessed string', () => {
  const bad: [string, FormatError][] = [
    ['1e5', 'not-a-decimal'],
    ['1E5', 'not-a-decimal'],
    ['1e+5', 'not-a-decimal'],
    ['NaN', 'not-a-decimal'],
    ['Infinity', 'not-a-decimal'],
    ['-Infinity', 'not-a-decimal'],
    ['', 'empty'],
    [' 1', 'not-a-decimal'],
    ['1 ', 'not-a-decimal'],
    ['1\n', 'not-a-decimal'],
    ['\t1', 'not-a-decimal'],
    ['1.', 'not-a-decimal'],
    ['.5', 'not-a-decimal'],
    ['-.5', 'not-a-decimal'],
    ['0x10', 'not-a-decimal'],
    ['1,000', 'not-a-decimal'],
    ['1_000', 'not-a-decimal'],
    ['\u0661\u0662\u0663', 'not-a-decimal'],
    ['--1', 'not-a-decimal'],
    ['+1', 'not-a-decimal'],
    ['-', 'not-a-decimal'],
    ['01', 'not-a-decimal'],
    ['00', 'not-a-decimal'],
    ['1.2.3', 'not-a-decimal'],
    ['1.5\u00a0', 'not-a-decimal'],
    ['\uff11', 'not-a-decimal'],
  ];
  it.each(bad)('%j -> %s', (v, reason) => {
    expect(formatDecimal(v, { locale: 'en-US' })).toEqual({ ok: false, reason });
  });
  it('non-strings are refused, not coerced', () => {
    for (const v of [undefined, null, 1.5, 12, 10n, {}, ['1']]) {
      expect(formatDecimal(v as never, { locale: 'en-US' })).toEqual({ ok: false, reason: 'not-a-decimal' });
    }
  });
  it('a 10 000 digit string is too-long and answers fast; the limit is exact', () => {
    const t0 = performance.now();
    expect(formatDecimal('9'.repeat(10_000), { locale: 'en-US' })).toEqual({ ok: false, reason: 'too-long' });
    expect(formatDecimal('9'.repeat(10_000) + '.' + '9'.repeat(10_000), { locale: 'en-US' })).toEqual({ ok: false, reason: 'too-long' });
    expect(performance.now() - t0).toBeLessThan(250);
    expect(MAX_INPUT_LENGTH).toBe(128);
    expect(formatDecimal('1'.repeat(MAX_INPUT_LENGTH), { locale: 'en-US' }).ok).toBe(true);
    expect(formatDecimal('1'.repeat(MAX_INPUT_LENGTH + 1), { locale: 'en-US' })).toEqual({ ok: false, reason: 'too-long' });
  });
  it('the check order is options, locale, value', () => {
    expect(formatDecimal('x', { locale: 'zz-nope', maxFractionDigits: -1 })).toEqual({ ok: false, reason: 'bad-options' });
    expect(formatDecimal('x', { locale: 'tlh' })).toEqual({ ok: false, reason: 'bad-locale' });
  });
});

describe('orPlaceholder: the only way to turn a result into screen text', () => {
  it('ok gives the text, failure the placeholder, never blank', () => {
    expect(orPlaceholder(formatDecimal('1234.5', { locale: 'en-US' }))).toBe('1,234.5');
    expect(orPlaceholder(formatDecimal('1e5', { locale: 'en-US' }))).toBe(PLACEHOLDER);
    expect(PLACEHOLDER).toBe('\u2014');
    expect(orPlaceholder({ ok: false, reason: 'empty' }, 'n/a')).toBe('n/a');
  });
  it('a failed result has no text property to display by accident', () => {
    const r = formatDecimal('NaN', { locale: 'en-US' });
    expect('text' in r).toBe(false);
  });
});
