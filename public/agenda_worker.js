// Agenda service worker. Handles push notifications + click-through to the
// PWA. Mirrors whisper_worker.js / push_worker.js, scoped to "/agenda".
//
// Push payloads server-side should look like:
//   { title: "Standup in 5", body: "@ Office", tag: "agenda-item-123",
//     icon: "/favicon/android-chrome-192x192.png",
//     data: { url: "/agenda", count: 3 } }
// `count` (optional) drives the app badge.

self.addEventListener("install", (evt) => {
  console.log("Agenda service worker installed:", evt);
  // Skip waiting so updates take effect immediately on next page load.
  self.skipWaiting();
});

self.addEventListener("activate", (evt) => {
  console.log("Agenda service worker activated:", evt);
  evt.waitUntil(self.clients.claim());
});

self.addEventListener("push", (evt) => {
  let data = {};
  try {
    data = evt.data ? evt.data.json() : {};
  } catch (e) {
    console.error("Failed to parse agenda push data:", e, evt.data?.text());
    return;
  }

  // Close-by-tag short-circuit: server sends { dismiss: true, tag } to
  // dismiss an existing notification (e.g. when an item is completed
  // elsewhere) without showing a new one.
  if (data.dismiss && data.tag) {
    evt.waitUntil(
      self.registration
        .getNotifications({ tag: data.tag })
        .then((notifications) => {
          notifications.forEach((n) => n.close());
        }),
    );
    return;
  }

  data.icon = data.icon || "/favicon/android-chrome-192x192.png";

  // App badge count (iOS Safari 16.4+, Chrome). Server can include
  // data.data.count for the current outstanding-items count.
  const badgeCount = parseInt(data.data?.count || 0, 10);
  if (navigator.setAppBadge) {
    if (badgeCount > 0) {
      navigator.setAppBadge(badgeCount);
    } else {
      navigator.clearAppBadge();
    }
  }

  if (data.title || data.body) {
    evt.waitUntil(self.registration.showNotification(data.title || "Agenda", data));
  }
});

self.addEventListener("notificationclick", (evt) => {
  evt.notification.close();
  const targetUrl = evt.notification.data?.url || "/agenda";

  evt.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((clientList) => {
      // Prefer focusing an existing Agenda window — and navigate it to the
      // notification's target URL if it isn't already there.
      for (const client of clientList) {
        const url = new URL(client.url);
        if (url.pathname.startsWith("/agenda") && "focus" in client) {
          if (client.url !== targetUrl && "navigate" in client) {
            return client.navigate(targetUrl).then(() => client.focus());
          }
          return client.focus();
        }
      }
      if (clients.openWindow) {
        return clients.openWindow(targetUrl);
      }
    }),
  );
});
