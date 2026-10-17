// Service worker: cache the shell, keep recently viewed pages for offline reading (DESIGN.md §7a).
// Writes stay online-only; the API is never cached here.
const SHELL = "shell-v1";
const PAGES = "pages-v1";
const SHELL_URLS = ["/app.css", "/manifest.webmanifest"];
const MAX_PAGES = 40;

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(SHELL).then((c) => c.addAll(SHELL_URLS)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== SHELL && k !== PAGES).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  if (req.method !== "GET") return;
  const url = new URL(req.url);
  if (url.origin !== location.origin || url.pathname.startsWith("/api/")) return;
  if (SHELL_URLS.includes(url.pathname)) {
    event.respondWith(caches.match(req).then((hit) => hit || fetch(req)));
    return;
  }
  if (req.mode !== "navigate") return;
  event.respondWith(networkFirst(req));
});

async function networkFirst(req) {
  const cache = await caches.open(PAGES);
  try {
    const res = await fetch(req);
    if (res.ok) {
      await cache.put(req, res.clone());
      trim(cache);
    }
    return res;
  } catch {
    const hit = await cache.match(req);
    if (hit) return hit;
    return new Response("<!doctype html><title>Offline</title><p>Offline, and this page is not cached.</p>", {
      status: 503, headers: { "content-type": "text/html; charset=utf-8" },
    });
  }
}

async function trim(cache) {
  const keys = await cache.keys();
  for (const key of keys.slice(0, Math.max(0, keys.length - MAX_PAGES))) await cache.delete(key);
}
