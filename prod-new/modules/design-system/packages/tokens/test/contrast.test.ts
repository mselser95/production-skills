// provenance: candidate; ttl: 2027-06-30; subject: WCAG 2.x contrast formula and the declared semantic pairings
import { describe, expect, it } from 'vitest';
import { built, cssValue, contrastPairs, contrastRatio, relativeLuminance, MODES } from '../src/index.ts';

describe('contrast formula (known values)', () => {
  it('black on white is 21:1 in both orders', () => {
    expect(contrastRatio('#000000', '#ffffff')).toBeCloseTo(21, 10);
    expect(contrastRatio('#ffffff', '#000000')).toBeCloseTo(21, 10);
  });
  it('a colour on itself is 1:1', () => {
    expect(contrastRatio('#336699', '#336699')).toBeCloseTo(1, 10);
  });
  it('#767676 on white is the well known 4.54:1 and #777777 falls just under 4.5', () => {
    expect(contrastRatio('#767676', '#ffffff')).toBeCloseTo(4.54, 2);
    expect(contrastRatio('#777777', '#ffffff')).toBeLessThan(4.5);
  });
  it('luminance anchors: white 1, black 0, pure red 0.2126', () => {
    expect(relativeLuminance('#ffffff')).toBeCloseTo(1, 10);
    expect(relativeLuminance('#000000')).toBe(0);
    expect(relativeLuminance('#ff0000')).toBeCloseTo(0.2126, 4);
  });
  it('refuses a translucent colour: it has no fixed ratio', () => {
    expect(() => contrastRatio('#00000066', '#ffffff')).toThrow(/translucent/);
  });
});

describe('declared semantic pairings hold in every theme', () => {
  it('declares a meaningful number of pairings', () => {
    expect(contrastPairs.length).toBeGreaterThanOrEqual(40);
  });
  for (const mode of MODES) {
    describe(mode, () => {
      for (const pair of contrastPairs) {
        it(`${pair.fg} on ${pair.bg} >= ${pair.min}:1 (${pair.kind})`, () => {
          const fg = built.themes[mode][pair.fg];
          const bg = built.themes[mode][pair.bg];
          expect(fg, `${pair.fg} missing in ${mode}`).toBeDefined();
          expect(bg, `${pair.bg} missing in ${mode}`).toBeDefined();
          const ratio = contrastRatio(cssValue(fg!), cssValue(bg!));
          expect(ratio, `${mode}: ${pair.fg} on ${pair.bg} is ${ratio.toFixed(2)}:1`).toBeGreaterThanOrEqual(pair.min);
        });
      }
    });
  }
  it('uses only the WCAG thresholds (4.5 body, 3 large or UI)', () => {
    for (const p of contrastPairs) expect(p.kind === 'body' ? p.min : 3).toBe(p.kind === 'body' ? 4.5 : p.min);
    for (const p of contrastPairs) expect([3, 4.5]).toContain(p.min);
  });
});
