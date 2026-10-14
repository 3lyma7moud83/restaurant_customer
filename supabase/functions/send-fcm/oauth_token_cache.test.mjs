import assert from "node:assert/strict";
import test from "node:test";

import { OAuthAccessTokenCache } from "./oauth_token_cache.ts";

const accountKey = "project|service@example.test|token-uri";

test("returns a valid cached token without refreshing", async () => {
  let now = 1_000;
  let refreshes = 0;
  const cache = new OAuthAccessTokenCache({ now: () => now });
  const refresh = async () => ({
    accountKey,
    token: `token-${++refreshes}`,
    refreshAtMs: 9_000,
    expiresAtMs: 10_000,
  });

  assert.equal(await cache.get({ accountKey, refresh }), "token-1");
  now = 8_999;
  assert.equal(await cache.get({ accountKey, refresh }), "token-1");
  assert.equal(refreshes, 1);
});

test("refreshes at the configured early-refresh boundary", async () => {
  let now = 1_000;
  let refreshes = 0;
  const cache = new OAuthAccessTokenCache({ now: () => now });
  const refresh = async () => ({
    accountKey,
    token: `token-${++refreshes}`,
    refreshAtMs: 9_000,
    expiresAtMs: 10_000,
  });

  await cache.get({ accountKey, refresh });
  now = 9_000;
  assert.equal(await cache.get({ accountKey, refresh }), "token-2");
  assert.equal(refreshes, 2);
});

test("shares one concurrent refresh for the same account", async () => {
  let resolveRefresh;
  let refreshes = 0;
  const cache = new OAuthAccessTokenCache();
  const gate = new Promise((resolve) => {
    resolveRefresh = resolve;
  });
  const refresh = async () => {
    refreshes += 1;
    await gate;
    return {
      accountKey,
      token: "shared-token",
      refreshAtMs: Date.now() + 9_000,
      expiresAtMs: Date.now() + 10_000,
    };
  };

  const first = cache.get({ accountKey, refresh });
  const second = cache.get({ accountKey, refresh });
  resolveRefresh();

  assert.deepEqual(await Promise.all([first, second]), ["shared-token", "shared-token"]);
  assert.equal(refreshes, 1);
});
