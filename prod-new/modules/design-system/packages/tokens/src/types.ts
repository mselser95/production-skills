/** A DTCG token tree: groups of groups ending in leaves that carry `$value`. */
export type TokenNode = { readonly [key: string]: unknown };

export type Layer = 'primitive' | 'semantic' | 'typography' | 'dimension';

export type Mode = 'light' | 'dark';

export const MODES: readonly Mode[] = ['light', 'dark'];

/** Declared text-on-surface pairing the contrast test must hold. */
export interface ContrastPair {
  readonly fg: string;
  readonly bg: string;
  readonly min: number;
  readonly kind: 'body' | 'large' | 'ui';
}

export interface RawSources {
  readonly primitives: TokenNode;
  readonly dimensions: TokenNode;
  readonly typography: TokenNode;
  readonly semantic: { readonly light: TokenNode; readonly dark: TokenNode };
}

export interface ResolvedToken {
  readonly path: string;
  readonly type: string;
  readonly layer: Layer;
  /** The value with every alias replaced (still structured for composites). */
  readonly value: unknown;
}

export type TokenTable = Readonly<Record<string, ResolvedToken>>;

export interface BuiltTokens {
  /** Theme independent tokens: primitives, dimensions, typography. */
  readonly shared: TokenTable;
  /** Semantic colours per theme. */
  readonly themes: { readonly light: TokenTable; readonly dark: TokenTable };
}

export class TokenError extends Error {
  override readonly name = 'TokenError';
}
