import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import swc from 'unplugin-swc';
import { defineConfig } from 'vitest/config';

const serverRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');

export default defineConfig({
  resolve: {
    tsconfigPaths: true,
  },
  test: {
    // FOTO_CODEX_MEMORY_SAFETY_V2
    maxWorkers: 1,
    fileParallelism: false,
    name: 'server:medium',
    root: serverRoot,
    globals: true,
    include: ['test/medium/**/*.spec.ts'],
    globalSetup: ['test/medium/globalSetup.ts'],
  },
  plugins: [swc.vite()],
});
