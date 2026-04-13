import assert from "node:assert/strict";

const maxRetries = 3;

function simulateNotification({ mode, tokens }) {
  const notification = {
    id: "notif-1",
    status: "pending",
    retries_count: 0,
    logs: [],
  };

  const tokenState = tokens.map((token, index) => ({
    id: `token-${index + 1}`,
    token,
    is_active: true,
  }));

  const attempts = new Map();

  while (notification.status !== "sent" && notification.retries_count < maxRetries) {
    const activeTokens = tokenState.filter((token) => token.is_active);
    if (activeTokens.length === 0) {
      notification.status = "failed";
      notification.retries_count = maxRetries;
      notification.error = "No active FCM tokens available for this user.";
      break;
    }

    let anySuccess = false;
    let sawRetryableFailure = false;
    let invalidTokenCount = 0;

    for (const token of activeTokens) {
      const key = `${notification.id}:${token.id}`;
      const nextAttempt = (attempts.get(key) ?? 0) + 1;
      attempts.set(key, nextAttempt);

      const result = resolveSimulatedSend(mode, nextAttempt);
      notification.logs.push({
        tokenId: token.id,
        ok: result.ok,
        invalidToken: result.invalidToken,
        error: result.error ?? null,
      });

      if (result.ok) {
        anySuccess = true;
        continue;
      }

      if (result.invalidToken) {
        invalidTokenCount += 1;
        token.is_active = false;
      } else {
        sawRetryableFailure = true;
      }
    }

    if (anySuccess) {
      notification.status = "sent";
      break;
    }

    const allTokensInvalid = invalidTokenCount === activeTokens.length;
    notification.status = "failed";
    notification.retries_count = allTokensInvalid && !sawRetryableFailure
      ? maxRetries
      : notification.retries_count + 1;
    notification.error = allTokensInvalid
      ? "Simulated invalid FCM token."
      : "Simulated transient delivery failure.";
  }

  return { notification, tokenState };
}

function resolveSimulatedSend(mode, attempt) {
  switch (mode) {
    case "success":
      return { ok: true, invalidToken: false };
    case "retry_then_success":
      return attempt >= 2
        ? { ok: true, invalidToken: false }
        : {
            ok: false,
            invalidToken: false,
            error: "Simulated transient delivery failure.",
          };
    case "invalid_token":
      return {
        ok: false,
        invalidToken: true,
        error: "Simulated invalid FCM token.",
      };
    case "always_fail":
      return {
        ok: false,
        invalidToken: false,
        error: "Simulated transient delivery failure.",
      };
    default:
      throw new Error(`Unsupported simulation mode: ${mode}`);
  }
}

function runScenario(name, runner) {
  try {
    runner();
    console.log(`[PASS] ${name}`);
  } catch (error) {
    console.error(`[FAIL] ${name}`);
    console.error(error);
    process.exitCode = 1;
  }
}

runScenario("Marks notification sent only after success", () => {
  const { notification } = simulateNotification({
    mode: "success",
    tokens: ["token-a"],
  });

  assert.equal(notification.status, "sent");
  assert.equal(notification.retries_count, 0);
  assert.equal(notification.logs.length, 1);
});

runScenario("Retries after failure and then marks sent on later success", () => {
  const { notification } = simulateNotification({
    mode: "retry_then_success",
    tokens: ["token-a"],
  });

  assert.equal(notification.status, "sent");
  assert.equal(notification.retries_count, 1);
  assert.equal(notification.logs.length, 2);
});

runScenario("Invalid tokens stop retrying infinitely", () => {
  const { notification, tokenState } = simulateNotification({
    mode: "invalid_token",
    tokens: ["token-a"],
  });

  assert.equal(notification.status, "failed");
  assert.equal(notification.retries_count, 3);
  assert.equal(tokenState[0].is_active, false);
});

runScenario("Transient failures stop at the retry ceiling", () => {
  const { notification } = simulateNotification({
    mode: "always_fail",
    tokens: ["token-a"],
  });

  assert.equal(notification.status, "failed");
  assert.equal(notification.retries_count, 3);
  assert.equal(notification.logs.length, 3);
});
