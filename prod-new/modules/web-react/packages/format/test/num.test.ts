// provenance: candidate; ttl: 2027-06-30; subject: formatNum counts: strings, bigint, safe-integer numbers; pinning: true
import { describe, expect, it } from 'vitest';
import { formatNum } from '../src/index.ts';
import type { FormatResult, NumOptions } from '../src/index.ts';

const text = (r: FormatResult): string => (r.ok ? r.text : 'ERR:' + r.reason);
const num = (v: string | bigint | number, o: Partial<NumOptions> = {}): string => text(formatNum(v, { locale: 'en-US', ...o }));

describe('formatNum', () => {
  it('accepts a safe integer number, a bigint and an integer string', () => {
    expect(num(1234567)).toBe('1,234,567');
    expect(num(-1000)).toBe('-1,000');
    expect(num(Number.MAX_SAFE_INTEGER)).toBe('9,007,199,254,740,991');
    expect(num(123456789012345678901234567890n)).toBe('123,456,789,012,345,678,901,234,567,890');
    expect(num('-1000')).toBe('-1,000');
    expect(num('0')).toBe('0');
  });
  it('negative zero as a number is zero without a sign', () => {
    expect(num(-0)).toBe('0');
    expect(num('-0')).toBe('0');
    expect(num(0n)).toBe('0');
  });
  it.each([1.5, Number.NaN, Infinity, -Infinity, 2 ** 53, Number.MAX_SAFE_INTEGER + 2, 1e21, 0.1])('number %s is not an integer', (v) => {
    expect(num(v)).toBe('ERR:not-an-integer');
  });
  it.each(['1.0', '1.5', '1e3', ' 1', '1,000', '+1', '01', '-', 'NaN', '\u0661'])('string %j is not an integer', (v) => {
    expect(num(v)).toBe('ERR:not-an-integer');
  });
  it('empty and over-long strings', () => {
    expect(num('')).toBe('ERR:empty');
    expect(num('9'.repeat(10_000))).toBe('ERR:too-long');
    expect(num(10n ** 200n)).toBe('ERR:too-long');
  });
  it('non-number types are refused', () => {
    expect(num(null as never)).toBe('ERR:not-an-integer');
    expect(num(undefined as never)).toBe('ERR:not-an-integer');
    expect(num(true as never)).toBe('ERR:not-an-integer');
  });
  it('locales and sign display', () => {
    expect(num(1234567, { locale: 'en-IN' })).toBe('12,34,567');
    expect(num(1234567, { locale: 'de-DE' })).toBe('1.234.567');
    expect(num(1234567, { locale: 'fr-FR' })).toBe('1\u202f234\u202f567');
    expect(num(5, { signDisplay: 'always' })).toBe('+5');
    expect(num(1234567, { grouping: false })).toBe('1234567');
    expect(num(1, { locale: 'tlh' })).toBe('ERR:bad-locale');
    expect(text(formatNum(1, undefined as never))).toBe('ERR:bad-options'); // missing options object: the same answer as the other five formatters
    expect(text(formatNum(1, {} as never))).toBe('ERR:bad-locale'); // an options object without a locale
    expect(num(1, { signDisplay: 'x' as never })).toBe('ERR:bad-options');
  });
});
