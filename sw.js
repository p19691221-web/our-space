// 讓手機可以把網頁「加到主畫面」。不做離線快取，所有請求照常連網。
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", e => e.waitUntil(self.clients.claim()));
self.addEventListener("fetch", () => {});
