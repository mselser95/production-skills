# @ds-scope/format

All display formatting goes through this package. It is pure TypeScript with no runtime dependency, and it formats
wire values that travel as decimal STRINGS: the digits are validated by a strict grammar, rounded and grouped by string
arithmetic, never through `Number`, `parseFloat` or `toFixed`. `Intl` is asked only about the locale's symbols,
grouping sizes and sign / currency / percent patterns (on small safe integers), never to format the value itself.

```ts
formatDecimal(value: string, { locale, minFractionDigits?, maxFractionDigits?, rounding?, signDisplay?, grouping? })
formatMoney(amount: string, currency: string, { locale, rounding?, signDisplay?, currencyDisplay? })
formatPercent(ratio: string, { locale, minFractionDigits?, maxFractionDigits?, rounding?, signDisplay? })   // "0.1234" -> "12.34%"
formatNum(value: string | bigint | number, { locale, signDisplay?, grouping? })                             // counts (integers)
formatDate(isoInstant: string, { locale, timeZone, dateStyle?, timeStyle? })                                 // RFC 3339 with offset or Z
formatCalendarDate("YYYY-MM-DD", { locale, dateStyle? })
orPlaceholder(result, placeholder = "—"): string
// every formatter returns FormatResult = { ok: true, text } | { ok: false, reason }
```

Rules (each is pinned by a test):

- **Typed failure.** An invalid value is `{ ok: false, reason }`, never a throw, a blank or a guessed string. `text`
  exists only on the ok branch. The screen shows `orPlaceholder(result)` (an em dash): a bad value is visible.
- **Grammar.** `-?(0|[1-9][0-9]*)(\.[0-9]+)?`, ASCII digits, at most `MAX_INPUT_LENGTH` (128) characters. No exponent,
  no `+`, no `.5` / `1.`, no leading zeros, no whitespace, no separators, no `NaN` / `Infinity`.
- **Rounding.** Default `half-up` (half away from zero, the `Intl` default); `half-even` and `trunc` are selectable.
  Carries propagate (`9.995` -> `10.00`).
- **Negative zero.** A value that rounds to zero is shown without a sign (`-0.004` -> `0.00`, `-$0.00` never).
- **Digits.** Always ASCII (`numberingSystem: 'latn'`), whatever the locale tag asks for; separators, grouping sizes
  (en-IN `12,34,567`, es-ES waits for five digits) and the minus sign come from the locale.
- **No ambient state.** `locale` is required (an unsupported tag is `bad-locale`, it does not fall back to the machine's
  default); `formatDate` requires `timeZone`. Results are identical under any `TZ`.
- **Counts.** `formatNum` accepts an integer string, a bigint, or a number that is a safe integer.
- **Negative money** uses the locale's own minus pattern; there is no accounting-parentheses style.
- No compact notation: it rounds to significant digits, which hides digits.

Tests (`pnpm test`): unit tables per function, fast-check properties (fixed seed) against an independent BigInt oracle,
the TZ matrix, and `test/guard.test.ts`, which fails if `src/` calls `toFixed(`, `parseFloat(`, `Number(`, `Math.round(`,
`toLocaleString(` and the like. The app-wide rule (no ad-hoc formatting outside this package) is the web app's eslint
configuration. The dev dependency `fast-check` needs a line in the root `pnpm-workspace.yaml` catalog.
