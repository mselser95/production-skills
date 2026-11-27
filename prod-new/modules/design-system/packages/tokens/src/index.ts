import { cssValue } from './emit.ts';
import { buildTokens } from './resolve.ts';
import { sources } from './sources.ts';
import type { DimensionPath, SemanticColorPath } from './paths.ts';
import type { Mode } from './types.ts';

export { contrastRatio, relativeLuminance, parseHex } from './contrast.ts';
export { cssValue, cssVarName, declarations, toCss, toJson, toTs, VAR_PREFIX } from './emit.ts';
export { buildTokens, collectAliases, flatten } from './resolve.ts';
export { contrastPairs, rawJson, sources } from './sources.ts';
export { MODES, TokenError } from './types.ts';
export type { DimensionPath, SemanticColorPath, SharedPath, TokenPath } from './paths.ts';
export type { BuiltTokens, TokenNode, ContrastPair, Layer, Mode, RawSources, ResolvedToken, TokenTable } from './types.ts';

/** The tokens built from this package's own JSON sources. */
export const built = buildTokens(sources);

/** CSS value of a semantic colour in one theme. Typed by path: a typo fails `tsc`. */
export function semanticValue(mode: Mode, path: SemanticColorPath): string | undefined {
  const t = built.themes[mode][path];
  return t === undefined ? undefined : cssValue(t);
}

/** CSS value of a theme independent dimension token. */
export function dimensionValue(path: DimensionPath): string {
  const t = built.shared[path];
  if (t === undefined) throw new Error(`no dimension token ${path}`);
  return cssValue(t);
}
