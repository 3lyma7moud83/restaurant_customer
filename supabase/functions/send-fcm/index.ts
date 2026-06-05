import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8";

const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim();
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();

if (!supabaseUrl || !serviceRoleKey) {
  throw new Error("Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
}

const SUPABASE_URL = supabaseUrl;
const SERVICE_ROLE_KEY = serviceRoleKey;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const WORKER_ID = `send-fcm:${crypto.randomUUID()}`;
const DEFAULT_BATCH_LIMIT = 80;
const MAX_BATCH_LIMIT = 200;

type QueueStatus =
  | "pending"
  | "processing"
  | "retry"
  | "sent"
  | "failed"
  | "dead";

type QueueRow = {
  id: number;
  driver_notification_id: string;
  driver_id: string;
  payload: Record<string, unknown>;
  status: QueueStatus;
  attempts: number;
  max_attempts: number;
  next_retry_at: string;
  processing_started_at: string | null;
  processor_id: string | null;
  created_at: string;
};

type SendFcmRequest = {
  process_single_queue_id?: number | string | null;
  target?: string | null;
  batch_limit?: number | string | null;
  fallback_mode?: boolean | null;
};

type TokenRow = {
  id: string;
  token: string;
  platform?: string | null;
  android_version?: string | null;
  manufacturer?: string | null;
  supports_http_v1?: boolean | null;
  is_active?: boolean | null;
};

type CustomerQueueStatus =
  | "pending"
  | "processing"
  | "retry"
  | "sent"
  | "failed";

type CustomerQueueRow = {
  id: number;
  notification_id: string;
  customer_user_id: string;
  status: CustomerQueueStatus;
  attempt_count: number;
  max_attempts: number;
  next_retry_at: string;
  processing_started_at: string | null;
  request_payload?: Record<string, unknown> | null;
  last_error?: string | null;
  worker_id?: string | null;
  created_at: string;
};

type CustomerNotificationRow = {
  id: string;
  customer_user_id: string;
  order_id: string | null;
  status_key: string | null;
  title: string;
  body: string;
  payload: Record<string, unknown> | null;
  queued_at: string | null;
  created_at: string;
};

type CustomerTokenRow = {
  id: string;
  user_id: string;
  fcm_token: string;
  platform: string;
  is_active: boolean;
  is_samsung: boolean;
  android_major: number | null;
  supports_http_v1: boolean;
};

type CustomerQueueOutcomeStatus = "sent" | "retry" | "failed";

type CustomerQueueOutcome = {
  queueId: number;
  status: CustomerQueueOutcomeStatus;
  attempts: number;
  successCount: number;
  failureCount: number;
  invalidTokenCount: number;
  retryableFailureCount: number;
  errorMessage?: string;
};

type CustomerTokenDeliveryAttempt = {
  tokenId: string;
  requestPayload: Record<string, unknown>;
  responsePayload: Record<string, unknown>;
  ok: boolean;
  invalidToken: boolean;
  retryable: boolean;
  errorMessage: string | null;
  latencyMs: number;
};

type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
};

type QueueOutcomeStatus = "sent" | "retry" | "failed" | "dead" | "poisoned";

type QueueOutcome = {
  queueId: number;
  status: QueueOutcomeStatus;
  sent: number;
  failed: number;
  invalidTokens: number;
  removedTokens: number;
  reason: string | null;
};

type DispatchResult = {
  ok: boolean;
  invalidToken: boolean;
  retryable: boolean;
  statusCode: number;
  errorMessage: string | null;
  requestPayload: Record<string, unknown>;
  responsePayload: Record<string, unknown>;
};

type NotificationTemplate = {
  title: string;
  body: string;
  route: string;
};

type RequestAuthorization = {
  ok: boolean;
  mode: "service_role" | "shared_secret" | null;
  reason?: string;
};

const TYPE_ARABIC_MAP: Record<string, NotificationTemplate> = {
  new_driver_order: {
    title: "طلب جديد",
    body: "تم إضافة طلب جديد لك",
    route: "/orders",
  },
  order_cancelled: {
    title: "تم إلغاء الطلب",
    body: "تم إلغاء أحد الطلبات",
    route: "/orders",
  },
  order_ready: {
    title: "الطلب جاهز",
    body: "الطلب جاهز للاستلام",
    route: "/orders",
  },
  support_message: {
    title: "رسالة دعم",
    body: "توجد رسالة جديدة من الإدارة",
    route: "/notifications",
  },
  driver_alert: {
    title: "تنبيه",
    body: "يوجد تنبيه جديد",
    route: "/notifications",
  },
  order_assigned: {
    title: "تم إسناد طلب جديد لك",
    body: "تمت إضافة طلب جديد لقائمتك",
    route: "/orders",
  },
  order_status_updated: {
    title: "تحديث حالة الطلب",
    body: "تم تحديث حالة أحد الطلبات",
    route: "/orders",
  },
  chat_message: {
    title: "رسالة جديدة في الشات",
    body: "لديك رسالة جديدة من العميل",
    route: "/chat",
  },
  delivery_address_changed: {
    title: "تعديل عنوان التوصيل",
    body: "تم تحديث عنوان أحد الطلبات",
    route: "/route",
  },
  priority_order: {
    title: "طلب عاجل",
    body: "يوجد طلب بأولوية عالية",
    route: "/orders",
  },
  pickup_timeout: {
    title: "انتهت مهلة الاستلام",
    body: "تجاوز أحد الطلبات مهلة الاستلام",
    route: "/orders",
  },
};

function optionalEnv(name: string): string | null {
  const value = Deno.env.get(name)?.trim();
  return value && value.length > 0 ? value : null;
}

function extractBearerToken(value: string | null): string | null {
  if (!value) return null;
  const normalized = value.trim();
  if (!normalized) return null;
  if (normalized.toLowerCase().startsWith("bearer ")) {
    const token = normalized.slice(7).trim();
    return token || null;
  }
  return normalized;
}

function constantTimeEqual(left: string, right: string): boolean {
  const leftBytes = new TextEncoder().encode(left);
  const rightBytes = new TextEncoder().encode(right);
  const maxLength = Math.max(leftBytes.length, rightBytes.length);
  let diff = leftBytes.length ^ rightBytes.length;
  for (let index = 0; index < maxLength; index += 1) {
    const leftByte = index < leftBytes.length ? leftBytes[index] : 0;
    const rightByte = index < rightBytes.length ? rightBytes[index] : 0;
    diff |= leftByte ^ rightByte;
  }
  return diff === 0;
}

function base64UrlDecode(segment: string): string | null {
  try {
    const normalized = segment.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
    return atob(padded);
  } catch {
    return null;
  }
}

function hasServiceRoleJwtClaims(token: string): boolean {
  const parts = token.split(".");
  if (parts.length < 2) return false;
  const payloadJson = base64UrlDecode(parts[1]);
  if (!payloadJson) return false;
  try {
    const payload = JSON.parse(payloadJson) as Record<string, unknown>;
    const role = String(payload.role ?? "").trim().toLowerCase();
    return role === "service_role";
  } catch {
    return false;
  }
}

function resolveSuppliedSharedSecret(
  req: Request,
  bearerToken: string | null,
): string | null {
  for (
    const headerName of [
      "x-driver-fcm-secret",
      "x-notification-dispatch-secret",
      "x-process-notifications-secret",
    ]
  ) {
    const value = req.headers.get(headerName)?.trim();
    if (value) return value;
  }
  return bearerToken;
}

function authorizeRequest(req: Request): RequestAuthorization {
  const bearerToken = extractBearerToken(req.headers.get("authorization"));
  const sharedSecret = optionalEnv("DRIVER_FCM_SHARED_SECRET") ??
    optionalEnv("PROCESS_NOTIFICATIONS_SHARED_SECRET");
  const suppliedSharedSecret = resolveSuppliedSharedSecret(req, bearerToken);
  const sharedSecretMatches = Boolean(
    sharedSecret &&
      suppliedSharedSecret &&
      constantTimeEqual(suppliedSharedSecret, sharedSecret),
  );

  if (bearerToken && constantTimeEqual(bearerToken, SERVICE_ROLE_KEY)) {
    return { ok: true, mode: "service_role" };
  }

  // Gateway JWT validation still applies before this handler runs.
  if (bearerToken && hasServiceRoleJwtClaims(bearerToken)) {
    return { ok: true, mode: "service_role" };
  }

  if (sharedSecretMatches) {
    return { ok: true, mode: "shared_secret" };
  }

  if (!sharedSecret) {
    return {
      ok: false,
      mode: null,
      reason: "service role bearer token is required",
    };
  }

  return {
    ok: false,
    mode: null,
    reason: "service role bearer or shared secret is required",
  };
}

function normalizePrivateKey(raw: string): string {
  return raw.replace(/\\n/g, "\n").trim();
}

function parseAndroidMajor(version: string | null | undefined): number | null {
  if (!version) return null;
  const major = Number.parseInt(version.split(".")[0] ?? "", 10);
  return Number.isFinite(major) ? major : null;
}

function isSamsungAndroid8(token: TokenRow): boolean {
  const manufacturer = (token.manufacturer ?? "").toLowerCase();
  const major = parseAndroidMajor(token.android_version);
  return manufacturer.includes("samsung") && major === 8;
}

function shouldUseMinimalNotificationOnly(token: TokenRow): boolean {
  if (isSamsungAndroid8(token)) return true;
  return token.supports_http_v1 === false;
}

function normalizeType(value: unknown): string {
  const normalized = String(value ?? "driver_alert").trim().toLowerCase();
  return normalized.length > 0 ? normalized : "driver_alert";
}

function sanitizeText(value: unknown): string {
  return String(value ?? "").trim();
}

function safeRecord(value: unknown): Record<string, unknown> {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value as Record<string, unknown>;
  }
  return {};
}

function normalizeQueueId(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.floor(value);
  }
  if (typeof value === "string") {
    const parsed = Number.parseInt(value.trim(), 10);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function parseBatchLimit(value: unknown): number {
  const parsed = typeof value === "number"
    ? value
    : typeof value === "string"
    ? Number.parseInt(value.trim(), 10)
    : DEFAULT_BATCH_LIMIT;
  if (!Number.isFinite(parsed)) return DEFAULT_BATCH_LIMIT;
  return Math.max(1, Math.min(Math.floor(parsed), MAX_BATCH_LIMIT));
}

function parseCustomerBatchLimit(value: unknown): number {
  const parsed = typeof value === "number"
    ? value
    : typeof value === "string"
    ? Number.parseInt(value.trim(), 10)
    : 100;
  if (!Number.isFinite(parsed)) return 100;
  return Math.max(1, Math.min(Math.floor(parsed), 500));
}

function uniqueNonEmpty(values: Array<string | null | undefined>): string[] {
  const unique = new Set<string>();
  for (const value of values) {
    const normalized = sanitizeText(value);
    if (normalized.length > 0) {
      unique.add(normalized);
    }
  }
  return [...unique];
}

function isPoisonPayload(payload: Record<string, unknown>): boolean {
  const driverId = sanitizeText(payload.driver_id);
  const notificationId = sanitizeText(payload.driver_notification_id);
  return driverId.length === 0 || notificationId.length === 0;
}

function computeNextRetryAt(attempts: number): string {
  const boundedAttempt = Math.min(Math.max(attempts, 1), 8);
  const base = Math.min(300, 2 ** boundedAttempt);
  const jitter = Math.floor(Math.random() * 8);
  return new Date(Date.now() + (base + jitter) * 1000).toISOString();
}

function resolveClickAction(
  data: Record<string, unknown>,
  fallbackRoute: string,
): string {
  for (const key of ["click_action", "route", "path", "link", "url"]) {
    const value = sanitizeText(data[key]);
    if (value.length > 0) {
      if (value.toUpperCase() === "FLUTTER_NOTIFICATION_CLICK") {
        continue;
      }
      return value.startsWith("/") ? value : `/${value}`;
    }
  }
  return fallbackRoute;
}

function resolveNotificationContent(
  payload: Record<string, unknown>,
): {
  title: string;
  body: string;
  type: string;
  data: Record<string, unknown>;
} {
  const rawType = normalizeType(payload.type ?? payload.notification_type);
  const template = TYPE_ARABIC_MAP[rawType] ?? TYPE_ARABIC_MAP.driver_alert;
  const data = safeRecord(payload.data);

  const rawTitle = sanitizeText(payload.title);
  const rawBody = sanitizeText(payload.body);
  const title = rawTitle.length === 0 || rawTitle.toLowerCase() === rawType
    ? template.title
    : rawTitle;
  const body = rawBody.length === 0 || rawBody.toLowerCase() === rawType
    ? template.body
    : rawBody;

  const clickAction = resolveClickAction(data, template.route);
  return {
    title,
    body,
    type: rawType,
    data: {
      ...data,
      type: rawType,
      click_action: clickAction,
      route: sanitizeText(data.route) || template.route,
    },
  };
}

function stringifyData(data: Record<string, unknown>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(data)) {
    const normalizedKey = key.trim();
    if (!normalizedKey) continue;
    if (value === null || value === undefined) continue;
    out[normalizedKey] = String(value);
  }
  return out;
}

function buildMessagePayload(args: {
  token: TokenRow;
  content: {
    title: string;
    body: string;
    type: string;
    data: Record<string, unknown>;
  };
}): Record<string, unknown> {
  const { token, content } = args;
  const minimalNotificationOnly = shouldUseMinimalNotificationOnly(token);

  const androidNotification = {
    channel_id: "high_importance_channel",
    click_action: "FLUTTER_NOTIFICATION_CLICK",
    sound: "default",
    default_sound: true,
    default_vibrate_timings: true,
  };

  const baseAndroid = {
    priority: "HIGH",
    ttl: "0s",
    notification: androidNotification,
  };

  if (minimalNotificationOnly) {
    return {
      message: {
        token: token.token,
        notification: { title: content.title, body: content.body },
        android: baseAndroid,
      },
    };
  }

  const dataPayload = stringifyData(content.data);
  if (!dataPayload.type) dataPayload.type = content.type;
  if (!dataPayload.title) dataPayload.title = content.title;
  if (!dataPayload.body) dataPayload.body = content.body;
  if (!dataPayload.click_action) {
    dataPayload.click_action = resolveClickAction(content.data, "/orders");
  }

  return {
    message: {
      token: token.token,
      notification: { title: content.title, body: content.body },
      data: dataPayload,
      android: baseAndroid,
    },
  };
}

function isCustomerSamsungAndroid8(token: CustomerTokenRow): boolean {
  return token.is_samsung === true && token.android_major === 8;
}

function shouldUseCustomerMinimalNotificationOnly(
  token: CustomerTokenRow,
): boolean {
  if (isCustomerSamsungAndroid8(token)) return true;
  return token.supports_http_v1 === false;
}

function isCustomerWebToken(token: CustomerTokenRow): boolean {
  return sanitizeText(token.platform).toLowerCase() === "web";
}

function resolveCustomerNotificationContent(args: {
  notification: CustomerNotificationRow;
  queuePayload: Record<string, unknown>;
}): {
  title: string;
  body: string;
  type: string;
  data: Record<string, unknown>;
} {
  const payload = safeRecord(args.notification.payload);
  const queuePayloadData = safeRecord(args.queuePayload);
  const payloadData = safeRecord(payload.data);
  const queuePayloadNestedData = safeRecord(queuePayloadData.data);
  const mergedData: Record<string, unknown> = {
    ...queuePayloadNestedData,
    ...payloadData,
  };

  const normalizedStatus = normalizeType(
    args.notification.status_key ??
      payload.status_key ??
      queuePayloadData.status_key ??
      payload.type ??
      queuePayloadData.type ??
      "order_update",
  );
  const template = TYPE_ARABIC_MAP[normalizedStatus] ?? {
    title: "تحديث الطلب",
    body: "تم تحديث حالة طلبك",
    route: "/orders",
  };

  const rawTitle = sanitizeText(args.notification.title) ||
    sanitizeText(payload.title) ||
    sanitizeText(queuePayloadData.title);
  const rawBody = sanitizeText(args.notification.body) ||
    sanitizeText(payload.body) ||
    sanitizeText(queuePayloadData.body);
  const title = rawTitle.length > 0 ? rawTitle : template.title;
  const body = rawBody.length > 0 ? rawBody : template.body;

  const route = resolveClickAction(mergedData, "/orders");
  const typeHint = sanitizeText(mergedData.type) || normalizedStatus;
  const eventHint = sanitizeText(mergedData.event) || typeHint;
  const orderId = sanitizeText(
    args.notification.order_id ??
      mergedData.order_id ??
      queuePayloadData.order_id ??
      "",
  );

  const finalData: Record<string, unknown> = {
    ...mergedData,
    title,
    body,
    type: typeHint,
    notification_type: typeHint,
    event: eventHint,
    status_key: sanitizeText(args.notification.status_key ?? normalizedStatus),
    screen: sanitizeText(mergedData.screen) || "orders",
    click_action: route,
    route,
    sound: sanitizeText(mergedData.sound) || "default",
    notification_id: args.notification.id,
  };
  if (orderId.length > 0) {
    finalData.order_id = orderId;
  }

  return { title, body, type: typeHint, data: finalData };
}

function buildCustomerMessagePayload(args: {
  token: CustomerTokenRow;
  notification: CustomerNotificationRow;
  queuePayload: Record<string, unknown>;
}): Record<string, unknown> {
  const { token, notification, queuePayload } = args;
  const content = resolveCustomerNotificationContent({
    notification,
    queuePayload,
  });
  const dataPayload = stringifyData(content.data);
  if (!dataPayload.type) dataPayload.type = content.type;
  if (!dataPayload.title) dataPayload.title = content.title;
  if (!dataPayload.body) dataPayload.body = content.body;
  if (!dataPayload.screen) dataPayload.screen = "orders";
  if (!dataPayload.click_action) {
    dataPayload.click_action = resolveClickAction(
      content.data,
      "/orders",
    );
  }
  const webLink = dataPayload.click_action || "/orders";

  if (isCustomerWebToken(token)) {
    dataPayload.fcm_web_delivery_required = "service_worker_push";
    dataPayload.fcm_payload_version = "1";
    return {
      message: {
        token: token.fcm_token,
        data: dataPayload,
        webpush: {
          headers: {
            TTL: "0",
            Urgency: "high",
          },
          fcm_options: {
            link: webLink,
          },
        },
      },
    };
  }

  const messageBase: Record<string, unknown> = {
    token: token.fcm_token,
    notification: { title: content.title, body: content.body },
    android: {
      priority: "HIGH",
      ttl: "0s",
      notification: {
        channel_id: "high_importance_channel",
        click_action: "FLUTTER_NOTIFICATION_CLICK",
        sound: "default",
        default_sound: true,
        default_vibrate_timings: true,
      },
    },
    webpush: {
      notification: {
        title: content.title,
        body: content.body,
        icon: "/icons/Icon-192.png",
        badge: "/icons/Icon-192.png",
        requireInteraction: true,
        data: dataPayload,
      },
      fcm_options: {
        link: webLink,
      },
    },
  };

  if (shouldUseCustomerMinimalNotificationOnly(token)) {
    return { message: messageBase };
  }

  return {
    message: {
      ...messageBase,
      data: dataPayload,
    },
  };
}

function loadServiceAccount(): ServiceAccount {
  const jsonSecret = Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON");
  if (jsonSecret && jsonSecret.trim().length > 0) {
    const parsed = JSON.parse(jsonSecret) as ServiceAccount;
    if (!parsed.project_id || !parsed.client_email || !parsed.private_key) {
      throw new Error(
        "FIREBASE_SERVICE_ACCOUNT_JSON is missing required fields",
      );
    }
    return {
      ...parsed,
      private_key: normalizePrivateKey(parsed.private_key),
      token_uri: parsed.token_uri ?? "https://oauth2.googleapis.com/token",
    };
  }

  const projectId = Deno.env.get("FIREBASE_PROJECT_ID");
  const clientEmail = Deno.env.get("FIREBASE_CLIENT_EMAIL");
  const privateKey = Deno.env.get("FIREBASE_PRIVATE_KEY");
  if (!projectId || !clientEmail || !privateKey) {
    throw new Error("Missing Firebase credentials");
  }
  return {
    project_id: projectId,
    client_email: clientEmail,
    private_key: normalizePrivateKey(privateKey),
    token_uri: "https://oauth2.googleapis.com/token",
  };
}

function base64UrlEncode(input: Uint8Array): string {
  const base64 = btoa(String.fromCharCode(...input));
  return base64.replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/g, "");
}

function encodeJsonBase64Url(payload: Record<string, unknown>): string {
  return base64UrlEncode(new TextEncoder().encode(JSON.stringify(payload)));
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  const normalized = pem
    .replace("-----BEGIN PRIVATE KEY-----", "")
    .replace("-----END PRIVATE KEY-----", "")
    .replace(/\s+/g, "");
  const binary = atob(normalized);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

async function createJwtAssertion(
  serviceAccount: ServiceAccount,
  now: number,
): Promise<string> {
  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: serviceAccount.client_email,
    sub: serviceAccount.client_email,
    aud: serviceAccount.token_uri ?? "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
    scope: FCM_SCOPE,
  };
  const encodedHeader = encodeJsonBase64Url(header);
  const encodedPayload = encodeJsonBase64Url(payload);
  const unsigned = `${encodedHeader}.${encodedPayload}`;
  const privateKey = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(serviceAccount.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signatureBuffer = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    privateKey,
    new TextEncoder().encode(unsigned),
  );
  return `${unsigned}.${base64UrlEncode(new Uint8Array(signatureBuffer))}`;
}

async function createAccessToken(
  serviceAccount: ServiceAccount,
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const assertion = await createJwtAssertion(serviceAccount, now);
  const tokenResponse = await fetch(
    serviceAccount.token_uri ?? "https://oauth2.googleapis.com/token",
    {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
        assertion,
      }),
    },
  );
  const json = await tokenResponse.json().catch(() => ({}));
  if (
    !tokenResponse.ok || typeof json.access_token !== "string" ||
    !json.access_token
  ) {
    throw new Error(
      `Failed to obtain Firebase access token: ${JSON.stringify(json)}`,
    );
  }
  return json.access_token;
}

function parseFcmResponseError(responseJson: Record<string, unknown>): {
  invalidToken: boolean;
  retryable: boolean;
  message: string;
} {
  const root = (responseJson ?? {}) as Record<string, unknown>;
  const error = (root.error ?? {}) as Record<string, unknown>;
  const status = String(error.status ?? "").toUpperCase();
  const message = sanitizeText(error.message) || "FCM request failed";

  const invalidToken = status === "NOT_FOUND" ||
    status === "INVALID_ARGUMENT" ||
    message.includes("UNREGISTERED");

  const retryable = [
    "UNAVAILABLE",
    "DEADLINE_EXCEEDED",
    "ABORTED",
    "INTERNAL",
    "RESOURCE_EXHAUSTED",
    "UNKNOWN",
  ].includes(status);

  return { invalidToken, retryable, message };
}

async function sendHttpV1(
  fcmUrl: string,
  accessToken: string,
  payload: Record<string, unknown>,
): Promise<DispatchResult> {
  const response = await fetch(fcmUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json; charset=UTF-8",
    },
    body: JSON.stringify(payload),
  });

  const responseJson = await response.json().catch(
    () => ({} as Record<string, unknown>),
  );
  if (response.ok) {
    return {
      ok: true,
      invalidToken: false,
      retryable: false,
      statusCode: response.status,
      errorMessage: null,
      requestPayload: payload,
      responsePayload: responseJson as Record<string, unknown>,
    };
  }

  const parsed = parseFcmResponseError(responseJson as Record<string, unknown>);
  return {
    ok: false,
    invalidToken: parsed.invalidToken,
    retryable: parsed.retryable,
    statusCode: response.status,
    errorMessage: parsed.message,
    requestPayload: payload,
    responsePayload: responseJson as Record<string, unknown>,
  };
}

async function claimQueue(args: {
  limit: number;
  processSingleQueueId: number | null;
}): Promise<QueueRow[]> {
  const { data, error } = await supabase.rpc("claim_driver_fcm_queue", {
    p_limit: args.limit,
    p_process_single_queue_id: args.processSingleQueueId,
    p_worker_id: WORKER_ID,
    p_stale_after_seconds: 180,
  });
  if (error) throw error;
  return (data ?? []) as QueueRow[];
}

async function loadActiveTokens(driverId: string): Promise<TokenRow[]> {
  const { data, error } = await supabase
    .from("driver_device_tokens")
    .select(
      "id,token,platform,android_version,manufacturer,supports_http_v1,is_active",
    )
    .eq("driver_id", driverId)
    .eq("is_active", true);

  if (error) throw error;
  const rows = (data ?? []) as TokenRow[];
  return rows.filter((row) => sanitizeText(row.token).length > 0);
}

async function deactivateInvalidToken(token: TokenRow): Promise<void> {
  await supabase
    .from("driver_device_tokens")
    .update({
      is_active: false,
      invalidated_at: new Date().toISOString(),
      invalidation_reason: "fcm_invalid_token",
      last_seen_at: new Date().toISOString(),
    })
    .eq("id", token.id)
    .eq("is_active", true);
}

async function insertDeliveryLog(args: {
  queueRow: QueueRow;
  token: TokenRow | null;
  status:
    | "sent"
    | "retry_scheduled"
    | "invalid_token"
    | "failed"
    | "no_tokens"
    | "poisoned";
  requestPayload: Record<string, unknown>;
  responsePayload: Record<string, unknown> | null;
  errorMessage: string | null;
  latencyMs: number | null;
}): Promise<void> {
  const {
    queueRow,
    token,
    status,
    requestPayload,
    responsePayload,
    errorMessage,
    latencyMs,
  } = args;
  await supabase.from("driver_fcm_delivery_logs").insert({
    queue_id: queueRow.id,
    driver_notification_id: queueRow.driver_notification_id,
    driver_id: queueRow.driver_id,
    token: token?.token ?? null,
    token_platform: token?.platform ?? null,
    token_manufacturer: token?.manufacturer ?? null,
    token_android_version: token?.android_version ?? null,
    attempt_number: queueRow.attempts,
    processor_id: WORKER_ID,
    delivery_status: status,
    request_payload: requestPayload,
    response_payload: responsePayload,
    error_message: errorMessage,
    latency_ms: latencyMs,
  });
}

async function markQueueSent(
  queueRow: QueueRow,
  lastError: string | null,
): Promise<void> {
  await supabase
    .from("queue_driver_fcm")
    .update({
      status: "sent",
      sent_at: new Date().toISOString(),
      last_error: lastError,
      next_retry_at: new Date().toISOString(),
      processing_started_at: null,
      processor_id: null,
      claimed_at: null,
      dead_reason: null,
    })
    .eq("id", queueRow.id)
    .eq("status", "processing")
    .eq("processor_id", WORKER_ID);
}

async function markQueueRetry(
  queueRow: QueueRow,
  reason: string,
): Promise<void> {
  const retryAt = computeNextRetryAt(queueRow.attempts + 1);
  await supabase
    .from("queue_driver_fcm")
    .update({
      status: "retry",
      last_error: reason,
      next_retry_at: retryAt,
      processing_started_at: null,
      processor_id: null,
      claimed_at: null,
    })
    .eq("id", queueRow.id)
    .eq("status", "processing")
    .eq("processor_id", WORKER_ID);
}

async function markQueueFailed(
  queueRow: QueueRow,
  reason: string,
): Promise<void> {
  await supabase
    .from("queue_driver_fcm")
    .update({
      status: "failed",
      last_error: reason,
      next_retry_at: new Date().toISOString(),
      processing_started_at: null,
      processor_id: null,
      claimed_at: null,
    })
    .eq("id", queueRow.id)
    .eq("status", "processing")
    .eq("processor_id", WORKER_ID);
}

async function markQueueDead(
  queueRow: QueueRow,
  reason: string,
): Promise<void> {
  await supabase
    .from("queue_driver_fcm")
    .update({
      status: "dead",
      last_error: reason,
      dead_reason: reason,
      processing_started_at: null,
      processor_id: null,
      claimed_at: null,
    })
    .eq("id", queueRow.id)
    .eq("status", "processing")
    .eq("processor_id", WORKER_ID);

  await supabase.from("driver_fcm_dead_letters").insert({
    queue_id: queueRow.id,
    driver_notification_id: queueRow.driver_notification_id,
    driver_id: queueRow.driver_id,
    payload: queueRow.payload ?? {},
    reason,
    attempt_count: queueRow.attempts,
  });
}

async function processQueueRow(args: {
  queueRow: QueueRow;
  fcmUrl: string;
  accessToken: string;
}): Promise<QueueOutcome> {
  const { queueRow, fcmUrl, accessToken } = args;
  const payload = safeRecord(queueRow.payload);

  if (isPoisonPayload(payload)) {
    const reason = "poison_payload_missing_driver_or_notification_id";
    await insertDeliveryLog({
      queueRow,
      token: null,
      status: "poisoned",
      requestPayload: payload,
      responsePayload: null,
      errorMessage: reason,
      latencyMs: null,
    });
    await markQueueDead(queueRow, reason);
    return {
      queueId: queueRow.id,
      status: "poisoned",
      sent: 0,
      failed: 1,
      invalidTokens: 0,
      removedTokens: 0,
      reason,
    };
  }

  const content = resolveNotificationContent(payload);
  const tokens = await loadActiveTokens(queueRow.driver_id);

  if (tokens.length === 0) {
    const reason = "no_active_tokens";
    await insertDeliveryLog({
      queueRow,
      token: null,
      status: "no_tokens",
      requestPayload: {
        driver_id: queueRow.driver_id,
        queue_id: queueRow.id,
      },
      responsePayload: null,
      errorMessage: reason,
      latencyMs: null,
    });
    if (queueRow.attempts >= queueRow.max_attempts) {
      await markQueueDead(queueRow, reason);
      return {
        queueId: queueRow.id,
        status: "dead",
        sent: 0,
        failed: 1,
        invalidTokens: 0,
        removedTokens: 0,
        reason,
      };
    }
    await markQueueRetry(queueRow, reason);
    return {
      queueId: queueRow.id,
      status: "retry",
      sent: 0,
      failed: 1,
      invalidTokens: 0,
      removedTokens: 0,
      reason,
    };
  }

  let sent = 0;
  let failed = 0;
  let invalidTokens = 0;
  let removedTokens = 0;
  let anyRetryableFailure = false;
  let lastReason: string | null = null;

  for (const token of tokens) {
    const messagePayload = buildMessagePayload({ token, content });
    const sendStartedAt = Date.now();
    const result = await sendHttpV1(fcmUrl, accessToken, messagePayload);
    const latency = Date.now() - sendStartedAt;

    if (result.ok) {
      sent += 1;
      await insertDeliveryLog({
        queueRow,
        token,
        status: "sent",
        requestPayload: result.requestPayload,
        responsePayload: result.responsePayload,
        errorMessage: null,
        latencyMs: latency,
      });
      continue;
    }

    failed += 1;
    lastReason = result.errorMessage ?? "fcm_delivery_failed";
    anyRetryableFailure = anyRetryableFailure || result.retryable;
    if (result.invalidToken) {
      invalidTokens += 1;
      await deactivateInvalidToken(token);
      removedTokens += 1;
    }

    await insertDeliveryLog({
      queueRow,
      token,
      status: result.invalidToken ? "invalid_token" : "failed",
      requestPayload: result.requestPayload,
      responsePayload: result.responsePayload,
      errorMessage: result.errorMessage,
      latencyMs: latency,
    });
  }

  if (sent > 0) {
    await markQueueSent(queueRow, failed > 0 ? "partial_failed" : null);
    return {
      queueId: queueRow.id,
      status: "sent",
      sent,
      failed,
      invalidTokens,
      removedTokens,
      reason: failed > 0 ? "partial_failed" : null,
    };
  }

  const reason = lastReason ?? "all_delivery_attempts_failed";
  if (queueRow.attempts >= queueRow.max_attempts) {
    await markQueueDead(queueRow, reason);
    return {
      queueId: queueRow.id,
      status: "dead",
      sent,
      failed,
      invalidTokens,
      removedTokens,
      reason,
    };
  }

  if (anyRetryableFailure || failed > 0) {
    await markQueueRetry(queueRow, reason);
    return {
      queueId: queueRow.id,
      status: "retry",
      sent,
      failed,
      invalidTokens,
      removedTokens,
      reason,
    };
  }

  await markQueueFailed(queueRow, reason);
  return {
    queueId: queueRow.id,
    status: "failed",
    sent,
    failed,
    invalidTokens,
    removedTokens,
    reason,
  };
}

async function claimCustomerQueueRows(args: {
  processSingleQueueId: number | null;
  batchLimit: number;
}): Promise<CustomerQueueRow[]> {
  const { data, error } = await supabase.rpc("claim_customer_fcm_queue", {
    p_process_single_queue_id: args.processSingleQueueId,
    p_batch_limit: args.batchLimit,
    p_worker_id: WORKER_ID,
  });
  if (error) {
    throw new Error(`customer_claim_failed:${error.message}`);
  }
  return (data ?? []) as CustomerQueueRow[];
}

async function loadCustomerNotifications(
  notificationIds: string[],
): Promise<CustomerNotificationRow[]> {
  if (notificationIds.length === 0) {
    return [];
  }
  const { data, error } = await supabase
    .from("customer_notifications")
    .select(
      "id, customer_user_id, order_id, status_key, title, body, payload, queued_at, created_at",
    )
    .in("id", notificationIds);
  if (error) {
    throw new Error(`customer_notifications_load_failed:${error.message}`);
  }
  return (data ?? []) as CustomerNotificationRow[];
}

async function loadCustomerTokensByUsers(
  userIds: string[],
): Promise<CustomerTokenRow[]> {
  if (userIds.length === 0) {
    return [];
  }
  const { data, error } = await supabase
    .from("customer_device_tokens")
    .select(
      "id, user_id, fcm_token, platform, is_active, is_samsung, android_major, supports_http_v1",
    )
    .in("user_id", userIds)
    .eq("is_active", true)
    .order("updated_at", { ascending: false });
  if (error) {
    throw new Error(`customer_tokens_load_failed:${error.message}`);
  }
  const rows = (data ?? []) as CustomerTokenRow[];
  return rows.filter((row) => sanitizeText(row.fcm_token).length > 0);
}

async function insertCustomerDeliveryLogs(
  logs: Array<{
    queue_id: number;
    notification_id: string;
    token_id: string;
    request_payload: Record<string, unknown>;
    response_payload: Record<string, unknown>;
    error_message: string | null;
    fcm_latency_ms: number;
  }>,
): Promise<void> {
  if (logs.length === 0) {
    return;
  }
  const { error } = await supabase
    .from("customer_notification_delivery_logs")
    .insert(logs);
  if (error) {
    console.error("[send-fcm][customer] delivery logs insert failed", {
      error: error.message,
      count: logs.length,
    });
  }
}

async function deactivateInvalidCustomerTokens(
  tokenIds: string[],
  reason: string,
): Promise<void> {
  const uniqueIds = uniqueNonEmpty(tokenIds);
  if (uniqueIds.length === 0) {
    return;
  }
  const nowIso = new Date().toISOString();
  const { error } = await supabase
    .from("customer_device_tokens")
    .update({
      is_active: false,
      last_error: reason,
      last_seen_at: nowIso,
      updated_at: nowIso,
    })
    .in("id", uniqueIds)
    .eq("is_active", true);
  if (error) {
    console.error("[send-fcm][customer] invalid token deactivation failed", {
      error: error.message,
      count: uniqueIds.length,
    });
  }
}

function computeCustomerRetryDelaySeconds(attempts: number): number {
  const boundedAttempt = Math.min(Math.max(attempts, 1), 8);
  const baseSeconds = Math.min(300, 2 ** boundedAttempt);
  const jitterSeconds = Math.floor(Math.random() * 10);
  return baseSeconds + jitterSeconds;
}

async function markCustomerQueueSent(args: {
  queueId: number;
  notificationId: string;
  attempts: number;
  nowIso: string;
  responsePayload: Record<string, unknown>;
  lastError: string | null;
}): Promise<void> {
  const {
    queueId,
    notificationId,
    attempts,
    nowIso,
    responsePayload,
    lastError,
  } = args;

  const { error: queueError } = await supabase
    .from("queue_customer_fcm")
    .update({
      status: "sent",
      attempt_count: attempts,
      sent_at: nowIso,
      failed_at: null,
      last_error: lastError,
      next_retry_at: nowIso,
      processing_started_at: null,
      worker_id: null,
      response_payload: responsePayload,
      updated_at: nowIso,
    })
    .eq("id", queueId)
    .eq("status", "processing")
    .eq("worker_id", WORKER_ID);

  const { error: notificationError } = await supabase
    .from("customer_notifications")
    .update({
      delivery_status: "sent",
      retries_count: Math.max(0, attempts - 1),
      pushed_at: nowIso,
      failed_at: null,
      last_error: lastError,
      updated_at: nowIso,
    })
    .eq("id", notificationId);

  if (queueError) {
    throw new Error(`customer_queue_mark_sent_failed:${queueError.message}`);
  }
  if (notificationError) {
    throw new Error(
      `customer_notification_mark_sent_failed:${notificationError.message}`,
    );
  }
}

async function markCustomerQueueFailed(args: {
  queueId: number;
  notificationId: string;
  attempts: number;
  maxAttempts: number;
  nowIso: string;
  errorMessage: string;
  retryable: boolean;
  responsePayload: Record<string, unknown>;
}): Promise<"retry" | "failed"> {
  const {
    queueId,
    notificationId,
    attempts,
    maxAttempts,
    nowIso,
    errorMessage,
    retryable,
    responsePayload,
  } = args;
  const shouldRetry = retryable && attempts < maxAttempts;
  const nextStatus: "retry" | "failed" = shouldRetry ? "retry" : "failed";
  const retryDelaySeconds = shouldRetry
    ? computeCustomerRetryDelaySeconds(attempts)
    : 0;
  const nextRetryAtIso = shouldRetry
    ? new Date(Date.parse(nowIso) + retryDelaySeconds * 1000).toISOString()
    : nowIso;

  const { error: queueError } = await supabase
    .from("queue_customer_fcm")
    .update({
      status: nextStatus,
      attempt_count: attempts,
      next_retry_at: nextRetryAtIso,
      failed_at: shouldRetry ? null : nowIso,
      sent_at: null,
      last_error: errorMessage,
      processing_started_at: null,
      worker_id: null,
      response_payload: responsePayload,
      updated_at: nowIso,
    })
    .eq("id", queueId)
    .eq("status", "processing")
    .eq("worker_id", WORKER_ID);

  const { error: notificationError } = await supabase
    .from("customer_notifications")
    .update({
      delivery_status: shouldRetry ? "processing" : "failed",
      retries_count: attempts,
      pushed_at: null,
      failed_at: shouldRetry ? null : nowIso,
      last_error: errorMessage,
      updated_at: nowIso,
    })
    .eq("id", notificationId);

  if (queueError) {
    throw new Error(`customer_queue_mark_failed_failed:${queueError.message}`);
  }
  if (notificationError) {
    throw new Error(
      `customer_notification_mark_failed_failed:${notificationError.message}`,
    );
  }

  return nextStatus;
}

async function deliverCustomerNotificationToToken(args: {
  queueRow: CustomerQueueRow;
  notification: CustomerNotificationRow;
  token: CustomerTokenRow;
  fcmUrl: string;
  accessToken: string;
}): Promise<CustomerTokenDeliveryAttempt> {
  const requestPayload = buildCustomerMessagePayload({
    token: args.token,
    notification: args.notification,
    queuePayload: safeRecord(args.queueRow.request_payload),
  });
  console.log(JSON.stringify({
    type: "customer_notification_sent",
    message: "Notification sent",
    worker_id: WORKER_ID,
    queue_id: args.queueRow.id,
    notification_id: args.notification.id,
    token_id: args.token.id,
    platform: args.token.platform,
    payload_mode: isCustomerWebToken(args.token)
      ? "web_data_only_service_worker_push"
      : shouldUseCustomerMinimalNotificationOnly(args.token)
      ? "minimal_notification_only"
      : "notification_and_data",
  }));

  const startedAt = Date.now();
  const result = await sendHttpV1(
    args.fcmUrl,
    args.accessToken,
    requestPayload,
  );
  const latencyMs = Date.now() - startedAt;

  if (result.ok) {
    console.log(JSON.stringify({
      type: "customer_fcm_accepted",
      message: "FCM accepted",
      worker_id: WORKER_ID,
      queue_id: args.queueRow.id,
      notification_id: args.notification.id,
      token_id: args.token.id,
      platform: args.token.platform,
      status_code: result.statusCode,
      fcm_response_name: sanitizeText(result.responsePayload.name),
      latency_ms: latencyMs,
    }));
  }

  console.log(JSON.stringify({
    type: "customer_fcm_delivery_attempt",
    worker_id: WORKER_ID,
    queue_id: args.queueRow.id,
    notification_id: args.notification.id,
    token_id: args.token.id,
    platform: args.token.platform,
    ok: result.ok,
    invalid_token: result.invalidToken,
    retryable: result.retryable,
    latency_ms: latencyMs,
    status_code: result.statusCode,
    error: result.errorMessage ?? null,
  }));

  return {
    tokenId: args.token.id,
    requestPayload: result.requestPayload,
    responsePayload: result.responsePayload,
    ok: result.ok,
    invalidToken: result.invalidToken,
    retryable: result.retryable,
    errorMessage: result.errorMessage,
    latencyMs,
  };
}

async function processCustomerQueueRow(args: {
  queueRow: CustomerQueueRow;
  notification: CustomerNotificationRow | null;
  tokens: CustomerTokenRow[];
  fcmUrl: string;
  accessToken: string;
}): Promise<CustomerQueueOutcome> {
  const { queueRow, notification, tokens } = args;
  const attempts = queueRow.attempt_count + 1;
  const nowIso = new Date().toISOString();

  if (!notification) {
    const errorMessage = "customer_notification_not_found";
    await markCustomerQueueFailed({
      queueId: queueRow.id,
      notificationId: queueRow.notification_id,
      attempts,
      maxAttempts: queueRow.max_attempts,
      nowIso,
      errorMessage,
      retryable: false,
      responsePayload: {
        ok: false,
        worker_id: WORKER_ID,
        reason: errorMessage,
      },
    });
    return {
      queueId: queueRow.id,
      status: "failed",
      attempts,
      successCount: 0,
      failureCount: 1,
      invalidTokenCount: 0,
      retryableFailureCount: 0,
      errorMessage,
    };
  }

  console.log(JSON.stringify({
    type: "customer_notification_requested",
    message: "Notification requested",
    worker_id: WORKER_ID,
    queue_id: queueRow.id,
    notification_id: notification.id,
    customer_user_id: notification.customer_user_id,
    token_count: tokens.length,
    source: "queue_customer_fcm",
  }));

  if (tokens.length === 0) {
    const errorMessage = "no_active_customer_tokens";
    await markCustomerQueueFailed({
      queueId: queueRow.id,
      notificationId: notification.id,
      attempts,
      maxAttempts: queueRow.max_attempts,
      nowIso,
      errorMessage,
      retryable: false,
      responsePayload: {
        ok: false,
        worker_id: WORKER_ID,
        reason: errorMessage,
      },
    });
    return {
      queueId: queueRow.id,
      status: "failed",
      attempts,
      successCount: 0,
      failureCount: 1,
      invalidTokenCount: 0,
      retryableFailureCount: 0,
      errorMessage,
    };
  }

  const tokenAttempts = await Promise.all(
    tokens.map((token) =>
      deliverCustomerNotificationToToken({
        queueRow,
        notification,
        token,
        fcmUrl: args.fcmUrl,
        accessToken: args.accessToken,
      })
    ),
  );

  const successfulAttempts = tokenAttempts.filter((attempt) => attempt.ok);
  const failedAttempts = tokenAttempts.filter((attempt) => !attempt.ok);
  const invalidAttempts = tokenAttempts.filter((attempt) =>
    attempt.invalidToken
  );
  const retryableFailures = tokenAttempts.filter((attempt) =>
    !attempt.ok && attempt.retryable
  );

  await insertCustomerDeliveryLogs(
    tokenAttempts.map((attempt) => ({
      queue_id: queueRow.id,
      notification_id: notification.id,
      token_id: attempt.tokenId,
      request_payload: attempt.requestPayload,
      response_payload: attempt.responsePayload,
      error_message: attempt.errorMessage,
      fcm_latency_ms: attempt.latencyMs,
    })),
  );

  if (invalidAttempts.length > 0) {
    await deactivateInvalidCustomerTokens(
      invalidAttempts.map((attempt) => attempt.tokenId),
      invalidAttempts[0]?.errorMessage ?? "invalid_token",
    );
  }

  if (successfulAttempts.length > 0) {
    const partialError = failedAttempts.length > 0 ? "partial_failed" : null;
    await markCustomerQueueSent({
      queueId: queueRow.id,
      notificationId: notification.id,
      attempts,
      nowIso,
      responsePayload: {
        ok: true,
        worker_id: WORKER_ID,
        successful_tokens: successfulAttempts.length,
        failed_tokens: failedAttempts.length,
        invalid_tokens: invalidAttempts.length,
      },
      lastError: partialError,
    });
    return {
      queueId: queueRow.id,
      status: "sent",
      attempts,
      successCount: successfulAttempts.length,
      failureCount: failedAttempts.length,
      invalidTokenCount: invalidAttempts.length,
      retryableFailureCount: retryableFailures.length,
    };
  }

  const errorMessage = failedAttempts[0]?.errorMessage ??
    "customer_fcm_delivery_failed";
  const failedStatus = await markCustomerQueueFailed({
    queueId: queueRow.id,
    notificationId: notification.id,
    attempts,
    maxAttempts: queueRow.max_attempts,
    nowIso,
    errorMessage,
    retryable: retryableFailures.length > 0,
    responsePayload: {
      ok: false,
      worker_id: WORKER_ID,
      failed_tokens: failedAttempts.length,
      invalid_tokens: invalidAttempts.length,
      retryable_failures: retryableFailures.length,
      reason: errorMessage,
    },
  });
  return {
    queueId: queueRow.id,
    status: failedStatus,
    attempts,
    successCount: 0,
    failureCount: failedAttempts.length,
    invalidTokenCount: invalidAttempts.length,
    retryableFailureCount: retryableFailures.length,
    errorMessage,
  };
}

async function processCustomerTarget(args: {
  processSingleQueueId: number | null;
  batchLimit: number;
  fallbackMode: boolean;
}): Promise<Record<string, unknown>> {
  const claimedRows = await claimCustomerQueueRows({
    processSingleQueueId: args.processSingleQueueId,
    batchLimit: args.batchLimit,
  });
  if (claimedRows.length === 0) {
    return {
      success: true,
      mode: args.processSingleQueueId === null ? "batch" : "single",
      target: "customer",
      worker_id: WORKER_ID,
      claimed: 0,
      processed: 0,
      sent: 0,
      retry: 0,
      failed: 0,
      queue_ids: [],
      fallback_mode: args.fallbackMode,
    };
  }

  const notificationIds = uniqueNonEmpty(
    claimedRows.map((row) => row.notification_id),
  );
  const userIds = uniqueNonEmpty(
    claimedRows.map((row) => row.customer_user_id),
  );

  const [notifications, tokens] = await Promise.all([
    loadCustomerNotifications(notificationIds),
    loadCustomerTokensByUsers(userIds),
  ]);

  const notificationsById = new Map(
    notifications.map((notification) => [notification.id, notification]),
  );
  const tokensByUserId = new Map<string, CustomerTokenRow[]>();
  for (const token of tokens) {
    const existing = tokensByUserId.get(token.user_id);
    if (existing) {
      existing.push(token);
    } else {
      tokensByUserId.set(token.user_id, [token]);
    }
  }

  const serviceAccount = loadServiceAccount();
  const accessToken = await createAccessToken(serviceAccount);
  const fcmUrl =
    `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`;

  const outcomes = await Promise.all(
    claimedRows.map((queueRow) =>
      processCustomerQueueRow({
        queueRow,
        notification: notificationsById.get(queueRow.notification_id) ?? null,
        tokens: tokensByUserId.get(queueRow.customer_user_id) ?? [],
        fcmUrl,
        accessToken,
      })
    ),
  );

  const sent = outcomes.filter((outcome) => outcome.status === "sent").length;
  const retry = outcomes.filter((outcome) => outcome.status === "retry").length;
  const failed =
    outcomes.filter((outcome) => outcome.status === "failed").length;

  return {
    success: true,
    mode: args.processSingleQueueId === null ? "batch" : "single",
    target: "customer",
    worker_id: WORKER_ID,
    claimed: claimedRows.length,
    processed: outcomes.length,
    sent,
    retry,
    failed,
    queue_ids: outcomes.map((outcome) => outcome.queueId),
    outcomes,
    fallback_mode: args.fallbackMode,
  };
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  try {
    const authorization = authorizeRequest(req);
    if (!authorization.ok) {
      console.error("[send-fcm] unauthorized", {
        reason: authorization.reason ?? "unauthorized",
        has_authorization: req.headers.has("authorization"),
        has_driver_secret: req.headers.has("x-driver-fcm-secret"),
        has_dispatch_secret: req.headers.has("x-notification-dispatch-secret"),
        has_process_secret: req.headers.has("x-process-notifications-secret"),
      });
      return Response.json({ success: false, error: "unauthorized" }, {
        status: 401,
      });
    }

    const body = (await req.json().catch(() => ({}))) as SendFcmRequest;
    const target = sanitizeText(body.target ?? "driver").toLowerCase();
    if (target !== "customer" && target !== "driver") {
      return Response.json({ success: false, error: "unsupported_target" }, {
        status: 400,
      });
    }

    const processSingleQueueId = normalizeQueueId(body.process_single_queue_id);
    const fallbackMode = body.fallback_mode === true;

    if (target === "customer") {
      const summary = await processCustomerTarget({
        processSingleQueueId,
        batchLimit: processSingleQueueId === null
          ? parseCustomerBatchLimit(body.batch_limit)
          : 1,
        fallbackMode,
      });
      return Response.json(summary);
    }

    const batchLimit = parseBatchLimit(body.batch_limit);

    if (fallbackMode) {
      await supabase.rpc("recover_stale_driver_fcm_processing", {
        p_stale_after_seconds: 180,
        p_limit: 1000,
      });
      await supabase.rpc("recover_failed_driver_fcm_queue", {
        p_limit: 1000,
      });
    }

    const claimedRows = await claimQueue({
      limit: processSingleQueueId === null ? batchLimit : 1,
      processSingleQueueId,
    });

    if (claimedRows.length === 0) {
      return Response.json({
        success: true,
        mode: processSingleQueueId === null ? "batch" : "single",
        worker_id: WORKER_ID,
        claimed: 0,
        processed: 0,
        sent: 0,
        retry: 0,
        failed: 0,
        dead: 0,
        poisoned: 0,
        removed_tokens: 0,
        queue_ids: [],
      });
    }

    const serviceAccount = loadServiceAccount();
    const accessToken = await createAccessToken(serviceAccount);
    const fcmUrl =
      `https://fcm.googleapis.com/v1/projects/${serviceAccount.project_id}/messages:send`;

    const outcomes: QueueOutcome[] = [];
    for (const row of claimedRows) {
      const outcome = await processQueueRow({
        queueRow: row,
        fcmUrl,
        accessToken,
      });
      outcomes.push(outcome);
    }

    const sent = outcomes.filter((o) => o.status === "sent").length;
    const retry = outcomes.filter((o) => o.status === "retry").length;
    const failed = outcomes.filter((o) => o.status === "failed").length;
    const dead = outcomes.filter((o) => o.status === "dead").length;
    const poisoned = outcomes.filter((o) => o.status === "poisoned").length;
    const removedTokens = outcomes.reduce(
      (acc, row) => acc + row.removedTokens,
      0,
    );

    return Response.json({
      success: true,
      mode: processSingleQueueId === null ? "batch" : "single",
      worker_id: WORKER_ID,
      claimed: claimedRows.length,
      processed: outcomes.length,
      sent,
      retry,
      failed,
      dead,
      poisoned,
      removed_tokens: removedTokens,
      queue_ids: outcomes.map((o) => o.queueId),
    });
  } catch (error) {
    console.error("[send-fcm] fatal", error);
    return Response.json({ success: false, error: String(error) }, {
      status: 500,
    });
  }
});
