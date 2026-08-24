"use strict";

const CACHE = "keydrop-offline-spike-v5";
const ASSETS = [
  "./",
  "./index.html",
  "./decrypt.bundle.js",
  "./autoselect.js",
  "./manifest.webmanifest",
  "./icon.svg",
  "./smoke-not-a-secret.toml.enc",
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(ASSETS)));
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
  );
  self.clients.claim();
});

self.addEventListener("fetch", (event) => {
  if (event.request.method !== "GET") return;
  event.respondWith(caches.match(event.request).then((response) => response || Response.error()));
});
