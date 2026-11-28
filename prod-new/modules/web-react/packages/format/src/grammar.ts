import { MAX_INPUT_LENGTH } from './types.ts';
import type { FormatError } from './types.ts';

/** A parsed decimal string: sign, integer digits (no leading zero except a lone "0"), fraction digits. */
export interface Decimal {
  readonly negative: boolean;
  readonly int: string;
  readonly frac: string;
}

export type Parsed = { readonly ok: true; readonly value: Decimal } | { readonly ok: false; readonly reason: FormatError };

// The whole grammar: an optional "-", an integer part with no leading zero, an optional "." followed by at least one
// digit. ASCII digits only. No "+", no exponent, no whitespace, no separators, no "NaN"/"Infinity", no ".5", no "1.".
const DECIMAL = /^(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?$/;
const INTEGER = /^(-?)(0|[1-9][0-9]*)$/;

function parseWith(rx: RegExp, s: unknown, notMatching: FormatError): Parsed {
  if (typeof s !== 'string') return { ok: false, reason: notMatching };
  if (s.length === 0) return { ok: false, reason: 'empty' };
  if (s.length > MAX_INPUT_LENGTH) return { ok: false, reason: 'too-long' };
  const m = rx.exec(s);
  if (m === null) return { ok: false, reason: notMatching };
  return { ok: true, value: { negative: m[1] === '-', int: m[2] ?? '0', frac: m[3] ?? '' } };
}

export const parseDecimal = (s: unknown): Parsed => parseWith(DECIMAL, s, 'not-a-decimal');
export const parseInteger = (s: unknown): Parsed => parseWith(INTEGER, s, 'not-an-integer');
