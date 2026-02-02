self.addEventListener("install", (evt) => {
  console.log("Whisper service worker installed:", evt);
});

self.addEventListener("activate", (evt) => {
  console.log("Whisper service worker activated:", evt);
});

self.addEventListener("push", (evt) => {
  console.log("Whisper push notification received:", evt);
  let data = {};
  try {
    data = evt.data ? evt.data.json() : {};
    console.log("Whisper push data:", JSON.stringify(data));
  } catch (e) {
    console.error("Failed to parse push data:", e, evt.data?.text());
    return;
  }

  // Handle dismiss request - close notification by tag instead of showing
  if (data.dismiss && data.tag) {
    evt.waitUntil(
      self.registration
        .getNotifications({ tag: data.tag })
        .then((notifications) => {
          console.log(
            `Dismissing ${notifications.length} notification(s) with tag: ${data.tag}`,
          );
          notifications.forEach((n) => n.close());
        }),
    );
    return;
  }

  data.icon = data.icon || "/whisper_favicon/whisper-detail.png";

  let badgeCount = parseInt(data.data?.count || 0);
  if (navigator.setAppBadge) {
    if (badgeCount > 0) {
      navigator.setAppBadge(badgeCount);
    } else {
      navigator.clearAppBadge();
    }
  }

  if (data.title || data.body) {
    evt.waitUntil(self.registration.showNotification(data.title, data));
  }
});

self.addEventListener("notificationclick", (evt) => {
  console.log("Whisper notification clicked:", evt);
  evt.notification.close();

  const targetUrl = evt.notification.data?.url || "/";

  evt.waitUntil(
    clients.matchAll({ type: "window" }).then((clientList) => {
      // Try to focus an existing Whisper window
      for (const client of clientList) {
        if ("focus" in client) {
          return client.focus();
        }
      }
      // Otherwise open a new window
      if (clients.openWindow) {
        return clients.openWindow(targetUrl);
      }
    }),
  );
});
