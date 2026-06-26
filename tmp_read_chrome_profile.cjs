const { chromium } = require('playwright');
(async () => {
  const context = await chromium.launchPersistentContext('tmp_playwright_chrome_profile', {
    channel: 'chrome',
    headless: true,
    args: ['--no-first-run','--no-default-browser-check'],
  });
  try {
    const page = context.pages()[0] || await context.newPage();
    await page.goto('http://127.0.0.1:7357/', { waitUntil: 'networkidle', timeout: 60000 });
    await page.waitForTimeout(3000);
    const values = await page.evaluate(() => {
      const out = {};
      for (const key of Object.keys(localStorage)) out[key] = localStorage.getItem(key);
      return { href: location.href, keys: Object.keys(localStorage), values: out, body: document.body?.innerText?.slice(0, 500) || '' };
    });
    console.log(JSON.stringify(values, null, 2));
  } finally {
    await context.close();
  }
})();
