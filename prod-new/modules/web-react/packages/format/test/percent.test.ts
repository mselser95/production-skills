// provenance: candidate; ttl: 2027-06-30; subject: formatPercent shift by string arithmetic, rounding, patterns; pinning: true
import { describe, expect, it } from 'vitest';
import { formatDecimal, formatPercent } from '../src/index.ts';
import type { FormatResult, FractionOptions } from '../src/index.ts';

const text = (r: FormatResult): string => (r.ok ? r.text : 'ERR:' + r.reason);
const pct = (v: string, o: Partial<FractionOptions> = {}): string => text(formatPercent(v, { locale: 'en-US', ...o }));

describe('formatPercent', () => {
  it.each([
    ['0.1234', '12.34%'],
    ['0.12345', '12.35%'],
    ['1', '100%'],
    ['0', '0%'],
    ['12', '1,200%'],
    ['0.005', '0.5%'],
    ['0.00005', '0.01%'],
    ['0.000049', '0%'],
    ['-0.1234', '-12.34%'],
    ['-0.00004', '0%'],
    ['-0', '0%'],
    ['0.995', '99.5%'],
    ['0.99995', '100%'],
    ['1.5', '150%'],
    ['123456789012345678901234567890', '12,345,678,901,234,567,890,123,456,789,000%'],
    ['0.123456789012345678', '12.35%'],
  ])('%s -> %s', (v, want) => expect(pct(v)).toBe(want));
  it('digit options and rounding', () => {
    expect(pct('0.5', { minFractionDigits: 2, maxFractionDigits: 2 })).toBe('50.00%');
    expect(pct('0.125', { maxFractionDigits: 0 })).toBe('13%');
    expect(pct('0.125', { maxFractionDigits: 0, rounding: 'half-even' })).toBe('12%');
    expect(pct('0.12999', { maxFractionDigits: 0, rounding: 'trunc' })).toBe('12%');
    expect(pct('0.995', { maxFractionDigits: 0 })).toBe('100%');
  });
  it('signDisplay always', () => {
    expect(pct('0.1', { signDisplay: 'always' })).toBe('+10%');
    expect(pct('0', { signDisplay: 'always' })).toBe('0%');
  });
  it('the percent sign and spacing are the locale own', () => {
    expect(pct('0.1234', { locale: 'de-DE' })).toBe('12,34\u00a0%');
    expect(pct('0.1234', { locale: 'fr-FR' })).toBe('12,34\u00a0%');
    expect(pct('0.1234', { locale: 'tr-TR' })).toBe('%12,34');
    expect(pct('-0.1234', { locale: 'tr-TR' })).toBe('-%12,34');
  });
  it('agrees with Intl on exactly representable ratios', () => {
    for (const locale of ['en-US', 'de-DE', 'fr-FR', 'tr-TR', 'ar-EG', 'en-IN']) {
      const nf = new Intl.NumberFormat(locale, { style: 'percent', numberingSystem: 'latn', maximumFractionDigits: 2 });
      for (const v of ['0.5', '-0.5', '0.1234', '1', '12.5', '0.0001']) expect(pct(v, { locale }), `${locale} ${v}`).toBe(nf.format(v as never));
    }
  });
  it.each(['1e-2', '12%', 'NaN', '', ' 0.1', '.1', '1.', '0,5'])('invalid ratio %j', (v) => {
    expect(pct(v)).toMatch(/^ERR:(not-a-decimal|empty)$/);
  });
  it('bad options / locale / too long', () => {
    expect(pct('0.1', { maxFractionDigits: 99 })).toBe('ERR:bad-options');
    expect(pct('0.1', { locale: 'tlh' })).toBe('ERR:bad-locale');
    expect(pct('1'.repeat(500))).toBe('ERR:too-long');
    expect(text(formatPercent('1', undefined as never))).toBe('ERR:bad-options');
  });
});

describe('percent separators are the percent style own', () => {
  it('equals Intl in 33 locales on exactly representable ratios (a failure prints both strings)', () => {
    const locales = 'en-US en-GB en-IN en-CH de-DE de-AT de-CH de-LI fr-FR fr-CH fr-BE fr-CA es-ES es-AR es-MX pt-BR pt-PT it-IT it-CH nl-NL nl-BE sv-SE nb-NO da-DK fi-FI pl-PL cs-CZ hu-HU ru-RU tr-TR ja-JP ko-KR zh-CN'.split(' ');
    const bad: string[] = [];
    for (const locale of locales) {
      const nf = new Intl.NumberFormat(locale, { style: 'percent', numberingSystem: 'latn', maximumFractionDigits: 2, roundingMode: 'halfExpand' });
      for (const v of ['0', '0.5', '-0.5', '0.1234', '12345.6789', '-12345.6789', '123456.5', '0.0001']) {
        const got = pct(v, { locale });
        const want = nf.format(v as never);
        if (got !== want) bad.push(`${locale} ${v}: package ${JSON.stringify(got)} intl ${JSON.stringify(want)}`);
      }
    }
    expect(bad.slice(0, 10), `${bad.length} mismatches`).toEqual([]);
  });
});

// Percent learns its OWN grouping sizes and its own minimum grouping (CLDR keeps them apart from the plain-number ones).
describe('percent grouping is the percent style own (not the plain-number one)', () => {
  const nbsp = ' ';
  it.each([
    // CLDR's percent pattern groups by 3 where the decimal pattern groups Indian-style (6+ displayed integer digits)
    ['mr-IN', '1234.5678', '123,456.78%'],
    ['ml-IN', '1234.5678', '123,456.78%'],
    ['ne-NP', '1234.5678', '123,456.78%'],
    ['or-IN', '1234.5678', '123,456.78%'],
    ['te-IN', '1234.5678', '123,456.78%'],
    ['mr-IN', '12345.5', '1,234,550%'],
    ['te-IN', '12345.5', '1,234,550%'],
    // minimum grouping is learned from a DISPLAYED four- and five-digit percent: 12.34 shows 1234%, 123.45 shows 12345%
    ['es-ES', '12.34', `1234${nbsp}%`],
    ['es-ES', '123.45', `12.345${nbsp}%`],
    ['hu-HU', '12.34', '1234%'],
    ['hu-HU', '123.45', `12${nbsp}345%`],
    ['bg-BG', '12.34', '1234%'],
    ['bg-BG', '123.45', `12${nbsp}345%`],
    ['et-EE', '12.34', '1234%'],
    ['et-EE', '123.45', `12${nbsp}345%`],
    ['be-BY', '12.34', `1234${nbsp}%`],
    ['be-BY', '123.45', `12${nbsp}345${nbsp}%`],
  ])('%s %s -> %j', (locale, v, want) => expect(pct(v, { locale })).toBe(want));
  it('the same Indian-grouped locale still groups plain decimals Indian-style (the two styles differ)', () => {
    expect(text(formatDecimal('1234567.5', { locale: 'mr-IN' }))).toBe('12,34,567.5');
    expect(pct('12345.675', { locale: 'mr-IN' })).toBe('1,234,567.5%');
  });
  it('equals Intl in 64 locales on displayed integer parts of 1 to 9 digits (a failure prints both strings)', () => {
    const locales = ('mr-IN ml-IN ne-NP or-IN te-IN es-ES hu-HU bg-BG et-EE be-BY en-US en-GB en-IN en-CH de-DE de-AT de-CH fr-FR fr-CH fr-CA es-MX es-AR pt-BR pt-PT it-IT nl-NL sv-SE nb-NO da-DK fi-FI pl-PL cs-CZ sk-SK ru-RU uk-UA tr-TR el-GR ro-RO hr-HR sl-SI lt-LT lv-LV ca-ES gl-ES eu-ES ja-JP ko-KR zh-CN zh-TW hi-IN bn-BD bn-IN ta-IN kn-IN gu-IN pa-IN as-IN ar-EG ar-SA he-IL fa-IR ur-PK th-TH vi-VN id-ID').split(' ');
    expect(locales.length).toBeGreaterThanOrEqual(60);
    const ratios: string[] = [];
    for (let n = 1; n <= 9; n++) {
      const shown = '987654321'.slice(0, n).padStart(3, '0'); // the displayed integer digits, as a ratio * 100
      const r = shown.slice(0, -2).replace(/^0+(?=[0-9])/, '') + '.' + shown.slice(-2);
      ratios.push(r, '-' + r, r + '5');
    }
    const bad: string[] = [];
    for (const locale of locales) {
      const nf = new Intl.NumberFormat(locale, { style: 'percent', numberingSystem: 'latn', minimumFractionDigits: 0, maximumFractionDigits: 2, roundingMode: 'halfExpand' });
      for (const v of ratios) {
        const got = pct(v, { locale });
        const want = nf.format(v as never); // a decimal STRING: Intl reads it exactly
        if (got !== want) bad.push(`${locale} ${v}: package ${JSON.stringify(got)} intl ${JSON.stringify(want)}`);
      }
    }
    expect(bad.slice(0, 10), `${bad.length} mismatches`).toEqual([]);
  });
});
