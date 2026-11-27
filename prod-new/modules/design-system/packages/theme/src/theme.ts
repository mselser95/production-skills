import { built, cssValue, cssVarName } from '@ds-scope/tokens';
import type { Mode } from '@ds-scope/tokens';
import { contractPaths } from './contract.ts';
import type { ContractPath } from './contract.ts';

/** A theme: one CSS value for every contract key. */
export type Theme = Readonly<Record<ContractPath, string>>;

export interface ThemeResolution {
  readonly values: Partial<Record<ContractPath, string>>;
  /** Contract keys the tokens do not provide for this mode. */
  readonly missing: readonly ContractPath[];
}

/** Read every contract key from the tokens; report (do not hide) the ones that are absent. */
export function resolveTheme(mode: Mode): ThemeResolution {
  const values: Partial<Record<ContractPath, string>> = {};
  const missing: ContractPath[] = [];
  for (const path of contractPaths) {
    const token = built.themes[mode][path] ?? built.shared[path];
    if (token === undefined) missing.push(path);
    else values[path] = cssValue(token);
  }
  return { values, missing };
}

/** Same as resolveTheme but refuses to return an incomplete theme. */
export function createTheme(mode: Mode): Theme {
  const { values, missing } = resolveTheme(mode);
  if (missing.length > 0) throw new Error(`theme "${mode}" is missing contract keys: ${missing.join(', ')}`);
  return values as Theme;
}

/** `--ds-...: value;` declarations of a theme, in contract order. */
export function themeDeclarations(theme: Theme): readonly (readonly [string, string])[] {
  return contractPaths.map((p) => [cssVarName(p), theme[p]] as const);
}
