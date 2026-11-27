import type { rawJson } from './sources.ts';

type J = typeof rawJson;

type Leaves<T, P extends string = ''> = T extends { readonly $value: unknown }
  ? P
  : T extends object
    ? { [K in keyof T & string]: K extends `$${string}` ? never : Leaves<T[K], P extends '' ? K : `${P}.${K}`> }[keyof T & string]
    : never;

/** Every semantic colour path, derived from the JSON itself (no build step needed). */
export type SemanticColorPath = Leaves<J['semantic']['light']>;
export type SharedPath = Leaves<J['primitives']> | Leaves<J['dimensions']> | Leaves<J['typography']>;
export type DimensionPath = Leaves<J['dimensions']>;
export type TokenPath = SemanticColorPath | SharedPath;
