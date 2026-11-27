import { TokenError } from './types.ts';
import type { BuiltTokens, Layer, Mode, RawSources, ResolvedToken, TokenNode, TokenTable } from './types.ts';

interface RawLeaf {
  readonly path: string;
  readonly type: string;
  readonly layer: Layer;
  readonly value: unknown;
}

const ALIAS = /^\{([^{}]+)\}$/;
const EMBEDDED = /[{}]/;

function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** Walk a group, inheriting `$type` from the nearest ancestor (DTCG rule). */
export function flatten(root: TokenNode, layer: Layer, into: Map<string, RawLeaf> = new Map()): Map<string, RawLeaf> {
  const walk = (node: Record<string, unknown>, prefix: string, inherited: string | undefined): void => {
    const own = node['$type'];
    const type = typeof own === 'string' ? own : inherited;
    for (const [key, child] of Object.entries(node)) {
      if (key.startsWith('$') || !isObject(child)) continue;
      const path = prefix === '' ? key : `${prefix}.${key}`;
      if ('$value' in child) {
        const leafType = typeof child['$type'] === 'string' ? child['$type'] : type;
        if (leafType === undefined) throw new TokenError(`token ${path} has no $type (own or inherited)`);
        if (into.has(path)) throw new TokenError(`duplicate token path ${path}`);
        into.set(path, { path, type: leafType, layer, value: child['$value'] });
      } else {
        walk(child, path, type);
      }
    }
  };
  walk(root as Record<string, unknown>, '', undefined);
  return into;
}

function resolveTable(own: Map<string, RawLeaf>, shared: Map<string, RawLeaf>, label: string): TokenTable {
  const cache = new Map<string, unknown>();

  const lookup = (path: string): RawLeaf | undefined => own.get(path) ?? shared.get(path);

  const resolvePath = (path: string, stack: readonly string[], from: string): unknown => {
    if (stack.includes(path)) {
      throw new TokenError(`alias cycle in ${label}: ${[...stack, path].join(' -> ')}`);
    }
    if (cache.has(path)) return cache.get(path);
    const leaf = lookup(path);
    if (leaf === undefined) throw new TokenError(`dangling alias {${path}} referenced from ${from} (${label})`);
    const value = resolveValue(leaf.value, [...stack, path], path);
    cache.set(path, value);
    return value;
  };

  const resolveValue = (value: unknown, stack: readonly string[], from: string): unknown => {
    if (typeof value === 'string') {
      const m = ALIAS.exec(value);
      if (m !== null) return resolvePath(m[1] as string, stack, from);
      if (EMBEDDED.test(value)) throw new TokenError(`malformed or embedded alias "${value}" in ${from} (${label})`);
      return value;
    }
    if (Array.isArray(value)) return value.map((v) => resolveValue(v, stack, from));
    if (isObject(value)) {
      return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, resolveValue(v, stack, from)]));
    }
    return value;
  };

  const out: Record<string, ResolvedToken> = {};
  for (const leaf of own.values()) {
    out[leaf.path] = { path: leaf.path, type: leaf.type, layer: leaf.layer, value: resolvePath(leaf.path, [], leaf.path) };
  }
  return out;
}

/** Resolve every alias in every layer; throws TokenError on a cycle or a dangling reference. */
export function buildTokens(sources: RawSources): BuiltTokens {
  const shared = new Map<string, RawLeaf>();
  flatten(sources.primitives, 'primitive', shared);
  flatten(sources.dimensions, 'dimension', shared);
  flatten(sources.typography, 'typography', shared);
  const noOwn = new Map<string, RawLeaf>();
  const sharedTable = resolveTable(shared, noOwn, 'shared');
  const themes = {} as Record<Mode, TokenTable>;
  for (const mode of ['light', 'dark'] as const) {
    const own = flatten(sources.semantic[mode], 'semantic');
    for (const path of own.keys()) {
      if (shared.has(path)) throw new TokenError(`semantic token ${path} (${mode}) collides with a shared token`);
    }
    themes[mode] = resolveTable(own, shared, mode);
  }
  return { shared: sharedTable, themes };
}

/** Every `{alias}` string found anywhere in a raw tree (used by tests as an independent check). */
export function collectAliases(node: unknown, into: string[] = []): string[] {
  if (typeof node === 'string') {
    const m = ALIAS.exec(node);
    if (m !== null) into.push(m[1] as string);
  } else if (Array.isArray(node)) {
    for (const v of node) collectAliases(v, into);
  } else if (isObject(node)) {
    for (const [k, v] of Object.entries(node)) if (k !== '$description') collectAliases(v, into);
  }
  return into;
}
