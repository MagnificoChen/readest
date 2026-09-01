import { partialMD5 } from '@/utils/md5';
import type { ManifestFile } from '@/types/replica';
import type { AppService, BaseDir } from '@/types/system';

/**
 * Whether the local copy of one manifest file is the file that was published.
 *
 * Existence alone is not enough. A download that loses a byte range writes a
 * file of exactly the right length with a zero-filled hole in it, and because
 * the orchestrator skips any bundle whose files are "already there", such a
 * file is never re-fetched — a synced font stays permanently short of glyphs.
 * Size catches a truncated file; the manifest's `partialMd5` (sampled at
 * exponentially spaced offsets, so ~12 KB of reads whatever the file size)
 * catches the holes that leave the length intact. Both values come from the
 * manifest the publishing device committed, so this costs no round trip.
 *
 * Fail-open on a read error: an unreadable file is a local problem of its own,
 * and answering "damaged" would re-queue the download on every pull cycle.
 */
export const matchesManifest = async (
  service: AppService,
  base: BaseDir,
  bundleDir: string,
  file: ManifestFile,
): Promise<boolean> => {
  const path = `${bundleDir}/${file.filename}`;
  if (!(await service.exists(path, base))) return false;
  try {
    const local = await service.openFile(path, base);
    if (file.byteSize > 0 && local.size !== file.byteSize) return false;
    if (!file.partialMd5) return true;
    return (await partialMD5(local)) === file.partialMd5;
  } catch (err) {
    console.warn('replica file verification failed', path, err);
    return true;
  }
};
