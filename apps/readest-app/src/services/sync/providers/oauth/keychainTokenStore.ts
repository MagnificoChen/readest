/**
 * OS-keychain token persistence over the keyed secure-KV bridge, shared by every
 * OAuth provider. Keyed by a caller-supplied storage key so each provider owns a
 * distinct slot; `label` names the provider in error/log messages. `load` is
 * fail-soft (a keychain error reads as "not connected"); `save` is fail-loud (the
 * connect flow must know the token did not persist). No ephemeral fallback for
 * the refresh token — a provider is simply unavailable where secure storage is.
 */
import { isTauriAppPlatform } from '@/services/environment';
import {
  clearSecureItem,
  getSecureItem,
  isSyncKeychainAvailable,
  setSecureItem,
} from '@/utils/bridge';
import { FileSyncError } from '@/services/sync/file/provider';
import type { TokenSet } from './tokenEndpoint';

export interface TokenPersistence {
  load(): Promise<TokenSet | null>;
  save(tokens: TokenSet): Promise<void>;
  clear(): Promise<void>;
}

/**
 * Windows Credential Manager caps a single generic credential's secret blob at
 * 2560 *bytes*; with the keyring's UTF-16 encoding that is 1280 chars (verified
 * empirically: 1280 chars writes, 1281 fails). Microsoft token sets exceed
 * that: the access token is a long JWT and even the refresh token alone can run
 * past the cap on personal Microsoft accounts. Two measures keep the value
 * storable: the short-lived access token (refreshable at any time from the
 * refresh token) is dropped from the persisted form, and any value still over
 * the single-credential budget is split across several credentials
 * (`<key>__part0..N`), each chunk prefixed `<count>:` so load can reassemble
 * and validate the sequence.
 */
const PERSISTED_MAX_CHARS = 1200;

/** Per-credential chunk size for the split form; safe under the 1280-char cap. */
const PART_CHUNK_CHARS = 1000;

/** Safety bound on split credentials; far above any real token set. */
const MAX_PARTS = 16;

/** Storage key of chunk `index` of the split form. */
const partKey = (key: string, index: number) => `${key}__part${index}`;

/**
 * Token-set form safe to persist. `accessToken` is optional here only because
 * it is dropped under the platform size budget; in memory a loaded set without
 * it is immediately refreshed on first use.
 */
interface PersistedTokenSet extends Omit<TokenSet, 'accessToken'> {
  accessToken?: string;
}

/** Whether the JSON form of a token set fits the single-credential budget. */
const fitsBudget = (tokens: PersistedTokenSet): boolean =>
  JSON.stringify(tokens).length <= PERSISTED_MAX_CHARS;

/** A refreshable persisted form: the access token may be dropped to fit. */
const toPersistedForm = (tokens: TokenSet): PersistedTokenSet =>
  fitsBudget(tokens) ? tokens : { ...tokens, accessToken: undefined };

/** Reject a persisted form that could never be refreshed back to usable. */
const isUsablePersistedForm = (tokens: PersistedTokenSet): tokens is PersistedTokenSet =>
  typeof tokens.accessToken === 'string' || typeof tokens.refreshToken === 'string';

export class KeychainTokenPersistence implements TokenPersistence {
  constructor(
    private readonly key: string,
    private readonly label: string,
  ) {}

  async load(): Promise<TokenSet | null> {
    try {
      const first = await getSecureItem({ key: partKey(this.key, 0) });
      let json: string | null;
      if (first.value && !first.error) {
        json = await this.readParts(first.value);
      } else {
        const legacy = await getSecureItem({ key: this.key });
        json = legacy.value && !legacy.error ? legacy.value : null;
      }
      if (!json) return null;
      const persisted = JSON.parse(json) as PersistedTokenSet;
      if (!isUsablePersistedForm(persisted)) return null;
      // A set persisted without its access token (dropped for the Windows size
      // budget) gets a synthetic, already-expired one so every consumer treats
      // it as stale and refreshes from the refresh token on first use.
      const accessToken = persisted.accessToken ?? '';
      const expiresAt = persisted.accessToken ? persisted.expiresAt : 0;
      return { ...persisted, accessToken, expiresAt };
    } catch (err) {
      console.warn(`[${this.label}] token load failed`, err);
      return null;
    }
  }

  /**
   * Reassemble the split form from `part0`'s declared chunk count. Returns null
   * (reads as "not connected") on any missing or inconsistent chunk so a stale
   * or partial sequence is never parsed as a token set.
   */
  private async readParts(firstPart: string): Promise<string | null> {
    const separator = firstPart.indexOf(':');
    if (separator <= 0) return null;
    const count = Number(firstPart.slice(0, separator));
    if (!Number.isInteger(count) || count < 1 || count > MAX_PARTS) return null;
    const chunks = [firstPart.slice(separator + 1)];
    for (let i = 1; i < count; i++) {
      const res = await getSecureItem({ key: partKey(this.key, i) });
      if (res.error || !res.value) return null;
      const sep = res.value.indexOf(':');
      if (sep <= 0 || Number(res.value.slice(0, sep)) !== count) return null;
      chunks.push(res.value.slice(sep + 1));
    }
    return chunks.join('');
  }

  async save(tokens: TokenSet): Promise<void> {
    const json = JSON.stringify(toPersistedForm(tokens));
    if (json.length <= PERSISTED_MAX_CHARS) {
      await this.write(this.key, json);
      // Drop any chunks left by a previous split save so load never sees both forms.
      if (await this.hasParts()) await this.clearParts(0);
      return;
    }
    const count = Math.ceil(json.length / PART_CHUNK_CHARS);
    for (let i = 0; i < count; i++) {
      const chunk = json.slice(i * PART_CHUNK_CHARS, (i + 1) * PART_CHUNK_CHARS);
      await this.write(partKey(this.key, i), `${count}:${chunk}`);
    }
    await clearSecureItem({ key: this.key });
    await this.clearParts(count);
  }

  async clear(): Promise<void> {
    try {
      await clearSecureItem({ key: this.key });
      await this.clearParts(0);
    } catch (err) {
      console.warn(`[${this.label}] token clear failed`, err);
    }
  }

  private async write(key: string, value: string): Promise<void> {
    const res = await setSecureItem({ key, value });
    if (!res.success) {
      throw new FileSyncError(
        `OS keychain rejected the ${this.label} token: ${res.error ?? 'unknown error'}`,
        'AUTH_FAILED',
      );
    }
  }

  private async hasParts(): Promise<boolean> {
    const res = await getSecureItem({ key: partKey(this.key, 0) });
    return !res.error && !!res.value;
  }

  private async clearParts(from: number): Promise<void> {
    for (let i = from; i < MAX_PARTS; i++) {
      await clearSecureItem({ key: partKey(this.key, i) });
    }
  }
}

export const createKeychainTokenPersistence = async (
  key: string,
  label: string,
): Promise<TokenPersistence | null> => {
  if (!isTauriAppPlatform()) return null;
  try {
    const res = await isSyncKeychainAvailable();
    if (res.available) return new KeychainTokenPersistence(key, label);
  } catch (err) {
    console.warn(`[${label}] keychain probe threw`, err);
  }
  return null;
};
