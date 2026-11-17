/* Mizpah Technology PWA service worker.
 * Deliberately does not cache product, stock, order, account, admin,
 * payment, Supabase, or other live application data.
 */
"use strict";

const CACHE_NAME = "mizpah-pwa-shell-v1";
const OFFLINE_URL = "/offline.html";

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.add(new Request(OFFLINE_URL, { cache: "reload" })))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(
        keys
          .filter((key) => key.startsWith("mizpah-pwa-shell-") && key !== CACHE_NAME)
          .map((key) => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET" || request.mode !== "navigate") return;

  const url = new URL(request.url);
  if (url.origin !== self.location.origin) return;

  // Always request live pages from the server. If offline, show a clear
  // fallback instead of stale product prices, stock, orders, or account data.
  event.respondWith(
    fetch(request).catch(async () => {
      const cache = await caches.open(CACHE_NAME);
      return (await cache.match(OFFLINE_URL)) || new Response(
        "You are offline. Reconnect to the internet and try again.",
        { status: 503, headers: { "Content-Type": "text/plain; charset=utf-8" } }
      );
    })
  );
});
