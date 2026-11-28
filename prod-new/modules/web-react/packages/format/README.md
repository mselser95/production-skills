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
formatDate(isoInstant: string, { locale, timeZone, dateStyle?, timeStyle? })                                 // RFC 3339 with offset or Z (see Instants)
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
- **Digits.** Always ASCII (`numberingSystem: 'latn'`), whatever the locale tag asks for; separators and grouping sizes
  (en-IN `12,34,567`, es-ES waits for five digits) come from the locale.
- **Signs.** The sign prefix / suffix is every literal part Intl puts around the number for a negative (or `+`) sample,
  so it comes from the locale INCLUDING bidi control characters: `ar-EG`, `he-IL`, `ar-SA`, `ur-PK` print U+200E before
  the minus, `fa-IR` U+200E U+2212. Plain decimals, money and percent all equal `Intl` there.
- **Money separators are the currency style's own.** CLDR defines currency separators apart from plain-number ones in
  some locales (fr-CH money decimal `.`, de-AT money group `.`, en-CH money group `,`), so `formatMoney` learns group,
  decimal, grouping sizes and minimum grouping per (locale, currency, currencyDisplay) from `Intl`'s currency style on
  safe sample numbers. Percent was measured in 33 locales and equals `Intl` with the plain-number separators.
- **No ambient state.** `locale` is required (an unsupported tag is `bad-locale`, it does not fall back to the machine's
  default); `formatDate` requires `timeZone`. Results are identical under any `TZ`.
- **Never throws.** Every exported function returns a result (or a string) for a value of any JS type in any
  parameter. An options argument that is not a plain object (null, a primitive, an array) or cannot be read (a getter
  or Proxy that throws) is `bad-options`: each option is read once, inside a try. `orPlaceholder` shows text only for
  `{ ok: true, text: string }`; anything else (null included) is the placeholder, and a non-string placeholder
  argument falls back to the dash. `formatNum` with a missing options object is `bad-locale` (locale is required).
- **Counts.** `formatNum` accepts an integer string, a bigint, or a number that is a safe integer.
- **Negative money** uses the locale's own minus pattern; there is no accounting-parentheses style.
- **Instants.** `formatDate` accepts RFC 3339 `YYYY-MM-DDThh:mm:ss[.f{1,9}](Z|+hh:mm|-hh:mm)`; fractional seconds ARE
  accepted (digits beyond milliseconds are dropped). Rejected as `bad-instant`: lower-case `t` / `z`, a space
  separator, more than 9 fraction digits, a missing offset, a leap second (`:60`), an out-of-range field or an
  offset hour above 23 or minute above 59, years outside 0001..9999. `-00:00` is read as an ordinary offset of zero
  (the same instant as `Z`).
- **Unknown region.** A tag that is well formed but whose region is unknown (`de-XX`) is supported by the engine and
  formats as its language (best fit, here `de`), never as the ambient locale; a tag the engine does not support at all
  is `bad-locale`.
- No compact notation: it rounds to significant digits, which hides digits.

Tests (`pnpm test`): unit tables per function, fast-check properties (fixed seed) against an independent BigInt oracle,
the TZ matrix, Intl cross-checks (33 locales x 5 currencies x 3 displays for money, RTL locales for decimals), a
never-throws fuzz over every parameter, and `test/guard.test.ts`. The guard lexes `src/` (comments, strings, template
code and regex literals handled by state, no per-line escape marker) and flags `.toFixed` / `.toPrecision` /
`.toExponential` / `.toLocaleString` / `.toString`, `parseFloat(` / `parseInt(` / `Number(` / `String(`, `Math.*`,
unary `+` and non-literal unary `-`, `* / % **` (and compound forms) and float or 10-digit numeric literals. The
exemptions are an explicit allow-list in the test (`ALLOW`, with an exact expected length), so each one is a visible
diff. The hermetic repo selftest only runs a coarse grep with no exemption marker; this test is the real guard.

## Declared gaps

- There is no `module.json` for web-react yet, so this package is not registered as a module.
- The dev dependency `fast-check` needs a line in the root `pnpm-workspace.yaml` catalog (the monorepo-root module owns
  that file; the selftest injects the line in its scratch workspace only).
- The app-wide rule (no ad-hoc formatting, `toFixed` or `toLocaleString` outside this package) is the web app's lint
  configuration, which does not exist yet; this package guards only its own `src/`.
- Not validated: other ICU / CLDR data (the pinned strings are those of the ICU shipped with the node in the hand-back).
