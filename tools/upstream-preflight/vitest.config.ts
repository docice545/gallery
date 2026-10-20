import { defineConfig } from 'vitest/config';

export default defineConfig({
  test: {
    // FOTO_CODEX_MEMORY_SAFETY_V2
    maxWorkers: 1,
    fileParallelism: false,
    environment: 'node',
    include: ['src/**/*.spec.ts'],
  },
});
