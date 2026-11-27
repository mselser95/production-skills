import { cssVarName } from '@ds-scope/tokens';
import type { DimensionPath, SemanticColorPath, SharedPath } from '@ds-scope/tokens';

/**
 * The theme contract: the exact set of values a component may consume. Leaves are `null` here and
 * become `var(--ds-...)` references in `contract`. Adding a key means adding it here (and in the
 * tokens); a theme that does not fill it fails the contract test.
 */
export const contractShape = {
  color: {
    text: {
      primary: null,
      secondary: null,
      muted: null,
      disabled: null,
      inverse: null,
      link: null,
      linkHover: null,
      onAction: null,
      positive: null,
      negative: null,
      caution: null,
    },
    surface: {
      page: null,
      raised: null,
      sunken: null,
      overlay: null,
      inverse: null,
      hover: null,
      pressed: null,
      selected: null,
      disabled: null,
    },
    border: {
      subtle: null,
      default: null,
      strong: null,
      focus: null,
      disabled: null,
    },
    action: {
      primary: {
        default: null,
        hover: null,
        pressed: null,
        disabled: null,
      },
      secondary: {
        default: null,
        hover: null,
        pressed: null,
        disabled: null,
      },
      destructive: {
        default: null,
        hover: null,
        pressed: null,
        disabled: null,
      },
    },
    feedback: {
      info: {
        bg: null,
        border: null,
        text: null,
      },
      positive: {
        bg: null,
        border: null,
        text: null,
      },
      negative: {
        bg: null,
        border: null,
        text: null,
      },
      caution: {
        bg: null,
        border: null,
        text: null,
      },
    },
    overlay: {
      scrim: null,
    },
  },
  fontSize: {
    "2xs": null,
    xs: null,
    sm: null,
    md: null,
    lg: null,
    xl: null,
    "2xl": null,
    "3xl": null,
    "4xl": null,
    "5xl": null,
  },
  lineHeight: {
    none: null,
    tight: null,
    snug: null,
    normal: null,
    relaxed: null,
  },
  letterSpacing: {
    tight: null,
    normal: null,
    wide: null,
    caps: null,
  },
  space: {
    inset: {
      xs: null,
      sm: null,
      md: null,
      lg: null,
      xl: null,
    },
    stack: {
      xs: null,
      sm: null,
      md: null,
      lg: null,
      xl: null,
    },
    inline: {
      xs: null,
      sm: null,
      md: null,
      lg: null,
    },
  },
  radius: {
    none: null,
    sm: null,
    md: null,
    lg: null,
    xl: null,
    full: null,
  },
  borderWidth: {
    thin: null,
    medium: null,
    thick: null,
  },
  controlHeight: {
    sm: null,
    md: null,
    lg: null,
    xl: null,
  },
  zIndex: {
    base: null,
    raised: null,
    sticky: null,
    dropdown: null,
    overlay: null,
    modal: null,
    toast: null,
    tooltip: null,
  },
  motion: {
    duration: {
      instant: null,
      fast: null,
      base: null,
      slow: null,
      slower: null,
    },
    easing: {
      standard: null,
      enter: null,
      exit: null,
      linear: null,
    },
  },
  shadow: {
    sm: null,
    md: null,
    lg: null,
    xl: null,
  },
  font: {
    family: {
      sans: null,
      serif: null,
      mono: null,
    },
    weight: {
      regular: null,
      medium: null,
      semibold: null,
      bold: null,
    },
  },
} as const;

type Shape = typeof contractShape;

export type ContractTree<T> = { readonly [K in keyof T]: T[K] extends null ? string : ContractTree<T[K]> };
export type ThemeContract = ContractTree<Shape>;

type Paths<T, P extends string = ''> = {
  [K in keyof T & string]: T[K] extends null ? (P extends '' ? K : `${P}.${K}`) : Paths<T[K], P extends '' ? K : `${P}.${K}`>;
}[keyof T & string];

/** Dotted path of every contract key, e.g. `color.text.primary`. */
export type ContractPath = Paths<Shape>;

/** Compile-time proof that every contract key names a real token (a typo fails `tsc`). */
type KnownToken = SemanticColorPath | DimensionPath | SharedPath;
export const contractKeysAreTokens: ContractPath extends KnownToken ? true : never = true;

function build<T extends object>(shape: T, prefix: string): ContractTree<T> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(shape)) {
    const path = prefix === '' ? k : `${prefix}.${k}`;
    out[k] = v === null ? `var(${cssVarName(path)})` : build(v as object, path);
  }
  return out as ContractTree<T>;
}

export function createThemeContract<T extends object>(shape: T): ContractTree<T> {
  return build(shape, '');
}

/** What components consume: `contract.color.text.primary === 'var(--ds-color-text-primary)'`. */
export const contract: ThemeContract = createThemeContract(contractShape);

/** Dotted paths of every leaf of a shape or contract tree, in declaration order. */
export function leafPaths(tree: object, prefix = ''): string[] {
  return Object.entries(tree).flatMap(([k, v]) => {
    const path = prefix === '' ? k : `${prefix}.${k}`;
    return v !== null && typeof v === 'object' ? leafPaths(v as object, path) : [path];
  });
}

export const contractPaths = leafPaths(contractShape) as readonly ContractPath[];
