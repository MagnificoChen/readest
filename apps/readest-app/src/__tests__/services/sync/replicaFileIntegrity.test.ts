import { describe, expect, test, vi } from 'vitest';
import { matchesManifest } from '@/services/sync/replicaFileIntegrity';
import { partialMD5 } from '@/utils/md5';
import type { ManifestFile } from '@/types/replica';
import type { AppService } from '@/types/system';

/** A file whose bytes are `fill`, at the given size. */
const fileOf = (size: number, fill: number, name = 'font.ttf'): File =>
  new File([new Uint8Array(size).fill(fill)], name);

const serviceFor = (file: File | null): AppService =>
  ({
    exists: vi.fn(async () => file !== null),
    openFile: vi.fn(async () => {
      if (!file) throw new Error('ENOENT');
      return file;
    }),
  }) as unknown as AppService;

const manifestFor = async (file: File): Promise<ManifestFile> => ({
  filename: file.name,
  byteSize: file.size,
  partialMd5: await partialMD5(file),
});

describe('matchesManifest', () => {
  test('accepts a file that matches the manifest', async () => {
    const file = fileOf(8192, 0x41);
    const service = serviceFor(file);

    expect(await matchesManifest(service, 'Fonts', 'bundle-1', await manifestFor(file))).toBe(true);
    expect(service.exists).toHaveBeenCalledWith('bundle-1/font.ttf', 'Fonts');
  });

  test('rejects a missing file without opening it', async () => {
    const service = serviceFor(null);
    const entry = await manifestFor(fileOf(8192, 0x41));

    expect(await matchesManifest(service, 'Fonts', 'bundle-1', entry)).toBe(false);
    expect(service.openFile).not.toHaveBeenCalled();
  });

  test('rejects a truncated file', async () => {
    const entry = await manifestFor(fileOf(8192, 0x41));
    const service = serviceFor(fileOf(4096, 0x41));

    expect(await matchesManifest(service, 'Fonts', 'bundle-1', entry)).toBe(false);
  });

  test('rejects a same-size file whose contents differ — the zero-filled hole a dropped download range leaves behind', async () => {
    const published = fileOf(8192, 0x41);
    const entry = await manifestFor(published);
    // Right length, wrong bytes: exactly what `set_len` + a skipped part produces.
    const holed = new File([new Uint8Array(8192)], 'font.ttf');
    const service = serviceFor(holed);

    expect(await matchesManifest(service, 'Fonts', 'bundle-1', entry)).toBe(false);
  });

  test('accepts on a read error rather than re-queueing the download every cycle', async () => {
    const entry = await manifestFor(fileOf(8192, 0x41));
    const service = {
      exists: vi.fn(async () => true),
      openFile: vi.fn(async () => {
        throw new Error('EACCES');
      }),
    } as unknown as AppService;
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});

    expect(await matchesManifest(service, 'Fonts', 'bundle-1', entry)).toBe(true);
    warn.mockRestore();
  });

  test('falls back to the size check when the manifest predates partialMd5', async () => {
    const file = fileOf(8192, 0x41);
    const service = serviceFor(file);
    const entry: ManifestFile = { filename: 'font.ttf', byteSize: 8192, partialMd5: '' };

    expect(await matchesManifest(service, 'Fonts', 'bundle-1', entry)).toBe(true);
  });
});
