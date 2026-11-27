// provenance: candidate; ttl: 2027-06-30; subject: theme contract completeness and token provenance
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import { built, cssValue, declarations } from '@ds-scope/tokens';
import { contract, contractPaths, createTheme, dark, leafPaths, light, resolveTheme, themeDeclarations, toThemeCss } from '../src/index.ts';

const diff = (want: readonly string[], got: readonly string[]): { missing: string[]; extra: string[] } => ({
  missing: want.filter((k) => !got.includes(k)),
  extra: got.filter((k) => !want.includes(k)),
});

describe('contract and themes have exactly the same key set', () => {
  const keys = [...contractPaths].sort();
  it('the contract is non-trivial', () => {
    expect(keys.length).toBeGreaterThan(100);
    expect(new Set(keys).size).toBe(keys.length);
  });
  it('the nested contract object has the same leaves as the declared shape', () => {
    expect(leafPaths(contract).sort()).toEqual(keys);
  });
  for (const [name, theme] of [['light', light], ['dark', dark]] as const) {
    it(`${name}: no missing key, no extra key`, () => {
      expect(diff(keys, Object.keys(theme).sort())).toEqual({ missing: [], extra: [] });
    });
    it(`${name}: resolveTheme reports nothing missing`, () => {
      expect(resolveTheme(name).missing).toEqual([]);
    });
  }
  it('the diff helper really detects a missing and an extra key', () => {
    expect(diff(['a', 'b'], ['a', 'c'])).toEqual({ missing: ['b'], extra: ['c'] });
  });
  it('every semantic colour token is part of the contract (a new token must be added deliberately)', () => {
    const contractColours = keys.filter((k) => k.startsWith('color.'));
    expect(contractColours).toEqual(Object.keys(built.themes.light).sort());
  });
  it('createTheme refuses an incomplete theme instead of returning it', () => {
    const saved = built.themes.dark['color.text.primary'];
    expect(saved).toBeDefined();
    const mutable = built.themes.dark as Record<string, unknown>;
    delete mutable['color.text.primary'];
    try {
      expect(resolveTheme('dark').missing).toEqual(['color.text.primary']);
      expect(() => createTheme('dark')).toThrow(/missing contract keys: color\.text\.primary/);
    } finally {
      mutable['color.text.primary'] = saved;
    }
  });
});

describe('theme values come from the tokens package', () => {
  it('every theme value equals the token value for its mode', () => {
    for (const [mode, theme] of [['light', light], ['dark', dark]] as const) {
      for (const p of contractPaths) {
        const t = built.themes[mode][p] ?? built.shared[p];
        expect(theme[p], `${mode} ${p}`).toBe(cssValue(t!));
      }
    }
  });
  it('light and dark differ for colours and agree for dimensions', () => {
    expect(light['color.surface.page']).not.toBe(dark['color.surface.page']);
    expect(light['radius.md']).toBe(dark['radius.md']);
  });
  it('contract references use the same variable names the tokens CSS declares', () => {
    const tokenNames = new Set([...Object.values(built.shared), ...Object.values(built.themes.light)].flatMap((t) => declarations(t).map(([n]) => n)));
    for (const [, [name]] of themeDeclarations(light).entries()) expect(tokenNames.has(name), name).toBe(true);
    expect(contract.color.text.primary).toBe('var(--ds-color-text-primary)');
  });
  it('emitted theme CSS declares exactly the contract in light and in dark', () => {
    const css = toThemeCss(light, dark);
    for (const [n, v] of themeDeclarations(dark)) expect(css).toContain(`${n}: ${v};`);
    expect(css.match(/--ds-color-surface-page:/g)?.length).toBe(3);
  });
  it('theme sources hold no hard-coded colour literal (hex, rgb(a), hsl(a))', () => {
    const src = join(dirname(fileURLToPath(import.meta.url)), '..', 'src');
    const files: string[] = [];
    const walk = (d: string): void => {
      for (const e of readdirSync(d)) {
        const p = join(d, e);
        if (statSync(p).isDirectory()) walk(p);
        else if (p.endsWith('.ts')) files.push(p);
      }
    };
    walk(src);
    expect(files.length).toBeGreaterThanOrEqual(6);
    const literal = /#[0-9a-fA-F]{3,8}\b|\brgba?\s*\(|\bhsla?\s*\(/;
    for (const f of files) expect(readFileSync(f, 'utf8'), f).not.toMatch(literal);
  });
});
