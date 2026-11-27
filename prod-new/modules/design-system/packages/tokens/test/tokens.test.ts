// provenance: candidate; ttl: 2027-06-30; subject: token sources, resolver, emitters
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import {
  MODES, TokenError, buildTokens, built, collectAliases, cssVarName, flatten, parseHex, rawJson, sources, toCss, toJson, toTs,
} from '../src/index.ts';
import type { RawSources, TokenNode } from '../src/index.ts';
import { writeDist } from '../scripts/build.ts';

const tiny = (over: Partial<RawSources> = {}): RawSources => ({
  primitives: { $type: 'color', a: { $value: '#000000' } },
  dimensions: {},
  typography: {},
  semantic: { light: { $type: 'color', x: { $value: '{a}' } }, dark: { $type: 'color', x: { $value: '{a}' } } },
  ...over,
});

describe('resolver', () => {
  it('resolves an alias chain', () => {
    const b = buildTokens(tiny({ primitives: { $type: 'color', a: { $value: '#000000' }, b: { $value: '{a}' }, c: { $value: '{b}' } } }));
    expect(b.shared['c']?.value).toBe('#000000');
  });
  it('a cycle is an error naming the loop', () => {
    const src = tiny({ primitives: { $type: 'color', a: { $value: '{b}' }, b: { $value: '{a}' } } });
    expect(() => buildTokens(src)).toThrow(/cycle.*a -> b -> a/);
  });
  it('a self reference is a cycle', () => {
    expect(() => buildTokens(tiny({ primitives: { $type: 'color', a: { $value: '{a}' } } }))).toThrow(TokenError);
  });
  it('a dangling alias is an error naming both ends', () => {
    const src = tiny({ semantic: { light: { $type: 'color', x: { $value: '{nope}' } }, dark: { $type: 'color', x: { $value: '{a}' } } } });
    expect(() => buildTokens(src)).toThrow(/dangling alias \{nope\} referenced from x/);
  });
  it('a token without any type is an error', () => {
    expect(() => flatten({ a: { $value: '#000000' } } as TokenNode, 'primitive')).toThrow(/no \$type/);
  });
  it('an embedded alias is rejected rather than half resolved', () => {
    expect(() => buildTokens(tiny({ primitives: { $type: 'color', a: { $value: 'x {b} y' }, b: { $value: '#000000' } } }))).toThrow(/embedded/);
  });
  it('a semantic token may not shadow a shared one', () => {
    expect(() => buildTokens(tiny({ semantic: { light: { $type: 'color', a: { $value: '#ffffff' } }, dark: { $type: 'color', a: { $value: '#ffffff' } } } }))).toThrow(/collides/);
  });
});

describe('the real sources', () => {
  it('every {alias} in every JSON file points at an existing token (independent scan)', () => {
    const known = new Set([...Object.keys(built.shared), ...Object.keys(built.themes.light), ...Object.keys(built.themes.dark)]);
    const all = Object.values(rawJson).flatMap((j) => collectAliases(j));
    expect(all.length).toBeGreaterThan(100);
    for (const a of all) expect(known.has(a), `dangling {${a}}`).toBe(true);
  });
  it('build succeeds, so no cycles', () => {
    expect(() => buildTokens(sources)).not.toThrow();
  });
  it('every semantic colour exists in BOTH themes, with the same set of keys', () => {
    const light = Object.keys(built.themes.light).sort();
    const dark = Object.keys(built.themes.dark).sort();
    expect(light.length).toBeGreaterThan(40);
    expect(dark).toEqual(light);
  });
  it('every colour token resolves to a hex colour', () => {
    for (const t of [...Object.values(built.shared), ...Object.values(built.themes.light), ...Object.values(built.themes.dark)]) {
      if (t.type === 'color') expect(t.value, t.path).toMatch(/^#[0-9a-f]{6}([0-9a-f]{2})?$/);
    }
  });
  it('semantic colours in each theme differ somewhere (dark is really dark)', () => {
    expect(built.themes.dark['color.surface.page']?.value).not.toBe(built.themes.light['color.surface.page']?.value);
  });
  it('declares between 200 and 260 leaf tokens', () => {
    // distinct token paths: a semantic colour counts once, it has a value in each theme
    const n = new Set([...Object.keys(built.shared), ...Object.keys(built.themes.light), ...Object.keys(built.themes.dark)]).size;
    expect(n).toBeGreaterThanOrEqual(200);
    expect(n).toBeLessThanOrEqual(260);
  });
  it('neutral and accent ramps get monotonically darker', () => {
    const lum = (hex: string): number => { const { r, g, b } = parseHex(hex); return r * 0.2126 + g * 0.7152 + b * 0.0722; };
    for (const ramp of ['neutral', 'accent', 'positive', 'negative', 'caution']) {
      const steps = Object.keys(built.shared).filter((p) => p.startsWith(`palette.${ramp}.`)).sort((a, b) => Number(a.split('.')[2]) - Number(b.split('.')[2]));
      const l = steps.map((p) => lum(String(built.shared[p]?.value)));
      for (let i = 1; i < l.length; i++) expect(l[i], `${ramp} step ${steps[i]}`).toBeLessThan(l[i - 1] as number);
    }
  });
  it('breakpoints are 360, 768 and 1280', () => {
    expect(['compact', 'medium', 'expanded'].map((k) => built.shared[`breakpoint.${k}`]?.value)).toEqual(['360px', '768px', '1280px']);
  });
  it('brand neutral: no company or product word in any source (generic colour names only)', () => {
    const text = Object.values(rawJson).map((j) => JSON.stringify(j)).join('\n');
    expect(text).not.toMatch(/brand|logo/i);
  });
});

describe('emitters', () => {
  it('css variable names are unique and kebab-cased', () => {
    const css = toCss(built);
    const names = [...css.matchAll(/^ {2}(--ds-[a-z0-9-]+):/gm)].map((m) => m[1] as string);
    expect(names.length).toBeGreaterThan(200);
    expect(cssVarName('color.text.onAction')).toBe('--ds-color-text-on-action');
    const shared = names.slice(0, names.indexOf('--ds-color-text-primary'));
    expect(new Set(shared).size).toBe(shared.length);
  });
  it('css matches the reviewed snapshot (a token change is a visible diff)', async () => {
    await expect(toCss(built)).toMatchFileSnapshot('./__snapshots__/tokens.css');
  });
  it('light and dark blocks are present, plus the OS preference block', () => {
    const css = toCss(built);
    expect(css).toContain('[data-theme="light"]');
    expect(css).toContain('[data-theme="dark"]');
    expect(css).toContain('prefers-color-scheme: dark');
  });
  it('the typed export names every semantic path and var reference', () => {
    const ts = toTs(built);
    expect(ts).toContain('"color.text.primary": "var(--ds-color-text-primary)"');
    expect(ts).toContain('export type SemanticTokenPath');
  });
  it('build is deterministic: in-memory twice and on disk twice', () => {
    const again = buildTokens(sources);
    expect([toCss(again), toJson(again), toTs(again)]).toEqual([toCss(built), toJson(built), toTs(built)]);
    const a = mkdtempSync(join(tmpdir(), 'ds-tok-a-'));
    const b = mkdtempSync(join(tmpdir(), 'ds-tok-b-'));
    try {
      writeDist(a);
      writeDist(b);
      for (const f of ['tokens.css', 'tokens.json', 'tokens.ts']) {
        expect(readFileSync(join(a, f)).equals(readFileSync(join(b, f))), f).toBe(true);
      }
    } finally {
      rmSync(a, { recursive: true, force: true });
      rmSync(b, { recursive: true, force: true });
    }
  });
  it('both modes are listed', () => {
    expect(MODES).toEqual(['light', 'dark']);
  });
});
