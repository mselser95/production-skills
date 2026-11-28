// provenance: candidate; ttl: 2027-06-30; subject: the package source contains no float-based number formatting or arithmetic on values
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

// The package owns this guard for its OWN src/. The app-wide rule (no toFixed / toLocaleString / ad-hoc money outside
// this package) is the web app's eslint configuration, not this test.
//
// What it protects: the README's central claim, "number, money and percent values never reach Intl; Intl formats only
// fixed sample numbers (to learn a locale's symbols) and Date instants". A float anywhere in the path, or a value
// handed straight to Intl, would format money wrongly beyond 2^53 or at the rounding edge.
//
// How it works: a small lexer (comments dropped by state, strings and template text blanked, template `${...}` code
// scanned, regex literals recognised) turns each source file into tokens, and the rules below run on the TOKENS, so a
// comment, a string or a line starting with `*` can neither hide a call nor fake one. There is no per-line escape
// marker: the one way to exempt something is an entry in ALLOW, which is DATA carrying the file, the finding AND the
// full trimmed source LINE of its site, so swapping one use for another with the same token text changes a line and
// fails, and an entry whose line no longer exists fails. An exemption is always a visible diff in this file.
//
// Rules (a finding is `file | kind | text | line`):
//   member    .toFixed .toPrecision .toExponential .toLocaleString .toString .valueOf (any use)
//   call      parseFloat( parseInt( Number( String( isFinite( isNaN(   (Number.isInteger / Number.isNaN / isSafeInteger are not these)
//   numparse  Number.parseFloat / Number.parseInt
//   math      Math.<anything>
//   unary     a prefix + (any operand) or a prefix - on a non-literal operand: after an operator, an opener, a keyword such as
//             `return` / `await` / `yield`, a logical `!`, or the `)` of an if / while / for / with head (a postfix non-null `x!` is a value)
//   arith     * / % ** and their compound assignments (text = the operator with its neighbours); a generator's `function*` is not
//   bitwise   ~ ^ & << >> >>> and their compound assignments, and `|` next to a numeric literal (`x | 0`): each converts like `* 1`
//   coerce    a binary minus whose right operand is the literal 0 (`x - 0`), which converts like `* 1`
//   literal   a numeric literal with a fraction or exponent, or of ten or more digits (a float sample or a big sample)
//   intl      every `Intl` use: a call or construction (`new Intl.NumberFormat(`, `Intl.NumberFormat.supportedLocalesOf(`),
//             an alias (`const I = Intl`, `const NF = Intl.NumberFormat`) or a bare `Intl` token
//   intlcall  every `.format(` `.formatToParts(` `.formatRange(` `.formatRangeToParts(` `.resolvedOptions(` member, with its
//             exact argument text. Number-style calls are allowed ONLY in locale.ts / money.ts with a numeric LITERAL
//             argument (the fixed samples) and `.resolvedOptions()` (a currency's fraction digits); the date calls are
//             allowed ONLY in date.ts (dates legitimately go through Intl). A value passed to Intl is therefore a finding.
//   intlname  the five names `format` `formatToParts` `formatRange` `formatRangeToParts` `resolvedOptions` as a WHOLE identifier
//             anywhere that is not after a dot (`const { format } = nf`, `{ format: f }`, `{ format }`, `const format = 1`, a
//             parameter, an interface member), and a string or template whose entire content is one of them (`nf['format']`).
//             They are reserved in src/: a bound method can never be named, so it cannot be called out of sight. `formatMoney`
//             is a different identifier. A comment, or a string that merely contains the name (`"use format() here"`), is not one.
// A `globalThis.` / `window.` / `self.` / `global.` prefix does not hide a name (`globalThis.Math.round`, `globalThis.Intl`).
//
// NOT flagged (documented, not hidden): binary `+` and `-` in general (index arithmetic and string concatenation are
// everywhere and the rule would need types: `x - y` on strings converts like `* 1`), `++` / `--`, `|` between two
// non-literals (it is the type-union token), `valueOf` reached by a computed member name (`x['valueOf']()`), any
// other computed member name or string-built name (`Math['round']`, `globalThis['Number']`, `'for' + 'mat'`; a string that is
// exactly one of the five Intl names IS flagged), unicode-escaped identifiers
// (`\u004dath`), a statement that begins with a sign right after a block (`}` then `+x;`; after the head of an `if` / `while` /
// `for` / `with` it IS flagged), integer literals below ten digits (fixed samples such as 1, -1, 1000), a type position `Intl.X` after
// `:` / `<` / `,` (told apart from a value alias only by the token before it). The backstop for those is behavioural:
// the 30-digit round-trip properties and the BigInt oracle (test/properties.test.ts) fail as soon as a FLOAT is in the
// path, because a float loses digits beyond 2^53. They do NOT see a value sent to Intl as a string (Intl reads strings
// exactly): for that route the guard is the check, with the rounding-mode and negative-zero tests a partial second line.

export interface Token {
  readonly kind: 'id' | 'num' | 'str' | 'tpl' | 'regex' | 'punct';
  readonly text: string;
  readonly line: number;
  /** The unblanked content of a string or a template text: only for the exact-name rule (`nf['format']`). */
  readonly raw?: string;
  /** A template chunk that ENDS in `${`: code follows, so for the next token it is an opener like `(` or `=`, never a value. */
  readonly opens?: boolean;
}

const PUNCT = ['>>>=', '**=', '...', '===', '!==', '<<=', '>>=', '>>>', '&&=', '||=', '??=', '=>', '==', '!=', '<=', '>=', '&&', '||', '??', '?.', '++', '--', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<', '>>', '**'];
const ID_START = /[A-Za-z_$]/;
const ID_PART = /[A-Za-z0-9_$]/;
const KEYWORDS_BEFORE_REGEX = new Set(['return', 'typeof', 'case', 'in', 'of', 'delete', 'void', 'throw', 'new', 'instanceof', 'else', 'do', 'await', 'yield']);

export function lex(src: string): Token[] {
  const out: Token[] = [];
  let i = 0;
  let line = 1;
  // context stack: 'code' with its brace depth, or 'tpl' (inside template text)
  const stack: { mode: 'code' | 'tpl'; depth: number }[] = [{ mode: 'code', depth: 0 }];
  const push = (kind: Token['kind'], text: string, raw?: string, opens?: boolean): void => void out.push({ kind, text, line, ...(raw === undefined ? {} : { raw }), ...(opens === true ? { opens } : {}) });
  const prevAllowsRegex = (): boolean => {
    const p = out[out.length - 1];
    if (p === undefined) return true;
    if (p.kind === 'punct') return ![')', ']', '}'].includes(p.text);
    if (p.kind === 'id') return KEYWORDS_BEFORE_REGEX.has(p.text);
    if (p.kind === 'tpl') return p.opens === true;
    return false;
  };
  // Read template text from i (just after the opening backtick or a closing `}` of a substitution).
  const templateText = (): void => {
    let text = '';
    let raw = '';
    while (i < src.length) {
      const c = src[i] ?? '';
      if (c === '\\') { raw += src.slice(i, i + 2); i += 2; continue; }
      if (c === '`') { i++; push('tpl', text, raw); stack.pop(); return; }
      if (c === '$' && src[i + 1] === '{') { i += 2; push('tpl', text, raw, true); stack.push({ mode: 'code', depth: 0 }); return; }
      if (c === '\n') line++;
      text += ' ';
      raw += c;
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
      push('str', ' '.repeat(Math.max(0, j - i - 1)), src.slice(i + 1, j));
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
  /** The whole trimmed source line of the finding's token: what an ALLOW entry pins. */
  readonly src: string;
}

const MEMBERS = new Set(['toFixed', 'toPrecision', 'toExponential', 'toLocaleString', 'toString', 'valueOf']);
const CALLS = new Set(['parseFloat', 'parseInt', 'Number', 'String', 'isFinite', 'isNaN']);
const ARITH = new Set(['*', '/', '%', '**', '*=', '/=', '%=', '**=']);
const BITWISE = new Set(['~', '^', '&', '<<', '>>', '>>>', '|=', '&=', '^=', '<<=', '>>=', '>>>=']);
const INTL_MEMBERS = new Set(['format', 'formatToParts', 'formatRange', 'formatRangeToParts', 'resolvedOptions']);
const GLOBAL_OBJECTS = new Set(['globalThis', 'window', 'self', 'global']);
const CLOSERS = new Set([')', ']', '}']);

export function scan(source: string): Finding[] {
  const t = lex(source);
  const lines = source.split('\n');
  const found: Finding[] = [];
  const add = (kind: string, text: string, line: number): void => void found.push({ kind, text, line, src: (lines[line - 1] ?? '').trim() });
  /** The text of the call arguments starting at the `(` at index `open`: tokens joined without spaces. */
  const argsAfter = (open: number): string => {
    let depth = 0;
    let out = '';
    for (let k = open; k < t.length; k++) {
      const x = t[k];
      if (x === undefined) break;
      if (x.kind === 'punct' && (x.text === '(' || x.text === '[' || x.text === '{')) depth++;
      if (x.kind === 'punct' && (x.text === ')' || x.text === ']' || x.text === '}')) depth--;
      out += x.kind === 'str' ? '"' + x.text + '"' : x.text;
      if (depth === 0) break;
    }
    return out;
  };
  // the `)` that closes the head of `if` / `while` / `for` / `with`: a sign after it starts the body statement, so it is unary
  const headClose = new Set<number>();
  const opened: number[] = [];
  t.forEach((x, k) => {
    if (x.kind !== 'punct') return;
    if (x.text === '(') opened.push(k);
    else if (x.text === ')') {
      const o = opened.pop() ?? -1;
      const kw = t[o - 1];
      const head = kw?.kind === 'id' && (['if', 'while', 'with', 'for'].includes(kw.text) || (kw.text === 'await' && t[o - 2]?.text === 'for'));
      if (head && t[o - 2]?.text !== '.' && t[o - 2]?.text !== '?.') headClose.add(k);
    }
  });
  /** Does the token at `k` END a value? A postfix non-null `!` after a value is one; a `!` after an opener or operator is logical not. */
  const endsValue = (k: number): boolean => {
    const x = t[k];
    if (x === undefined) return false;
    if (x.kind === 'punct') return x.text === '!' ? endsValue(k - 1) : CLOSERS.has(x.text) && !headClose.has(k);
    if (x.kind === 'id') return !KEYWORDS_BEFORE_REGEX.has(x.text);
    return x.kind !== 'tpl' || x.opens !== true;
  };
  t.forEach((tok, i) => {
    const prev = t[i - 1];
    const next = t[i + 1];
    if (tok.kind === 'id') {
      const dotBefore = prev?.kind === 'punct' && (prev.text === '.' || prev.text === '?.');
      // `globalThis.Math` is as much `Math` as the bare name: only a prefix that is NOT a global object makes a member
      const isMember = dotBefore && !GLOBAL_OBJECTS.has(t[i - 2]?.text ?? '');
      if (dotBefore && MEMBERS.has(tok.text)) add('member', '.' + tok.text, tok.line);
      if (!isMember && CALLS.has(tok.text) && next?.text === '(') add('call', tok.text + '(', tok.line);
      if (!isMember && tok.text === 'Number' && next?.text === '.' && /^parse/.test(t[i + 2]?.text ?? '')) add('numparse', 'Number.' + (t[i + 2]?.text ?? ''), tok.line);
      if (!isMember && tok.text === 'Math' && next?.text === '.') add('math', 'Math.' + (t[i + 2]?.text ?? ''), tok.line);
      if (dotBefore && INTL_MEMBERS.has(tok.text)) add('intlcall', '.' + tok.text + (next?.text === '(' ? argsAfter(i + 1) : ''), tok.line);
      // the five names are RESERVED in src/: as a whole identifier anywhere else (a destructuring pattern, an object key or
      // shorthand, a local, a parameter, a type member) they would let a bound method escape the `.format(` rule
      if (!dotBefore && INTL_MEMBERS.has(tok.text)) add('intlname', tok.text, tok.line);
      if (!isMember && tok.text === 'Intl') {
        // the chain Intl.A.B... and whether a call follows it
        let end = i;
        let chain = 'Intl';
        while (t[end + 1]?.text === '.' && t[end + 2]?.kind === 'id') {
          chain += '.' + (t[end + 2]?.text ?? '');
          end += 2;
        }
        if (t[end + 1]?.text === '(') add('intl', chain + '(', tok.line);
        else if (chain === 'Intl') add('intl', 'Intl', tok.line);
        else if ((prev?.kind === 'punct' && ['=', '(', '?', '||', '??', '&&'].includes(prev.text) && t[i - 3]?.text !== 'type') || prev?.opens === true) add('intl', chain, tok.line); // `type P = Intl.X` is a type
        else if (prev?.kind === 'id' && prev.text === 'return') add('intl', chain, tok.line);
      }
    } else if ((tok.kind === 'str' || tok.kind === 'tpl') && INTL_MEMBERS.has(tok.raw ?? '')) {
      // a string whose WHOLE content is one of the five names is how a computed access is written: `nf['format'](v)`
      add('intlname', '"' + (tok.raw ?? '') + '"', tok.line);
    } else if (tok.kind === 'num') {
      if (/[.eE]/.test(tok.text) && !/^0[xX]/.test(tok.text)) add('literal', tok.text, tok.line);
      else if (tok.text.replace(/_/g, '').length >= 10) add('literal', tok.text, tok.line);
    } else if (tok.kind === 'punct') {
      // `function* gen`, `yield* x`, `export * from` and `import * as ns` are not multiplications
      const generator = prev?.kind === 'id' && ['function', 'yield', 'async', 'export', 'import'].includes(prev.text);
      const binary = prev !== undefined && endsValue(i - 1) && !generator;
      if ((tok.text === '+' || tok.text === '-') && !binary) {
        if (tok.text === '+' || next?.kind !== 'num') add('unary', tok.text + (next?.text ?? ''), tok.line);
      }
      if (tok.text === '-' && binary && next?.kind === 'num' && Number(next.text.replace(/_/g, '')) === 0) add('coerce', `${prev?.text ?? ''} - ${next.text}`, tok.line);
      if (ARITH.has(tok.text) && binary) add('arith', `${prev?.text ?? ''} ${tok.text} ${next?.text ?? ''}`, tok.line);
      if (BITWISE.has(tok.text)) add('bitwise', `${prev?.text ?? ''} ${tok.text} ${next?.text ?? ''}`, tok.line);
      if (tok.text === '|' && (next?.kind === 'num' || prev?.kind === 'num')) add('bitwise', `${prev?.text ?? ''} | ${next?.text ?? ''}`, tok.line);
    }
  });
  return found;
}

// The ONLY exemptions. Matching consumes one entry per finding: file + kind + exact text + the full trimmed source
// LINE of the site. A finding no entry covers fails; an entry that matches no finding (its line changed, moved or is
// gone) fails too. Adding an exemption therefore changes this list AND ALLOW_COUNT: a visible diff.
export interface Allowed {
  readonly file: string;
  readonly kind: string;
  readonly text: string;
  readonly line: string;
  readonly why: string;
}
export const ALLOW: readonly Allowed[] = [
  { file: 'date.ts', kind: 'arith', text: 'n * 10', line: 'for (let i = 0; i < (s ?? \'\').length; i++) n = n * 10 + ((s ?? \'\').charCodeAt(i) - 48);', why: 'integer digit accumulation of a regex-validated ASCII digit run' },
  { file: 'date.ts', kind: 'arith', text: 'year % 4', line: 'if (month === 2) return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28;', why: 'leap-year rule on a validated integer year' },
  { file: 'date.ts', kind: 'arith', text: 'year % 100', line: 'if (month === 2) return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28;', why: 'leap-year rule on a validated integer year' },
  { file: 'date.ts', kind: 'arith', text: 'year % 400', line: 'if (month === 2) return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28;', why: 'leap-year rule on a validated integer year' },
  { file: 'date.ts', kind: 'intl', text: 'Intl.DateTimeFormat(', line: 'const made = new Intl.DateTimeFormat(locale, { ...o, numberingSystem: \'latn\', calendar: \'gregory\' });', why: 'a Date formatter: dates legitimately go through Intl (an instant, never a number)' },
  { file: 'date.ts', kind: 'arith', text: 'sign * (', line: 'const instant = new Date(t.getTime() - sign * (offH * 60 + offM) * 60000);', why: 'offset sign times whole minutes' },
  { file: 'date.ts', kind: 'arith', text: 'offH * 60', line: 'const instant = new Date(t.getTime() - sign * (offH * 60 + offM) * 60000);', why: 'offset hours to minutes (integers)' },
  { file: 'date.ts', kind: 'arith', text: ') * 60000', line: 'const instant = new Date(t.getTime() - sign * (offH * 60 + offM) * 60000);', why: 'offset minutes to milliseconds (integers)' },
  { file: 'date.ts', kind: 'intlcall', text: '.format(instant)', line: 'return okText(f.format(instant));', why: 'formats a Date instant, never a number, money or percent value' },
  { file: 'date.ts', kind: 'intlcall', text: '.format(utcDay(y,mo,d))', line: 'return okText(f.format(utcDay(y, mo, d)));', why: 'formats a Date instant, never a number, money or percent value' },
  { file: 'locale.ts', kind: 'intl', text: 'Intl.NumberFormat.supportedLocalesOf(', line: 'return Intl.NumberFormat.supportedLocalesOf([locale]).length === 1 && Intl.DateTimeFormat.supportedLocalesOf([locale]).length === 1;', why: 'asks whether a locale tag is supported: no value is involved' },
  { file: 'locale.ts', kind: 'intl', text: 'Intl.DateTimeFormat.supportedLocalesOf(', line: 'return Intl.NumberFormat.supportedLocalesOf([locale]).length === 1 && Intl.DateTimeFormat.supportedLocalesOf([locale]).length === 1;', why: 'asks whether a locale tag is supported: no value is involved' },
  { file: 'locale.ts', kind: 'intlcall', text: '.formatToParts(10)', line: 'if (hasGroup(percent ? auto.formatToParts(10) : auto.formatToParts(1000))) return 1;', why: 'a fixed numeric LITERAL sample: learns the locale\'s symbols; the value being formatted never enters Intl' },
  { file: 'locale.ts', kind: 'intlcall', text: '.formatToParts(1000)', line: 'if (hasGroup(percent ? auto.formatToParts(10) : auto.formatToParts(1000))) return 1;', why: 'a fixed numeric LITERAL sample: learns the locale\'s symbols; the value being formatted never enters Intl' },
  { file: 'locale.ts', kind: 'intlcall', text: '.formatToParts(100)', line: 'if (hasGroup(percent ? auto.formatToParts(100) : auto.formatToParts(10000))) return 2;', why: 'a fixed numeric LITERAL sample: learns the locale\'s symbols; the value being formatted never enters Intl' },
  { file: 'locale.ts', kind: 'intlcall', text: '.formatToParts(10000)', line: 'if (hasGroup(percent ? auto.formatToParts(100) : auto.formatToParts(10000))) return 2;', why: 'a fixed numeric LITERAL sample: learns the locale\'s symbols; the value being formatted never enters Intl' },
  { file: 'locale.ts', kind: 'intl', text: 'Intl.NumberFormat(', line: 'const always = new Intl.NumberFormat(locale, { ...base, useGrouping: true, minimumFractionDigits: 1, maximumFractionDigits: 1 });', why: 'a formatter built only for fixed sample numbers that teach a locale\'s symbols and patterns' },
  { file: 'locale.ts', kind: 'intl', text: 'Intl.NumberFormat(', line: 'const auto = new Intl.NumberFormat(locale, base);', why: 'a formatter built only for fixed sample numbers that teach a locale\'s symbols and patterns' },
  { file: 'locale.ts', kind: 'intlcall', text: '.formatToParts(1234567890123)', line: 'const big = always.formatToParts(1234567890123);', why: 'a fixed numeric LITERAL sample: learns the locale\'s symbols; the value being formatted never enters Intl' },
  { file: 'locale.ts', kind: 'literal', text: '1234567890123', line: 'const big = always.formatToParts(1234567890123);', why: 'fixed sample: learns grouping sizes from Intl, the value itself never enters Intl' },
  { file: 'locale.ts', kind: 'intlcall', text: '.formatToParts(1.5)', line: 'decimal: part(always.formatToParts(1.5), \'decimal\', \'.\'),', why: 'a fixed numeric LITERAL sample: learns the locale\'s symbols; the value being formatted never enters Intl' },
  { file: 'locale.ts', kind: 'literal', text: '1.5', line: 'decimal: part(always.formatToParts(1.5), \'decimal\', \'.\'),', why: 'fixed sample: learns the decimal separator from Intl' },
  { file: 'locale.ts', kind: 'math', text: 'Math.max', line: 'const start = Math.max(0, end - size);', why: 'integer index arithmetic (slice bounds)' },
  { file: 'locale.ts', kind: 'math', text: 'Math.max', line: 'return { prefix: join(parts.slice(0, Math.max(first, 0))), suffix: join(parts.slice(last + 1)) };', why: 'integer index arithmetic (slice bounds)' },
  { file: 'locale.ts', kind: 'intl', text: 'Intl.NumberFormat(', line: 'pos: templateOf(new Intl.NumberFormat(locale, base).formatToParts(1)),', why: 'a formatter built only for fixed sample numbers that teach a locale\'s symbols and patterns' },
  { file: 'locale.ts', kind: 'intlcall', text: '.formatToParts(1)', line: 'pos: templateOf(new Intl.NumberFormat(locale, base).formatToParts(1)),', why: 'a fixed numeric LITERAL sample: learns the locale\'s symbols; the value being formatted never enters Intl' },
  { file: 'locale.ts', kind: 'intl', text: 'Intl.NumberFormat(', line: 'neg: templateOf(new Intl.NumberFormat(locale, base).formatToParts(-1)),', why: 'a formatter built only for fixed sample numbers that teach a locale\'s symbols and patterns' },
  { file: 'locale.ts', kind: 'intlcall', text: '.formatToParts(-1)', line: 'neg: templateOf(new Intl.NumberFormat(locale, base).formatToParts(-1)),', why: 'a fixed numeric LITERAL sample: learns the locale\'s symbols; the value being formatted never enters Intl' },
  { file: 'locale.ts', kind: 'intl', text: 'Intl.NumberFormat(', line: 'plus: templateOf(new Intl.NumberFormat(locale, { ...base, signDisplay: \'always\' }).formatToParts(1)),', why: 'a formatter built only for fixed sample numbers that teach a locale\'s symbols and patterns' },
  { file: 'locale.ts', kind: 'intlcall', text: '.formatToParts(1)', line: 'plus: templateOf(new Intl.NumberFormat(locale, { ...base, signDisplay: \'always\' }).formatToParts(1)),', why: 'a fixed numeric LITERAL sample: learns the locale\'s symbols; the value being formatted never enters Intl' },
  { file: 'money.ts', kind: 'intl', text: 'Intl.NumberFormat(', line: 'const resolved = new Intl.NumberFormat(options.locale, style).resolvedOptions();', why: 'builds the currency style only to read its fraction digits (resolvedOptions)' },
  { file: 'money.ts', kind: 'intlcall', text: '.resolvedOptions()', line: 'const resolved = new Intl.NumberFormat(options.locale, style).resolvedOptions();', why: 'reads the currency\'s fraction digits, formats nothing' },
  { file: 'number.ts', kind: 'math', text: 'Math.min', line: 'const min = gmin ?? Math.min(defMin, gmax ?? defMax);', why: 'integer digit-count bounds' },
  { file: 'number.ts', kind: 'math', text: 'Math.max', line: 'const max = gmax ?? Math.max(defMax, min);', why: 'integer digit-count bounds' },
  { file: 'number.ts', kind: 'member', text: '.toString', line: 'if (typeof value === \'bigint\') text = value.toString();', why: 'a bigint as digits' },
  { file: 'number.ts', kind: 'call', text: 'String(', line: 'else if (typeof value === \'number\') text = Number.isSafeInteger(value) ? String(value) : undefined;', why: 'a safe integer (Number.isSafeInteger checked on the same line) as digits' },
  { file: 'round.ts', kind: 'arith', text: 'lastKept % 2', line: 'return mode === \'half-up\' ? true : lastKept % 2 === 1;', why: 'parity of one ASCII digit (half-even)' },
];
export const ALLOW_COUNT = 37;

/** Findings of `source` that no remaining allow entry covers (entries are consumed from `allow`). */
export function judge(file: string, source: string, allow: Allowed[]): { open: string[] } {
  const open: string[] = [];
  for (const f of scan(source)) {
    const at = allow.findIndex((a) => a.file === file && a.kind === f.kind && a.text === f.text && a.line === f.src);
    if (at >= 0) allow.splice(at, 1);
    else open.push(`${file}:${f.line} ${f.kind} ${JSON.stringify(f.text)} | ${f.src}`);
  }
  return { open };
}

// Module specifiers. tsc compiles any file that is IMPORTED, whatever `include` says, so a file outside src/ reached from
// src/ would format values unread by this guard. Rule, by allow-list: in every scanned file every module specifier (the
// string after `from`, after a side-effect `import`, inside `import(`, `require(`, and in a `/// <reference path|types|lib>`)
// is RELATIVE (`./` or `../`) and resolves, by path arithmetic from the importing file's directory, to a place inside src/.
// A `..` that would pass above src/ at ANY point is a finding even if the path re-enters (`../src/a.ts`). Findings:
// `import-outside-src` (climbs out, absolute, URL), `import-bare` (a package, `node:` builtin or `#imports` name, unless in
// BARE_ALLOW, which is EMPTY: the package has no runtime dependency), `import-dynamic` (a non-literal `import(x)` or
// `require(x)`; a template without `${}` counts as a literal). Type-only imports follow the same rule. Not caught: an
// ambient `declare module 'x'`, `createRequire(...)`, `import.meta` tricks (mistakes, not an adversary, are the trust model).
export const SHIPPED_SCRIPTS: Record<string, string> = { test: 'vitest run', typecheck: 'tsc -p tsconfig.json' };
/** Differences between a package `scripts` value and the shipped one: a changed, missing or extra script. */
export function scriptsProblems(scripts: unknown): string[] {
  if (typeof scripts !== 'object' || scripts === null) return ['scripts is not an object'];
  const have = scripts as Record<string, unknown>;
  const out: string[] = [];
  for (const [k, v] of Object.entries(SHIPPED_SCRIPTS)) if (have[k] !== v) out.push(`script ${k} is not "${v}"`);
  for (const k of Object.keys(have)) if (!(k in SHIPPED_SCRIPTS)) out.push(`extra script ${k}`);
  return out;
}
/** The pinned test files absent from a directory listing. */
export function missingRequired(have: readonly string[]): string[] {
  return REQUIRED_TESTS.filter((n) => !have.includes(n));
}
export const REQUIRED_TESTS = ['readme.test.ts', 'ownoptions.test.ts', 'guard.test.ts', 'options.test.ts', 'mingrouping.test.ts', 'robust.test.ts', 'rtl.test.ts', 'contract.test.ts'];
export const BARE_ALLOW: readonly string[] = [];

/** The finding kind of one module specifier written in `file` (path relative to src/, forward slashes), or null when it stays inside src/. */
export function specifierKind(file: string, spec: string): 'import-outside-src' | 'import-bare' | null {
  if (spec === '.' || spec === '..' || spec.startsWith('./') || spec.startsWith('../')) {
    const stack = file.split('/').slice(0, -1);
    for (const seg of spec.split('/')) {
      if (seg === '' || seg === '.') continue;
      if (seg === '..') {
        if (stack.length === 0) return 'import-outside-src';
        stack.pop();
      } else stack.push(seg);
    }
    return null;
  }
  if (spec.startsWith('/') || spec.startsWith('\\') || /^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(spec)) return 'import-outside-src';
  return BARE_ALLOW.includes(spec) ? null : 'import-bare';
}

export function importFindings(file: string, source: string): { kind: string; text: string; line: number }[] {
  const t = lex(source);
  const out: { kind: string; text: string; line: number }[] = [];
  const spec = (s: string, line: number): void => {
    const kind = specifierKind(file, s);
    if (kind !== null) out.push({ kind, text: s, line });
  };
  t.forEach((tok, i) => {
    const next = t[i + 1];
    if (tok.kind !== 'id') return;
    // `loader.require('x')` / `obj.import(x)` is a method call, not the module function
    const prevTok = t[i - 1];
    const memberCall = prevTok?.kind === 'punct' && (prevTok.text === '.' || prevTok.text === '?.');
    if (memberCall) return;
    if (tok.text === 'from' && next?.kind === 'str') spec(next.raw ?? '', next.line);
    else if (tok.text === 'import' && next?.kind === 'str') spec(next.raw ?? '', next.line);
    else if ((tok.text === 'import' || tok.text === 'require') && next?.text === '(' && next.kind === 'punct') {
      // a method or signature DECLARATION named import / require (`import(s: string) {`, `require(s: string): unknown`): the
      // parameter list is empty or starts with a typed parameter, and a `{` or `:` follows its `)`. A string literal argument
      // (`c ? require('../q') : y`) is never a declaration.
      let depth = 0;
      let close = i + 1;
      for (; close < t.length; close++) {
        const x = t[close];
        if (x?.kind === 'punct' && x.text === '(') depth++;
        if (x?.kind === 'punct' && x.text === ')' && --depth === 0) break;
      }
      const typed = t[i + 2]?.text === ')' || (t[i + 2]?.kind === 'id' && [':', '?'].includes(t[i + 3]?.text ?? ''));
      if (typed && [':', '{'].includes(t[close + 1]?.text ?? '')) return;
      const arg = t[i + 2];
      const after = t[i + 3]?.text;
      const literal = (arg?.kind === 'str' || arg?.kind === 'tpl') && (after === ')' || (after === ',' && tok.text === 'import'));
      if (literal) spec(arg?.raw ?? '', arg?.line ?? tok.line);
      else out.push({ kind: 'import-dynamic', text: tok.text + '(', line: tok.line });
    }
  });
  source.split('\n').forEach((l, n) => {
    const m = /^\s*\/\/\/\s*<reference\s+(?:path|types|lib)\s*=\s*(["'])(.*?)\1/.exec(l);
    if (m?.[2] !== undefined) spec(m[2], n + 1);
  });
  return out;
}

const kinds = (s: string): string[] => scan(s).map((f) => `${f.kind}:${f.text}`);

// The set of files the guard scans is the set the compiler builds: EVERY file under src/, at any depth, with a TypeScript
// extension (`.d.ts` and `.d.mts` end in one). The package tsconfig includes the whole `src` directory, so a file the
// guard skipped would still be compiled and imported. Refused as a finding, never skipped: a JavaScript source (outside
// the lexer's contract; with `allowJs` off, which the repo selftest asserts on the base config, it cannot be imported
// anyway, so refusing it is cheap) and a symbolic link (never followed). An ALLOW entry's `file` is the path RELATIVE to
// src/ with forward slashes (`sub/x.ts`), so a nested file is unambiguous.
export const SOURCE_EXT = ['.ts', '.mts', '.cts', '.tsx'];
export const REFUSED_EXT = ['.js', '.mjs', '.cjs', '.jsx'];

export function walkSources(root: string): { files: string[]; refused: string[] } {
  const files: string[] = [];
  const refused: string[] = [];
  const visit = (rel: string): void => {
    for (const e of readdirSync(join(root, rel), { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
      const key = rel === '' ? e.name : rel + '/' + e.name;
      if (e.isSymbolicLink()) refused.push(`${key} is a symbolic link (not followed)`);
      else if (e.isDirectory()) visit(key);
      else if (e.isFile() && SOURCE_EXT.some((x) => e.name.endsWith(x))) files.push(key);
      else if (e.isFile() && REFUSED_EXT.some((x) => e.name.toLowerCase().endsWith(x))) refused.push(`${key} is a JavaScript source (outside the guard's contract)`);
    }
  };
  visit('');
  return { files, refused };
}

/** Every open finding of a source tree: refusals, then each scanned file judged against `allow` (consumed). */
export function auditTree(root: string, allow: Allowed[]): { files: string[]; open: string[] } {
  const { files, refused } = walkSources(root);
  const open = [...refused];
  for (const f of files) {
    const source = readFileSync(join(root, f), 'utf8');
    open.push(...judge(f, source, allow).open);
    for (const x of importFindings(f, source)) open.push(`${f}:${x.line} ${x.kind} ${JSON.stringify(x.text)}`);
  }
  return { files, open };
}

/** The package tsconfig must build only src/ (plus tests): every `include` entry is `src...` or `test...`, there is no `files`
 * list, and no `compilerOptions` (so `allowJs` can only come from the base, which the repo selftest checks). */
export const TSCONFIG_EXTENDS = '../../tsconfig.base.json';
export function tsconfigProblems(tsconfig: unknown): string[] {
  const t = tsconfig as { extends?: unknown; include?: unknown; files?: unknown; compilerOptions?: unknown };
  const out: string[] = [];
  if (t.extends !== TSCONFIG_EXTENDS) out.push(`extends is ${JSON.stringify(t.extends)}, not ${JSON.stringify(TSCONFIG_EXTENDS)}`);
  if (!Array.isArray(t.include) || t.include.length === 0) return [...out, 'include is not a non-empty array'];
  const normalize = (e: unknown): string => (typeof e === 'string' ? e.replace(/^\.\//, '').replace(/\/+$/, '') : '');
  for (const e of t.include) {
    const norm = normalize(e);
    if (!/^(src|test)(\/[^*]*|\/\*\*(\/\*)?)?$/.test(norm) || norm.includes('..')) out.push(`include entry ${JSON.stringify(e)} is not under src/ or test/`);
  }
  if (!t.include.some((e) => normalize(e) === 'src')) out.push('include has no "src" entry: the compiler would not build all of src/');
  if (t.files !== undefined) out.push('a "files" list can add a source outside src/');
  if (t.compilerOptions !== undefined) out.push('compilerOptions in the package could turn on allowJs');
  return out;
}

describe('the source contains no float-based formatting or arithmetic on values, and no value reaches Intl', () => {
  const root = fileURLToPath(new URL('../src/', import.meta.url));
  const { files } = walkSources(root);
  it('there are source files to scan (control)', () => {
    expect(files.length).toBeGreaterThanOrEqual(8);
  });
  it('every finding in src/ (every depth, every TypeScript extension) is covered by ALLOW, and every ALLOW entry is used', () => {
    const left = ALLOW.slice();
    const { open } = auditTree(root, left);
    expect(open).toEqual([]);
    expect(left.map((a) => `${a.file} ${a.kind} ${a.text} | ${a.line}`)).toEqual([]);
  });
  it('the tsconfig builds only src/ and test/ (so the walk of src/ covers what the compiler builds)', () => {
    const t: unknown = JSON.parse(readFileSync(fileURLToPath(new URL('../tsconfig.json', import.meta.url)), 'utf8'));
    expect(tsconfigProblems(t)).toEqual([]);
  });
  it('the tree walk: nested, .mts, deep, JavaScript and symlink are findings; a clean nested file is not (control)', () => {
    const base = mkdtempSync(join(tmpdir(), 'format-guard-'));
    try {
      const bad = 'export const a = (v: string) => new Intl.NumberFormat("en").format(v);\n';
      const tree = (name: string, put: (r: string) => void): { files: string[]; open: string[] } => {
        const r = join(base, name);
        mkdirSync(r, { recursive: true });
        writeFileSync(join(r, 'top.ts'), 'export const ok = 1;\n');
        put(r);
        return auditTree(r, []);
      };
      expect(tree('clean', (r) => { mkdirSync(join(r, 'sub')); writeFileSync(join(r, 'sub/clean.ts'), 'export const b = 2;\n'); })).toEqual({ files: ['sub/clean.ts', 'top.ts'], open: [] });
      const nested = tree('nested', (r) => { mkdirSync(join(r, 'sub')); writeFileSync(join(r, 'sub/x.ts'), bad); });
      expect(nested.files).toContain('sub/x.ts');
      expect(nested.open.length).toBeGreaterThan(0);
      expect(nested.open.every((o) => o.startsWith('sub/x.ts:'))).toBe(true);
      const mts = tree('mts', (r) => writeFileSync(join(r, 'y.mts'), bad));
      expect(mts.files).toContain('y.mts');
      expect(mts.open.some((o) => o.startsWith('y.mts:'))).toBe(true);
      const deep = tree('deep', (r) => { mkdirSync(join(r, 'deep/a/b'), { recursive: true }); writeFileSync(join(r, 'deep/a/b/c.ts'), bad); });
      expect(deep.open.some((o) => o.startsWith('deep/a/b/c.ts:'))).toBe(true);
      for (const ext of ['.cts', '.tsx', '.d.ts']) {
        const other = tree('ext' + ext, (r) => writeFileSync(join(r, 'z' + ext), bad));
        expect(other.open.some((o) => o.startsWith('z' + ext + ':')), ext).toBe(true);
      }
      for (const ext of ['.js', '.mjs', '.cjs', '.jsx']) {
        const js = tree('js' + ext, (r) => { mkdirSync(join(r, 'sub')); writeFileSync(join(r, 'sub/w' + ext), 'export const c = 1;\n'); });
        expect(js.open, ext).toEqual([`sub/w${ext} is a JavaScript source (outside the guard's contract)`]);
      }
      const link = tree('link', (r) => { writeFileSync(join(base, 'outside.ts'), 'export const d = 1;\n'); symlinkSync(join(base, 'outside.ts'), join(r, 'l.ts')); });
      expect(link.open).toEqual(['l.ts is a symbolic link (not followed)']);
      expect(link.files).toEqual(['top.ts']);
    } finally {
      rmSync(base, { recursive: true, force: true });
    }
  });
  it('the tsconfig check refuses a source outside src/, a files list, compilerOptions and another extends (control)', () => {
    const x = { extends: TSCONFIG_EXTENDS };
    expect(tsconfigProblems({ ...x, include: ['src', 'test'] })).toEqual([]);
    expect(tsconfigProblems({ ...x, include: ['./src/', 'test/**/*'] })).toEqual([]);
    expect(tsconfigProblems({ ...x, include: ['src', 'test', 'lib'] })).toHaveLength(1);
    expect(tsconfigProblems({ ...x, include: ['src', '../other/src'] })).toHaveLength(1);
    expect(tsconfigProblems({ ...x, include: ['test'] })).toHaveLength(1);
    expect(tsconfigProblems({ ...x, include: ['src'], files: ['x.ts'] })).toHaveLength(1);
    expect(tsconfigProblems({ ...x, include: ['src'], compilerOptions: { allowJs: true } })).toHaveLength(1);
    expect(tsconfigProblems(x)).toHaveLength(1);
    expect(tsconfigProblems({ include: ['src'] })).toHaveLength(1);
    expect(tsconfigProblems({ extends: '../../tsconfig.loose.json', include: ['src'] })).toHaveLength(1);
  });
  it('ALLOW has exactly the expected number of entries (a new exemption must bump this, visibly)', () => {
    expect(ALLOW.length).toBe(ALLOW_COUNT);
  });
  it('the Intl entries sit in the right places with the right arguments (the README sentence, as data)', () => {
    const NUMBER_FILES = ['locale.ts', 'money.ts'];
    for (const a of ALLOW.filter((x) => x.kind === 'intlcall')) {
      if (a.file === 'date.ts') expect(a.text, `${a.file} ${a.text}`).toMatch(/^\.format\((instant|utcDay\(y,mo,d\))\)$/);
      else {
        expect(NUMBER_FILES, `${a.file} ${a.text}`).toContain(a.file);
        // a number-style call takes ONE numeric literal (a fixed sample), or nothing at all for resolvedOptions
        expect(a.text, `${a.file} ${a.text}`).toMatch(/^(\.formatToParts\(-?[0-9.]+\)|\.resolvedOptions\(\))$/);
      }
    }
    for (const a of ALLOW.filter((x) => x.kind === 'intl')) {
      const dateOnly = /^Intl\.DateTimeFormat\($/.test(a.text);
      if (dateOnly) expect(a.file, a.text).toBe('date.ts');
      else expect([...NUMBER_FILES], `${a.file} ${a.text}`).toContain(a.file);
      expect(a.text, a.file).toMatch(/^Intl\.(NumberFormat|DateTimeFormat)(\.supportedLocalesOf)?\($/);
    }
    // number.ts, percent.ts, round.ts, grammar.ts, types.ts and index.ts never touch Intl at all
    for (const a of ALLOW) if (['number.ts', 'percent.ts', 'round.ts', 'grammar.ts', 'types.ts', 'index.ts'].includes(a.file)) expect(['intl', 'intlcall'], `${a.file} ${a.text}`).not.toContain(a.kind);
  });
  it('no source line carries an escape marker', () => {
    for (const f of files) expect(readFileSync(join(root, f), 'utf8'), f).not.toMatch(/format-guard-allow/);
  });

  it('the scanner finds each rule, wherever the code sits (control)', () => {
    expect(kinds('const a = x.toFixed(2);')).toEqual(['member:.toFixed']);
    expect(kinds('const a = x.toFixed(2)\n * 3;')).toEqual(['member:.toFixed', 'arith:) * 3']);
    expect(kinds('const a = Number(x);')).toEqual(['call:Number(']);
    expect(kinds('const a = parseFloat(x) + parseInt(y);')).toEqual(['call:parseFloat(', 'call:parseInt(']);
    expect(kinds('const a = isFinite(x) && isNaN(y) && Number.isNaN(z);')).toEqual(['call:isFinite(', 'call:isNaN(']);
    expect(kinds('const a = Math.round(x);')).toEqual(['math:Math.round']);
    expect(kinds('const a = x.toLocaleString("en");')).toEqual(['member:.toLocaleString']);
    expect(kinds('const a = x.valueOf();')).toEqual(['member:.valueOf']);
    expect(kinds('const a = (+digits).toString();')).toEqual(['unary:+digits', 'member:.toString']);
    expect(kinds('const a = +digits;')).toEqual(['unary:+digits']);
    expect(kinds('const a = -digits;')).toEqual(['unary:-digits']);
    // template substitutions: a chunk that ends in `${` is an opener (like `(` or `=`), not a value
    expect(kinds('const a = `${+x}`;')).toEqual(['unary:+x']);
    expect(kinds('const a = `v=${+x}`;')).toEqual(['unary:+x']);
    expect(kinds('const a = `${-x}`;')).toEqual(['unary:-x']);
    expect(kinds('const a = `${a}${+b}`;')).toEqual(['unary:+b']);
    expect(kinds('const a = `${`${+x}`}`;')).toEqual(['unary:+x']);
    expect(kinds('const a = `${a + b}`; const c = `${a - b}`;')).toEqual([]);
    expect(kinds('const a = `${x * 1}`;')).toEqual(['arith:x * 1']);
    expect(kinds('const a = `${ /a\\/b/.test(s) ? 1 : 2 }`;')).toEqual([]);
    expect(kinds('const a = `plain ${name} text`;')).toEqual([]);
    // a regex right after the head is a regex: lexed as code its body would show a unary `+q`
    expect(kinds('const a = `${ /b(+q)/.test(s) }`;')).toEqual([]);
    expect(kinds('const a = x * 100; const b = y / 3; const c = z ** 2; d *= 2;')).toEqual(['arith:x * 100', 'arith:y / 3', 'arith:z ** 2', 'arith:d *= 2']);
    expect(kinds('const a = 0.1; const b = 1e5; const c = 1234567890123;')).toEqual(['literal:0.1', 'literal:1e5', 'literal:1234567890123']);
    expect(kinds('const a = Number.parseFloat(x);')).toEqual(['numparse:Number.parseFloat']);
    expect(kinds('const s = `${x.toFixed(2)}`;')).toEqual(['member:.toFixed']);
    expect(kinds('const a = x?.toFixed(2);')).toEqual(['member:.toFixed']);
  });
  it('a sign after an expression-position keyword, a logical not or an if/while/for/with head is unary; after a postfix `!` it is binary (control)', () => {
    // keywords after which a sign is unary (`await` and `yield` included)
    expect(kinds('async function f() { return await +x; }')).toEqual(['unary:+x']);
    expect(kinds('async function f() { const q = await -x; }')).toEqual(['unary:-x']);
    expect(kinds('function* g() { const q = yield +x; }')).toEqual(['unary:+x']);
    for (const kw of ['return', 'typeof', 'void', 'throw', 'case', 'in', 'of', 'new', 'else', 'do', 'delete']) expect(kinds(`${kw} +x;`), kw).toEqual(['unary:+x']);
    expect(kinds('const b = a instanceof B; const c = a + b;')).toEqual([]);
    // a postfix non-null `!` ends a value (binary), a logical not is an opener (unary)
    expect(kinds('const c = arr[0]! + b;')).toEqual([]);
    expect(kinds('const c = x! + y; const d = f()! - g;')).toEqual([]);
    expect(kinds('const c = !+x;')).toEqual(['unary:+x']);
    expect(kinds('const c = a && !-x;')).toEqual(['unary:-x']);
    expect(kinds('const c = x!.y; const d = x!!; const e = !!x;')).toEqual([]);
    expect(kinds('const c = x!! + y;')).toEqual([]);
    expect(kinds('const c = `a${b}`! + y;')).toEqual([]);
    // the head of if / while / for / with: a sign after its `)` starts the body
    expect(kinds('if (c) +x;')).toEqual(['unary:+x']);
    expect(kinds('while (c) -x;')).toEqual(['unary:-x']);
    expect(kinds('for (;;) +x;')).toEqual(['unary:+x']);
    expect(kinds('async function f() { for await (const a of b) +a; }')).toEqual(['unary:+a']);
    expect(kinds('const c = (a) + b; const d = f(a) + b; if (c) { y = a + b }')).toEqual([]);
    expect(kinds('const c = x.if(a) + b; const d = g(h(a)) + b;')).toEqual([]);
  });
  it('bitwise coercions and the minus-zero coercion are findings; the type-union bar and plain minus are not (control)', () => {
    expect(kinds('const a = x | 0;')).toEqual(['bitwise:x | 0']);
    expect(kinds('const a = 0 | x;')).toEqual(['bitwise:0 | x']);
    expect(kinds('const a = x >> 0; const b = y >>> 0; const c = ~~z; const d = p << 1; const e = q ^ 1; const f = r & 255;')).toEqual([
      'bitwise:x >> 0', 'bitwise:y >>> 0', 'bitwise:= ~ ~', 'bitwise:~ ~ z', 'bitwise:p << 1', 'bitwise:q ^ 1', 'bitwise:r & 255',
    ]);
    expect(kinds('a |= b; c &= d; e ^= f; g <<= 1; h >>= 1; i >>>= 1;').length).toBe(6);
    expect(kinds('const a = x - 0;')).toEqual(['coerce:x - 0']);
    expect(kinds('type T = A | B | "c"; const a = b - 1; const c = d - e; const f = g || h; const i = j && k;')).toEqual([]);
  });
  it('a generator is not a multiplication, a global-object prefix hides nothing (control)', () => {
    expect(kinds('function* gen() { yield* other(); }')).toEqual([]);
    expect(kinds('const o = { *gen() { yield 1; } }; async function* ag() {}')).toEqual([]);
    expect(kinds('const a = globalThis.Number(x); const b = globalThis.Math.round(y); const c = window.parseFloat(z);')).toEqual(['call:Number(', 'math:Math.round', 'call:parseFloat(']);
    expect(kinds('const a = x * y;')).toEqual(['arith:x * y']);
  });
  it('a value handed to Intl is a finding wherever it sits (control)', () => {
    expect(kinds('const a = new Intl.NumberFormat(l).format(x);')).toEqual(['intl:Intl.NumberFormat(', 'intlcall:.format(x)']);
    expect(kinds('const a = nf.formatToParts(value);')).toEqual(['intlcall:.formatToParts(value)']);
    expect(kinds('const a = nf.formatRange(1, 2); const b = nf.formatRangeToParts(a, b); const c = nf.resolvedOptions();')).toEqual(['intlcall:.formatRange(1,2)', 'intlcall:.formatRangeToParts(a,b)', 'intlcall:.resolvedOptions()']);
    expect(kinds('const a = nf?.format(value); const f = nf.format;')).toEqual(['intlcall:.format(value)', 'intlcall:.format']);
    expect(kinds('const a = Intl.NumberFormat(l); const b = new Intl.PluralRules(l); const c = globalThis.Intl.Collator(l);')).toEqual(['intl:Intl.NumberFormat(', 'intl:Intl.PluralRules(', 'intl:Intl.Collator(']);
    expect(kinds('const I = Intl; const NF = Intl.NumberFormat; return Intl.NumberFormat;')).toEqual(['intl:Intl', 'intl:Intl.NumberFormat', 'intl:Intl.NumberFormat']);
    expect(kinds('const x: Intl.NumberFormat = a; const m = new Map<string, Intl.DateTimeFormat>(); const o: Intl.NumberFormatOptions = {}; type P = Intl.NumberFormatPart[];')).toEqual([]);
    expect(kinds('const a = f.format(utcDay(y, mo, d));')).toEqual(['intlcall:.format(utcDay(y,mo,d))']);
    // after a template head the alias is told by the head, not by a punctuation token: found by the alias rule, not the call rule
    expect(kinds('const a = `${Intl.NumberFormat}`;')).toEqual(['intl:Intl.NumberFormat']);
    expect(kinds('const a = `x${Intl.DateTimeFormat}y`;')).toEqual(['intl:Intl.DateTimeFormat']);
  });
  it('the five Intl method names are reserved identifiers: a bound or computed method is a finding (control)', () => {
    expect(kinds('const { format } = nf;')).toEqual(['intlname:format']);
    expect(kinds('const { format: f } = nf;')).toEqual(['intlname:format']);
    expect(kinds('({ formatToParts } = nf);')).toEqual(['intlname:formatToParts']);
    expect(kinds('const a = nf[\'format\'](v);')).toEqual(['intlname:"format"']);
    expect(kinds('const a = nf["resolvedOptions"]();')).toEqual(['intlname:"resolvedOptions"']);
    expect(kinds('const a = nf[`formatRange`](1, 2);')).toEqual(['intlname:"formatRange"']);
    expect(kinds('const o = { fmt: nf.format };')).toEqual(['intlcall:.format']);
    expect(kinds('const o = { format };')).toEqual(['intlname:format']);
    expect(kinds('const format = 1;')).toEqual(['intlname:format']);
    expect(kinds('function f(formatRangeToParts: string) {}')).toEqual(['intlname:formatRangeToParts']);
    expect(kinds('interface I { format: string }')).toEqual(['intlname:format']);
    // whole identifiers only; comments and longer strings say nothing
    expect(kinds('const a = formatMoney(x); const b = formatDecimal(y); const c = reformat(z); const d = format2;')).toEqual([]);
    expect(kinds('// format() here\n/* const { format } = nf */ const s = "use format() here"; const t = `a format b`;')).toEqual([]);
    // string concatenation stays documented as not flagged
    expect(kinds('const a = nf[\'for\' + \'mat\'](v);')).toEqual([]);
  });
  it('the scanner is not fooled: comments, strings, regex literals, a marker and a leading `*` hide nothing and fake nothing (control)', () => {
    expect(kinds('// x.toFixed(2)\n/* Number(x) */\n/*\n * Number(x)\n */')).toEqual([]);
    expect(kinds('const a = "x.toFixed(2)"; const b = \'Number(x)\'; const c = `Math.round(1.5)`; const d = "nf.format(x)";')).toEqual([]);
    expect(kinds('const a = x.toFixed(2); // format-guard-allow: test')).toEqual(['member:.toFixed']);
    expect(kinds('const a = x\n  * 2;\nconst b = y\n  .toFixed(2);')).toEqual(['arith:x * 2', 'member:.toFixed']);
    expect(kinds('const r = /^[0-9]+\\/x$/; const s = a ? b : c;')).toEqual([]);
    expect(kinds('const n = Number.isNaN(x) || Number.isInteger(x) || Number.isSafeInteger(x); i++; j--; const k = a + b - 1; const l = -1;')).toEqual([]);
    expect(kinds('const t = `a ${b} c ${d ? `e ${f}` : ""} g`; const u = h.toFixed(1);')).toEqual(['member:.toFixed']);
  });
  it('the allow list is judged per file, kind, text AND source line, and an unused or extra entry is visible (control)', () => {
    const src = 'const a = x.toString();';
    const entry: Allowed = { file: 'f.ts', kind: 'member', text: '.toString', line: src, why: 't' };
    expect(judge('f.ts', src, [entry]).open).toEqual([]);
    expect(judge('g.ts', src, [entry]).open).toHaveLength(1);
    expect(judge('f.ts', src, []).open).toHaveLength(1);
    const twice = [entry];
    judge('f.ts', src + '\n' + src, twice);
    expect(twice).toHaveLength(0);
    // the same token text on a DIFFERENT line is not covered: swapping one use for another is a finding
    expect(judge('f.ts', 'const b = y.toString();', [entry]).open).toHaveLength(1);
    // an entry whose line no longer exists stays unconsumed (the `left` check of the src test then fails)
    const unused = [entry];
    judge('f.ts', 'const z = 1;', unused);
    expect(unused).toHaveLength(1);
    // moved to another line of the same file with the same text: the old pinned line is gone
    const moved = [entry];
    expect(judge('f.ts', 'const q = 0;\nconst a2 = x.toString();', moved).open).toHaveLength(1);
    expect(moved).toHaveLength(1);
  });
});

describe('the package shape: imports stay in src/, scripts, tsconfig files and the test files are pinned', () => {
  const pkgDir = fileURLToPath(new URL('../', import.meta.url));
  const root = join(pkgDir, 'src');
  const run = (put: Record<string, string>): string[] => {
    const base = mkdtempSync(join(tmpdir(), 'format-imports-'));
    try {
      const r = join(base, 'src');
      mkdirSync(r, { recursive: true });
      for (const [rel, text] of Object.entries(put)) {
        mkdirSync(join(r, rel.split('/').slice(0, -1).join('/')), { recursive: true });
        writeFileSync(join(r, rel), text);
      }
      return auditTree(r, []).open.filter((o) => / import-/.test(o)).map((o) => o.replace(/^[^ ]+ /, ''));
    } finally {
      rmSync(base, { recursive: true, force: true });
    }
  };
  const one = (file: string, text: string): string[] => run({ [file]: text });
  it('today src/ imports only siblings inside src/, and BARE_ALLOW is empty (no runtime dependency)', () => {
    expect(BARE_ALLOW).toEqual([]);
    const pkg = JSON.parse(readFileSync(join(pkgDir, 'package.json'), 'utf8')) as Record<string, unknown>;
    for (const k of ['dependencies', 'peerDependencies', 'optionalDependencies']) expect(pkg[k], k).toBeUndefined();
    let seen = 0;
    for (const f of walkSources(root).files) {
      const src = readFileSync(join(root, f), 'utf8');
      expect(importFindings(f, src), f).toEqual([]);
      seen += (src.match(/from '\.\/[a-z]+\.ts'/g) ?? []).length;
    }
    expect(seen).toBeGreaterThan(10);
  });
  it('specifiers: relative inside src/ pass; leaving src/, absolute, URL, bare, node: and #imports are findings (control)', () => {
    expect(one('x.ts', "import { a } from './a.ts';")).toEqual([]);
    expect(one('x.ts', "import { b } from './sub/b.ts';")).toEqual([]);
    expect(one('sub/x.ts', "import { a } from '../a.ts';")).toEqual([]);
    expect(one('x.ts', "import type { T } from './a.ts'; import './side.ts'; export { y } from './a.ts';")).toEqual([]);
    expect(one('x.ts', "export * from './a.ts';")).toEqual([]);
    // `export *` and `import * as` are not multiplications: the whole file audit (scan + imports) is clean
    expect(kinds("export * from './a.ts';\nimport * as ns from './a.ts';\nexport const k = ns;")).toEqual([]);
    expect(kinds('const m = a\n  * b;')).toEqual(['arith:a * b']);
    expect(one('x.ts', "import * as ns from './a.ts'; export const k = ns;")).toEqual([]);
    expect(one('x.ts', "import('./a.ts'); import(`./a.ts`); import('./a.ts', { with: { type: 'json' } });")).toEqual([]);
    expect(one('x.ts', "import { a } from '../src/a.ts';")).toEqual(['import-outside-src "../src/a.ts"']);
    expect(one('sub/x.ts', "import { f } from '../../extra/fast.ts';")).toEqual(['import-outside-src "../../extra/fast.ts"']);
    expect(one('x.ts', "import { h } from '../test/helper.ts';")).toEqual(['import-outside-src "../test/helper.ts"']);
    expect(one('x.ts', "import { h } from '/abs/path.ts';")).toEqual(['import-outside-src "/abs/path.ts"']);
    expect(one('x.ts', "import a from 'file:///etc/x.js'; import b from 'https://h/x.js';")).toEqual(['import-outside-src "file:///etc/x.js"', 'import-outside-src "https://h/x.js"']);
    expect(one('x.ts', "import { i } from '#internal';")).toEqual(['import-bare "#internal"']);
    expect(one('x.ts', "import c from 'fast-check'; import d from 'node:intl'; import e from '@scope/x'; import 'left-pad';")).toEqual(['import-bare "fast-check"', 'import-bare "node:intl"', 'import-bare "@scope/x"', 'import-bare "left-pad"']);
    expect(one('x.ts', 'import(name);')).toEqual(['import-dynamic "import("']);
    expect(one('x.ts', 'import(`./${name}.ts`);')).toEqual(['import-dynamic "import("']);
    expect(one('x.ts', "import('./a' + b);")).toEqual(['import-dynamic "import("']);
    expect(one('x.ts', "const r = require('../extra/x');")).toEqual(['import-outside-src "../extra/x"']);
    expect(one('x.ts', "import q = require('fast-check');")).toEqual(['import-bare "fast-check"']);
    expect(one('x.ts', 'const r = require(p);')).toEqual(['import-dynamic "require("']);
    expect(one('x.ts', "const r = loader.require('../q'); const s = obj?.import(p);")).toEqual([]);
    expect(one('x.ts', "const r = require('../q');")).toEqual(['import-outside-src "../q"']);
    // a method or signature DECLARATION named import / require is not a call; a ternary around a call is still a call
    expect(one('x.ts', 'class K { import(s: string) { return s; } }')).toEqual([]);
    expect(one('x.ts', 'type T = { require(s: string): unknown };')).toEqual([]);
    expect(one('x.ts', 'interface I { import(): void; require?(s?: string): unknown }')).toEqual([]);
    expect(one('x.ts', "const a = cond ? require('../q') : y;")).toEqual(['import-outside-src "../q"']);
    expect(one('x.ts', 'const a = cond ? require(p) : y;')).toEqual(['import-dynamic "require("']);
    expect(one('x.ts', "async function f() { return await import('../q'); }")).toEqual(['import-outside-src "../q"']);
    expect(one('x.ts', 'const a = import(x);')).toEqual(['import-dynamic "import("']);
    expect(one('x.ts', "export * as ns from '../extra/fast.ts';")).toEqual(['import-outside-src "../extra/fast.ts"']);
    expect(one('x.ts', "export { x } from '../extra/fast.ts';")).toEqual(['import-outside-src "../extra/fast.ts"']);
    expect(one('x.ts', '/// <reference path="../extra/types.d.ts" />\nexport const z = 1;')).toEqual(['import-outside-src "../extra/types.d.ts"']);
    expect(one('x.ts', '/// <reference path="./types.d.ts" />\nexport const z = 1;')).toEqual([]);
  });
  it('a specifier in a comment or inside a longer string is not one (control)', () => {
    expect(one('x.ts', "// import { a } from '../extra/x.ts'\n/* import('fast-check') */\nexport const s = \"import { a } from '../extra/x.ts'\";")).toEqual([]);
    expect(one('x.ts', "export const t = `from '../extra/x.ts' import('y')`;")).toEqual([]);
  });
  it("the reviewer's patch: an import of ../extra/fast.ts from money.ts or index.ts, or of ../test/helper.ts, is caught in a real tree", () => {
    const money = readFileSync(join(root, 'money.ts'), 'utf8');
    const index = readFileSync(join(root, 'index.ts'), 'utf8');
    expect(run({ 'money.ts': money, 'index.ts': index })).toEqual([]);
    expect(run({ 'money.ts': "import { fast } from '../extra/fast.ts';\n" + money })).toEqual(['import-outside-src "../extra/fast.ts"']);
    expect(run({ 'index.ts': index + "export { x } from '../extra/fast.ts';\n" })).toEqual(['import-outside-src "../extra/fast.ts"']);
    expect(run({ 'money.ts': "import { helper } from '../test/helper.ts';\n" + money })).toEqual(['import-outside-src "../test/helper.ts"']);
  });
  it('package.json scripts equal the shipped ones, and there is no other tsconfig*.json file in the package', () => {
    const pkg = JSON.parse(readFileSync(join(pkgDir, 'package.json'), 'utf8')) as { scripts?: unknown };
    expect(scriptsProblems(pkg.scripts)).toEqual([]);
    expect(readdirSync(pkgDir).filter((n) => /^tsconfig.*\.json$/i.test(n))).toEqual(['tsconfig.json']);
  });
  it('the scripts check refuses a changed or extra script (control)', () => {
    expect(scriptsProblems({ test: 'vitest run', typecheck: 'tsc -p tsconfig.json' })).toEqual([]);
    expect(scriptsProblems({ test: 'vitest run', typecheck: 'tsc -p tsconfig.build.json' })).toHaveLength(1);
    expect(scriptsProblems({ test: 'vitest run', typecheck: 'tsc -p tsconfig.json', extra: 'x' })).toHaveLength(1);
    expect(scriptsProblems(undefined)).toHaveLength(1);
  });
  it('the test files that pin the contract exist (deleting one would otherwise pass `pnpm test` unnoticed)', () => {
    expect(missingRequired(readdirSync(join(pkgDir, 'test')))).toEqual([]);
  });
  it('the required-files check names a missing file (control)', () => {
    expect(missingRequired([...REQUIRED_TESTS])).toEqual([]);
    expect(missingRequired(REQUIRED_TESTS.filter((n) => n !== 'readme.test.ts'))).toEqual(['readme.test.ts']);
  });
});
