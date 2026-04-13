import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

type NotificationStatus = "pending" | "sent" | "failed";

type SimulationMode =
  | "success"
  | "retry_then_success"
  | "always_fail"
  | "invalid_token";

interface NotificationRow {
  id: string;
  user_id: string;
  title: string;
  body: string;
  status: NotificationStatus;
  retries_count: number;
  last_attempt_at: string | null;
  payload: Record<string, unknown> | null;
  error_message: string | null;
}

interface PushTokenRow {
  id: string;
  user_id: string;
  token: string;
  platform: string;
  device_label: string | null;
  is_active: boolean;
  last_error: string | null;
}

interface DeliveryLogInsert {
  notification_id: string;
  token_id: string | null;
  request_payload: Record<string, unknown>;
  response_payload?: Record<string, unknown> | null;
  error_message?: string | null;
}

interface FcmSendResult {
  ok: boolean;
  invalidToken: boolean;
  responseBody: Record<string, unknown>;
  errorMessage?: string;
}

interface ProcessorSummary {
  processed: number;
  sent: number;
  failed: number;
  exhausted: number;
  deliveryLogs: number;
}

interface ProcessRequestBody {
  simulate?: {
    mode?: SimulationMode;
  };
}

interface FcmClient {
  send(
    notification: NotificationRow,
    token: PushTokenRow,
  ): Promise<{ requestPayload: Record<string, unknown>; result: FcmSendResult }>;
}

const maxRetries = 3;
const queueBatchSize = 50;

Deno.serve(async (request) => {
  if (request.method !== "GET" && request.method !== "POST") {
    return jsonResponse(
      { error: "Method not allowed. Use GET or POST." },
      405,
    );
  }

  const supabaseUrl = mustGetEnv("SUPABASE_URL");
  const serviceRoleKey = mustGetEnv("SUPABASE_SERVICE_ROLE_KEY");

  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  let simulationMode: SimulationMode | undefined;
  if (request.method === "POST") {
    const body = await safeJson(request);
    simulationMode = body?.simulate?.mode;
  }

  const fcmClient = simulationMode
    ? new SimulationFcmClient(simulationMode)
    : new GoogleFcmClient();

  const processor = new NotificationProcessor(supabase, fcmClient);
  const summary = await processor.processAllPendingNotifications();

  return jsonResponse(
    {
      ok: true,
      simulationMode: simulationMode ?? null,
      summary,
    },
    200,
  );
});

class NotificationProcessor {
  constructor(
    private readonly supabase: SupabaseClient,
    private readonly fcmClient: FcmClient,
  ) {}

  async processAllPendingNotifications(): Promise<ProcessorSummary> {
    const summary: ProcessorSummary = {
      processed: 0,
      sent: 0,
      failed: 0,
      exhausted: 0,
      deliveryLogs: 0,
    };

    let loopCount = 0;
    while (true) {
      loopCount += 1;
      if (loopCount > 500) {
        throw new Error(
          "Safety stop triggered while processing notifications.",
        );
      }

      const notifications = await this.fetchDeliverableNotifications();
      if (notifications.length === 0) {
        return summary;
      }

      for (const notification of notifications) {
        summary.processed += 1;
        const result = await this.processNotification(notification);
        summary.deliveryLogs += result.deliveryLogs;

        if (result.status === "sent") {
          summary.sent += 1;
          continue;
        }

        summary.failed += 1;
        if (result.exhausted) {
          summary.exhausted += 1;
        }
      }
    }
  }

  private async fetchDeliverableNotifications(): Promise<NotificationRow[]> {
    const { data, error } = await this.supabase
      .from("notifications")
      .select(
        "id, user_id, title, body, status, retries_count, last_attempt_at, payload, error_message",
      )
      .in("status", ["pending", "failed"])
      .lt("retries_count", maxRetries)
      .order("created_at", { ascending: true })
      .limit(queueBatchSize);

    if (error) {
      throw new Error(`Failed to fetch pending notifications: ${error.message}`);
    }

    return (data ?? []) as NotificationRow[];
  }

  private async processNotification(
    initialNotification: NotificationRow,
  ): Promise<{ status: NotificationStatus; exhausted: boolean; deliveryLogs: number }> {
    let current = initialNotification;
    let deliveryLogs = 0;

    while (current.retries_count < maxRetries && current.status !== "sent") {
      const tokens = await this.fetchActiveTokens(current.user_id);
      const attemptAt = new Date().toISOString();

      if (tokens.length === 0) {
        await this.markNotificationFailed({
          notification: current,
          attemptAt,
          nextRetriesCount: maxRetries,
          errorMessage: "No active FCM tokens available for this user.",
        });

        return {
          status: "failed",
          exhausted: true,
          deliveryLogs,
        };
      }

      let anySuccess = false;
      let sawRetryableFailure = false;
      let invalidTokenCount = 0;
      let lastErrorMessage: string | null = null;

      for (const token of tokens) {
        const { requestPayload, result } = await this.fcmClient.send(
          current,
          token,
        );

        await this.insertDeliveryLog({
          notification_id: current.id,
          token_id: token.id,
          request_payload: requestPayload,
          response_payload: result.responseBody,
          error_message: result.errorMessage ?? null,
        });
        deliveryLogs += 1;

        console.log(
          JSON.stringify({
            type: "notification_delivery_attempt",
            notification_id: current.id,
            token_id: token.id,
            token_suffix: token.token.slice(-8),
            request_payload: requestPayload,
            response_payload: result.responseBody,
            error_message: result.errorMessage ?? null,
          }),
        );

        if (result.ok) {
          anySuccess = true;
          continue;
        }

        lastErrorMessage = result.errorMessage ?? "Unknown FCM error.";
        if (result.invalidToken) {
          invalidTokenCount += 1;
          await this.deactivateToken(token.id, lastErrorMessage);
        } else {
          sawRetryableFailure = true;
        }
      }

      if (anySuccess) {
        await this.markNotificationSent(current.id, attemptAt);
        return {
          status: "sent",
          exhausted: false,
          deliveryLogs,
        };
      }

      const allTokensInvalid = invalidTokenCount == tokens.length;
      const nextRetriesCount = allTokensInvalid && !sawRetryableFailure
        ? maxRetries
        : current.retries_count + 1;

      await this.markNotificationFailed({
        notification: current,
        attemptAt,
        nextRetriesCount,
        errorMessage: lastErrorMessage ?? "All FCM delivery attempts failed.",
      });

      if (nextRetriesCount >= maxRetries) {
        return {
          status: "failed",
          exhausted: true,
          deliveryLogs,
        };
      }

      current = {
        ...current,
        status: "failed",
        retries_count: nextRetriesCount,
        last_attempt_at: attemptAt,
        error_message: lastErrorMessage,
      };
    }

    return {
      status: current.status,
      exhausted: current.retries_count >= maxRetries,
      deliveryLogs,
    };
  }

  private async fetchActiveTokens(userId: string): Promise<PushTokenRow[]> {
    const { data, error } = await this.supabase
      .from("user_push_tokens")
      .select("id, user_id, token, platform, device_label, is_active, last_error")
      .eq("user_id", userId)
      .eq("is_active", true)
      .order("updated_at", { ascending: false });

    if (error) {
      throw new Error(`Failed to fetch push tokens: ${error.message}`);
    }

    return (data ?? []) as PushTokenRow[];
  }

  private async insertDeliveryLog(log: DeliveryLogInsert): Promise<void> {
    const { error } = await this.supabase
      .from("notification_delivery_logs")
      .insert(log);

    if (error) {
      console.error(
        JSON.stringify({
          type: "notification_delivery_log_insert_error",
          error: error.message,
          payload: log,
        }),
      );
    }
  }

  private async markNotificationSent(
    notificationId: string,
    attemptAt: string,
  ): Promise<void> {
    const { error } = await this.supabase
      .from("notifications")
      .update({
        status: "sent",
        last_attempt_at: attemptAt,
        error_message: null,
      })
      .eq("id", notificationId);

    if (error) {
      throw new Error(`Failed to mark notification as sent: ${error.message}`);
    }
  }

  private async markNotificationFailed(args: {
    notification: NotificationRow;
    attemptAt: string;
    nextRetriesCount: number;
    errorMessage: string;
  }): Promise<void> {
    const { notification, attemptAt, nextRetriesCount, errorMessage } = args;
    const { error } = await this.supabase
      .from("notifications")
      .update({
        status: "failed",
        retries_count: nextRetriesCount,
        last_attempt_at: attemptAt,
        error_message: errorMessage,
      })
      .eq("id", notification.id);

    if (error) {
      throw new Error(`Failed to mark notification as failed: ${error.message}`);
    }
  }

  private async deactivateToken(
    tokenId: string,
    errorMessage: string,
  ): Promise<void> {
    const { error } = await this.supabase
      .from("user_push_tokens")
      .update({
        is_active: false,
        last_error: errorMessage,
        last_seen_at: new Date().toISOString(),
      })
      .eq("id", tokenId);

    if (error) {
      console.error(
        JSON.stringify({
          type: "push_token_deactivate_error",
          token_id: tokenId,
          error: error.message,
        }),
      );
    }
  }
}

class GoogleFcmClient implements FcmClient {
  private accessToken: string | null = null;
  private accessTokenExpiresAt = 0;

  async send(
    notification: NotificationRow,
    token: PushTokenRow,
  ): Promise<{ requestPayload: Record<string, unknown>; result: FcmSendResult }> {
    const projectId = mustGetEnv("FIREBASE_PROJECT_ID");
    const accessToken = await this.getAccessToken();

    const requestPayload = buildFcmRequest(notification, token.token);
    const response = await fetch(
      `https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${accessToken}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify(requestPayload),
      },
    );

    const responseBody = await safeJson(response);
    if (response.ok) {
      return {
        requestPayload,
        result: {
          ok: true,
          invalidToken: false,
          responseBody,
        },
      };
    }

    const errorMessage = extractFcmErrorMessage(responseBody) ??
      `FCM request failed with status ${response.status}.`;
    return {
      requestPayload,
      result: {
        ok: false,
        invalidToken: looksLikeInvalidTokenError(responseBody),
        responseBody,
        errorMessage,
      },
    };
  }

  private async getAccessToken(): Promise<string> {
    const now = Date.now();
    if (this.accessToken != null && now < this.accessTokenExpiresAt) {
      return this.accessToken;
    }

    const serviceAccount = parseServiceAccount();
    const jwt = await createSignedJwt({
      clientEmail: serviceAccount.client_email,
      privateKey: serviceAccount.private_key,
      scope: "https://www.googleapis.com/auth/firebase.messaging",
      audience: "https://oauth2.googleapis.com/token",
    });

    const response = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion: jwt,
      }),
    });

    const payload = await safeJson(response);
    if (!response.ok) {
      throw new Error(
        extractFcmErrorMessage(payload) ??
          "Failed to obtain Google OAuth access token.",
      );
    }

    const accessToken = typeof payload.access_token === "string"
      ? payload.access_token
      : null;
    const expiresIn = typeof payload.expires_in === "number"
      ? payload.expires_in
      : 3600;

    if (!accessToken) {
      throw new Error("Google OAuth token response did not contain access_token.");
    }

    this.accessToken = accessToken;
    this.accessTokenExpiresAt = Date.now() + Math.max(expiresIn - 60, 60) * 1000;
    return accessToken;
  }
}

class SimulationFcmClient implements FcmClient {
  private readonly attempts = new Map<string, number>();

  constructor(private readonly mode: SimulationMode) {}

  async send(
    notification: NotificationRow,
    token: PushTokenRow,
  ): Promise<{ requestPayload: Record<string, unknown>; result: FcmSendResult }> {
    const key = `${notification.id}:${token.id}`;
    const nextAttempt = (this.attempts.get(key) ?? 0) + 1;
    this.attempts.set(key, nextAttempt);

    const requestPayload = buildFcmRequest(notification, token.token);

    if (this.mode === "success") {
      return {
        requestPayload,
        result: {
          ok: true,
          invalidToken: false,
          responseBody: { name: `simulated/messages/${notification.id}` },
        },
      };
    }

    if (this.mode === "retry_then_success" && nextAttempt >= 2) {
      return {
        requestPayload,
        result: {
          ok: true,
          invalidToken: false,
          responseBody: { name: `simulated/messages/${notification.id}` },
        },
      };
    }

    if (this.mode === "invalid_token") {
      return {
        requestPayload,
        result: {
          ok: false,
          invalidToken: true,
          responseBody: {
            error: {
              status: "INVALID_ARGUMENT",
              message: "Requested entity was not found.",
              details: [{ errorCode: "UNREGISTERED" }],
            },
          },
          errorMessage: "Simulated invalid FCM token.",
        },
      };
    }

    return {
      requestPayload,
      result: {
        ok: false,
        invalidToken: false,
        responseBody: {
          error: {
            status: "UNAVAILABLE",
            message: "Simulated transient error.",
          },
        },
        errorMessage: "Simulated transient delivery failure.",
      },
    };
  }
}

function buildFcmRequest(
  notification: NotificationRow,
  token: string,
): Record<string, unknown> {
  return {
    message: {
      token,
      notification: {
        title: notification.title,
        body: notification.body,
      },
      data: normalizeDataPayload(notification.payload),
      android: {
        priority: "high",
      },
      apns: {
        headers: {
          "apns-priority": "10",
        },
        payload: {
          aps: {
            sound: "default",
          },
        },
      },
    },
  };
}

function normalizeDataPayload(
  payload: Record<string, unknown> | null,
): Record<string, string> {
  if (!payload) {
    return {};
  }

  return Object.fromEntries(
    Object.entries(payload).map(([key, value]) => [
      key,
      typeof value === "string" ? value : JSON.stringify(value),
    ]),
  );
}

function looksLikeInvalidTokenError(responseBody: Record<string, unknown>): boolean {
  const error = isObject(responseBody.error) ? responseBody.error : null;
  if (!error) {
    return false;
  }

  const status = typeof error.status === "string" ? error.status : "";
  const message = typeof error.message === "string" ? error.message : "";
  const details = Array.isArray(error.details) ? error.details : [];

  if (
    status === "NOT_FOUND" ||
    status === "INVALID_ARGUMENT" ||
    message.includes("UNREGISTERED")
  ) {
    return true;
  }

  return details.some((detail) => {
    if (!isObject(detail)) {
      return false;
    }
    const errorCode = typeof detail.errorCode === "string" ? detail.errorCode : "";
    return [
      "UNREGISTERED",
      "INVALID_ARGUMENT",
      "SENDER_ID_MISMATCH",
    ].includes(errorCode);
  });
}

function extractFcmErrorMessage(
  responseBody: Record<string, unknown>,
): string | null {
  const error = isObject(responseBody.error) ? responseBody.error : null;
  if (!error) {
    return null;
  }

  if (typeof error.message === "string" && error.message.length > 0) {
    return error.message;
  }
  if (typeof error.status === "string" && error.status.length > 0) {
    return error.status;
  }
  return null;
}

function parseServiceAccount(): { client_email: string; private_key: string } {
  const raw = mustGetEnv("FIREBASE_SERVICE_ACCOUNT_JSON");
  const parsed = JSON.parse(raw);

  if (
    typeof parsed.client_email !== "string" ||
    typeof parsed.private_key !== "string"
  ) {
    throw new Error(
      "FIREBASE_SERVICE_ACCOUNT_JSON must contain client_email and private_key.",
    );
  }

  return parsed;
}

async function createSignedJwt(args: {
  clientEmail: string;
  privateKey: string;
  scope: string;
  audience: string;
}): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: args.clientEmail,
    scope: args.scope,
    aud: args.audience,
    iat: now,
    exp: now + 3600,
  };

  const encodedHeader = base64UrlEncode(
    new TextEncoder().encode(JSON.stringify(header)),
  );
  const encodedPayload = base64UrlEncode(
    new TextEncoder().encode(JSON.stringify(payload)),
  );
  const signingInput = `${encodedHeader}.${encodedPayload}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(args.privateKey),
    {
      name: "RSASSA-PKCS1-v1_5",
      hash: "SHA-256",
    },
    false,
    ["sign"],
  );

  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    key,
    new TextEncoder().encode(signingInput),
  );

  return `${signingInput}.${base64UrlEncode(new Uint8Array(signature))}`;
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const normalized = pem
    .replace(/-----BEGIN PRIVATE KEY-----/g, "")
    .replace(/-----END PRIVATE KEY-----/g, "")
    .replace(/\s+/g, "");

  const binary = atob(normalized);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes.buffer;
}

function base64UrlEncode(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }

  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function mustGetEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) {
    throw new Error(`Missing required environment variable ${name}.`);
  }
  return value;
}

async function safeJson(
  value: Request | Response,
): Promise<Record<string, unknown>> {
  try {
    return await value.json() as Record<string, unknown>;
  } catch (_) {
    return {};
  }
}

function jsonResponse(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      "Content-Type": "application/json",
    },
  });
}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
