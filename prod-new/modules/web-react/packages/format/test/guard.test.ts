// provenance: candidate; ttl: 2027-06-30; subject: the package source contains no float-based number formatting or arithmetic on values
import { readFileSync, readdirSync } from 'node:fs';
import { describe, expect, it } from 'vitest';

// The package owns this guard for its OWN src/. The app-wide rule (no toFixed / toLocaleString / ad-hoc money outside
// this package) is the web app's eslint configuration, not this test.
//
// How it works: a small lexer (comments dropped by state, strings and template text blanked, template `${...}` code
// scanned, regex literals recognised) turns each source file into tokens, and the rules below run on the TOKENS, so a
// comment, a string or a line starting with `*` can neither hide a call nor fake one. There is no per-line escape
// marker: the one way to exempt something is an entry in ALLOW, which is DATA with an exact expected length, so an
// exemption is always a visible diff in this file.
//
// Rules (a finding is `file | kind | text`):
//   member    .toFixed .toPrecision .toExponential .toLocaleString .toString (any use)
//   call      parseFloat( parseInt( Number( String(      (Number.isInteger / isNaN / isSafeInteger are not calls of Number)
//   numparse  Number.parseFloat / Number.parseInt
//   math      Math.<anything>
//   unary     a prefix + (any operand) or a prefix - on a non-literal operand
//   arith     * / % ** and their compound assignments (text = the operator with its neighbours)
//   literal   a numeric literal with a fraction or exponent, or of ten or more digits (a float sample or a big sample)
// Not flagged on purpose: binary + and - (index arithmetic and string concatenation are everywhere, and neither can
// format a decimal), ++ / --, integer literals below ten digits (fixed samples such as 1, -1, 1000).

export interface Token {
  readonly kind: 'id' | 'num' | 'str' | 'tpl' | 'regex' | 'punct';
  readonly text: string;
  readonly line: number;
}

const PUNCT = ['>>>=', '**=', '...', '===', '!==', '<<=', '>>=', '>>>', '&&=', '||=', '??=', '=>', '==', '!=', '<=', '>=', '&&', '||', '??', '?.', '++', '--', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<', '>>', '**'];
const ID_START = /[A-Za-z_$]/;
const ID_PART = /[A-Za-z0-9_$]/;
const KEYWORDS_BEFORE_REGEX = new Set(['return', 'typeof', 'case', 'in', 'of', 'delete', 'void', 'throw', 'new', 'instanceof', 'else', 'do']);

export function lex(src: string): Token[] {
  const out: Token[] = [];
  let i = 0;
  let line = 1;
  // context stack: 'code' with its brace depth, or 'tpl' (inside template text)
  const stack: { mode: 'code' | 'tpl'; depth: number }[] = [{ mode: 'code', depth: 0 }];
  const push = (kind: Token['kind'], text: string): void => void out.push({ kind, text, line });
  const prevAllowsRegex = (): boolean => {
    const p = out[out.length - 1];
    if (p === undefined) return true;
    if (p.kind === 'punct') return ![')', ']', '}'].includes(p.text);
    if (p.kind === 'id') return KEYWORDS_BEFORE_REGEX.has(p.text);
    return false;
  };
  // Read template text from i (just after the opening backtick or a closing `}` of a substitution).
  const templateText = (): void => {
    let text = '';
    while (i < src.length) {
      const c = src[i] ?? '';
      if (c === '\\') { i += 2; continue; }
      if (c === '`') { i++; push('tpl', text); stack.pop(); return; }
      if (c === '$' && src[i + 1] === '{') { i += 2; push('tpl', text); stack.push({ mode: 'code', depth: 0 }); return; }
      if (c === '\n') line++;
      text += ' ';
      i++;
    }
  };
  while (i < src.length) {
    const top = stack[stack.length - 1];
    if (top === undefined) break;
    if (top.mode === 'tpl') { templateText(); continue; }
    const c = src[i] ?? '';
    const two = src.slice(i, i + 2);
    if (c === '\n') { line++; i++; continue; }
    if (c === ' ' || c === '\t' || c === '\r') { i++; continue; }
    if (two === '//') { while (i < src.length && src[i] !== '\n') i++; continue; }
    if (two === '/*') {
      i += 2;
      while (i < src.length && src.slice(i, i + 2) !== '*/') { if (src[i] === '\n') line++; i++; }
      i += 2;
      continue;
    }
    if (c === '"' || c === "'") {
      let j = i + 1;
      while (j < src.length && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1;
      push('str', ' '.repeat(Math.max(0, j - i - 1)));
      i = j + 1;
      continue;
    }
    if (c === '`') { i++; stack.push({ mode: 'tpl', depth: 0 }); continue; }
    if (c === '/' && prevAllowsRegex()) {
      let j = i + 1;
      let inClass = false;
      while (j < src.length && (src[j] !== '/' || inClass) && src[j] !== '\n') {
        if (src[j] === '\\') j++;
        else if (src[j] === '[') inClass = true;
        else if (src[j] === ']') inClass = false;
        j++;
      }
      j++;
      while (j < src.length && ID_PART.test(src[j] ?? '')) j++;
      push('regex', '/re/');
      i = j;
      continue;
    }
    if (ID_START.test(c)) {
      let j = i + 1;
      while (j < src.length && ID_PART.test(src[j] ?? '')) j++;
      push('id', src.slice(i, j));
      i = j;
      continue;
    }
    if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(src[i + 1] ?? ''))) {
      let j = i + 1;
      while (j < src.length && (/[0-9A-Za-z_.]/.test(src[j] ?? '') || ((src[j] === '+' || src[j] === '-') && /[eE]/.test(src[j - 1] ?? '') && !/^0[xX]/.test(src.slice(i, j))))) j++;
      push('num', src.slice(i, j));
      i = j;
      continue;
    }
    if (c === '{') { top.depth++; push('punct', c); i++; continue; }
    if (c === '}') {
      if (top.depth === 0 && stack.length > 1) { stack.pop(); i++; continue; } // end of a `${...}`: back to template text
      top.depth--;
      push('punct', c);
      i++;
      continue;
    }
    const p = PUNCT.find((x) => src.startsWith(x, i)) ?? c;
    push('punct', p);
    i += p.length;
  }
  return out;
}

export interface Finding {
  readonly kind: string;
  readonly text: string;
  readonly line: number;
}

const MEMBERS = new Set(['toFixed', 'toPrecision', 'toExponential', 'toLocaleString', 'toString']);
const CALLS = new Set(['parseFloat', 'parseInt', 'Number', 'String']);
const ARITH = new Set(['*', '/', '%', '**', '*=', '/=', '%=', '**=']);
const CLOSERS = new Set([')', ']', '}']);

export function scan(source: string): Finding[] {
  const t = lex(source);
  const found: Finding[] = [];
  const add = (kind: string, text: string, line: number): void => void found.push({ kind, text, line });
  t.forEach((tok, i) => {
    const prev = t[i - 1];
    const next = t[i + 1];
    if (tok.kind === 'id') {
      if (prev?.kind === 'punct' && (prev.text === '.' || prev.text === '?.') && MEMBERS.has(tok.text)) add('member', '.' + tok.text, tok.line);
      const isMember = prev?.kind === 'punct' && (prev.text === '.' || prev.text === '?.');
      if (!isMember && CALLS.has(tok.text) && next?.text === '(') add('call', tok.text + '(', tok.line);
      if (!isMember && tok.text === 'Number' && next?.text === '.' && /^parse/.test(t[i + 2]?.text ?? '')) add('numparse', 'Number.' + (t[i + 2]?.text ?? ''), tok.line);
      if (!isMember && tok.text === 'Math' && next?.text === '.') add('math', 'Math.' + (t[i + 2]?.text ?? ''), tok.line);
    } else if (tok.kind === 'num') {
      if (/[.eE]/.test(tok.text) && !/^0[xX]/.test(tok.text)) add('literal', tok.text, tok.line);
      else if (tok.text.replace(/_/g, '').length >= 10) add('literal', tok.text, tok.line);
    } else if (tok.kind === 'punct') {
      const binary = prev !== undefined && (prev.kind !== 'punct' || CLOSERS.has(prev.text)) && !(prev.kind === 'id' && KEYWORDS_BEFORE_REGEX.has(prev.text));
      if ((tok.text === '+' || tok.text === '-') && !binary) {
        if (tok.text === '+' || next?.kind !== 'num') add('unary', tok.text + (next?.text ?? ''), tok.line);
      }
      if (ARITH.has(tok.text) && binary) add('arith', `${prev?.text ?? ''} ${tok.text} ${next?.text ?? ''}`, tok.line);
    }
  });
  return found;
}

// The ONLY exemptions. Matching consumes one entry per finding; an entry that matches nothing fails, and so does a
// finding no entry covers. Adding an exemption therefore changes this list AND ALLOW_COUNT: a visible diff.
export interface Allowed {
  readonly file: string;
  readonly kind: string;
  readonly text: string;
  readonly why: string;
}
export const ALLOW: readonly Allowed[] = [
  { file: 'locale.ts', kind: 'literal', text: '1234567890123', why: 'fixed sample: learns grouping sizes from Intl, the value itself never enters Intl' },
  { file: 'locale.ts', kind: 'literal', text: '1.5', why: 'fixed sample: learns the decimal separator from Intl' },
  { file: 'locale.ts', kind: 'math', text: 'Math.max', why: 'integer index arithmetic (slice bounds)' },
  { file: 'locale.ts', kind: 'math', text: 'Math.max', why: 'integer index arithmetic (slice bounds)' },
  { file: 'number.ts', kind: 'math', text: 'Math.min', why: 'integer digit-count bounds' },
  { file: 'number.ts', kind: 'math', text: 'Math.max', why: 'integer digit-count bounds' },
  { file: 'number.ts', kind: 'call', text: 'String(', why: 'a safe integer (Number.isSafeInteger checked on the line above) as digits' },
  { file: 'number.ts', kind: 'member', text: '.toString', why: 'a bigint as digits' },
  { file: 'date.ts', kind: 'arith', text: 'n * 10', why: 'integer digit accumulation of a regex-validated ASCII digit run' },
  { file: 'date.ts', kind: 'arith', text: 'year % 4', why: 'leap-year rule on a validated integer year' },
  { file: 'date.ts', kind: 'arith', text: 'year % 100', why: 'leap-year rule on a validated integer year' },
  { file: 'date.ts', kind: 'arith', text: 'year % 400', why: 'leap-year rule on a validated integer year' },
  { file: 'date.ts', kind: 'arith', text: 'sign * (', why: 'offset sign times whole minutes' },
  { file: 'date.ts', kind: 'arith', text: 'offH * 60', why: 'offset hours to minutes (integers)' },
  { file: 'date.ts', kind: 'arith', text: ') * 60000', why: 'offset minutes to milliseconds (integers)' },
  { file: 'round.ts', kind: 'arith', text: 'lastKept % 2', why: 'parity of one ASCII digit (half-even)' },
];
export const ALLOW_COUNT = 16;

/** Findings of `source` that no remaining allow entry covers, plus the allow entries left unused. */
export function judge(file: string, source: string, allow: Allowed[]): { open: string[] } {
  const open: string[] = [];
  for (const f of scan(source)) {
    const at = allow.findIndex((a) => a.file === file && a.kind === f.kind && a.text === f.text);
    if (at >= 0) allow.splice(at, 1);
    else open.push(`${file}:${f.line} ${f.kind} ${JSON.stringify(f.text)}`);
  }
  return { open };
}

const kinds = (s: string): string[] => scan(s).map((f) => `${f.kind}:${f.text}`);

describe('the source contains no float-based formatting or arithmetic on values', () => {
  const dir = new URL('../src/', import.meta.url);
  const files = readdirSync(dir).filter((f) => f.endsWith('.ts'));
  it('there are source files to scan (control)', () => {
    expect(files.length).toBeGreaterThanOrEqual(8);
  });
  it('every finding in src/ is covered by ALLOW, and every ALLOW entry is used', () => {
    const left = ALLOW.slice();
    const open: string[] = [];
    for (const f of files) open.push(...judge(f, readFileSync(new URL(f, dir), 'utf8'), left).open);
    expect(open).toEqual([]);
    expect(left.map((a) => `${a.file} ${a.kind} ${a.text}`)).toEqual([]);
  });
  it('ALLOW has exactly the expected number of entries (a new exemption must bump this, visibly)', () => {
    expect(ALLOW.length).toBe(ALLOW_COUNT);
  });
  it('no source line carries an escape marker', () => {
    for (const f of files) expect(readFileSync(new URL(f, dir), 'utf8'), f).not.toMatch(/format-guard-allow/);
  });

  it('the scanner finds each rule, wherever the code sits (control)', () => {
    expect(kinds('const a = x.toFixed(2);')).toEqual(['member:.toFixed']);
    expect(kinds('const a = x.toFixed(2)\n * 3;')).toEqual(['member:.toFixed', 'arith:) * 3']);
    expect(kinds('const a = Number(x);')).toEqual(['call:Number(']);
    expect(kinds('const a = parseFloat(x) + parseInt(y);')).toEqual(['call:parseFloat(', 'call:parseInt(']);
    expect(kinds('const a = Math.round(x);')).toEqual(['math:Math.round']);
    expect(kinds('const a = x.toLocaleString("en");')).toEqual(['member:.toLocaleString']);
    expect(kinds('const a = (+digits).toString();')).toEqual(['unary:+digits', 'member:.toString']);
    expect(kinds('const a = +digits;')).toEqual(['unary:+digits']);
    expect(kinds('const a = -digits;')).toEqual(['unary:-digits']);
    expect(kinds('const a = x * 100; const b = y / 3; const c = z ** 2; d *= 2;')).toEqual(['arith:x * 100', 'arith:y / 3', 'arith:z ** 2', 'arith:d *= 2']);
    expect(kinds('const a = 0.1; const b = 1e5; const c = 1234567890123;')).toEqual(['literal:0.1', 'literal:1e5', 'literal:1234567890123']);
    expect(kinds('const a = Number.parseFloat(x);')).toEqual(['numparse:Number.parseFloat']);
    expect(kinds('const s = `${x.toFixed(2)}`;')).toEqual(['member:.toFixed']);
    expect(kinds('const a = x?.toFixed(2);')).toEqual(['member:.toFixed']);
  });
  it('the scanner is not fooled: comments, strings, regex literals, a marker and a leading `*` hide nothing and fake nothing (control)', () => {
    expect(kinds('// x.toFixed(2)\n/* Number(x) */\n/*\n * Number(x)\n */')).toEqual([]);
    expect(kinds('const a = "x.toFixed(2)"; const b = \'Number(x)\'; const c = `Math.round(1.5)`;')).toEqual([]);
    expect(kinds('const a = x.toFixed(2); // format-guard-allow: test')).toEqual(['member:.toFixed']);
    expect(kinds('const a = x\n  * 2;\nconst b = y\n  .toFixed(2);')).toEqual(['arith:x * 2', 'member:.toFixed']);
    expect(kinds('const r = /^[0-9]+\\/x$/; const s = a ? b : c;')).toEqual([]);
    expect(kinds('const n = Number.isNaN(x) || Number.isInteger(x) || Number.isSafeInteger(x); i++; j--; const k = a + b - 1; const l = -1;')).toEqual([]);
    expect(kinds('const t = `a ${b} c ${d ? `e ${f}` : ""} g`; const u = h.toFixed(1);')).toEqual(['member:.toFixed']);
  });
  it('the allow list is judged per file, kind and text, and an unused or extra entry is visible (control)', () => {
    const src = 'const a = x.toString();';
    const entry: Allowed = { file: 'f.ts', kind: 'member', text: '.toString', why: 't' };
    expect(judge('f.ts', src, [entry]).open).toEqual([]);
    expect(judge('g.ts', src, [entry]).open).toHaveLength(1);
    expect(judge('f.ts', src, []).open).toHaveLength(1);
    const twice = [entry];
    judge('f.ts', src + src, twice);
    expect(twice).toHaveLength(0);
  });
});
