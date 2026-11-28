import type { RoundingMode } from './types.ts';

/** Unsigned digits: integer part and fraction part. */
export interface Magnitude {
  readonly int: string;
  readonly frac: string;
}

const ZERO = 48; // char code of "0"

/** `d` plus one, as a digit string; grows by one digit on all-nines. Pure string arithmetic. */
function increment(d: string): string {
  let i = d.length;
  while (i > 0 && d.charCodeAt(i - 1) === ZERO + 9) i--;
  if (i === 0) return '1' + '0'.repeat(d.length);
  return d.slice(0, i - 1) + String.fromCharCode(d.charCodeAt(i - 1) + 1) + '0'.repeat(d.length - i);
}

function hasNonZero(s: string, from: number): boolean {
  for (let i = from; i < s.length; i++) if (s.charCodeAt(i) !== ZERO) return true;
  return false;
}

function roundsUp(rest: string, lastKept: number, mode: RoundingMode): boolean {
  if (mode === 'trunc') return false;
  const first = rest.charCodeAt(0) - ZERO;
  if (first > 5) return true;
  if (first < 5) return false;
  if (hasNonZero(rest, 1)) return true;
  // exactly half
  return mode === 'half-up' ? true : lastKept % 2 === 1;
}

/** Round the magnitude to at most `maxFrac` fraction digits. The fraction of the result has exactly `maxFrac` digits
 * when rounding happened and the input's own digits otherwise. */
export function roundMagnitude(int: string, frac: string, maxFrac: number, mode: RoundingMode): Magnitude {
  if (frac.length <= maxFrac) return { int, frac };
  const kept = frac.slice(0, maxFrac);
  const rest = frac.slice(maxFrac);
  const lastKept = (maxFrac > 0 ? kept.charCodeAt(maxFrac - 1) : int.charCodeAt(int.length - 1)) - ZERO;
  if (!roundsUp(rest, lastKept, mode)) return { int, frac: kept };
  const bumped = increment(int + kept);
  const cut = bumped.length - maxFrac;
  return { int: bumped.slice(0, cut), frac: bumped.slice(cut) };
}

/** Pad the fraction with zeros up to `minFrac`, or drop trailing zeros down to `minFrac`. */
export function fitFraction(frac: string, minFrac: number): string {
  if (frac.length < minFrac) return frac + '0'.repeat(minFrac - frac.length);
  let end = frac.length;
  while (end > minFrac && frac.charCodeAt(end - 1) === ZERO) end--;
  return frac.slice(0, end);
}

export const isZero = (m: Magnitude): boolean => m.int === '0' && !hasNonZero(m.frac, 0);
