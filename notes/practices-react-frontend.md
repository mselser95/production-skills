# Frontend track: current practices as CI gates (React + TS + Vite + pnpm monorepo)
Research date: 2026-11-27. Method: WebSearch then WebFetch of the cited pages. IMPORTANT caveat on quotes: WebFetch
returns the output of a small summarising model, not raw page bytes. Quotes marked "q:" are what that tool returned as
verbatim page text (<=25 words); I could not byte-verify them against the live page. Anything from a non-primary site is
tagged [NP]. Format per item: PRACTICE -> why -> gate (command/config key) -> source.
## 1. Toolchain (versions as shown on the primary pages today)
| Tool | Current | Support policy / note | Source |
|---|---|---|---|
| React | 19.3.0 (2026-09-09) | docs track latest major; older majors archived | react.dev/versions, react.dev/blog |
| TypeScript | 7.0 (2026-07-08, native Go port); 7.1 beta 2026-10-20; 6.0 2026-03-23 | 6.0 "last release based on the current JavaScript codebase" | devblogs.microsoft.com/typescript |
| Vite | 8.4 | patches for 8.4; security backports to 7.3 and 8.3; "Security patches are also backported to vite@6.4 and vite@8.2" | vite.dev/releases |
| Vitest | 5.1.x (header of docs) | browser mode needs a provider (playwright/webdriverio/preview) | vitest.dev/guide/browser/ |
| Playwright | 1.65 | 1.63 dropped Ubuntu 20.04; docs pin image `mcr.microsoft.com/playwright:v1.64.1-noble` | playwright.dev/docs/release-notes, /ci |
| Storybook | docs 10.6 | Vitest addon is the recommended path for Vite projects; test-runner is the fallback | storybook.js.org/docs/writing-tests |
| Node | v26 (LTS, first released 2026-05-05), v24 LTS, v22 LTS; v27 alpha; v20 EOL | q: "Production applications should only use Active LTS or Maintenance LTS releases." Page does not say which LTS is Active vs Maintenance. From Node 27 releases are annual | nodejs.org/en/about/previous-releases |
| pnpm | 12.24.0 (2026-11-26); 11.x still patched | see section 3 | pnpm.io/blog |
| ESLint | 10.15.0 (2026-11-13) | | eslint.org/blog |
| typescript-eslint | 8.74 | typed linting via `parserOptions.projectService: true`, presets `strictTypeChecked` | typescript-eslint.io/getting-started/typed-linting |
PRACTICES
- Pin one Node LTS and one pnpm for dev and CI. Why: reproducible installs. Gate: root `package.json` has
  `"packageManager": "pnpm@<exact>"` and `"engines": {"node": ">=24 <27"}` (adjust); pnpm settings: `engineStrict: true`
  (q: "With `engineStrict` enabled, an incompatible `engines.node` in the project or a dependency fails the install.");
  CI: `node -v` compared to `.nvmrc`/`engines`. `devEngines.packageManager` takes ranges and is recorded in the lockfile
  (pnpm.io/package_json). q: "If the project's `engines.pnpm` does not accept the running pnpm version, the install fails."
- Corepack: bundled only until Node 25. q: distributed "from version 14.19.0 up to (but not including) 25.0.0."
  On Node 25+ run `npm install -g corepack` (github.com/nodejs/corepack). So an old guide saying "corepack enable just
  works" is wrong for Node 26. Gate: CI step installs pnpm explicitly (pnpm/action-setup or `npm i -g corepack`) then
  `pnpm -v` must equal the `packageManager` pin.
- TypeScript strictness. TS 6.0 made `strict` default true, `module` default `esnext`, `target` default latest (es2025),
  `types` default `[]`, `rootDir` default = tsconfig dir (devblogs 6.0 post). 6.0 deprecates `target es5`,
  `moduleResolution node`, `baseUrl`, `esModuleInterop:false`; removes `--outFile`, `moduleResolution classic`
  (removed outright in 7.0 per the post). Gate: `tsc -b --noEmit` (or `tsgo`) plus a config check that the shared base tsconfig
  sets explicitly: `strict`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes`, `noImplicitOverride`,
  `noFallthroughCasesInSwitch`, `noUncheckedSideEffectImports`, `verbatimModuleSyntax`, `isolatedModules`, `skipLibCheck: false`
  (decision, not source-mandated). Quoted definitions (typescriptlang.org/tsconfig):
  q: "Turning on `noUncheckedIndexedAccess` will add `undefined` to any un-declared field in the type."
  q: "`exactOptionalPropertyTypes` makes TypeScript truly enforce the definition provided as an optional property."
  `verbatimModuleSyntax`/`isolatedModules`/`composite` definitions were NOT in the fetched slice: see UNVERIFIED.
  Why noUncheckedIndexedAccess matters here: `rows[0].price` becomes `T | undefined`, which kills a class of `undefined` in the UI.
- Monorepo TS: project references with `composite` and `tsc -b` per package; one shared `tsconfig.base.json` via
  workspace package. Gate: `tsc -b` exits 0 and a script asserts every package tsconfig `extends` the base (unverified
  technique, my design).
- React Compiler: stable 1.0 since 2025-10-07 (react.dev/blog). q: "React Compiler is designed to work best with React 19, but it
  also supports React 17 and 18." Vite install needs `@vitejs/plugin-react` >= 6.0.0 plus `@rolldown/plugin-babel` and
  `reactCompilerPreset()`; q: "In `@vitejs/plugin-react@6.0.0`, the inline Babel option was removed." (react.dev/learn/react-compiler/installation).
  Recommendation: adopt on greenfield with React 19, because it is stable and the lint rules are free; do it behind the
  lint gate below. The compiler skips components that violate the Rules of React rather than failing, so the lint rule
  is the real gate. Gate: `eslint-plugin-react-hooks` with its `recommended` preset: the reference page lists 17 rules incl.
  `rules-of-hooks`, `exhaustive-deps`, `purity`, `refs`, `immutability`, `set-state-in-effect`, `set-state-in-render`,
  `static-components`, `preserve-manual-memoization`, `incompatible-library`, `error-boundaries`
  (react.dev/reference/eslint-plugin-react-hooks). q: "can be used even if your app hasn't adopted the compiler yet."
  The install page says `recommended-latest`; the reference page only names `recommended`: prefer `recommended` and verify
  by running eslint on a deliberately impure component (mutation test).
- Linters: ESLint 10 + typescript-eslint 8 typed linting is the fully verified baseline. Oxlint: type-aware backends
  `tsgolint`/`tsrs` exist, JS plugins are "(alpha)", jsx-a11y is covered, react-hooks not named (oxc.rs). Biome 2: 844 rules, type-aware
  rules via an opt-in Scanner that "increases run time and memory use" (biomejs.dev/linter). Neither is documented as parity
  with typescript-eslint + react-hooks compiler rules: use as a fast pre-pass only; do not replace the ESLint gate.
  eslint-plugin-jsx-a11y: no release/date visible on the fetched page; q: "only catches errors in static code" (README). Maintenance status UNVERIFIED.
## 2. Monorepo
- Layout: `apps/*`, `packages/*`; `pnpm-workspace.yaml` is the home for settings (q: "pnpm does not read settings from the `pnpm` field of
  `package.json`." pnpm.io/package_json). Internal deps use `"workspace:*"`. Gate: grep that no internal package is referenced
  by a semver range; `pnpm install --frozen-lockfile` fails if the lockfile is stale (flag documented by pnpm; page not fetched, see UNVERIFIED).
- Catalogs: define versions once in `pnpm-workspace.yaml` (`catalog:` / `catalogs:`), consume as `"react": "catalog:"`.
  `catalogMode: strict` q: "only allows dependency versions from the catalog." (default `manual`). Gate: `catalogMode: strict` plus a
  script failing on any `package.json` dependency not using `catalog:`/`workspace:` (my design). pnpm.io/catalogs.
- Orchestration: I found no primary source stating when turborepo/nx become necessary. Evidence-free recommendation: start with
  `pnpm -r --workspace-concurrency=N --filter "...[origin/main]" run <task>` (changed-package filter) and add a task cache only when
  the 2-minute budget is blown. Marked as judgment, UNVERIFIED against sources.
- Boundaries: `eslint-plugin-boundaries` ("Lint your architecture, not just your syntax", `boundaries/dependencies` rule with
  default allow/disallow) or `dependency-cruiser` (`forbidden` rules, `--init` defaults: circular, orphans, prod->dev dep). Gate:
  `eslint .` with boundaries rule, or `depcruise --config .dependency-cruiser.js apps packages` (exit code not documented on fetched page).
  Rules to encode: `apps/*` may import `packages/*`, never the reverse; `ui` may not import app code; `tokens` imports nothing.
- Dead code/deps: `knip` q: "will lint your project and report unused dependencies, exports and files." Workspaces via `workspaces` key
  (knip.dev). Gate: `pnpm knip` (non-zero on findings is standard but NOT confirmed on fetched pages) and run in `--production` for apps (not confirmed).
- Changesets: `@changesets/cli` "A tool to manage versioning and changelogs with a focus on monorepos." Gate: `changeset status --since=origin/main`
  fails a PR touching a published package without a changeset. The exact exit-code behaviour was NOT confirmed (two doc URLs 404/empty). Treat as UNVERIFIED until run.
## 3. Supply chain
| Practice | Why | Gate | Source |
|---|---|---|---|
| Install scripts blocked by default | worm payloads ran as postinstall | pnpm: dependency scripts blocked unless listed in `allowBuilds`; `strictDepBuilds` defaults `true` so install exits non-zero on an unreviewed script. q: "Packages not listed in allowBuilds are disallowed by default and are treated as unreviewed." Note: docs use `allowBuilds`, NOT `onlyBuiltDependencies` | pnpm.io/settings/build |
| Cooldown | most malicious versions are pulled within hours | pnpm `minimumReleaseAge` default 1440 min (1 day); raise (e.g. 10080) and use `minimumReleaseAgeExclude` by package name. npm: `min-release-age` exists but default `null` (OFF); `ignore-scripts` default `false` | pnpm.io/settings/dependency-resolution; docs.npmjs.com/cli/v11/using-npm/config |
| Exotic sources blocked | git/tarball transitive deps skip registry checks | `blockExoticSubdeps` default true: q: "only direct dependencies ... may use exotic sources." | pnpm.io/settings/dependency-resolution |
| Trust downgrade guard | publisher moved from provenance to none | `trustPolicy: no-downgrade` (off by default; q: "pnpm will fail if a package's trust level has decreased") | same |
| Lockfile enforced | tampered ranges | `pnpm install --frozen-lockfile` in CI | pnpm docs (not fetched) |
| Vuln scan | known CVEs | `pnpm audit --prod --audit-level high` (flags `--audit-level`, `--prod`, `--json`, `--fix` confirmed; pnpm.io/cli/audit); plus `osv-scanner scan source -L pnpm-lock.yaml` (command confirmed, exit codes NOT; google.github.io/osv-scanner/usage/) | |
| Provenance verification | detect publish not from CI | `npm audit signatures` verifies registry signatures and attestations (docs.npmjs.com/generating-provenance-statements) | |
| Publishing | no long-lived tokens | npm trusted publishing (OIDC): needs npm CLI >= 11.5.1, Node >= 22.14.0, `id-token: write`; provenance automatic; q: "disallow tokens" setting recommended (docs.npmjs.com/trusted-publishers). Gate: publish workflow has `permissions: id-token: write`, no `NPM_TOKEN` secret referenced | |
| Actions pinned | tags are mutable | q: "Pin references to actions to a commit SHA in your workflow files." Default `GITHUB_TOKEN` read-only; avoid `pull_request_target`. Gate: OpenSSF Scorecard checks `Pinned-Dependencies`, `Token-Permissions`, `Dangerous-Workflow` (github.com/ossf/scorecard docs/checks.md); or a grep for `uses: .*@[^0-9a-f]{40}` | docs.github.com secure-use |
| SRI for third-party | CDN compromise | `integrity="sha384-..."` + `crossorigin="anonymous"`; CDN must send CORS (MDN SRI). Best policy: no third-party scripts, self-host | |
Incidents and mitigations. Official: GitHub's plan after Shai-Hulud (2025-09-22): classic tokens deprecated, granular tokens
lifetime-limited, publishing "disallow tokens by default", prefer trusted publishing, WebAuthn over TOTP
(github.blog/security/supply-chain-security/our-plan-for-a-more-secure-npm-supply-chain). GitHub 2025-12-23 post: worm 2.0 targeted CI
and self-hosted runner registration; maintainers should use trusted publishing, branch protection, pin CI dependencies; staged
publishing was "planned (not yet released)". [NP] TanStack compromise 2026-05-11 (42 packages, 84 versions): chain of
`pull_request_target`, Actions cache poisoning and OIDC token extraction from runner memory; I found no copy of TanStack's own postmortem,
only InfoQ/Snyk/Register coverage via search, so treat details as [NP]. [NP] A July-2026 Better Stack guide claims the newer variant uses IDE-config hooks,
so `ignore-scripts` alone does not stop it: this is why cooldown + trusted publishing + CI hardening are all needed. Gate implication: forbid
`pull_request_target` with checkout of PR code, and do not share `actions/cache` between untrusted PR runs and release jobs (inference from the incident, [NP]).
SBOM: no primary source fetched; UNVERIFIED (candidate: CycloneDX via `@cyclonedx/cyclonedx-npm`, not checked).
Renovate/Dependabot: Renovate `minimumReleaseAge` options exist (docs.renovatebot.com, headings only fetched); preset names
`security:minimumReleaseAgeNpm` and `helpers:pinGitHubActionDigests` NOT confirmed.
## 4. Secure coding in React
- XSS. q: "Only use `dangerouslySetInnerHTML` with trusted and sanitized data." (react.dev/reference/react-dom/components/common). OWASP:
  q: "OWASP recommends DOMPurify for HTML Sanitization." sanitize right before insertion; React 19 blocks `javascript:` in `href/src` but that
  "does not replace application-specific URL validation" (cheatsheetseries.owasp.org XSS Prevention). The React docs page I fetched did NOT
  confirm the `javascript:` blocking, only OWASP did. Gate: ESLint `react/no-danger` (plugin eslint-plugin-react; not fetched, UNVERIFIED) or `no-restricted-syntax`
  on `JSXAttribute[name.name='dangerouslySetInnerHTML']` with an allowlisted wrapper component `SafeHtml`; a `safeUrl()` helper
  (parse with `new URL`, allow `http:`/`https:`/`mailto:`) with a unit test table of `javascript:`, `data:`, `vbscript:`, `//evil`, mixed-case, whitespace-prefixed.
- Trusted Types: Baseline 2026 on MDN (q: "Since February 2026, this feature works across the latest devices and browser versions"). React 19.3 passes
  TrustedHTML through without string coercion (react.dev/blog 19.3). CSP: `require-trusted-types-for 'script'; trusted-types <policy-names>`.
  Gate: e2e test loads the built app under that CSP and fails on any `securitypolicyviolation` event or console CSP error.
- CSP for a Vite SPA. MDN: q: "recommended practice is to use nonce- or hash-based fetch directives. This is called a strict CSP."
  Nonces must be unique per response; static SPAs without a server per response can use hashes (q: "both the CSP and the content can be static, because the hashes stay the same").
  Baseline policy to assert: `script-src 'nonce-...' or hashes; object-src 'none'; base-uri 'none'; frame-ancestors 'none'`.
  `frame-ancestors` replaces X-Frame-Options (OWASP CSP cheat sheet). q (MDN): "Developers should avoid `'unsafe-inline'`". If a
  directive has nonce/hash, `unsafe-inline` is ignored. Implication for styles: runtime CSS-in-JS injects `<style>` and needs a nonce or `unsafe-inline`;
  build-time extraction (vanilla-extract/CSS Modules) emits files and works with `style-src 'self'`. I did not find vanilla-extract docs using the
  words "zero-runtime" on the fetched page; the CSP statement about it is my inference, UNVERIFIED. Gate: Playwright test asserts response headers
  (`expect(response.headers()['content-security-policy'])` contains the required directives and not `unsafe-inline`/`unsafe-eval`), run against `vite preview` or the real edge config.
  Deploy via `Content-Security-Policy-Report-Only` first.
- Secrets in the bundle. q: "`VITE_*` variables should _not_ contain sensitive information such as API keys." (vite.dev/guide/env-and-mode). Gate:
  after `vite build`, `grep -rE` the `dist/` for secret patterns plus run gitleaks/trufflehog; lint rule forbidding `envPrefix: ''` in vite config.
- Token storage. OWASP HTML5: q: "Do not store session identifiers in local storage as the data is always accessible by JavaScript." Prefer `httpOnly`
  cookie. Gate: grep forbidding `localStorage.setItem(.*token` (lint `no-restricted-properties`), e2e asserts auth cookie has `HttpOnly; Secure; SameSite`
  via `context.cookies()`.
- CSRF. OWASP: SameSite is defence in depth; custom header + CORS lock; q: "Remember that Cross-Site Scripting (XSS) can defeat all CSRF
  mitigation techniques!" Gate: e2e/API test that a state-changing request without the CSRF header or with a foreign Origin is rejected (backend track).
- postMessage: q: "Check the `origin` attribute of the sender to verify the data is originating from the expected location." and never target `*` (OWASP HTML5). Gate:
  lint `no-restricted-syntax` for `postMessage(..., '*')` and `addEventListener('message'` handlers lacking `event.origin` (custom rule; UNVERIFIED feasibility).
- Source maps: Vite `build.sourcemap` values `true | 'inline' | 'hidden'`; `hidden` omits the comment from bundles (vite.dev/config/build-options). Policy: build `hidden`,
  upload to error tracker, do not serve `.map`. Gate: `find dist -name '*.map'` must be empty in the deployable artifact; no `sourceMappingURL` in `dist/**/*.js`.
- Open redirects, file upload/download, prototype pollution: no primary source fetched. UNVERIFIED. Minimal gate ideas: `safeRedirect(path)` accepting only same-origin relative paths with tests;
  `Content-Disposition: attachment` handled server-side; ban `Object.assign(target, untrusted)` / use `Object.create(null)` (judgment).
- RSC / Server Functions. Official: CVE-2025-55182, unauthenticated RCE, CVSS 10.0, affected `react-server-dom-{webpack,parcel,turbopack}` 19.0 to 19.2.0, fixed 19.0.1/19.1.2/19.2.1;
  follow-ups: DoS CVE-2025-55184/67779 (7.5), source exposure CVE-2025-55183 (5.3), DoS CVE-2026-23864 (7.5, added 2026-01-26). q: "If your app's React code does not use a server, your app is not affected by this vulnerability."
  and q: "Even if your app does not implement any React Server Function endpoints it may still be vulnerable if your app supports React Server Components."
  Affected-by-dependency list: next, react-router, waku, @parcel/rsc, @vitejs/plugin-rsc, rwsdk (react.dev/blog/2025/12/03/...). [NP] search results add react-router Jan-2026 batch (CVE-2026-22030 CSRF on actions/server functions, fixed 7.12.0) and
  @vitejs/plugin-rsc dev-server RCE CVE-2025-67489 fixed 0.5.6. RECOMMENDATION: a default Vite SPA backed by a Go/Rust/Python API should NOT use RSC/server functions: it adds a Node server
  attack surface this stack does not otherwise have. Gate: lockfile check `pnpm why react-server-dom-webpack react-server-dom-turbopack react-server-dom-parcel @vitejs/plugin-rsc` must be empty (command `pnpm why` unfetched; use `grep` on `pnpm-lock.yaml` as the stable form), and `'use server'` grep must be empty.
## 5. Data correctness at the boundary
- Runtime validation of every API response. Zod 4 is "stable", core about 2 KB gzipped (zod.dev); Valibot "Small bundle size starting at less than 700 bytes" and tree-shakeable (valibot.dev). I did not fetch an
  OpenAPI/protobuf generator comparison, so the comparison is judgment: schema-from-source-of-truth (OpenAPI -> zod via a generator, or proto -> `@bufbuild/protobuf` with its own validation) removes drift between backend and UI;
  hand-written zod schemas drift but are easier to make strict. Whichever: ONE `parseResponse(schema, response)` function is the only code allowed to call `fetch`/`response.json()` for the API.
  Gates: (a) ESLint `no-restricted-properties`/`no-restricted-syntax` banning `.json()` outside the API client package, and banning `as` assertions on parsed data (`@typescript-eslint/consistent-type-assertions: {assertionStyle: 'never'}` is a real typescript-eslint rule, not re-verified on the fetched page);
  (b) schemas use `.strict()`/no `any`; (c) a contract test replays recorded real responses (HAR or backend-generated fixtures) through the schemas and fails on unknown/missing fields; (d) Playwright adversarial fixture returns `"price": "abc"`, `null`, number-as-string and asserts the UI shows an explicit
  "unexpected data" state and `page.locator('body')` text does not match `/NaN|undefined|\[object Object\]|Infinity/`. That last regex assertion is a cheap global gate to run after every e2e step (my design).
- Typed errors: parse failures become a `SchemaError` (carrying path, endpoint, request id) distinct from `HttpError`/`NetworkError`; error boundary renders each. No source fetched; design.
- Formatting. `Intl.NumberFormat` options confirmed on MDN: `roundingMode` default `halfExpand` (also `halfEven`, `trunc`...), `signDisplay` (`auto|always|exceptZero|negative|never`), `notation: 'compact'`
  (default rounding then max 2 significant digits), `currencyDisplay`. q: "format() will use the exact value that the string represents, avoiding loss of precision during implicit conversion to a number."
  So pass decimal STRINGS or BigInt to `format()`: `nf.format("1234567891234567891")` is exact, while the number literal is not. Caveat from MDN: arithmetic is still not exact (use a decimal library / BigInt for math) and older engines parsed strings as Number.
- Dates: Temporal is not Baseline. q: "This feature is not Baseline because it does not work in some of the most widely-used browsers." (MDN). Use `Intl.DateTimeFormat` with explicit `timeZone`; polyfill `@js-temporal/polyfill` if needed. Playwright can pin `locale` and `timezoneId` per project (playwright.dev/docs/emulation); the test runner needs `TZ` env.
- Forbid ad-hoc money formatting. Gate: ESLint `no-restricted-properties` for `toFixed`, `toLocaleString` with args outside the `@org/format` package, `no-restricted-syntax` for template literals/concats containing `$` + number identifiers (heuristic, noisy);
  allow only `formatMoney/formatPercent/formatDate` from one package. Unit tests with `fast-check` property: `formatMoney(decimalString)` never contains `NaN`/`e+`, round-trips the digits for strings up to 30 digits (fast-check described as "the property-based testing library for JavaScript and TypeScript"; vitest integration not verified).
## 6. Testing pyramid
- Vitest 5.1.x. Browser mode runs q: "in a native browser instead of a simulated environment" (paraphrase of why page; quote of that page: "it's crucial to test in a real browser environment") and q: "does not completely replace standalone end-to-end test runners". Slower init. Stable/experimental label NOT stated on the fetched pages.
  Practice: jsdom/happy-dom for pure logic and light component tests (fast), browser mode for layout-dependent components. Gate: `vitest run --coverage`.
- Coverage: v8 is default; q: "Coverage report accuracy is as good as with Istanbul" (AST remapping since 3.2.0); v8 does not work in non-V8 engines. q: "Vitest will show only files that were imported during test run." so set `coverage.include` to the source glob or untested files are invisible (this is a vacuity trap).
  Threshold config keys (`coverage.thresholds.lines/functions/branches/statements`, `perFile`) are NOT confirmed on the fetched page; confirm with a mutation (delete a test, expect failure).
- Testing Library: q: `getByRole` "should be your top preference for just about everything"; test ids last (testing-library.com/docs/queries/about). Gate: eslint-plugin-testing-library (not fetched) or ban `getByTestId` outside allowlist.
- MSW: page fetched did not cover Vitest/Storybook/Playwright setup or `onUnhandledRequest`; UNVERIFIED. Principle: one set of handlers generated from real recorded shapes, reused across unit, Storybook and e2e. Playwright itself supports `page.route` and HAR replay (`routeFromHAR` with `update: true` to record real traffic; strict URL+method matching; commit the HAR) (playwright.dev/docs/mock).
- Storybook: Vitest addon runs stories as tests in browser mode; play functions for interaction; a11y addon `parameters.a11y.test`: `'error'` fails tests, `'todo'` warns, `'off'` skips; in CI a11y runs only for `'error'` stories.
  q: "In CI, accessibility tests run automatically only for stories set to 'error'" (paraphrase of docs). Gate: global preview `parameters.a11y.test = 'error'`, and a script that fails on any story file containing `'todo'` or `'off'` without an allowlisted ticket id.
  Visual tests in Storybook are via Chromatic (SaaS); Playwright screenshots are the self-hosted alternative.
- Visual regression (Playwright): q: "For consistent screenshots, run tests in the same environment where the baseline screenshots were generated." baselines are per browser and platform (`chromium-darwin` in names). `toHaveScreenshot` defaults: `animations: "disabled"`, `caret: "hide"`, `scale: "css"`, `threshold` 0.2 (page). Gate: generate baselines ONLY in the pinned Docker image `mcr.microsoft.com/playwright:v<same as @playwright/test>-noble`; CI step compares `@playwright/test` version to image tag; `--update-snapshots` is forbidden in CI (grep workflow). Fonts: self-host and `await document.fonts.ready` (design advice, not sourced).
- Mutation testing (Stryker): defaults `high 80`, `low 60`, `break: null`; exit 1 below `break`; `coverageAnalysis: perTest`; incremental file `reports/stryker-incremental.json` via `--incremental`; `mutate` must target production code, not tests (stryker-mutator.io config page). Realistic CI use: run only on the formatting/validation packages (money, dates, schemas), with `thresholds.break` set, incremental, on a nightly or changed-files job (not on every PR for the whole repo). The Vitest runner page was empty on fetch: UNVERIFIED.
## 7. Playwright end-to-end as a gate
Config keys (all confirmed on playwright.dev/docs/api/class-testconfig and test-cli): `forbidOnly` (CLI `--forbid-only`), `failOnFlakyTests` (CLI `--fail-on-flaky-tests`, q: "Fail if any test is flagged as flaky"), `retries` (default 0), `fullyParallel`,
`workers` (CLI default 50%), `maxFailures`, `reporter`, `webServer`. Docs CI page recommends q: `workers` "to "1" in CI environments to prioritize stability and reproducibility" and sharding for scale; but our 2-minute budget argues for `workers: '100%'` on a stable runner and measure flake rate (judgment).
- Projects: one per viewport class using device descriptors: `{name:'mobile', use:{...devices['iPhone 13']}}`, tablet, desktop `{viewport:{width:1280,height:800}}`; descriptors set UA, viewport, `isMobile`, touch; override viewport AFTER the spread (emulation docs). Extra projects: `locale`/`timezoneId`, `colorScheme: 'dark'`, `reducedMotion: 'reduce'` (all confirmed). Playwright 1.64 forwards `screen` from device descriptors.
- Mocking: `page.route` fulfilling with real-shaped payloads; prefer "perform the request and fulfill it with the modified response" (docs wording) or HAR so the shape cannot drift; Playwright docs example uses hand-written `{name,id}` which is NOT checked against the API: add a fixture test parsing every mock through the production zod schema.
- Assert every visible box and number: use `getByRole`/`getByTestId` + `toHaveText('$1,234.50')` with exact formatted strings from a fixture-driven expected table (expected values computed independently, not by the app's formatter). Structure assertions: `await expect(page).toMatchAriaSnapshot(...)` (exists since 1.60 for page; locator form older). Syntax per docs: `- role "name" [attribute=value]`; q: "You can perform partial matches on nodes by omitting attributes or accessible names."; regex like `- heading /Issues \d+/`; `.aria.yml` files; without `-u`, absent snapshots are generated but the test fails (good: new unreviewed snapshots fail CI).
  Playwright 1.65 caveat: text not rendered "is no longer part of accessible names and aria snapshots", re-baseline on upgrade.
- Overflow / clipping detection. Technique (my design; Playwright docs do not prescribe it): after each page state, `page.evaluate` over `document.querySelectorAll('*')`:
  (1) page-level: `document.documentElement.scrollWidth > document.documentElement.clientWidth` must be false; also `window.scrollX` after `scrollTo(100,0)` stays 0.
  (2) element-level: `el.scrollWidth > el.clientWidth + 1` (or height) when computed `overflow-x` is `visible`/`hidden`/`clip` is a clip candidate. Skip elements with `overflow: auto|scroll` ONLY if they carry `data-scrollable` (explicit allowlist, so accidental scrollers fail).
  (3) intentional truncation (`text-overflow: ellipsis`): require `data-truncate` marker AND `title`/tooltip/accessible full text, and assert the full string exists in the accessible name; otherwise a truncated number is a failure (money must never ellipsize).
  (4) bounding boxes: every visible element's `getBoundingClientRect()` must satisfy `right <= innerWidth + 0.5` and `left >= -0.5` (except `position: fixed` off-canvas with `aria-hidden`).
  (5) text clipped by a parent: compare child rect against nearest ancestor with non-visible overflow.
  Pitfalls: sub-pixel rounding (use tolerance 1px); `scrollWidth` on `display:inline` is 0; `position:absolute` children are not in parent's scrollWidth when parent not positioned; `overflow: hidden` + ellipsis hides content that `scrollWidth` still reports (so check works) but `line-clamp` needs `scrollHeight > clientHeight`; fonts not yet loaded change widths (await `document.fonts.ready`); animations (use `reducedMotion: 'reduce'`); virtualised lists render few rows.
  Run it as a fixture `assertNoOverflow(page)` invoked in an `afterEach` and after each navigation in every project, with adversarial data (below). Prove non-vacuity: the self-test mounts a fixture page with a known `width: 2000px` div and a known ellipsized span and expects the helper to RED.
- Accessibility: `@axe-core/playwright` `new AxeBuilder({page}).withTags(['wcag2a','wcag2aa','wcag21a','wcag21aa','wcag22aa']).analyze()` then `expect(results.violations).toEqual([])`. The docs example lists the first four tags; `wcag22aa` exists in axe's rule list, with `target-size` there, but q: "These rules are disabled by default, until WCAG 2.2 is more widely adopted and required." so enable explicitly (`.options({rules:{'target-size':{enabled:true}}})` is my reading of the API, unverified).
  q (Playwright): "automated testing cannot detect all types of WCAG violations." Also fail on `results.incomplete` for color-contrast ("needs review" per axe rule table) or review them. Use a shared fixture so no spec forgets the scan.
- Adversarial fixtures (all as parametrised fixtures): 300-char unbroken strings, 1e21 and 12-digit currency amounts as decimal strings, negative zero, RTL (Arabic/Hebrew) with `dir="rtl"` pass, emoji/ZWJ and combining marks, empty list, single item, 1000 items, 400/401/403/404/409/422/429/500/503, slow response (`route.fulfill` after delay), truncated/invalid JSON, schema-violating types, `route.abort('failed')` and `context.setOffline(true)`. Each asserts: an explicit state is shown (loading/empty/error/offline), no overflow, no `NaN|undefined|[object Object]`, axe clean.
- Trace/video: `use: {trace: 'retain-on-failure', video: 'retain-on-failure'}` (option names from memory, not re-fetched; UNVERIFIED) and upload `playwright-report/` (docs example retention 30 days).
- Speed: `fullyParallel: true`; `--shard=x/y` with blob reporter and `npx playwright merge-reports` (docs). q: "Without the fullyParallel setting, Playwright Test defaults to file-level granularity." Install only needed browsers; docs advise against caching browser binaries. Target: wall time per shard under 2 min, measured by the CI job duration, fail the gate if p95 exceeds 110 s.
- Flake policy: `retries: 1` max on CI, `failOnFlakyTests: true`, `forbidOnly: !!process.env.CI`. Rationale: retries without `failOnFlakyTests` hide flakes (a "flaky" test is one that failed first and passed on retry, per retries docs).
- Proving flow coverage: `flows.yaml` manifest listing every user flow id with route + owner; each Playwright spec title/annotation carries `@flow:<id>` (`test.info().annotations` or `test.describe({tag:'@flow:checkout'})`); a CI script runs `npx playwright test --list --reporter=json` and diffs ids: every manifest id covered by >=1 test per project, no orphan ids. Also derive candidate flows from the router table (routes in `src/routes`) and fail if a route is in neither the manifest nor an explicit `excluded:` list. (Design; `--list --reporter=json` is standard but not re-fetched.)
- Non-vacuity of e2e: mutation of the app in CI (nightly): (a) break the money formatter (`halfEven` -> `trunc`, or drop a digit) and expect >=1 e2e RED; (b) inject `width: 2000px` into a component and expect the overflow gate RED; (c) change a fixture field type and expect the "unexpected data" test RED; (d) remove an `aria-label` and expect axe/aria-snapshot RED. Gate fails if any mutation stays green.
## 8. Accessibility
- Bar: WCAG 2.2 AA, a W3C Recommendation of 12 December 2024. New AA criteria: 2.4.11 Focus Not Obscured (Minimum), 2.5.7 Dragging Movements, 2.5.8 Target Size (Minimum), 3.3.8 Accessible Authentication (Minimum); 4.1.1 Parsing removed (w3.org/TR/WCAG22). Contrast 1.4.3: q: "a contrast ratio of at least 4.5:1" (large text 3:1). The 24px target-size number was not visible in the fetched slice: UNVERIFIED.
- Automatable share: Deque says its automated tests found 57.38% of issues across 2,000+ audits (2021, vendor study [NP]: deque.com/blog/automated-testing-study-identifies-57-percent...); Storybook's a11y doc repeats "up to 57% of WCAG issues". Treat as an upper bound that is vendor-reported; rest is manual (screen reader, cognitive, meaning of alt text, focus order sense).
- Keyboard/focus tests in Playwright: `page.keyboard.press('Tab')` loops asserting `document.activeElement` order against an expected list, `Escape` closes dialogs and returns focus to the opener, focus trap in modals, visible focus (`toHaveCSS` outline not none), skip link. No source fetched for these techniques: design.
- Colour contrast as token-level test: compute WCAG ratio (relative luminance formula from WCAG 2.2) for every semantic fg/bg token pair in each theme in a Vitest unit test, fail below 4.5 (text), 3 (large text, UI components per 1.4.11, not fetched). APCA: no primary source fetched, status UNVERIFIED (WCAG 3 draft only). axe `color-contrast` returns "needs review" results, so token tests cover what axe cannot (gradients/images).
- Reduced motion: emulate `reducedMotion: 'reduce'` as a Playwright project (confirmed) and assert no running animations (`document.getAnimations().length === 0`, my design).
- Semantic HTML first; Radix/React Aria primitives: NOT fetched. UNVERIFIED maintenance status; verify before pinning. jsx-a11y covers only static JSX.
## 9. Design system engineering
- Token layers primitive -> semantic -> component, source in DTCG JSON. DTCG: the Format Module draft page (dated 2026-09-08) states latest published version 2025.10 and q: "Do not attempt to implement this version of the specification." (that wording is for the preview draft; the 2025.10 snapshot is the stable-ish target). Key concepts: `$value`, `$type`, aliases `{group.token}` or `$ref`; colour is a separate module with `colorSpace`, `components`, `alpha`.
  Style Dictionary v4 gave "first-class support for the DTCG format"; q: "the latest format 2025.10 does not have full support yet in Style Dictionary", full support "a work in progress in v5" (styledictionary.com/info/dtcg). Gate: `style-dictionary build` is deterministic (CI `git diff --exit-code` on generated output); schema check that every semantic token resolves to a primitive (no raw hex/px in semantic or component layers) and no alias cycles.
- Theme contract: vanilla-extract `createThemeContract` q: "a contract of locally scoped variable names for themes to implement"; themes via `createTheme(vars, {...})`. Whether a missing key is a compile error was NOT confirmed on the fetched page; verify with a mutation (delete a key from a theme, expect `tsc` RED).
- Zero-runtime CSS: vanilla-extract docs (fetched page) say styles are processed by the bundler integration (Vite listed), the word "zero-runtime" was not on that page; CSP compatibility as in section 4 is inferred. CSS Modules alternative is equally CSP-safe.
- Gates: (1) every export from `packages/ui/src/index.ts` has a `*.stories.tsx` (script comparing exported names with story `title`/component meta; knip can find unused exports); (2) every story renders and a11y `'error'` (above); (3) Storybook build `storybook build` succeeds in CI; (4) visual regression per story via Playwright or Chromatic (Chromatic is a paid SaaS [NP-ish: Storybook docs]); (5) changesets for `packages/ui`; (6) no hard-coded colours/spacing: `stylelint` or grep for `#[0-9a-f]{3,8}`/`px` outside token package (design). Responsive primitives and container queries: no source fetched, UNVERIFIED.
## 10. Performance budgets
- Core Web Vitals (web.dev/articles/vitals), evaluated at the 75th percentile, mobile and desktop separately: LCP <= 2.5 s, INP <= 200 ms, CLS <= 0.1. FID is gone; INP is the interactivity metric.
- Bundle: Vite `build.chunkSizeWarningLimit` default 500 kB uncompressed and only WARNS; `build.target` default `'baseline-widely-available'`. So a gate must be a real budget: `size-limit` (q: "throws an error if the cost exceeds the limit", config in `package.json` or `.size-limit.json`, `@size-limit/esbuild`, `@size-limit/time` uses headless Chrome) with `pnpm size-limit` as the command.
- Lighthouse CI: assert presets `lighthouse:recommended|all|no-pwa`; `assertions` level `error` gives non-zero exit, `warn` does not; collect default 3 runs; budgets file cannot combine with other assert options (github.com/GoogleChrome/lighthouse-ci docs/configuration.md). Maintenance status not stated on the page: UNVERIFIED. Lab Lighthouse is not CWV field data.
- Code splitting: `React.lazy` + route-level dynamic `import()`; gate = size-limit per entry chunk, and a check that the initial route chunk excludes heavy libs (rollup visualizer / `vite build --report` not fetched). Images policy: nothing sourced; design: explicit width/height (CLS), `loading="lazy"` below the fold, modern formats, max bytes asserted in the e2e via `response.body()` sizes.
## 11. State, data fetching, errors
- TanStack Query: page fetched confirms only "fetching, caching, synchronizing and updating server state"; version/ESLint plugin NOT confirmed. [NP] The May-2026 npm compromise touched `@tanstack/*` packages but reportedly NOT `@tanstack/query` (secondary reporting): check advisory GHSA-g7cv-rxg3-hmpx before relying.
- REQUIRED states for every data view: loading, empty, error (schema vs http vs network), partial/stale. Enforce by convention: a `<DataView query={q}>` component that is the only way to render a query result and takes mandatory `empty`, `error`, `loading` render props (TS makes omission a compile error). Prove by e2e: each view has fixtures for the four states (section 7 adversarial list) and the flow manifest lists `states: [loading, empty, error]` per view; a script fails if a view lacks the matching tests. ESLint `react-hooks` rule `error-boundaries` (confirmed in the rule list) validates that Error Boundaries are used instead of try/catch for child errors.
- i18n readiness and routing: no primary source fetched (React Router advisories only in section 4). UNVERIFIED. Gate idea: ban string literals in JSX via `eslint-plugin-i18next` (not verified) and pseudo-locale e2e project (long strings + RTL) reusing the overflow gate.
## 12. Client observability
- OpenTelemetry browser: q: "Client instrumentation for the browser is experimental and mostly unspecified." (opentelemetry.io). So do not make it a hard dependency; prefer a vendor SDK or plain `web-vitals` (library not fetched, UNVERIFIED).
- Error reporting without PII: no primary source fetched. Practice (design): scrub URLs/query strings, never send request/response bodies or form values, allowlist fields, test with an e2e that triggers an error with a fake PII string and asserts the captured outgoing report (via `page.route` on the collector URL) does not contain it.
- Source maps: build `hidden`, upload in the release job, delete from artifact (section 4 gate).
## 13. Default frontend CI gates
| Gate | Proves | Command | <2 min? | Cannot see |
|---|---|---|---|---|
| install | lockfile consistent, scripts reviewed | `pnpm install --frozen-lockfile` (strictDepBuilds on by default) | yes with store cache | malicious code in allowed builds |
| typecheck | strict TS, project refs | `pnpm -r exec tsc -b` or `tsc -b` at root | yes | runtime data shape |
| lint | hooks/compiler rules, a11y static, boundaries, bans | `pnpm eslint . --max-warnings 0` | typed lint may exceed on big repos | rendered DOM |
| unused | dead exports/deps | `pnpm knip` | yes | dynamic usage |
| unit | logic, formatters, schemas | `pnpm vitest run --coverage` | yes | layout, real browser |
| mutation (nightly/changed) | tests are not vacuous | `pnpm stryker run --incremental` | no, run off-PR | e2e, visuals |
| storybook | every component renders, a11y error | `pnpm storybook build` + vitest addon run | borderline | cross-component flows |
| e2e | flows, numbers, overflow, axe, CSP | `pnpm playwright test --shard=${i}/${n}` | yes with shards | real backend, real devices, screen readers |
| visual | pixel drift | `playwright test --project=visual` in pinned image | yes | semantics |
| flow-coverage | manifest vs specs | custom script on `playwright test --list --reporter=json` | yes | quality of assertions |
| size | bundle budget | `pnpm size-limit` | yes | runtime perf |
| lighthouse | lab perf/best-practice | `pnpm lhci autorun` | borderline | field CWV |
| audit | known vulns | `pnpm audit --prod --audit-level high`; `osv-scanner scan source -L pnpm-lock.yaml` | yes | zero-days, fresh malware |
| supply policy | cooldown, trustPolicy, SHA pins | grep `pnpm-workspace.yaml` for `minimumReleaseAge`, `trustPolicy`; Scorecard `Pinned-Dependencies` | yes | compromised maintainers |
| secrets in bundle | no keys shipped | gitleaks on repo + grep `dist/` | yes | obfuscated secrets |
| sourcemap | none served | `find dist -name '*.map'` empty | yes | CDN-side config |
| changeset | version intent | `changeset status --since=origin/main` | yes | wrong bump level |
## 14. What changed in ~12 months (older advice now wrong)
1. RSC security: Dec 2025 critical RCE (CVSS 10) and follow-ups through Jan 2026; "RSC is just a React feature, safe by default" is wrong; and a plain SPA is unaffected only if no RSC-capable bundler plugin is present.
2. React Compiler 1.0 stable (2025-10-07) and the compiler diagnostics ship in `eslint-plugin-react-hooks`; "memoize by hand, compiler is experimental" is outdated. Vite plugin: `@vitejs/plugin-react` 6 dropped inline Babel option.
3. React 19.3 (2026-09-09): Trusted Types pass-through, View Transitions and Fragment Refs stable; Trusted Types is Baseline since Feb 2026 (MDN), so "Chromium-only" advice is outdated.
4. TypeScript 6.0/7.0: `strict` default true, `types` default `[]`, many legacy options deprecated/removed, native compiler 7.0 (Go) about 10x faster; `baseUrl`, `moduleResolution node`, ES5 target advice is dead.
5. pnpm defaults: dependency build scripts blocked and `strictDepBuilds` on, `blockExoticSubdeps` on, `minimumReleaseAge` default 1 day; the setting is `allowBuilds` in `pnpm-workspace.yaml` (not `onlyBuiltDependencies` in `package.json`; pnpm "does not read settings from the `pnpm` field of `package.json`"). Exactly which pnpm major flipped each default is NOT stated on the pages I fetched.
6. Corepack no longer bundled from Node 25.
7. npm: classic tokens deprecated, trusted publishing (OIDC) preferred, npm `min-release-age` exists but is off by default, `ignore-scripts` default false.
8. Playwright: `toMatchAriaSnapshot` on the page (1.60), `page.ariaSnapshot()` (1.59), test agents (1.56), `failOnFlakyTests`, component testing moved to a stories model (1.62), aria snapshots no longer include unrendered text (1.65).
9. Storybook: Vitest addon is the primary test route; the standalone test-runner is the fallback.
10. Style Dictionary v5 / DTCG 2025.10 with only partial support; WCAG 2.2 is a Recommendation and axe's 2.2 rules (`target-size`) are off by default.
11. Node 20 EOL (2026-03-24 per page); Node 22/24/26 LTS lines.
## UNVERIFIED (what I could not confirm from a primary source, and what I tried)
- All WebFetch outputs came through a summarising model; quotes are tool-returned, not byte-checked.
- `pnpm install --frozen-lockfile` semantics, `pnpm why`, pnpm major in which each default (scripts blocked, minimumReleaseAge 1 day) landed: pnpm.io/settings pages gave defaults but no versions; settings overview page gave none.
- TypeScript `verbatimModuleSyntax`, `isolatedModules`, `composite`, `erasableSyntaxOnly` definitions: the fetched slice was truncated.
- ESLint rule names `react/no-danger`, `consistent-type-assertions`, testing-library plugin, `eslint-plugin-i18next`: not fetched.
- Whether `knip`, `depcruise`, `changeset status`, osv-scanner exit non-zero on findings: knip/changesets/osv exit-code pages 404 or silent.
- Turborepo/Nx necessity: no primary evidence gathered; Radix/React Aria status, web-vitals lib, error-reporting PII guidance, SBOM tooling, Dependabot/Renovate security presets (Renovate page truncated), Playwright trace/video option names, `--list --reporter=json`, WCAG 2.5.8 24px, APCA, container queries, image policy, open redirects/upload/prototype pollution, Vitest runner for Stryker, MSW integration details, fast-check vitest package, Lighthouse CI maintenance, eslint-plugin-jsx-a11y maintenance, OpenAPI-vs-zod generators comparison, Storybook exact current version (releases page returned 307), Vitest browser stable label: not obtained.
- TanStack and Shai-Hulud 2026 details are [NP] (InfoQ/Snyk/Better Stack/dev.to via search); the official TanStack postmortem was not fetched.
- Node: page did not distinguish Active vs Maintenance LTS.
- Fixture note: the Playwright mocking doc shows hand-written mocks; "copy the real wire shape" is my requirement, not Playwright's.
## SOURCES (date shown on page, else "no date shown")
- https://react.dev/versions (lists 19.3.0 2026-09-09)
- https://react.dev/blog (index; posts dated 2025-10-01 to 2026-09-09)
- https://react.dev/blog/2026/09/09/react-19-3 (2026-09-09)
- https://react.dev/blog/2025/12/03/critical-security-vulnerability-in-react-server-components (2025-12-03, updated to 2026-01-26)
- https://react.dev/learn/react-compiler/installation (no date shown)
- https://react.dev/reference/eslint-plugin-react-hooks (no date shown)
- https://react.dev/reference/react-dom/components/common (no date shown)
- https://devblogs.microsoft.com/typescript/ (index) ; https://devblogs.microsoft.com/typescript/announcing-typescript-6-0/ (2026-03-23 per index)
- https://www.typescriptlang.org/tsconfig/ (no date shown)
- https://typescript-eslint.io/getting-started/typed-linting/ (no date shown)
- https://vite.dev/releases ; https://vite.dev/guide/env-and-mode ; https://vite.dev/config/build-options (no date shown)
- https://vitest.dev/guide/browser/ ; /guide/browser/why ; /guide/coverage (no date shown)
- https://playwright.dev/docs/release-notes ; /ci ; /test-cli ; /api/class-testconfig ; /api/class-pageassertions ; /test-snapshots ; /aria-snapshots ; /accessibility-testing ; /test-sharding ; /test-retries ; /mock ; /emulation (no date shown)
- https://storybook.js.org/docs/writing-tests ; /docs/writing-tests/accessibility-testing (no date shown; docs 10.6)
- https://nodejs.org/en/about/previous-releases (page rows updated through 2026-11-25)
- https://github.com/nodejs/corepack#readme (no date shown)
- https://pnpm.io/blog (release list through 2026-11-26) ; /supply-chain-security ; /settings/build ; /settings/dependency-resolution ; /settings ; /catalogs ; /package_json ; /cli/audit (no date shown)
- https://pnpm.io/blog/2025/12/05/newsroom-npm-supply-chain-security (2025-12-05; content was a Seattle Times case study, little settings detail)
- https://docs.npmjs.com/trusted-publishers ; /generating-provenance-statements ; /cli/v11/using-npm/config (no date shown)
- https://github.blog/security/supply-chain-security/our-plan-for-a-more-secure-npm-supply-chain/ (2025-09-22)
- https://github.blog/security/supply-chain-security/strengthening-supply-chain-security-preparing-for-the-next-malware-campaign/ (2025-12-23)
- https://docs.github.com/en/actions/reference/security/secure-use (no date shown)
- https://github.com/ossf/scorecard/blob/main/docs/checks.md (no date shown)
- https://google.github.io/osv-scanner/ ; /usage/ (no date shown)
- https://cheatsheetseries.owasp.org/cheatsheets/{Cross_Site_Scripting_Prevention,HTML5_Security,Content_Security_Policy,Cross-Site_Request_Forgery_Prevention}_Cheat_Sheet.html (no date shown)
- https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/CSP ; /Web/Security/Defenses/Subresource_Integrity ; /Web/API/Trusted_Types_API ; /Web/JavaScript/Reference/Global_Objects/Temporal ; .../Intl/NumberFormat/NumberFormat ; .../Intl/NumberFormat/format (no date shown)
- https://www.w3.org/TR/WCAG22/ (Recommendation 2024-12-12)
- https://www.designtokens.org/tr/drafts/format/ (draft dated 2026-09-08; latest published 2025.10) ; https://styledictionary.com/info/dtcg/ (no date shown)
- https://github.com/dequelabs/axe-core/blob/develop/doc/rule-descriptions.md (no date shown)
- https://vanilla-extract.style/documentation/api/create-theme-contract/ ; /documentation/getting-started/ (no date shown)
- https://zod.dev/ ; https://valibot.dev/guides/introduction/ ; https://tanstack.com/query/latest/docs/framework/react/overview ; https://testing-library.com/docs/queries/about/ ; https://mswjs.io/docs/ (no date shown)
- https://stryker-mutator.io/docs/stryker-js/configuration/ ; https://fast-check.dev/docs/introduction/ (no date shown)
- https://knip.dev/overview/getting-started ; /features/monorepos-and-workspaces ; https://github.com/ai/size-limit ; https://github.com/GoogleChrome/lighthouse-ci/blob/main/docs/configuration.md ; https://github.com/sverweij/dependency-cruiser ; https://github.com/javierbrea/eslint-plugin-boundaries ; https://github.com/jsx-eslint/eslint-plugin-jsx-a11y ; https://github.com/changesets/changesets/blob/main/packages/cli/README.md (no date shown)
- https://eslint.org/blog/ (v10.15.0 2026-11-13) ; https://oxc.rs/docs/guide/usage/linter ; https://biomejs.dev/linter/ (no date shown)
- https://opentelemetry.io/docs/languages/js/getting-started/browser/ (no date shown)
- https://docs.renovatebot.com/configuration-options/#minimumreleaseage (headings only; no date shown)
- [NP] https://www.deque.com/blog/automated-testing-study-identifies-57-percent-of-digital-accessibility-issues (March 2021 per search snippet)
- [NP] WebSearch results: snyk.io, infoq.com/news/2026/05/tanstack-supply-chain-attack, betterstack.com Shai-Hulud guide, netlify.com/changelog/2026-01-15-react-router-remix-security-vulnerabilities, osv.dev CVE-2025-67489 (dates as in snippets only)
