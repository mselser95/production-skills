# @ds-scope/format

All display formatting goes through this package. It is pure TypeScript with no runtime dependency, and it formats
wire values that travel as decimal STRINGS: the digits are validated by a strict grammar, rounded and grouped by string
arithmetic, never through `Number`, `parseFloat` or `toFixed`. Number, money and percent values never reach `Intl`;
`Intl` formats only fixed sample numbers (to learn a locale's symbols, grouping sizes and sign / currency / percent
patterns) and `Date` instants, and is asked a currency's fraction digits (`resolvedOptions`). The guard test enforces
that sentence on `src/` (see Tests).

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
  safe sample numbers.
- **Percent symbols are the percent style's own.** CLDR's percent pattern groups by 3 where the decimal pattern groups
  Indian-style (`mr`, `ml`, `ne`, `or`, `te`: `mr-IN` 1234.5678 is `123,456.78%`, not `1,23,456.78%`). Group and decimal
  separators and grouping sizes are learned from `Intl`'s percent style; the MINIMUM grouping is learned from percent
  samples whose DISPLAYED integer part has exactly 4 digits and then 5 (the samples 10 and 100, shown as 1000% and
  10000%), because `be`, `bg`, `es`, `et`, `hu` print a four-digit percent ungrouped (`1234 %`). Money and plain
  decimals learn minimum grouping from samples whose displayed integer part has those two lengths, in their own style (1000, 10000).
- **No ambient state.** `locale` is required (an unsupported tag is `bad-locale`, it does not fall back to the machine's
  default); `formatDate` requires `timeZone`. Results are identical under any `TZ`.
- **Never throws.** Every exported function returns a result (or a string) for a value of any JS type in any
  parameter. An options argument that is not a plain object (null, a primitive, an array, or missing) or cannot be read
  (a getter or Proxy that throws) is `bad-options`: each option is read once, inside a try, and the output follows
  that first read. `orPlaceholder` shows text only for
  `{ ok: true, text: string }`; anything else (null included) is the placeholder, and a non-string placeholder
  argument falls back to the dash. An options object without `locale` is `bad-locale`.
- **Unknown option keys are refused.** A key the function does not know (a typo such as `maximumFractionDigits` for
  `maxFractionDigits`, or another formatter's key) is `bad-options`: an unknown OWN ENUMERABLE key is never silently
  ignored. Options are a plain record: a known name is read only when it is an OWN property (enumerable or not, so
  `Object.create(null)` works); an inherited (prototype) key is ignored as absent, and an inherited or non-enumerable
  UNKNOWN key is not checked (it has no effect). `formatNum(1, undefined)` is `bad-options` like the other
  five. A settings CLASS whose fields are prototype getters (`get locale()`) is therefore ignored and yields
  `bad-locale`: pass a plain object or own fields.
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
the TZ matrix, Intl cross-checks (money over the locales, currencies and displays listed in `test/money.test.ts`; percent over
the locales listed in `test/percent.test.ts` x displayed integer parts of 1 to 9 digits; RTL locales for decimals), a never-throws fuzz over every parameter, option
read-once, own-key and unknown-key tests, and `test/guard.test.ts`. The sizes of those lists are stated in ONE line, which
`test/readme.test.ts` regenerates from the lists and compares for equality:

Cross-check sizes: money 33 locales x 5 currencies x 3 displays; percent 65 locales.

Anywhere else in this file a digit sequence or a spelled-out number (one to twenty, the tens, hundred) within two words of
`locale`, `currenc`, `display` or `language` fails that test. It catches a number on either side of those stems in any letter case, hyphenated (`N-locale`) or after a colon;
it does not catch a count worded away from those stems (for example "the full set of N tags"), and it does not judge any
other number.

The guard walks every file under `src/` at any depth with a `.ts`, `.mts`, `.cts` or `.tsx` extension, refuses any import
that leaves `src/` or names a package (every `import`, `export ... from`, `import()`, `require()` and `/// <reference>`
specifier must be relative and stay inside `src/`; the allow-list of packages is empty), so no compiled code that formats a
value lies outside what it reads; `test/` is not scanned and cannot be imported from `src/`. It also refuses a JavaScript source or a symbolic link as a finding, asserts that the tsconfig builds only `src`
and `test`, and keys ALLOW entries on the path relative to `src/`. It lexes each file (comments, strings, template code
and regex literals handled by state, no per-line escape
marker). It flags: `.toFixed` / `.toPrecision` / `.toExponential` / `.toLocaleString` / `.toString` / `.valueOf`;
`parseFloat(` / `parseInt(` / `Number(` / `String(` / `isFinite(` / `isNaN(`; `Math.*`; unary `+` and non-literal unary
`-`; `* / % **` (and compound forms; a generator's `function*` is not one); bitwise `~ ^ & << >> >>>` (and compound
forms) and `|` next to a numeric literal; a binary `- 0`; float or 10-digit numeric literals; every `Intl` call,
construction or alias; and every `.format(` / `.formatToParts(` / `.formatRange(` / `.formatRangeToParts(` /
`.resolvedOptions(` member. Those five Intl method names are reserved identifiers in `src/`: the guard flags each as a
whole identifier wherever it occurs (a destructuring pattern, an object key or shorthand, a local, a parameter, an
interface member, a string that is exactly the name as in `nf['format']`), so a bound method can never be named and
called out of sight; `formatMoney` is another identifier, and a comment or a longer string is not a finding. A
`globalThis.` / `window.` / `self.` / `global.` prefix hides nothing. Number-style Intl
calls are allowed only in `locale.ts` (and `resolvedOptions` in `money.ts`) with a numeric literal argument; the date
calls only in `date.ts`. The exemptions are an explicit allow-list in the test (`ALLOW`, exact expected length), each
entry pinning its file, the finding and the full source LINE of its site, so each is a visible diff and swapping one use
for another fails.

What the guard does NOT flag, by design (it has no types): binary `+` / `-` in general, `++` / `--`, `|` between two
non-literals (the type-union token), other computed or string-built member names (`Math['round']`, `x['valueOf']()`, `'for' + 'mat'`; a literal key that is
exactly one of the five Intl names IS flagged), unicode-escaped identifiers, integer literals below ten digits, a
type-position `Intl.X`. The backstop for FLOAT paths is behavioural: the 30-digit round-trip properties and the BigInt
oracle fail as soon as a float is in the path (a float loses digits beyond 2^53). They cannot see a value sent to Intl
as a string (Intl reads strings exactly): for a value routed through Intl the guard is the check, with the rounding-mode
and negative-zero tests as a partial second line. The hermetic repo selftest only runs a coarse grep with no exemption marker; this test is
the real guard.

## Declared gaps

- There is no `module.json` for web-react yet, so this package is not registered as a module.
- The dev dependency `fast-check` needs a line in the root `pnpm-workspace.yaml` catalog (the monorepo-root module owns
  that file; the selftest injects the line in its scratch workspace only).
- The app-wide rule (no ad-hoc formatting, `toFixed` or `toLocaleString` outside this package) is the web app's lint
  configuration, which does not exist yet; this package guards only its own `src/`.
- Not validated: other ICU / CLDR data (the pinned strings are those of the ICU shipped with the node in the hand-back).
