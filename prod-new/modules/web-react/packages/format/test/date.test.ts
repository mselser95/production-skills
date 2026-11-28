// provenance: candidate; ttl: 2027-06-30; subject: formatDate / formatCalendarDate grammar, explicit zone, no ambient time zone; pinning: true
import { afterEach, describe, expect, it } from 'vitest';
import { formatCalendarDate, formatDate } from '../src/index.ts';
import type { CalendarDateOptions, DateOptions, FormatResult } from '../src/index.ts';

// ICU (since 72) puts U+202F before AM/PM; normalise it so the tables read the same on older ICU.
const text = (r: FormatResult): string => (r.ok ? r.text.replace(/\u202f/g, ' ') : 'ERR:' + r.reason);
const at = (v: string, o: Partial<DateOptions> = {}): string => text(formatDate(v, { locale: 'en-US', timeZone: 'UTC', ...o }));
const day = (v: string, o: Partial<CalendarDateOptions> = {}): string => text(formatCalendarDate(v, { locale: 'en-US', ...o }));

describe('formatDate', () => {
  it('formats an instant in the requested zone', () => {
    expect(at('2026-11-27T12:34:56Z')).toBe('Nov 27, 2026, 12:34:56 PM');
    expect(at('2026-11-27T12:34:56Z', { dateStyle: 'short', timeStyle: 'short' })).toBe('11/27/26, 12:34 PM');
    expect(at('2026-11-27T12:34:56Z', { locale: 'de-DE', timeZone: 'Asia/Kolkata' })).toBe('27.11.2026, 18:04:56');
    expect(at('2026-11-27T12:34:56Z', { locale: 'de-DE', timeZone: 'America/Argentina/Buenos_Aires' })).toBe('27.11.2026, 09:34:56');
  });
  it('an offset moves the instant, and the zone decides the wall clock', () => {
    expect(at('2026-11-27T23:30:00-03:00', { locale: 'de-DE' })).toBe('28.11.2026, 02:30:00');
    expect(at('2026-11-27T23:30:00-03:00', { locale: 'de-DE', timeZone: 'America/Argentina/Buenos_Aires' })).toBe('27.11.2026, 23:30:00');
    expect(at('2026-11-27T05:30:00+05:30', { locale: 'de-DE' })).toBe('27.11.2026, 00:00:00');
    expect(at('2026-11-27T12:00:00-00:00', { locale: 'de-DE' })).toBe('27.11.2026, 12:00:00');
  });
  it('date only / time only / fractions', () => {
    expect(at('2026-11-27T12:34:56Z', { timeStyle: 'none' })).toBe('Nov 27, 2026');
    expect(at('2026-11-27T12:34:56Z', { dateStyle: 'none' })).toBe('12:34:56 PM');
    expect(at('2026-11-27T12:34:56.789123456Z', { dateStyle: 'none' })).toBe('12:34:56 PM');
    expect(at('2026-11-27T12:34:56.7Z', { dateStyle: 'none' })).toBe('12:34:56 PM');
  });
  it('leap days and years', () => {
    expect(at('2000-02-29T00:00:00Z', { timeStyle: 'none' })).toBe('Feb 29, 2000');
    expect(at('2024-02-29T00:00:00Z', { timeStyle: 'none' })).toBe('Feb 29, 2024');
    expect(at('1500-03-01T00:00:00Z', { timeStyle: 'none' })).toBe('Mar 1, 1500');
    expect(at('0099-12-31T00:00:00Z', { timeStyle: 'none' })).toBe('Dec 31, 99');
    expect(at('9999-12-31T23:59:59Z', { timeStyle: 'none' })).toBe('Dec 31, 9999');
  });
  it.each([
    '2026-11-27T12:34:56',
    '2026-11-27',
    '2026-11-27 12:34:56Z',
    '2026-11-27t12:34:56z',
    '2026-11-27T12:34Z',
    '2026-02-30T00:00:00Z',
    '2100-02-29T00:00:00Z',
    '2026-13-01T00:00:00Z',
    '2026-00-10T00:00:00Z',
    '2026-11-00T00:00:00Z',
    '2026-11-27T24:00:00Z',
    '2026-11-27T12:60:00Z',
    '2026-11-27T12:00:60Z',
    '2026-11-27T12:00:00+24:00',
    '2026-11-27T12:00:00+05:60',
    '2026-11-27T12:00:00+0530',
    '2026-11-27T12:00:00+05',
    '2026-11-27T12:00:00.Z',
    '2026-11-27T12:00:00.1234567890Z',
    '0000-01-01T00:00:00Z',
    ' 2026-11-27T12:34:56Z',
    '2026-11-27T12:34:56Z ',
    '2026-11-27T12:34:56Z\n',
    '\u0662\u0660\u0662\u0666-11-27T12:34:56Z',
    '1795869296000',
    'NaN',
  ])('bad instant %j', (v) => expect(at(v)).toBe('ERR:bad-instant'));
  it('empty, over-long and non-string instants', () => {
    expect(at('')).toBe('ERR:bad-instant');
    expect(at('2026-11-27T12:34:56Z' + ' '.repeat(200))).toBe('ERR:bad-instant');
    expect(at(1795869296000 as never)).toBe('ERR:bad-instant');
    expect(at(new Date() as never)).toBe('ERR:bad-instant');
  });
  it('the time zone is required and checked', () => {
    expect(at('2026-11-27T12:34:56Z', { timeZone: 'Mars/Phobos' })).toBe('ERR:bad-time-zone');
    expect(at('2026-11-27T12:34:56Z', { timeZone: '' })).toBe('ERR:bad-time-zone');
    expect(text(formatDate('2026-11-27T12:34:56Z', { locale: 'en-US' } as never))).toBe('ERR:bad-time-zone');
  });
  it('locale and options are checked', () => {
    expect(at('2026-11-27T12:34:56Z', { locale: 'tlh' })).toBe('ERR:bad-locale');
    expect(at('2026-11-27T12:34:56Z', { dateStyle: 'none', timeStyle: 'none' })).toBe('ERR:bad-options');
    expect(at('2026-11-27T12:34:56Z', { dateStyle: 'weird' as never })).toBe('ERR:bad-options');
    expect(text(formatDate('2026-11-27T12:34:56Z', undefined as never))).toBe('ERR:bad-options');
  });
  it('digits are ASCII whatever the locale numbering', () => {
    expect(at('2026-11-27T12:34:56Z', { locale: 'ar-EG', dateStyle: 'short' })).toMatch(/^[^\p{Nd}]*[0-9]/u);
    expect((at('2026-11-27T12:34:56Z', { locale: 'ar-EG' }).match(/\p{Nd}/gu) ?? []).every((c) => /[0-9]/.test(c))).toBe(true);
  });
});

describe('formatCalendarDate', () => {
  it('formats a date-only value', () => {
    expect(day('2026-11-27')).toBe('Nov 27, 2026');
    expect(day('2026-11-27', { dateStyle: 'long' })).toBe('November 27, 2026');
    expect(day('2026-11-27', { dateStyle: 'full' })).toBe('Friday, November 27, 2026');
    expect(day('2026-11-27', { dateStyle: 'short' })).toBe('11/27/26');
    expect(day('2026-11-27', { locale: 'de-DE', dateStyle: 'long' })).toBe('27. November 2026');
    expect(day('2024-02-29')).toBe('Feb 29, 2024');
    expect(day('1500-03-01')).toBe('Mar 1, 1500');
  });
  it.each(['2023-02-29', '2026-11-31', '2026-13-01', '2026-00-01', '2026-1-1', '20261127', '2026-11-27T00:00:00Z', ' 2026-11-27', '2026-11-27 ', '0000-01-01', '', 'NaN'])('bad date %j', (v) => {
    expect(day(v)).toBe('ERR:bad-date');
  });
  it('locale and options are checked', () => {
    expect(day('2026-11-27', { locale: 'tlh' })).toBe('ERR:bad-locale');
    expect(day('2026-11-27', { dateStyle: 'none' as never })).toBe('ERR:bad-options');
    expect(text(formatCalendarDate('2026-11-27', undefined as never))).toBe('ERR:bad-options');
  });
});

// The ambient time zone must not matter. Node honours a runtime change of process.env.TZ; the control asserts the
// ambient zone really changed (otherwise the matrix would prove nothing).
describe('no ambient time zone: identical under TZ=UTC, America/Argentina/Buenos_Aires and Asia/Kolkata', () => {
  const saved = process.env['TZ'];
  afterEach(() => {
    if (saved === undefined) delete process.env['TZ'];
    else process.env['TZ'] = saved;
  });
  const zones: [string, number][] = [['UTC', 0], ['America/Argentina/Buenos_Aires', 180], ['Asia/Kolkata', -330]];
  const run = (): string[] => [
    at('2026-11-27T23:30:00-03:00'),
    at('2026-11-27T23:30:00Z', { timeZone: 'Asia/Tokyo' }),
    at('2026-01-01T00:00:00Z', { timeZone: 'America/Argentina/Buenos_Aires', locale: 'de-DE' }),
    at('2026-07-01T00:00:00Z', { timeStyle: 'full', locale: 'en-GB' }),
    day('2026-01-01'),
    day('2026-12-31', { dateStyle: 'full' }),
    day('2026-03-01'),
  ];
  it('the ambient zone really changes (control)', () => {
    const seen = zones.map(([z]) => {
      process.env['TZ'] = z;
      return new Date(2026, 0, 1).getTimezoneOffset();
    });
    expect(seen).toEqual(zones.map(([, off]) => off));
  });
  it('outputs do not depend on it', () => {
    const outputs = zones.map(([z]) => {
      process.env['TZ'] = z;
      return run();
    });
    expect(outputs[1]).toEqual(outputs[0]);
    expect(outputs[2]).toEqual(outputs[0]);
    expect(outputs[0]?.[0]).toBe('Nov 28, 2026, 2:30:00 AM');
    expect(outputs[0]?.[1]).toBe('Nov 28, 2026, 8:30:00 AM');
    expect(outputs[0]?.[2]).toBe('31.12.2025, 21:00:00');
    expect(outputs[0]?.[4]).toBe('Jan 1, 2026');
    expect(outputs[0]?.[5]).toBe('Thursday, December 31, 2026');
  });
});
