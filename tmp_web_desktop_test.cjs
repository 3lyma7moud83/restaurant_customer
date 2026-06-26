const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('playwright');

const origin = process.env.TEST_ORIGIN || 'http://127.0.0.1:7357';
const sessionPath = process.env.SESSION_PATH ||
  path.join(process.cwd(), 'tmp_web_session_current.json');
const userDataDir = process.env.USER_DATA_DIR ||
  path.join(process.cwd(), 'tmp_playwright_chrome_profile');
const pollSeconds = Number(process.env.POLL_SECONDS || '90');
const headless = (process.env.HEADLESS || 'false').toLowerCase() === 'true';
const skipSessionInjection =
  (process.env.SKIP_SESSION_INJECTION || 'false').toLowerCase() === 'true';

function deriveSupabasePersistKeys(sessionString) {
  void sessionString;
  return ['supabase.auth.token'];
}

async function collectNotifications(page) {
  return page.evaluate(async () => {
    const registration = await navigator.serviceWorker.ready;
    const notifications = await registration.getNotifications();
    return notifications.map((notification) => ({
      title: notification.title,
      body: notification.body,
      data: notification.data || {},
      tag: notification.tag || '',
      timestamp: notification.timestamp || 0,
    }));
  });
}

async function collectSnapshot(page) {
  return page.evaluate(async () => {
    const registrations = await navigator.serviceWorker.getRegistrations();
    const readyRegistration = await navigator.serviceWorker.ready;
    const notifications = await readyRegistration.getNotifications();
    return {
      href: window.location.href,
      title: document.title,
      permission: Notification.permission,
      serviceWorkerCount: registrations.length,
      localStorageKeys: Object.keys(localStorage),
      notificationCount: notifications.length,
      bodyText: document.body?.innerText?.slice(0, 800) || '',
    };
  });
}

async function main() {
  const sessionString = fs.readFileSync(sessionPath, 'utf8').trim();
  if (!sessionString) {
    throw new Error(`Empty session file: ${sessionPath}`);
  }
  const persistKeys = deriveSupabasePersistKeys(sessionString);

  const context = await chromium.launchPersistentContext(userDataDir, {
    channel: 'chrome',
    headless,
    args: [
      '--no-first-run',
      '--no-default-browser-check',
    ],
  });

  try {
    await context.grantPermissions(['notifications'], { origin });
    const page = context.pages()[0] || await context.newPage();
    page.on('console', (message) => {
      console.log(`[console:${message.type()}] ${message.text()}`);
    });
    page.on('pageerror', (error) => {
      console.log(`[pageerror] ${error.message}`);
    });

    await page.goto(origin, {
      waitUntil: 'networkidle',
      timeout: 60000,
    });
    if (!skipSessionInjection) {
      await page.evaluate(
        ({ persistedSession, keys }) => {
          for (const key of keys) {
            window.localStorage.setItem(key, persistedSession);
          }
        },
        {
          persistedSession: sessionString,
          keys: persistKeys,
        },
      );
      await page.goto(origin, {
        waitUntil: 'networkidle',
        timeout: 60000,
      });
    }
    await page.waitForTimeout(10000);

    console.log('[baseline]', JSON.stringify(await collectSnapshot(page)));

    const deadline = Date.now() + (pollSeconds * 1000);
    let notifications = [];
    while (Date.now() < deadline) {
      notifications = await collectNotifications(page);
      if (notifications.length > 0) {
        break;
      }
      await page.waitForTimeout(3000);
    }

    console.log('[notifications]', JSON.stringify(notifications));
    console.log('[final]', JSON.stringify(await collectSnapshot(page)));
  } finally {
    await context.close();
  }
}

main().catch((error) => {
  console.error('[fatal]', error);
  process.exitCode = 1;
});
