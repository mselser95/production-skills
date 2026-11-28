// provenance: candidate; ttl: 2027-06-30; subject: the README's instant grammar and unknown-region statements
import { describe, expect, it } from 'vitest';
import { formatDate, formatDecimal } from '../src/index.ts';

const inst = (s: string): string => {
  const r = formatDate(s, { locale: 'en-US', timeZone: 'UTC' });
  return r.ok ? r.text : 'ERR:' + r.reason;
};

describe('instants: accepted and rejected forms (README "Instants")', () => {
  it('fractional seconds are accepted, and -00:00 is the same instant as Z', () => {
    expect(inst('2024-01-01T00:00:00.345Z')).toBe(inst('2024-01-01T00:00:00Z'));
    expect(inst('2024-01-01T00:00:00-00:00')).toBe(inst('2024-01-01T00:00:00Z'));
    expect(inst('2024-01-01T00:00:00.123456789Z')).not.toMatch(/^ERR/);
  });
  it.each([
    '2024-01-01t00:00:00Z',
    '2024-01-01T00:00:00z',
    '2024-01-01 00:00:00Z',
    '2024-01-01T00:00:00.1234567890Z',
    '2024-01-01T00:00:00',
    '2024-12-31T23:59:60Z',
    '2024-01-01T00:00:00+24:00',
    '2024-01-01T00:00:00+00:60',
  ])('%s is bad-instant', (s) => expect(inst(s)).toBe('ERR:bad-instant'));
});

describe('a tag with an unknown region formats as its language, never as the ambient locale', () => {
  it('de-XX equals de-DE output for numbers', () => {
    const r = formatDecimal('1234.5', { locale: 'de-XX' });
    expect(r.ok ? r.text : r.reason).toBe('1.234,5');
  });
});
