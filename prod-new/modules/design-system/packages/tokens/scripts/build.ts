import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { built, toCss, toJson, toTs } from '../src/index.ts';

export function writeDist(outDir: string): void {
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'tokens.css'), toCss(built));
  writeFileSync(join(outDir, 'tokens.json'), toJson(built));
  writeFileSync(join(outDir, 'tokens.ts'), toTs(built));
}

const here = dirname(fileURLToPath(import.meta.url));
if (process.argv[1] !== undefined && fileURLToPath(import.meta.url) === process.argv[1]) {
  const out = process.argv[2] ?? join(here, '..', 'dist');
  writeDist(out);
  console.log(`tokens: wrote css, json, ts to ${out}`);
}
