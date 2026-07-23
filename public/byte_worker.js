// Byte service worker — mirror of whisper_worker's push handler.
// Purpose today: receive server-sent push notifications when the PWA
// isn't focused. Left intentionally simple; add caching / offline
// support here when needed.

self.addEventListener("install", (evt) => {
  console.log("Byte service worker installed:", evt);
  self.skipWaiting();
});

self.addEventListener("activate", (evt) => {
  console.log("Byte service worker activated:", evt);
  evt.waitUntil(self.clients.claim());
});

self.addEventListener("push", (evt) => {
  let data = {};
  try {
    data = evt.data ? evt.data.json() : {};
  } catch (e) {
    console.error("Failed to parse push data:", e, evt.data?.text());
    return;
  }

  if (data.dismiss && data.tag) {
    evt.waitUntil(
      self.registration.getNotifications({ tag: data.tag }).then((notes) => {
        notes.forEach((n) => n.close());
      }),
    );
    return;
  }

  data.icon = data.icon || "/byte_favicon/byte-detail.png";
  data.badge = data.badge || "/byte_favicon/byte-detail.png";

  const badgeCount = parseInt(data.data?.count || 0);
  if (navigator.setAppBadge) {
    if (badgeCount > 0) navigator.setAppBadge(badgeCount);
    else navigator.clearAppBadge();
  }

  if (data.title || data.body) {
    evt.waitUntil(self.registration.showNotification(data.title, data));
  }
});

self.addEventListener("notificationclick", (evt) => {
  evt.notification.close();
  const targetUrl = evt.notification.data?.url || "/";

  evt.waitUntil(
    clients.matchAll({ type: "window" }).then((clientList) => {
      for (const client of clientList) {
        if (client.url.includes("byte") && "focus" in client) {
          return client.focus();
        }
      }
      if (clients.openWindow) return clients.openWindow(targetUrl);
    }),
  );
});
