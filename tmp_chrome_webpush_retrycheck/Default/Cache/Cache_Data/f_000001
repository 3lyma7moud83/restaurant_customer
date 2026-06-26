const ENV_FILE_CANDIDATES = buildEnvFileCandidates();
const DELIVERY_DB_NAME = 'customer_fcm_notification_flow.v1';
const DELIVERY_RECORD_STORE = 'notification_records';
const DELIVERY_META_STORE = 'notification_meta';
const DELIVERY_RECORD_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_RECOVERY_RECORDS = 50;
const NOTIFICATION_VIBRATION_PATTERN = [200, 100, 200];
const FCM_PAYLOAD_CONTAINER_KEYS = new Set([
  'android',
  'apns',
  'data',
  'fcmOptions',
  'fcm_options',
  'message',
  'notification',
  'token',
  'webpush',
]);

const inFlightNotificationKeys = new Set();
const memoryNotificationRecords = new Map();
const memoryMetaRecords = new Map();

let initialized = false;
let messaging = null;
let deliveryDbPromise = null;

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    Promise.all([
      self.clients.claim(),
      executeRecovery('service_worker_activate'),
    ]),
  );
});

self.addEventListener('push', (event) => {
  event.waitUntil(handlePushEvent(event));
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const data = normalizeNotificationData(event.notification?.data || {});
  const targetPath = resolveTargetPath(data);

  event.waitUntil(handleNotificationClick(data, targetPath));
});

self.addEventListener('notificationclose', (event) => {
  const data = normalizeNotificationData(event.notification?.data || {});
  event.waitUntil(handleNotificationDismissed(data));
});

self.addEventListener('message', (event) => {
  event.waitUntil(handleClientMessage(event));
});

// Register custom notification handlers before importing FCM. The Firebase SDK
// can otherwise replace click behavior during service-worker initialization.
importScripts(
  'https://www.gstatic.com/firebasejs/10.13.2/firebase-app-compat.js',
);
importScripts(
  'https://www.gstatic.com/firebasejs/10.13.2/firebase-messaging-compat.js',
);

async function ensureMessagingInitialized() {
  if (initialized) {
    return messaging;
  }

  const firebaseConfig = await loadFirebaseConfig();
  if (!firebaseConfig) {
    console.warn(
      '[FCM][sw] Firebase web config is missing or invalid.',
    );
    return null;
  }

  try {
    if (!firebase.apps || firebase.apps.length === 0) {
      firebase.initializeApp(firebaseConfig);
    }
    messaging = firebase.messaging();
    messaging.onBackgroundMessage((payload) => {
      logNotificationFlow('notification_callback_executed', {
        message: 'Notification callback executed',
        callback: 'onBackgroundMessage',
        source: 'firebase_messaging_sdk',
        notification_id: notificationIdFromPayload(payload),
      });
    });
    initialized = true;
    return messaging;
  } catch (error) {
    console.error(
      '[FCM][sw] Failed to initialize messaging service worker.',
      error,
    );
    return null;
  }
}

async function handlePushEvent(event) {
  await ensureMessagingInitialized();
  const rawPayload = extractPushPayload(event);
  logNotificationFlow('service_worker_received_push', {
    message: 'Service Worker received push',
    has_payload: rawPayload != null,
  });

  if (!rawPayload) {
    logNotificationFlow('notification_payload_rejected', {
      message: 'Service Worker rejected push without a payload',
      reason: 'missing_push_payload',
    });
    return;
  }

  const presentation = buildValidatedNotificationPresentation(rawPayload);
  if (!presentation) {
    return;
  }

  const dedupKey = presentation.dedupKey;
  if (inFlightNotificationKeys.has(dedupKey)) {
    await recordDuplicatePrevented(presentation, 'in_flight');
    return;
  }

  inFlightNotificationKeys.add(dedupKey);
  try {
    const existing = await readNotificationRecord(dedupKey);
    if (existing?.displayedAt || existing?.acknowledgedAt) {
      await recordDuplicatePrevented(presentation, 'persisted_state');
      return;
    }

    await self.registration.showNotification(
      presentation.title,
      presentation.options,
    );

    const nowIso = utcNow();
    const record = {
      id: dedupKey,
      notificationId: presentation.notificationId,
      messageId: presentation.messageId,
      title: presentation.title,
      body: presentation.options.body || '',
      data: presentation.options.data,
      pushReceivedAt: presentation.pushReceivedAt,
      displayedAt: nowIso,
      acknowledgedAt: nowIso,
      clickedAt: existing?.clickedAt || null,
      dismissedAt: existing?.dismissedAt || null,
      status: 'received',
      updatedAt: nowIso,
    };
    await writeNotificationRecord(record);

    logNotificationFlow('notification_displayed', {
      message: 'Notification displayed',
      notification_id: presentation.notificationId,
      message_id: presentation.messageId,
      dedup_key: dedupKey,
    });
    await postLifecycleEvent('displayed', presentation, {
      displayed_at: nowIso,
    });

    logNotificationFlow('notification_received', {
      message: 'Notification state recorded as received',
      notification_id: presentation.notificationId,
      message_id: presentation.messageId,
      dedup_key: dedupKey,
    });
    await postLifecycleEvent('received', presentation, {
      received_at: nowIso,
    });

    await updateBadgeCount(1);
    await postLifecycleEvent('badge_updated', presentation, {
      badge_count: await readBadgeCount(),
    });

    logNotificationFlow('notification_acknowledged', {
      message: 'Notification acknowledged',
      notification_id: presentation.notificationId,
      message_id: presentation.messageId,
      dedup_key: dedupKey,
      acknowledged_at: nowIso,
    });
    await postLifecycleEvent('acknowledged', presentation, {
      acknowledged_at: nowIso,
    });

    logNotificationFlow('notification_callback_executed', {
      message: 'Notification callbacks execute',
      callback: 'service_worker_lifecycle_broadcast',
      notification_id: presentation.notificationId,
      message_id: presentation.messageId,
    });

    logNotificationFlow('notification_effects_requested', {
      message: 'Sound/vibration requested if supported',
      notification_id: presentation.notificationId,
      vibration_supported: true,
      sound_supported: false,
    });
  } catch (error) {
    await writeNotificationRecord({
      id: dedupKey,
      notificationId: presentation.notificationId,
      messageId: presentation.messageId,
      title: presentation.title,
      body: presentation.options.body || '',
      data: presentation.options.data,
      pushReceivedAt: presentation.pushReceivedAt,
      displayedAt: null,
      acknowledgedAt: null,
      status: 'display_failed',
      error: String(error),
      updatedAt: utcNow(),
    });
    console.error('[FCM][sw] Notification display failed.', error);
  } finally {
    inFlightNotificationKeys.delete(dedupKey);
    await pruneNotificationRecords();
  }
}

async function handleNotificationClick(data, targetPath) {
  const dedupKey = dedupKeyFromData(data);
  const nowIso = utcNow();
  const windowClients = await self.clients.matchAll({
    type: 'window',
    includeUncontrolled: true,
  });

  let existing = null;
  let shouldDecrementBadge = true;
  if (dedupKey) {
    existing = await readNotificationRecord(dedupKey);
    shouldDecrementBadge = !existing?.clickedAt && !existing?.dismissedAt;
    await writeNotificationRecord({
      ...(existing || {}),
      id: dedupKey,
      notificationId: data.notification_id || existing?.notificationId || '',
      messageId: data.message_id || existing?.messageId || '',
      title: data.title || existing?.title || '',
      body: data.body || existing?.body || '',
      data: data,
      clickedAt: nowIso,
      needsClickRecovery: windowClients.length === 0,
      updatedAt: nowIso,
      status: existing?.status || 'received',
    });
  }

  logNotificationFlow('notification_clicked', {
    message: 'Notification clicked',
    notification_id: data.notification_id || '',
    message_id: data.message_id || '',
    dedup_key: dedupKey || '',
  });
  if (shouldDecrementBadge) {
    await updateBadgeCount(-1);
  }
  await broadcastLifecycleEvent('clicked', data, {
    clicked_at: nowIso,
    badge_count: await readBadgeCount(),
  });

  for (const client of windowClients) {
    postNotificationClickToClient(client, data);
  }

  const normalizedTargetUrl = toAbsoluteUrl(targetPath);
  if (normalizedTargetUrl) {
    const targetClient = windowClients.find(
      (client) => stripHash(client.url) === stripHash(normalizedTargetUrl),
    );
    if (targetClient && 'focus' in targetClient) {
      return targetClient.focus();
    }
  }

  for (const client of windowClients) {
    if ('focus' in client) {
      return client.focus();
    }
  }
  if (self.clients.openWindow) {
    return self.clients.openWindow(targetPath);
  }
  return null;
}

async function handleNotificationDismissed(data) {
  const dedupKey = dedupKeyFromData(data);
  const nowIso = utcNow();
  let shouldDecrementBadge = true;
  if (dedupKey) {
    const existing = await readNotificationRecord(dedupKey);
    shouldDecrementBadge = !existing?.clickedAt && !existing?.dismissedAt;
    await writeNotificationRecord({
      ...(existing || {}),
      id: dedupKey,
      notificationId: data.notification_id || existing?.notificationId || '',
      messageId: data.message_id || existing?.messageId || '',
      title: data.title || existing?.title || '',
      body: data.body || existing?.body || '',
      data: data,
      dismissedAt: nowIso,
      updatedAt: nowIso,
      status: existing?.status || 'received',
    });
  }

  logNotificationFlow('notification_dismissed', {
    message: 'Notification dismissed',
    notification_id: data.notification_id || '',
    message_id: data.message_id || '',
    dedup_key: dedupKey || '',
  });
  if (shouldDecrementBadge) {
    await updateBadgeCount(-1);
  }
  await broadcastLifecycleEvent('dismissed', data, {
    dismissed_at: nowIso,
    badge_count: await readBadgeCount(),
  });
}

async function handleClientMessage(event) {
  const message = decodeClientMessage(event.data);
  if (!message || typeof message !== 'object') {
    return;
  }

  if (message.type === 'fcm_recovery_request') {
    await executeRecovery(
      sanitizeTextValue(message.reason) || 'client_request',
      event.source || null,
    );
  }
}

async function executeRecovery(reason, targetClient = null) {
  await pruneNotificationRecords();
  const records = await readAllNotificationRecords();
  const badgeCount = await readBadgeCount();
  await applyBrowserBadge(badgeCount);

  const recoverable = records
    .filter((record) => record && record.acknowledgedAt)
    .sort((a, b) =>
      String(a.updatedAt || '').localeCompare(String(b.updatedAt || '')),
    )
    .slice(-MAX_RECOVERY_RECORDS);

  logNotificationFlow('recovery_executed', {
    message: 'Recovery executed',
    reason,
    recovered_count: recoverable.length,
    badge_count: badgeCount,
  });

  await postRecoveryMessage(targetClient, {
    reason,
    recovered_count: recoverable.length,
    badge_count: badgeCount,
  });

  for (const record of recoverable) {
    const data = normalizeNotificationData(record.data || {});
    if (record.needsClickRecovery && record.clickedAt) {
      await postNotificationClickRecovery(targetClient, record, data);
      await writeNotificationRecord({
        ...record,
        needsClickRecovery: false,
        clickRecoveredAt: utcNow(),
        updatedAt: utcNow(),
      });
      continue;
    }
  }
}

async function postNotificationClickRecovery(targetClient, record, data) {
  const message = JSON.stringify({
    type: 'fcm_notification_click',
    data,
    meta: {
      notification_id: record.notificationId || data.notification_id || '',
      message_id: record.messageId || data.message_id || '',
      recovered: true,
      clicked_at: record.clickedAt,
    },
  });

  if (targetClient) {
    postClientMessage(targetClient, message);
    return;
  }

  const clients = await self.clients.matchAll({
    type: 'window',
    includeUncontrolled: true,
  });
  for (const client of clients) {
    postClientMessage(client, message);
  }
}

async function postRecoveryMessage(targetClient, meta) {
  await postLifecycleMessage(targetClient, 'recovery_executed', {}, {
    ...meta,
    recovered: true,
  });
}

function buildValidatedNotificationPresentation(payload) {
  if (!payload || typeof payload !== 'object') {
    logNotificationFlow('notification_payload_rejected', {
      message: 'Service Worker rejected invalid push payload',
      reason: 'payload_not_object',
    });
    return null;
  }

  const data = buildBackgroundNotificationData(payload);
  const notificationId = sanitizeTextValue(data.notification_id);
  if (!notificationId) {
    logNotificationFlow('notification_payload_rejected', {
      message: 'Service Worker rejected push without notification_id',
      reason: 'missing_notification_id',
    });
    return null;
  }

  const title = normalizeBrandingText(
    payload?.notification?.title ||
      payload?.webpush?.notification?.title ||
      data.title ||
      '',
  );
  const body = normalizeBrandingText(
    payload?.notification?.body ||
      payload?.webpush?.notification?.body ||
      data.body ||
      '',
  );
  if (!title || !body) {
    logNotificationFlow('notification_payload_rejected', {
      message: 'Service Worker rejected push without title/body',
      reason: 'missing_title_or_body',
      notification_id: notificationId,
    });
    return null;
  }

  const messageId =
    sanitizeTextValue(payload?.messageId) ||
    sanitizeTextValue(payload?.message_id) ||
    sanitizeTextValue(payload?.fcmMessageId) ||
    sanitizeTextValue(data.message_id);
  const clickAction = resolveTargetPath(data);
  data.notification_id = notificationId;
  data.title = title;
  data.body = body;
  data.fcm_push_received = 'true';
  data.delivery_proof = 'service_worker_push';
  data.received_by = 'firebase-messaging-sw.js';
  if (messageId) {
    data.message_id = messageId;
  }
  if (!data.click_action && clickAction) {
    data.click_action = clickAction;
  }

  const tag = notificationId;
  const pushReceivedAt = utcNow();
  const dedupKey = `notification:${notificationId}`;
  logNotificationFlow('notification_payload_validated', {
    message: 'Service Worker validated notification payload',
    notification_id: notificationId,
    message_id: messageId || '',
    dedup_key: dedupKey,
  });

  return {
    title,
    notificationId,
    messageId,
    dedupKey,
    pushReceivedAt,
    options: {
      body,
      data,
      icon:
        payload?.notification?.icon ||
        payload?.webpush?.notification?.icon ||
        '/icons/Icon-192.png',
      badge: '/icons/Icon-192.png',
      tag,
      requireInteraction: true,
      renotify: true,
      ...(shouldUseNotificationVibration()
        ? { vibrate: NOTIFICATION_VIBRATION_PATTERN }
        : {}),
    },
  };
}

function shouldUseNotificationVibration() {
  const userAgent = self.navigator?.userAgent || '';
  return /android/i.test(userAgent);
}

function buildBackgroundNotificationData(payload) {
  const fromTopLevel = normalizeTopLevelNotificationData(payload || {});
  const fromData = normalizeNotificationData(payload?.data || {});
  const fromStringifiedData = normalizeNotificationData(
    parseUnknownJson(payload?.data) || {},
  );
  const fromNestedData = normalizeNotificationData(
    parseUnknownJson(payload?.data?.data) || {},
  );
  const fromWebpushNotification = normalizeNotificationData(
    payload?.webpush?.notification?.data || {},
  );

  const merged = {
    ...fromTopLevel,
    ...fromWebpushNotification,
    ...fromStringifiedData,
    ...fromNestedData,
    ...fromData,
  };
  const payloadLink = normalizeTargetPath(
    payload?.fcmOptions?.link ||
      payload?.webpush?.fcm_options?.link ||
      payload?.webpush?.fcmOptions?.link,
  );
  if (!merged.click_action && payloadLink) {
    merged.click_action = payloadLink;
  }

  return merged;
}

function normalizeTopLevelNotificationData(payload) {
  if (!payload || typeof payload !== 'object') {
    return {};
  }
  const normalized = {};
  for (const [key, value] of Object.entries(payload)) {
    if (!key || FCM_PAYLOAD_CONTAINER_KEYS.has(key)) {
      continue;
    }
    if (value !== null && typeof value === 'object') {
      continue;
    }
    const next = sanitizeTextValue(value);
    if (next) {
      normalized[key] = next;
    }
  }
  return normalized;
}

function extractPushPayload(event) {
  if (!event || !event.data) {
    return null;
  }

  let raw = null;
  try {
    raw = event.data.json();
  } catch (_) {
    try {
      raw = parseUnknownJson(event.data.text());
    } catch (_) {
      raw = null;
    }
  }
  return unwrapFcmPushPayload(raw);
}

function unwrapFcmPushPayload(raw) {
  if (!raw || typeof raw !== 'object') {
    return null;
  }

  if (raw.message && typeof raw.message === 'object') {
    return raw.message;
  }

  if (typeof raw.data === 'string') {
    const decodedData = parseUnknownJson(raw.data);
    if (decodedData && typeof decodedData === 'object') {
      return decodedData;
    }
  } else if (raw.data && typeof raw.data === 'object') {
    const dataObject = raw.data;
    if (
      dataObject.notification ||
      dataObject.webpush ||
      dataObject.data ||
      dataObject.fcmOptions
    ) {
      return dataObject;
    }
  }

  return raw;
}

function parseUnknownJson(value) {
  if (typeof value !== 'string') {
    return null;
  }
  const trimmed = value.trim();
  if (!trimmed) {
    return null;
  }
  try {
    return JSON.parse(trimmed);
  } catch (_) {
    return null;
  }
}

async function recordDuplicatePrevented(presentation, reason) {
  logNotificationFlow('duplicate_notification_prevented', {
    message: 'Duplicate notification prevented',
    reason,
    notification_id: presentation.notificationId,
    message_id: presentation.messageId || '',
    dedup_key: presentation.dedupKey,
  });
  await postLifecycleEvent('duplicate_prevented', presentation, {
    reason,
  });
}

function notificationIdFromPayload(payload) {
  const data = buildBackgroundNotificationData(payload || {});
  return sanitizeTextValue(data.notification_id);
}

function dedupKeyFromData(data) {
  const notificationId = sanitizeTextValue(data.notification_id);
  if (notificationId) {
    return `notification:${notificationId}`;
  }
  const messageId = sanitizeTextValue(data.message_id);
  if (messageId) {
    return `message:${messageId}`;
  }
  return null;
}

async function postLifecycleEvent(eventName, presentation, meta = {}) {
  await broadcastLifecycleEvent(
    eventName,
    presentation.options?.data || {},
    {
      notification_id: presentation.notificationId,
      message_id: presentation.messageId || '',
      dedup_key: presentation.dedupKey,
      push_received_at: presentation.pushReceivedAt,
      ...meta,
    },
  );
}

async function broadcastLifecycleEvent(eventName, data, meta = {}) {
  await postLifecycleMessage(null, eventName, data, meta);
}

async function postLifecycleMessage(targetClient, eventName, data, meta = {}) {
  const payload = JSON.stringify({
    type: 'fcm_notification_lifecycle',
    event: eventName,
    data: normalizeNotificationData(data),
    meta: {
      occurred_at: utcNow(),
      ...meta,
    },
  });

  if (targetClient) {
    postClientMessage(targetClient, payload);
    return;
  }

  const clients = await self.clients.matchAll({
    type: 'window',
    includeUncontrolled: true,
  });
  for (const client of clients) {
    postClientMessage(client, payload);
  }
}

function postNotificationClickToClient(client, data) {
  postClientMessage(
    client,
    JSON.stringify({
      type: 'fcm_notification_click',
      data,
    }),
  );
}

function postClientMessage(client, message) {
  try {
    client.postMessage(message);
  } catch (_) {
    // Ignore postMessage failures and rely on recovery replay.
  }
}

async function readNotificationRecord(id) {
  if (!id) {
    return null;
  }
  if (memoryNotificationRecords.has(id)) {
    return memoryNotificationRecords.get(id);
  }

  const db = await openDeliveryDb();
  if (!db) {
    return null;
  }

  return new Promise((resolve) => {
    try {
      const transaction = db.transaction(DELIVERY_RECORD_STORE, 'readonly');
      const request = transaction.objectStore(DELIVERY_RECORD_STORE).get(id);
      request.onsuccess = () => resolve(request.result || null);
      request.onerror = () => resolve(null);
    } catch (_) {
      resolve(null);
    }
  });
}

async function writeNotificationRecord(record) {
  if (!record?.id) {
    return;
  }
  memoryNotificationRecords.set(record.id, record);

  const db = await openDeliveryDb();
  if (!db) {
    return;
  }

  await new Promise((resolve) => {
    try {
      const transaction = db.transaction(DELIVERY_RECORD_STORE, 'readwrite');
      transaction.objectStore(DELIVERY_RECORD_STORE).put(record);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => resolve();
      transaction.onabort = () => resolve();
    } catch (_) {
      resolve();
    }
  });
}

async function readAllNotificationRecords() {
  const db = await openDeliveryDb();
  if (!db) {
    return Array.from(memoryNotificationRecords.values());
  }

  return new Promise((resolve) => {
    try {
      const transaction = db.transaction(DELIVERY_RECORD_STORE, 'readonly');
      const request = transaction.objectStore(DELIVERY_RECORD_STORE).getAll();
      request.onsuccess = () => resolve(request.result || []);
      request.onerror = () => resolve(Array.from(memoryNotificationRecords.values()));
    } catch (_) {
      resolve(Array.from(memoryNotificationRecords.values()));
    }
  });
}

async function pruneNotificationRecords() {
  const cutoff = Date.now() - DELIVERY_RECORD_RETENTION_MS;
  const records = await readAllNotificationRecords();
  const expiredIds = records
    .filter((record) => {
      const updatedAt = Date.parse(record.updatedAt || record.displayedAt || '');
      return Number.isFinite(updatedAt) && updatedAt < cutoff;
    })
    .map((record) => record.id)
    .filter(Boolean);

  for (const id of expiredIds) {
    memoryNotificationRecords.delete(id);
  }

  const db = await openDeliveryDb();
  if (!db || expiredIds.length === 0) {
    return;
  }

  await new Promise((resolve) => {
    try {
      const transaction = db.transaction(DELIVERY_RECORD_STORE, 'readwrite');
      const store = transaction.objectStore(DELIVERY_RECORD_STORE);
      for (const id of expiredIds) {
        store.delete(id);
      }
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => resolve();
      transaction.onabort = () => resolve();
    } catch (_) {
      resolve();
    }
  });
}

async function readBadgeCount() {
  const record = await readMetaRecord('badge_count');
  const value = Number.parseInt(String(record?.value ?? '0'), 10);
  return Number.isFinite(value) ? Math.max(0, value) : 0;
}

async function updateBadgeCount(delta) {
  const current = await readBadgeCount();
  const next = Math.max(0, current + delta);
  await writeMetaRecord({ key: 'badge_count', value: next, updatedAt: utcNow() });
  await applyBrowserBadge(next);
}

async function applyBrowserBadge(count) {
  try {
    if (count > 0 && self.registration?.setAppBadge) {
      await self.registration.setAppBadge(count);
      return;
    }
    if (count === 0 && self.registration?.clearAppBadge) {
      await self.registration.clearAppBadge();
      return;
    }
  } catch (_) {
    // Badge support is optional.
  }
}

async function readMetaRecord(key) {
  if (memoryMetaRecords.has(key)) {
    return memoryMetaRecords.get(key);
  }

  const db = await openDeliveryDb();
  if (!db) {
    return null;
  }

  return new Promise((resolve) => {
    try {
      const transaction = db.transaction(DELIVERY_META_STORE, 'readonly');
      const request = transaction.objectStore(DELIVERY_META_STORE).get(key);
      request.onsuccess = () => resolve(request.result || null);
      request.onerror = () => resolve(null);
    } catch (_) {
      resolve(null);
    }
  });
}

async function writeMetaRecord(record) {
  if (!record?.key) {
    return;
  }
  memoryMetaRecords.set(record.key, record);

  const db = await openDeliveryDb();
  if (!db) {
    return;
  }

  await new Promise((resolve) => {
    try {
      const transaction = db.transaction(DELIVERY_META_STORE, 'readwrite');
      transaction.objectStore(DELIVERY_META_STORE).put(record);
      transaction.oncomplete = () => resolve();
      transaction.onerror = () => resolve();
      transaction.onabort = () => resolve();
    } catch (_) {
      resolve();
    }
  });
}

function openDeliveryDb() {
  if (typeof indexedDB === 'undefined') {
    return Promise.resolve(null);
  }
  if (deliveryDbPromise) {
    return deliveryDbPromise;
  }

  deliveryDbPromise = new Promise((resolve) => {
    try {
      const request = indexedDB.open(DELIVERY_DB_NAME, 1);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(DELIVERY_RECORD_STORE)) {
          db.createObjectStore(DELIVERY_RECORD_STORE, { keyPath: 'id' });
        }
        if (!db.objectStoreNames.contains(DELIVERY_META_STORE)) {
          db.createObjectStore(DELIVERY_META_STORE, { keyPath: 'key' });
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => resolve(null);
      request.onblocked = () => resolve(null);
    } catch (_) {
      resolve(null);
    }
  });
  return deliveryDbPromise;
}

async function loadFirebaseConfig() {
  const invalidPaths = [];
  for (const path of ENV_FILE_CANDIDATES) {
    try {
      const response = await fetch(path, {
        cache: 'no-store',
        credentials: 'same-origin',
      });
      if (!response.ok) {
        continue;
      }

      const text = await response.text();
      if (text.trim().length === 0) {
        continue;
      }

      const parsed = parseFirebaseConfig(text);
      if (parsed) {
        console.debug('[FCM][sw] Firebase config loaded from:', path);
        return parsed;
      }
      invalidPaths.push(path);
    } catch (_) {
      // Ignore and try the next path.
    }
  }
  if (invalidPaths.length > 0) {
    console.warn(
      '[FCM][sw] Firebase config file(s) found but invalid:',
      invalidPaths.join(', '),
    );
  }
  return null;
}

function parseFirebaseConfig(envText) {
  if (!envText) {
    return null;
  }

  const env = {};
  for (const rawLine of envText.split('\n')) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#') || !line.includes('=')) {
      continue;
    }

    const separatorIndex = line.indexOf('=');
    const key = line.substring(0, separatorIndex).trim();
    const value = sanitizeEnvValue(line.substring(separatorIndex + 1));
    if (!key || !value) {
      continue;
    }
    env[key] = value;
  }

  const required = [
    'FIREBASE_API_KEY',
    'FIREBASE_PROJECT_ID',
    'FIREBASE_MESSAGING_SENDER_ID',
    'FIREBASE_WEB_APP_ID',
  ];
  const missingRequired = required.some(
    (key) => !env[key] || looksLikePlaceholder(env[key]),
  );
  if (missingRequired) {
    return null;
  }
  if (!env.FIREBASE_WEB_APP_ID.includes(':web:')) {
    console.warn(
      '[FCM][sw] FIREBASE_WEB_APP_ID must contain ":web:".',
    );
    return null;
  }

  return {
    apiKey: env.FIREBASE_API_KEY,
    authDomain: env.FIREBASE_AUTH_DOMAIN,
    projectId: env.FIREBASE_PROJECT_ID,
    storageBucket: env.FIREBASE_STORAGE_BUCKET,
    messagingSenderId: env.FIREBASE_MESSAGING_SENDER_ID,
    appId: env.FIREBASE_WEB_APP_ID,
    measurementId: env.FIREBASE_MEASUREMENT_ID,
  };
}

function buildEnvFileCandidates() {
  let scopePath = '/';
  try {
    const scopeUrl = new URL(self.registration.scope);
    scopePath = scopeUrl.pathname || '/';
  } catch (_) {
    scopePath = '/';
  }

  const normalizedScope = scopePath.endsWith('/') ? scopePath : `${scopePath}/`;
  return Array.from(
    new Set([
      `${normalizedScope}assets/assets/env/app.env`,
      `${normalizedScope}assets/env/app.env`,
      `${normalizedScope}.env`,
      `${normalizedScope}./assets/assets/env/app.env`,
      `${normalizedScope}./assets/env/app.env`,
      '/assets/assets/env/app.env',
      '/assets/env/app.env',
      '/.env',
      'assets/assets/env/app.env',
      'assets/env/app.env',
      './assets/assets/env/app.env',
      './assets/env/app.env',
      '.env',
    ]),
  );
}

function sanitizeEnvValue(rawValue) {
  const trimmed = rawValue.trim();
  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"')) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'"))
  ) {
    return trimmed.slice(1, -1).trim();
  }
  return trimmed;
}

function looksLikePlaceholder(value) {
  if (typeof value !== 'string') {
    return true;
  }
  const lowered = value.trim().toLowerCase();
  return (
    !lowered ||
    lowered.includes('your_') ||
    lowered.includes('your-') ||
    lowered.includes('replace_with') ||
    lowered.includes('replace-with') ||
    lowered.includes('placeholder')
  );
}

function normalizeNotificationData(rawData) {
  if (!rawData || typeof rawData !== 'object') {
    return {};
  }
  const normalized = {};
  for (const [key, value] of Object.entries(rawData)) {
    if (!key) {
      continue;
    }
    if (value === null || value === undefined) {
      continue;
    }
    const next = typeof value === 'string' ? value.trim() : String(value).trim();
    if (!next) {
      continue;
    }
    normalized[key] = stripWrappingQuotes(next);
  }
  return normalized;
}

function sanitizeTextValue(value) {
  if (value === null || value === undefined) {
    return '';
  }
  return stripWrappingQuotes(String(value).trim());
}

function stripWrappingQuotes(value) {
  if (!value || value.length < 2) {
    return value;
  }
  const startsWithDouble = value.startsWith('"') && value.endsWith('"');
  const startsWithSingle = value.startsWith("'") && value.endsWith("'");
  if (startsWithDouble || startsWithSingle) {
    return value.slice(1, -1).trim();
  }
  return value;
}

function normalizeBrandingText(value) {
  if (typeof value !== 'string' || value.length === 0) {
    return value || '';
  }

  return value
    .replace(/support@delivery-mat3mk\.com/gi, 'support@deliverymat3mk.com')
    .replace(/delivery-mat3mk/gi, 'Delivery Mat3mk')
    .replace(/restaurant_(customer|driver|admin)/gi, 'Delivery Mat3mk')
    .replace(/mat3amak/gi, 'Delivery Mat3mk');
}

function resolveTargetPath(data) {
  const inferredOrderId =
    typeof data.order_id === 'string' ? data.order_id.trim() : '';
  const trackingPath = inferredOrderId
    ? `/?screen=order_tracking&order_id=${encodeURIComponent(inferredOrderId)}`
    : '';
  const explicitCandidates = [
    data.click_action,
    data.link,
    data.url,
    data.path,
  ];
  for (const candidate of explicitCandidates) {
    const normalized = normalizeTargetPath(candidate);
    if (!normalized) {
      continue;
    }
    if (trackingPath && isGenericOrdersTarget(normalized)) {
      return trackingPath;
    }
    return normalized;
  }

  const rawScreen =
    typeof data.screen === 'string' ? data.screen.trim().toLowerCase() : '';
  if (rawScreen) {
    if (trackingPath && isGenericOrdersScreen(rawScreen)) {
      return trackingPath;
    }
    const query = new URLSearchParams({
      screen: rawScreen,
    });
    if (inferredOrderId) {
      query.set('order_id', inferredOrderId);
    }
    return `/?${query.toString()}`;
  }

  if (trackingPath) {
    return trackingPath;
  }

  return '/';
}

function isGenericOrdersScreen(screen) {
  return (
    screen === 'orders' ||
    screen === 'order' ||
    screen === 'my_orders'
  );
}

function isGenericOrdersTarget(pathOrUrl) {
  try {
    const url = new URL(pathOrUrl, self.location.origin);
    const screen = sanitizeTextValue(url.searchParams.get('screen'));
    if (url.searchParams.has('order_id')) {
      return false;
    }
    if (screen && !isGenericOrdersScreen(screen.toLowerCase())) {
      return false;
    }

    const normalizedPath = (url.pathname || '/').toLowerCase();
    return (
      isGenericOrdersScreen((screen || '').toLowerCase()) ||
      normalizedPath === '/orders' ||
      normalizedPath.endsWith('/orders')
    );
  } catch (_) {
    const normalized = pathOrUrl.trim().toLowerCase();
    return (
      normalized === '/orders' ||
      normalized === 'orders' ||
      normalized === '/?screen=orders' ||
      normalized === '?screen=orders'
    );
  }
}

function normalizeTargetPath(candidate) {
  if (typeof candidate !== 'string') {
    return null;
  }

  const trimmed = candidate.trim();
  if (!trimmed || trimmed.toUpperCase() === 'FLUTTER_NOTIFICATION_CLICK') {
    return null;
  }

  if (/^https?:\/\//i.test(trimmed)) {
    return trimmed;
  }
  if (trimmed.startsWith('/')) {
    return trimmed;
  }
  if (trimmed.startsWith('?') || trimmed.startsWith('#')) {
    return `/${trimmed}`;
  }
  return `/${trimmed}`;
}

function toAbsoluteUrl(pathOrUrl) {
  try {
    return new URL(pathOrUrl, self.location.origin).toString();
  } catch (_) {
    return null;
  }
}

function stripHash(url) {
  if (typeof url !== 'string') {
    return '';
  }

  const hashIndex = url.indexOf('#');
  return hashIndex >= 0 ? url.slice(0, hashIndex) : url;
}

function decodeClientMessage(value) {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (!trimmed) {
      return null;
    }
    try {
      return JSON.parse(trimmed);
    } catch (_) {
      return null;
    }
  }
  return value;
}

function utcNow() {
  return new Date().toISOString();
}

function logNotificationFlow(type, payload = {}) {
  try {
    console.log(JSON.stringify({
      type,
      app: 'restaurant_customer',
      surface: 'firebase-messaging-sw.js',
      at: utcNow(),
      ...payload,
    }));
  } catch (_) {
    console.log('[FCM][sw]', type, payload);
  }
}

ensureMessagingInitialized();
