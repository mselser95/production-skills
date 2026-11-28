// @ds-scope/format: ALL display formatting goes through this package. Every function is pure, takes its locale (and
// for instants its time zone) explicitly, and returns a FormatResult: `{ok: true, text}` or `{ok: false, reason}`.
// Show a result with `orPlaceholder(result)` ("\u2014" on failure). Decimal strings are never converted to a float: the
// digits are validated by a strict grammar, rounded and grouped by string arithmetic, and Intl is consulted only
// for the locale's symbols and patterns (on small safe integers). There is deliberately NO compact notation
// (formatCompact): nothing asks for it, and compact output rounds to significant digits, which hides digits.
export { PLACEHOLDER, MAX_INPUT_LENGTH, MAX_FRACTION_DIGITS, orPlaceholder } from './types.ts';
export type { FormatError, FormatResult, RoundingMode, SignDisplay } from './types.ts';
export { formatDecimal, formatNum } from './number.ts';
export type { DecimalOptions, FractionOptions, NumOptions } from './number.ts';
export { formatMoney } from './money.ts';
export type { MoneyOptions } from './money.ts';
export { formatPercent } from './percent.ts';
export { formatDate, formatCalendarDate } from './date.ts';
export type { CalendarDateOptions, DateOptions, DateStyle } from './date.ts';
