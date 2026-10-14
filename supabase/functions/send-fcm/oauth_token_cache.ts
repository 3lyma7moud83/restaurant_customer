export type CachedOAuthAccessToken = {
  accountKey: string;
  token: string;
  expiresAtMs: number;
  refreshAtMs: number;
};

/// Caches short-lived OAuth tokens for the lifetime of a warm Edge isolate.
/// A refresh is shared per account so concurrent notification batches do not
/// request duplicate Google tokens.
export class OAuthAccessTokenCache {
  constructor({ now = () => Date.now() }: { now?: () => number } = {}) {
    this.#now = now;
  }

  readonly #now: () => number;
  readonly #tokens = new Map<string, CachedOAuthAccessToken>();
  readonly #refreshes = new Map<string, Promise<string>>();

  async get({
    accountKey,
    refresh,
  }: {
    accountKey: string;
    refresh: () => Promise<CachedOAuthAccessToken>;
  }): Promise<string> {
    const cached = this.#tokens.get(accountKey);
    const now = this.#now();
    if (cached != null && cached.refreshAtMs > now && cached.expiresAtMs > now) {
      return cached.token;
    }

    const inFlight = this.#refreshes.get(accountKey);
    if (inFlight != null) {
      return inFlight;
    }

    const refreshPromise = refresh().then((token) => {
      this.#tokens.set(accountKey, token);
      return token.token;
    });
    this.#refreshes.set(accountKey, refreshPromise);
    try {
      return await refreshPromise;
    } finally {
      if (this.#refreshes.get(accountKey) === refreshPromise) {
        this.#refreshes.delete(accountKey);
      }
    }
  }
}
