// Runs the real inline controller with a deterministic clock; no network/Flutter.
// Usage: node --test scripts/test_web_splash.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '../web/index.html'), 'utf8');
const controller = html.match(/<script id="app-splash-controller">([\s\S]*?)<\/script>/)[1];

class Target {
  listeners = new Map();
  addEventListener(name, callback) {
    if (!this.listeners.has(name)) this.listeners.set(name, new Set());
    this.listeners.get(name).add(callback);
  }
  removeEventListener(name, callback) { this.listeners.get(name)?.delete(callback); }
  dispatchEvent(event) {
    [...(this.listeners.get(event.type) || [])].forEach(callback => callback(event));
  }
  emit(type) { this.dispatchEvent({type}); }
  listenerCount() { return [...this.listeners.values()].reduce((n, set) => n + set.size, 0); }
}

function harness({rejectPlay = false, initialHidden = false, autoFrame = true,
  posterLoaded = true, reduceMotion = false} = {}) {
  let now = 0;
  let sequence = 0;
  const jobs = new Map();
  const window = new Target();
  const document = new Target();
  const video = new Target();
  const overlay = new Target();
  const retry = new Target();
  const poster = new Target();
  poster.complete = posterLoaded;
  poster.naturalWidth = posterLoaded ? 1472 : 0;
  const classes = new Set();
  const properties = {};
  let removedEvents = 0;
  let reloads = 0;
  const source = {removed: false, removeAttribute() { this.removed = true; }};
  document.hidden = initialHidden;
  retry.hidden = true;
  overlay.removed = false;
  overlay.remove = () => { overlay.removed = true; };
  overlay.classList = {add: name => classes.add(name), remove: name => classes.delete(name)};
  overlay.style = {setProperty: (name, value) => { properties[name] = value; }};
  Object.assign(video, {
    duration: 2.5, currentTime: 0, paused: true, playCalls: 0, pauseCalls: 0,
    loadCalls: 0, frameCallback: null,
    play() {
      this.playCalls++;
      this.paused = false;
      if (!rejectPlay && autoFrame) window.setTimeout(() => {
        this.emit('playing');
        this.presentFrame();
      }, 0);
      return {catch: handler => { if (rejectPlay) handler(new Error('autoplay')); }};
    },
    pause() { this.paused = true; this.pauseCalls++; },
    load() { this.loadCalls++; },
    removeAttribute() {},
    querySelectorAll() { return [source]; },
    requestVideoFrameCallback(callback) { this.frameCallback = callback; return 1; },
    cancelVideoFrameCallback() { this.frameCallback = null; },
    presentFrame() { const cb = this.frameCallback; this.frameCallback = null; cb?.(); }
  });
  document.getElementById = id => ({
    'app-splash': overlay, 'app-splash-video': video, 'app-splash-retry': retry,
    'app-splash-poster': poster
  }[id]);
  window.setTimeout = (callback, delay = 0) => {
    const id = ++sequence;
    jobs.set(id, {callback, due: now + delay});
    return id;
  };
  window.clearTimeout = id => jobs.delete(id);
  window.requestAnimationFrame = callback => window.setTimeout(callback, 16);
  window.cancelAnimationFrame = window.clearTimeout;
  window.location = {reload() { reloads++; }};
  window.matchMedia = () => ({matches: reduceMotion});
  window.addEventListener('delivery-mat3mk-web-splash-removed', () => removedEvents++);
  vm.runInNewContext(controller, {window, document, performance: {now: () => now}, Event: class {
    constructor(type) { this.type = type; }
  }});

  function advance(target) {
    while (true) {
      const next = [...jobs.entries()].filter(([, job]) => job.due <= target)
        .sort((a, b) => a[1].due - b[1].due || a[0] - b[0])[0];
      if (!next) break;
      const [id, job] = next;
      now = Math.max(now, job.due);
      jobs.delete(id);
      job.callback();
    }
    now = target;
  }
  return {
    window, document, video, overlay, retry, poster, classes, properties, source, jobs,
    advance, skipTo: target => { now = target; },
    ready: () => window.emit('delivery-mat3mk-web-splash-ready'),
    get metrics() { return window.__appSplashMetrics; },
    get removedEvents() { return removedEvents; },
    get reloads() { return reloads; },
  };
}

test('ready app fades inside 2500ms, then disposes video and sends one removal event', () => {
  const h = harness({autoFrame: false});
  h.advance(16);
  h.advance(100);
  h.video.emit('playing');
  assert.equal(h.classes.has('app-splash--video-ready'), false);
  h.video.presentFrame();
  assert.equal(h.classes.has('app-splash--video-ready'), true);
  assert.equal(h.metrics.startedAt, null, 'await the frame containing the video');
  h.advance(116);
  h.ready();
  h.advance(2435);
  assert.equal(h.classes.has('app-splash--hidden'), false);
  h.advance(2436);
  assert.equal(h.classes.has('app-splash--hidden'), true);
  assert.equal(h.overlay.removed, false);
  h.advance(2615);
  assert.equal(h.overlay.removed, false);
  h.advance(2616);
  assert.equal(h.metrics.removedAt - h.metrics.startedAt, 2500);
  assert.equal(h.overlay.removed, true);
  assert.equal(h.removedEvents, 1);
  assert.equal(h.video.playCalls, 1);
  assert.equal(h.video.pauseCalls, 1);
  assert.equal(h.source.removed, true);
  assert.equal(h.video.listenerCount(), 0);
  assert.equal(h.poster.listenerCount(), 0);
  assert.equal(h.document.listenerCount(), 0);
  assert.equal(h.jobs.size, 0);
  h.ready();
  h.window.emit('pageshow');
  h.advance(20000);
  assert.equal(h.removedEvents, 1);
  assert.equal(h.video.playCalls, 1);
});

test('short/ended video cannot shorten the visual deadline', () => {
  const h = harness();
  h.advance(16);
  h.ready();
  h.advance(400);
  h.video.emit('ended');
  h.advance(2531);
  assert.equal(h.overlay.removed, false);
  h.advance(2532);
  assert.equal(h.overlay.removed, true);
});

for (const failure of ['autoplay-rejected', 'media-error']) {
  test(`${failure} preserves poster and removes at 2500ms when app is ready`, () => {
    const h = harness({rejectPlay: failure === 'autoplay-rejected'});
    h.advance(16);
    if (failure === 'media-error') h.video.emit('error');
    h.ready();
    h.advance(2531);
    assert.equal(h.overlay.removed, false);
    assert.equal(h.metrics.fallbackReason, failure);
    assert.equal(h.classes.has('app-splash--video-ready'), false);
    h.advance(2532);
    assert.equal(h.metrics.removedAt - h.metrics.startedAt, 2500);
    assert.equal(h.video.playCalls, 1);
  });
}

test('late app keeps a static branded screen and reveals the ready app without an extra timer', () => {
  const h = harness();
  h.advance(2532);
  assert.equal(h.video.paused, true);
  assert.equal(h.metrics.videoStoppedAt - h.metrics.startedAt, 2500);
  assert.equal(h.metrics.heldForApp, true);
  assert.equal(h.overlay.removed, false);
  h.advance(9000);
  assert.equal(h.overlay.removed, false, 'never force-hide onto an unpainted app');
  h.ready();
  assert.equal(h.overlay.removed, true);
  assert.equal(h.metrics.removedAt, 9000);
  assert.equal(h.jobs.size, 0);
  assert.equal(h.video.playCalls, 1);
});

test('app ready just before deadline uses only the remaining fade time', () => {
  const h = harness();
  h.advance(2516);
  h.ready();
  assert.equal(h.properties['--app-splash-fade-ms'], '16ms');
  h.advance(2532);
  assert.equal(h.metrics.removedAt - h.metrics.startedAt, 2500);
});

test('loader failure exposes an accessible reload control without revealing a blank app', () => {
  const h = harness();
  h.advance(15015);
  assert.equal(h.retry.hidden, true);
  h.advance(15016);
  assert.equal(h.retry.hidden, false);
  assert.equal(h.overlay.removed, false);
  h.retry.emit('click');
  assert.equal(h.reloads, 1);
});

test('background/resume with throttled timers does not replay or restart the deadline', () => {
  const h = harness();
  h.advance(32);
  h.ready();
  h.document.hidden = true;
  h.document.emit('visibilitychange');
  assert.equal(h.video.paused, true);
  h.skipTo(5000);
  h.document.hidden = false;
  h.document.emit('visibilitychange');
  assert.equal(h.overlay.removed, true);
  assert.equal(h.video.playCalls, 1);
  assert.equal(h.metrics.startedAt, 32);
  assert.equal(h.jobs.size, 0);
});

test('initially backgrounded document starts the clock only on first visible presentation', () => {
  const h = harness({initialHidden: true});
  h.advance(10000);
  assert.equal(h.metrics.startedAt, null);
  assert.equal(h.video.playCalls, 0);
  h.document.hidden = false;
  h.document.emit('visibilitychange');
  h.advance(10032);
  assert.equal(h.metrics.startedAt, 10032);
  h.ready();
  h.advance(12532);
  assert.equal(h.metrics.removedAt, 12532);
});

test('slow media gets the full visual budget only after the first decoded frame', () => {
  const h = harness({autoFrame: false});
  h.advance(1200);
  h.ready();
  assert.equal(h.metrics.startedAt, null);
  assert.equal(h.overlay.removed, false);
  h.video.emit('playing');
  h.video.presentFrame();
  h.advance(1216);
  assert.equal(h.metrics.startedAt, 1216);
  h.advance(3715);
  assert.equal(h.overlay.removed, false);
  h.advance(3716);
  assert.equal(h.metrics.removedAt - h.metrics.startedAt, 2500);
});

test('hung video and poster use a bounded static fallback and reject late frames', () => {
  const h = harness({autoFrame: false, posterLoaded: false});
  h.ready();
  h.advance(1515);
  assert.equal(h.metrics.startedAt, null);
  h.advance(1532);
  assert.equal(h.metrics.fallbackReason, 'media-readiness-timeout');
  assert.equal(h.metrics.startedAt, 1532);
  h.video.emit('playing');
  h.video.presentFrame();
  assert.equal(h.classes.has('app-splash--video-ready'), false);
  h.advance(4032);
  assert.equal(h.overlay.removed, true);
  assert.equal(h.video.playCalls, 1);
});

test('autoplay failure waits for the selected poster to load before timing', () => {
  const h = harness({rejectPlay: true, posterLoaded: false});
  h.ready();
  h.advance(500);
  assert.equal(h.metrics.startedAt, null);
  h.poster.emit('load');
  h.advance(516);
  assert.equal(h.metrics.startedAt, 516);
  h.advance(3016);
  assert.equal(h.metrics.removedAt, 3016);
});

test('reduced motion keeps the poster with no video playback or fade', () => {
  const h = harness({reduceMotion: true});
  h.ready();
  h.advance(32);
  assert.equal(h.video.playCalls, 0);
  assert.equal(h.metrics.fallbackReason, 'reduced-motion');
  assert.equal(h.metrics.fadeMs, 0);
  h.advance(2531);
  assert.equal(h.classes.has('app-splash--hidden'), false);
  h.advance(2532);
  assert.equal(h.overlay.removed, true);
});

test('markup preserves full-frame contain, original branding, autoplay safety and FCM bootstrap', () => {
  assert.match(html, /object-fit: contain/);
  assert.doesNotMatch(html, /object-fit: cover/);
  assert.match(html, /rgba\(242, 140, 40, 0\.58\)/);
  assert.match(html, /<span>delivery-mat3mk<\/span>/);
  assert.match(html, /prefers-reduced-motion/);
  assert.match(html, /linear-gradient\(135deg, #343235/);
  assert.match(html, /env\(safe-area-inset-top\)/);
  assert.doesNotMatch(html, /requestFullscreen/);
  assert.match(html, /aria-label="إعادة تحميل التطبيق"/);
  assert.match(html, /firebase-messaging-sw\.js/);
  assert.match(html, /window\.__fcmServiceWorkerReady = registrationPromise/);
  assert.match(html, /<script src="flutter_bootstrap\.js" async>/);
});
