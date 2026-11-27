/** WCAG 2.x relative luminance and contrast ratio, implemented from the definition. */

export interface Rgb {
  readonly r: number;
  readonly g: number;
  readonly b: number;
}

export function parseHex(hex: string): Rgb {
  const m = /^#([0-9a-f]{6})([0-9a-f]{2})?$/i.exec(hex);
  if (m === null) throw new Error(`not an opaque-capable hex colour: ${hex}`);
  if (m[2] !== undefined && m[2].toLowerCase() !== 'ff') throw new Error(`translucent colour has no fixed contrast: ${hex}`);
  const n = parseInt(m[1] as string, 16);
  return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 };
}

function channel(c8: number): number {
  const c = c8 / 255;
  return c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
}

export function relativeLuminance(hex: string): number {
  const { r, g, b } = parseHex(hex);
  return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b);
}

export function contrastRatio(fgHex: string, bgHex: string): number {
  const a = relativeLuminance(fgHex);
  const b = relativeLuminance(bgHex);
  const [hi, lo] = a >= b ? [a, b] : [b, a];
  return (hi + 0.05) / (lo + 0.05);
}
