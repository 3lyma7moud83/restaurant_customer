importScripts(
  'https://www.gstatic.com/firebasejs/10.13.2/firebase-app-compat.js',
);
importScripts(
  'https://www.gstatic.com/firebasejs/10.13.2/firebase-messaging-compat.js',
);

const ENV_FILE_CANDIDATES = buildEnvFileCandidates();
const RECENT_NOTIFICATION_WINDOW_MS = 12000;
const recentlyShownNotificationKeys = new Map();

let initialized = false;
let messaging = null;

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(self.clients.claim());
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
      void showBackgroundNotificationFromPayload(payload, 'onBackgroundMessage');
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
  const payload = extractPushPayload(event);
  if (!payload) {
    return;
  }
  await showBackgroundNotificationFromPayload(payload, 'push_event');
}

async function handleNotificationClick(data, targetPath) {
  const windowClients = await self.clients.matchAll({
    type: 'window',
    includeUncontrolled: true,
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
    const openedClient = await self.clients.openWindow(targetPath);
    if (openedClient) {
      postNotificationClickToClient(openedClient, data);
    }
    return openedClient;
  }
  return null;
}

function buildBackgroundNotificationData(payload) {
  const fromData = normalizeNotificationData(payload?.data || {});
  const fromWebpushNotification = normalizeNotificationData(
    payload?.webpush?.notification?.data || {},
  );

  const merged = {
    ...fromWebpushNotification,
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

async function showBackgroundNotificationFromPayload(payload, source) {
  const presentation = buildNotificationPresentation(payload);
  if (!presentation) {
    return false;
  }

  const dedupKey = notificationDedupKey(presentation);
  if (shouldSkipRecentlyShownNotification(dedupKey)) {
    return false;
  }

  console.debug(
    '[FCM][sw] Showing background notification from',
    source,
    'tag=',
    presentation.options?.tag || '<none>',
  );
  await self.registration.showNotification(
    presentation.title,
    presentation.options,
  );
  return true;
}

function buildNotificationPresentation(payload) {
  if (!payload || typeof payload !== 'object') {
    return null;
  }

  const data = buildBackgroundNotificationData(payload);
  const title =
    normalizeBrandingText(
      payload?.notification?.title ||
        payload?.webpush?.notification?.title ||
        data.title ||
        'Delivery Mat3mk',
    );
  const body =
    normalizeBrandingText(
      payload?.notification?.body ||
        payload?.webpush?.notification?.body ||
        data.body ||
        '',
    );
  const clickAction = resolveTargetPath(data);
  if (!data.click_action && clickAction) {
    data.click_action = clickAction;
  }

  const tag = payload?.messageId || data.notification_id || undefined;
  return {
    title,
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
      vibrate: [200, 100, 200],
    },
  };
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

function notificationDedupKey(presentation) {
  const data = presentation.options?.data || {};
  const tag = presentation.options?.tag;
  if (tag) {
    return `tag:${tag}`;
  }
  const rawSignature = JSON.stringify({
    title: presentation.title,
    body: presentation.options?.body || '',
    click_action: data.click_action || '',
    notification_id: data.notification_id || '',
    message_id: data.message_id || '',
  });
  return `content:${rawSignature}`;
}

function shouldSkipRecentlyShownNotification(key) {
  if (!key) {
    return false;
  }
  pruneRecentlyShownNotifications();
  const now = Date.now();
  const previous = recentlyShownNotificationKeys.get(key);
  recentlyShownNotificationKeys.set(key, now);
  return previous != null && now - previous < RECENT_NOTIFICATION_WINDOW_MS;
}

function pruneRecentlyShownNotifications() {
  if (recentlyShownNotificationKeys.size === 0) {
    return;
  }
  const now = Date.now();
  for (const [key, seenAt] of recentlyShownNotificationKeys.entries()) {
    if (now - seenAt > RECENT_NOTIFICATION_WINDOW_MS * 2) {
      recentlyShownNotificationKeys.delete(key);
    }
  }
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
  const explicitCandidates = [
    data.click_action,
    data.link,
    data.url,
    data.path,
  ];
  for (const candidate of explicitCandidates) {
    const normalized = normalizeTargetPath(candidate);
    if (normalized) {
      return normalized;
    }
  }

  const rawScreen =
    typeof data.screen === 'string' ? data.screen.trim().toLowerCase() : '';
  if (rawScreen) {
    return `/?screen=${encodeURIComponent(rawScreen)}`;
  }

  return '/';
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

function postNotificationClickToClient(client, data) {
  try {
    client.postMessage(
      JSON.stringify({
        type: 'fcm_notification_click',
        data,
      }),
    );
  } catch (_) {
    // Ignore postMessage failures and continue navigation fallback.
  }
}

ensureMessagingInitialized();
