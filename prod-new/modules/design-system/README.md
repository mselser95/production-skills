# design-system module

Brand-neutral design tokens and a typed theme contract. No React yet: components come later.

```
packages/tokens   DTCG JSON sources, alias resolver, CSS + JSON + typed TS emitters, contrast helpers
packages/theme    typed theme contract over CSS variables, light and dark themes filled from the tokens
```

This module contributes PACKAGES, not a repository root. `module.json` places `packages/**` at the repository's
`packages/` (placement `root`); the root `package.json`, `pnpm-workspace.yaml` (with the version catalog),
lockfile, `tsconfig.base.json` and `.gitignore` belong to the monorepo-root module. Every third-party dependency here is
`catalog:` and the sibling is `workspace:*`; the versions live in monorepo-root's `pnpm-workspace.yaml`.
It is no longer a standalone workspace: assemble it with monorepo-root (`--layout monorepo --module monorepo-root
--module design-system`), then in the assembled repo `pnpm install`, `pnpm -r typecheck`, `pnpm -r test`,
`pnpm -r build` (or the same per package). Requires Node >=24 <27 and pnpm 10.34.3 (pinned there).

The root `pnpm-lock.yaml` is not shipped (it would name one scope): in a monorepo, run `make lock` at the root after assembly
(monorepo-root's README, "The lockfile"). The manifest DECLARES the two packages as units (`units`: ids `tokens` and `theme`,
kind `package`, language `ts`), so with monorepo-root the generated `repo.yaml` lists both and the root settings check has
no `unit-unlisted` finding.

Manifest summary: id `design-system`, declared units `tokens` and `theme` (kind package), lands at `packages/tokens` and `packages/theme`; this README is not placed.

## Token layers (`packages/tokens/src/json`)

| File | Layer | Content |
|---|---|---|
| `primitives.json` | 1 | palette ramps (neutral, accent, positive, negative, caution, alpha), font stacks and weights, spacing scale |
| `color.semantic.json` | 2 | `light` and `dark` roles (text, surface, border, action, feedback, overlay) that reference primitives; also declares the contrast pairings under `$extensions["contrast.pairs"]` |
| `typography.composition.json` | 3 | named text styles composed from family, size, weight, line height, tracking |
| `dimensions.json` | - | type scale, spacing aliases, radii, control heights, breakpoints 360/768/1280, z-index, motion, shadows |

DTCG shape: `$value` / `$type`, `{path.to.token}` aliases, `$type` inherited from the group.
The resolver is about 100 lines in `src/resolve.ts` and has no dependency: a cycle or a dangling alias throws `TokenError`
and fails `build`. A token tool was not adopted: it would add a large dependency tree for what the script does.

Output (`pnpm -F @ds-scope/tokens build`, into `dist/`, git-ignored): `tokens.css` (`:root` shared, light, dark, and a
`prefers-color-scheme` block that yields to an explicit `data-theme="light"`), `tokens.json`, `tokens.ts` (literal-typed).
Variable names: `--ds-<path in kebab-case>`. The reviewed CSS snapshot is `test/__snapshots__/tokens.css`; a token change
shows up as a diff there (`vitest -u` to accept after review).

## Theme contract (`packages/theme`)

Choice: a plain typed contract over CSS custom properties, not vanilla-extract.
- `contractShape` lists every key a component may use; `contract` maps each to `var(--ds-...)`. Zero runtime, no inline
  style, CSP-safe: the output is one static CSS file.
- vanilla-extract was rejected for now: it needs a bundler plugin in the test, build and Storybook pipelines (a second
  compile step for tests and a bigger install) to give what a typed object plus a test already gives. Its compile-time
  "theme misses a key" guarantee is replaced here by a test (the practices note flags that behaviour as unverified).
  Revisit if components move to `.css.ts` styling.
- Compile-time: `ContractPath extends TokenPath` is asserted, so a key that names no token fails `tsc`.
- Test-time: contract keys equal each theme's keys (missing or extra fails), every theme value equals the token value for
  its mode, every semantic colour token is in the contract, and theme sources contain no hex/rgb/hsl literal.
- Typography styles are not in the contract: consume `--ds-typography-<style>-<property>` from the tokens CSS.

## Slot

`<SCOPE>` as a literal token cannot be a pnpm dependency name, so the module uses the literal `ds-scope`
(`@ds-scope/tokens`, `@ds-scope/theme`) and `module.json` declares it as slot `SCOPE` (npm scope without `@`, e.g. `acme`). Assembly replaces the literal.

## Stubs and limits

Contrast is checked for opaque colour pairs only; translucent colours (alpha steps, scrim, shadows) are excluded by design.
Large-text pairings are supported by the schema (`kind: large`, 3:1) but none is declared yet.
