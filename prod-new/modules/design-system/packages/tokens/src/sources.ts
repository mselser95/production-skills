import dimensions from './json/dimensions.json' with { type: 'json' };
import semantic from './json/color.semantic.json' with { type: 'json' };
import primitives from './json/primitives.json' with { type: 'json' };
import typography from './json/typography.composition.json' with { type: 'json' };
import type { ContrastPair, RawSources } from './types.ts';

export const sources: RawSources = {
  primitives,
  dimensions,
  typography,
  semantic: { light: semantic.light, dark: semantic.dark },
};

export const contrastPairs: readonly ContrastPair[] = semantic.$extensions['contrast.pairs'] as readonly ContrastPair[];

export const rawJson = { primitives, dimensions, typography, semantic } as const;
