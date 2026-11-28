// Shared result and option types. A formatter returns a FormatResult: the text exists ONLY on the ok branch, so a
// caller cannot display an invalid value by forgetting a check; `orPlaceholder` is the one way to turn a result into
// a string for the screen, and it renders PLACEHOLDER for a failure, never a blank and never a guessed number.

/** What the UI shows for a value that failed to format ("unexpected data"); an em dash, never an empty string. */
export const PLACEHOLDER = '\u2014';

/** Longest accepted input string, in UTF-16 units. 30 integer digits + 18 fraction digits + sign + point is 50; the
 * limit leaves room and keeps every code path bounded (a 10 000 digit string is `too-long`, not a slow loop). */
export const MAX_INPUT_LENGTH = 128;

/** Most fraction digits a caller may ask for. */
export const MAX_FRACTION_DIGITS = 36;

export type FormatError =
  | 'empty'
  | 'too-long'
  | 'not-a-decimal'
  | 'not-an-integer'
  | 'bad-locale'
  | 'bad-options'
  | 'bad-currency'
  | 'bad-instant'
  | 'bad-date'
  | 'bad-time-zone';

export type FormatResult =
  | { readonly ok: true; readonly text: string }
  | { readonly ok: false; readonly reason: FormatError };

export const okText = (text: string): FormatResult => ({ ok: true, text });
export const failWith = (reason: FormatError): FormatResult => ({ ok: false, reason });

/** The string to put on the screen: the text when ok, else the placeholder. */
export function orPlaceholder(result: FormatResult, placeholder: string = PLACEHOLDER): string {
  return result.ok ? result.text : placeholder;
}

/** How a discarded digit string rounds. `half-up` = half away from zero (the Intl default, `halfExpand`);
 * `half-even` = ties to the even digit; `trunc` = toward zero. All three act on the magnitude. */
export type RoundingMode = 'half-up' | 'half-even' | 'trunc';

/** `auto`: a minus sign for a negative value that is non-zero after rounding. `always`: also a plus sign for a
 * positive one. Zero (after rounding) never carries a sign. */
export type SignDisplay = 'auto' | 'always';
