import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { dark, light, toThemeCss } from '../src/index.ts';

export function writeDist(outDir: string): void {
  mkdirSync(outDir, { recursive: true });
  writeFileSync(join(outDir, 'theme.css'), toThemeCss(light, dark));
}

if (process.argv[1] !== undefined && fileURLToPath(import.meta.url) === process.argv[1]) {
  const out = process.argv[2] ?? join(dirname(fileURLToPath(import.meta.url)), '..', 'dist');
  writeDist(out);
  console.log(`theme: wrote css to ${out}`);
}
