import { afterEach, describe, expect, test, vi } from 'vitest';

vi.mock('@/utils/bridge', () => ({
  getSecureItem: vi.fn(),
  setSecureItem: vi.fn(),
  clearSecureItem: vi.fn(),
  isSyncKeychainAvailable: vi.fn(),
}));
vi.mock('@/services/environment', () => ({ isTauriAppPlatform: vi.fn() }));

import {
  clearSecureItem,
  getSecureItem,
  isSyncKeychainAvailable,
  setSecureItem,
} from '@/utils/bridge';
import { isTauriAppPlatform } from '@/services/environment';
import { FileSyncError } from '@/services/sync/file/provider';
import {
  createKeychainTokenPersistence,
  KeychainTokenPersistence,
} from '@/services/sync/providers/oauth/keychainTokenStore';

const KEY = 'gdrive_token_set';
const LABEL = 'Google Drive';

const tokens = { accessToken: 'AT', refreshToken: 'RT', expiresAt: 123 };

const partKeyOf = (key: string, index: number) => `${key}__part${index}`;

afterEach(() => vi.clearAllMocks());

describe('KeychainTokenPersistence', () => {
  test('save serialises through the keyed secure-KV and fails loud on rejection', async () => {
    vi.mocked(setSecureItem).mockResolvedValueOnce({ success: true });
    vi.mocked(getSecureItem).mockResolvedValue({});
    await new KeychainTokenPersistence(KEY, LABEL).save(tokens);
    expect(setSecureItem).toHaveBeenCalledWith({
      key: KEY,
      value: JSON.stringify(tokens),
    });

    vi.mocked(setSecureItem).mockResolvedValueOnce({ success: false, error: 'denied' });
    await expect(new KeychainTokenPersistence(KEY, LABEL).save(tokens)).rejects.toBeInstanceOf(
      FileSyncError,
    );
  });

  test('save error message includes the provider label', async () => {
    vi.mocked(setSecureItem).mockResolvedValueOnce({ success: false, error: 'denied' });
    await expect(new KeychainTokenPersistence(KEY, LABEL).save(tokens)).rejects.toThrow(LABEL);
  });

  test('load parses a stored token set; returns null when absent or on error', async () => {
    const byKey = vi
      .mocked(getSecureItem)
      .mockImplementation(async ({ key }) =>
        key === KEY ? { value: JSON.stringify(tokens) } : {},
      );
    expect(await new KeychainTokenPersistence(KEY, LABEL).load()).toEqual(tokens);
    byKey.mockRestore();

    const err = vi.mocked(getSecureItem).mockImplementation(async () => ({ error: 'no item' }));
    expect(await new KeychainTokenPersistence(KEY, LABEL).load()).toBeNull();
    err.mockRestore();

    const empty = vi.mocked(getSecureItem).mockImplementation(async () => ({}));
    expect(await new KeychainTokenPersistence(KEY, LABEL).load()).toBeNull();
    empty.mockRestore();
  });

  test('save drops the access token when the set exceeds the size budget', async () => {
    // Windows Credential Manager caps a credential blob at 2560 bytes
    // (1280 UTF-16 chars); a Microsoft token set (long JWT access token)
    // exceeds it.
    const big = { accessToken: 'A'.repeat(3000), refreshToken: 'RT', expiresAt: 123 };
    vi.mocked(setSecureItem).mockResolvedValueOnce({ success: true });
    vi.mocked(getSecureItem).mockResolvedValue({});
    await new KeychainTokenPersistence(KEY, LABEL).save(big);
    const persisted = JSON.parse(vi.mocked(setSecureItem).mock.calls[0]![0].value);
    expect(persisted.accessToken).toBeUndefined();
    expect(persisted.refreshToken).toBe('RT');
    expect(persisted.expiresAt).toBe(123);
  });

  test('save keeps the full set when it fits the size budget', async () => {
    vi.mocked(setSecureItem).mockResolvedValue({ success: true });
    vi.mocked(getSecureItem).mockResolvedValue({});
    await new KeychainTokenPersistence(KEY, LABEL).save(tokens);
    expect(vi.mocked(setSecureItem).mock.calls[0]![0].value).toBe(JSON.stringify(tokens));
  });

  test('save splits a value whose refresh token alone exceeds the budget', async () => {
    // Personal Microsoft accounts issue refresh tokens longer than the
    // 2560-byte (1280-char) Windows credential cap; the slim form has to split.
    const huge = { accessToken: 'A', refreshToken: 'R'.repeat(5000), expiresAt: 123 };
    vi.mocked(setSecureItem).mockResolvedValue({ success: true });
    vi.mocked(clearSecureItem).mockResolvedValue({ success: true });
    await new KeychainTokenPersistence(KEY, LABEL).save(huge);

    const writes = vi.mocked(setSecureItem).mock.calls;
    const partWrites = writes.filter((c) => c[0].key.includes('__part'));
    expect(partWrites.length).toBeGreaterThanOrEqual(3);
    const chunks = partWrites.map((c) => c[0].value);
    for (const chunk of chunks) {
      expect(Number(chunk.slice(0, chunk.indexOf(':')))).toBe(partWrites.length);
    }
    const reassembled = JSON.parse(chunks.map((c) => c.slice(c.indexOf(':') + 1)).join(''));
    expect(reassembled.refreshToken).toBe('R'.repeat(5000));
    // The legacy single credential is cleared so load sees only the split form.
    expect(vi.mocked(clearSecureItem).mock.calls.some((c) => c[0].key === KEY)).toBe(true);
  });

  test('load reassembles a split form back into the token set', async () => {
    const slim = JSON.stringify({ refreshToken: 'R'.repeat(5000), expiresAt: 123 });
    const count = Math.ceil(slim.length / 1000);
    const parts: Record<string, string> = {};
    for (let i = 0; i < count; i++) {
      parts[partKeyOf(KEY, i)] = `${count}:${slim.slice(i * 1000, (i + 1) * 1000)}`;
    }
    vi.mocked(getSecureItem).mockImplementation(async ({ key }) =>
      parts[key] ? { value: parts[key] } : {},
    );
    const loaded = await new KeychainTokenPersistence(KEY, LABEL).load();
    expect(loaded).toEqual({
      accessToken: '',
      refreshToken: 'R'.repeat(5000),
      expiresAt: 0,
    });
  });

  test('load returns null when a split form is missing a chunk', async () => {
    const slim = JSON.stringify({ refreshToken: 'R'.repeat(5000), expiresAt: 123 });
    const count = Math.ceil(slim.length / 1000);
    const parts: Record<string, string> = {};
    for (let i = 0; i < count - 1; i++) {
      parts[partKeyOf(KEY, i)] = `${count}:${slim.slice(i * 1000, (i + 1) * 1000)}`;
    }
    vi.mocked(getSecureItem).mockImplementation(async ({ key }) =>
      parts[key] ? { value: parts[key] } : {},
    );
    expect(await new KeychainTokenPersistence(KEY, LABEL).load()).toBeNull();
  });

  test('load rebuilds an expired-marker access token for a slim persisted set', async () => {
    const slim = { refreshToken: 'RT', expiresAt: 123 };
    vi.mocked(getSecureItem).mockImplementation(async ({ key }) =>
      key === KEY ? { value: JSON.stringify(slim) } : {},
    );
    const loaded = await new KeychainTokenPersistence(KEY, LABEL).load();
    expect(loaded).toEqual({ accessToken: '', refreshToken: 'RT', expiresAt: 0 });
  });

  test('load rejects a persisted form with neither token', async () => {
    vi.mocked(getSecureItem).mockImplementation(async ({ key }) =>
      key === KEY ? { value: JSON.stringify({ expiresAt: 1 }) } : {},
    );
    expect(await new KeychainTokenPersistence(KEY, LABEL).load()).toBeNull();
  });

  test('clear removes the legacy credential and every split chunk', async () => {
    vi.mocked(clearSecureItem).mockResolvedValue({ success: true });
    await new KeychainTokenPersistence(KEY, LABEL).clear();
    expect(clearSecureItem).toHaveBeenCalledWith({ key: KEY });
    const clearedKeys = vi.mocked(clearSecureItem).mock.calls.map((c) => c[0].key);
    expect(clearedKeys).toContain(partKeyOf(KEY, 0));
    expect(clearedKeys).toContain(partKeyOf(KEY, 15));
  });
});

describe('createKeychainTokenPersistence', () => {
  test('returns null off-Tauri (no ephemeral fallback for the refresh token)', async () => {
    vi.mocked(isTauriAppPlatform).mockReturnValue(false);
    expect(await createKeychainTokenPersistence(KEY, LABEL)).toBeNull();
    expect(isSyncKeychainAvailable).not.toHaveBeenCalled();
  });

  test('returns a keychain store when the probe reports available', async () => {
    vi.mocked(isTauriAppPlatform).mockReturnValue(true);
    vi.mocked(isSyncKeychainAvailable).mockResolvedValueOnce({ available: true });
    expect(await createKeychainTokenPersistence(KEY, LABEL)).toBeInstanceOf(
      KeychainTokenPersistence,
    );
  });

  test('returns null when the keychain is unavailable', async () => {
    vi.mocked(isTauriAppPlatform).mockReturnValue(true);
    vi.mocked(isSyncKeychainAvailable).mockResolvedValueOnce({ available: false });
    expect(await createKeychainTokenPersistence(KEY, LABEL)).toBeNull();
  });
});
