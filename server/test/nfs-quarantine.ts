import { constants } from 'node:fs';
import fs from 'node:fs/promises';
import { vi } from 'vitest';

const isQuarantine = (path: unknown) => String(path).endsWith('/.gallery-deletion-quarantine');

// Only metadata and mkdir's mode are injected. Descriptor chmod, rename,
// directory fsync, hashing and unlink still operate on real disposable files.
// This is not a claim of validation on a real NFS server.
export async function emulateNfsRootSquash(root: string) {
  const rootHandle = await fs.open(root, constants.O_RDONLY | constants.O_DIRECTORY);
  let mountId: string;
  try {
    mountId = /^mnt_id:\s*(\d+)$/m.exec(await fs.readFile('/proc/self/fdinfo/' + rootHandle.fd, 'utf8'))![1];
  } finally {
    await rootHandle.close();
  }
  vi.spyOn(process, 'getuid').mockReturnValue(0);
  vi.spyOn(process, 'getgid').mockReturnValue(0);
  const readActual = fs.readFile;
  vi.spyOn(fs, 'readFile').mockImplementation(async (path, options) => {
    const result = await readActual(path, options);
    if (String(path) !== '/proc/self/mountinfo' || typeof result !== 'string') return result;
    return result
      .split('\n')
      .map((line) =>
        line.startsWith(mountId + ' ') ? line.split(' - ', 1)[0] + ' - nfs 192.0.2.10:/test-export rw,vers=3' : line,
      )
      .join('\n');
  });
  let uid = 1024;
  let gid = 100;
  const mapped = <T extends { uid: number | bigint; gid: number | bigint }>(stat: T) =>
    Object.assign(stat, {
      uid: typeof stat.uid === 'bigint' ? BigInt(uid) : uid,
      gid: typeof stat.gid === 'bigint' ? BigInt(gid) : gid,
    });
  const statActual = fs.lstat;
  vi.spyOn(fs, 'lstat').mockImplementation(async (path, options) => {
    const stat = await statActual(path, options);
    return isQuarantine(path) ? mapped(stat) : stat;
  });
  const openActual = fs.open;
  vi.spyOn(fs, 'open').mockImplementation(async (path, flags, mode) => {
    const handle = await openActual(path, flags, mode);
    if (isQuarantine(path)) {
      const statActual = handle.stat.bind(handle);
      vi.spyOn(handle, 'stat').mockImplementation(async (options) => mapped(await statActual(options)));
    }
    return handle;
  });
  const mkdirActual = fs.mkdir;
  const chmodActual = fs.chmod;
  vi.spyOn(fs, 'mkdir').mockImplementation(async (path, options) => {
    const result = await mkdirActual(path, options);
    if (isQuarantine(path)) await chmodActual(path, 0o777);
    return result;
  });
  return {
    setOwner: (owner: number, group: number) => {
      uid = owner;
      gid = group;
    },
  };
}
