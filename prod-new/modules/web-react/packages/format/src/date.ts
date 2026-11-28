import { isSupportedLocale } from './locale.ts';
import { MAX_INPUT_LENGTH, failWith, okText, readOptions } from './types.ts';
import type { FormatResult } from './types.ts';

export type DateStyle = 'short' | 'medium' | 'long' | 'full';

export interface DateOptions {
  /** BCP 47 tag, REQUIRED. */
  readonly locale: string;
  /** IANA zone name, REQUIRED ("UTC", "America/Argentina/Buenos_Aires"): the ambient zone is never used. */
  readonly timeZone: string;
  /** Default `medium`; `none` leaves the date out. */
  readonly dateStyle?: DateStyle | 'none';
  /** Default `medium`; `none` leaves the time out. At least one of the two must be shown. */
  readonly timeStyle?: DateStyle | 'none';
}

export interface CalendarDateOptions {
  readonly locale: string;
  /** Default `medium`. */
  readonly dateStyle?: DateStyle;
}

// RFC 3339 date-time with a REQUIRED offset: upper-case T, whole seconds required, optional fraction of 1..9 digits,
// "Z" or +hh:mm / -hh:mm. No lower-case t/z, no space separator, no leap second (":60"), no date-time without an
// offset (which would have to be read in a local time zone).
const INSTANT = /^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?(Z|[+-][0-9]{2}:[0-9]{2})$/;
const CALENDAR = /^([0-9]{4})-([0-9]{2})-([0-9]{2})$/;
const STYLES: readonly string[] = ['short', 'medium', 'long', 'full'];

/** A run of ASCII digits as an integer, without Number() or parseInt(). */
function digits(s: string | undefined): number {
  let n = 0;
  for (let i = 0; i < (s ?? '').length; i++) n = n * 10 + ((s ?? '').charCodeAt(i) - 48);
  return n;
}

function daysInMonth(year: number, month: number): number {
  if (month === 2) return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28;
  return month === 4 || month === 6 || month === 9 || month === 11 ? 30 : 31;
}

/** The UTC date of a validated calendar day, built without any local-time constructor. */
function utcDay(y: number, m: number, d: number): Date {
  const t = new Date(0);
  t.setUTCFullYear(y, m - 1, d);
  return t;
}

const validDay = (y: number, m: number, d: number): boolean => y >= 1 && m >= 1 && m <= 12 && d >= 1 && d <= daysInMonth(y, m);

const cache = new Map<string, Intl.DateTimeFormat>();
function formatter(key: string, locale: string, o: Intl.DateTimeFormatOptions): Intl.DateTimeFormat {
  const hit = cache.get(key);
  if (hit !== undefined) return hit;
  const made = new Intl.DateTimeFormat(locale, { ...o, numberingSystem: 'latn', calendar: 'gregory' });
  if (cache.size >= 64) cache.clear();
  cache.set(key, made);
  return made;
}

/**
 * Format an RFC 3339 instant (offset or Z REQUIRED, see the grammar above; years 0001..9999) in an EXPLICIT time zone
 * and locale. The result never depends on the machine's zone or locale. Fractions beyond milliseconds are dropped.
 * Invalid text is `bad-instant`; an unknown zone is `bad-time-zone`.
 */
export function formatDate(isoInstant: string, opts: DateOptions): FormatResult {
  const options = readOptions<DateOptions>(opts, ['locale', 'timeZone', 'dateStyle', 'timeStyle']);
  if (options === undefined) return failWith('bad-options');
  const dateStyle = options.dateStyle ?? 'medium';
  const timeStyle = options.timeStyle ?? 'medium';
  const dOk = dateStyle === 'none' || STYLES.includes(dateStyle);
  const tOk = timeStyle === 'none' || STYLES.includes(timeStyle);
  if (!dOk || !tOk || (dateStyle === 'none' && timeStyle === 'none')) return failWith('bad-options');
  if (!isSupportedLocale(options.locale)) return failWith('bad-locale');
  if (typeof options.timeZone !== 'string' || options.timeZone.length === 0) return failWith('bad-time-zone');
  if (typeof isoInstant !== 'string' || isoInstant.length === 0) return failWith('bad-instant');
  if (isoInstant.length > MAX_INPUT_LENGTH) return failWith('bad-instant');
  const m = INSTANT.exec(isoInstant);
  if (m === null) return failWith('bad-instant');
  const [y, mo, d, h, mi, s] = [digits(m[1]), digits(m[2]), digits(m[3]), digits(m[4]), digits(m[5]), digits(m[6])];
  const off = m[8] ?? 'Z';
  const offH = off === 'Z' ? 0 : digits(off.slice(1, 3));
  const offM = off === 'Z' ? 0 : digits(off.slice(4, 6));
  if (!validDay(y, mo, d) || h > 23 || mi > 59 || s > 59 || offH > 23 || offM > 59) return failWith('bad-instant');
  const ms = digits(((m[7] ?? '') + '000').slice(0, 3));
  const t = utcDay(y, mo, d);
  t.setUTCHours(h, mi, s, ms);
  const sign = off.startsWith('-') ? -1 : 1;
  const instant = new Date(t.getTime() - sign * (offH * 60 + offM) * 60000);
  if (Number.isNaN(instant.getTime())) return failWith('bad-instant');
  const o: Intl.DateTimeFormatOptions = { timeZone: options.timeZone };
  if (dateStyle !== 'none') o.dateStyle = dateStyle;
  if (timeStyle !== 'none') o.timeStyle = timeStyle;
  try {
    const f = formatter(`i|${options.locale}|${options.timeZone}|${dateStyle}|${timeStyle}`, options.locale, o);
    return okText(f.format(instant));
  } catch {
    return failWith('bad-time-zone');
  }
}

/**
 * Format a calendar date "YYYY-MM-DD" (a real day of the proleptic Gregorian calendar, years 0001..9999). The day is
 * built at UTC midnight and formatted in the zone "UTC", so no local-time Date is ever constructed and the day cannot
 * shift with the machine's zone.
 */
export function formatCalendarDate(ymd: string, opts: CalendarDateOptions): FormatResult {
  const options = readOptions<CalendarDateOptions>(opts, ['locale', 'dateStyle']);
  if (options === undefined) return failWith('bad-options');
  const dateStyle = options.dateStyle ?? 'medium';
  if (!STYLES.includes(dateStyle)) return failWith('bad-options');
  if (!isSupportedLocale(options.locale)) return failWith('bad-locale');
  const m = typeof ymd === 'string' && ymd.length <= MAX_INPUT_LENGTH ? CALENDAR.exec(ymd) : null;
  if (m === null) return failWith('bad-date');
  const [y, mo, d] = [digits(m[1]), digits(m[2]), digits(m[3])];
  if (!validDay(y, mo, d)) return failWith('bad-date');
  const f = formatter(`d|${options.locale}|${dateStyle}`, options.locale, { timeZone: 'UTC', dateStyle });
  return okText(f.format(utcDay(y, mo, d)));
}
