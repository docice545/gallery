import base from '../vitest.config.medium.mjs';

// The parent medium suite owns the disposable PostgreSQL container and clone.
// A worker must use that clone, never create another fixture or load a real DB.
export default {
  ...base,
  test: {
    ...base.test,
    globalSetup: [],
    include: ['test/medium/quarantine-crash.worker.ts'],
    fileParallelism: false,
    testTimeout: 30_000,
  },
};
