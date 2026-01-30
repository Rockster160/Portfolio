self.addEventListener("install", evt => {
  console.log("Whisper service worker installed:", evt);
  self.skipWaiting();
});

self.addEventListener("activate", evt => {
  console.log("Whisper service worker activated:", evt);
  evt.waitUntil(clients.claim());
});

self.addEventListener("push", evt => {
  console.log("Whisper push notification received:", evt);
  const data = evt.data ? evt.data.json() : {};
  data.icon = data.icon || "/whisper_favicon/whisper-detail.png";

  if (data.title || data.body) {
    evt.waitUntil(self.registration.showNotification(data.title, data));
  }
});

self.addEventListener("notificationclick", evt => {
  console.log("Whisper notification clicked:", evt);
  evt.notification.close();

  const targetUrl = evt.notification.data?.url || "/whisper";

  evt.waitUntil(
    clients.matchAll({ type: "window" }).then(clientList => {
      // Try to focus an existing Whisper window
      for (const client of clientList) {
        if (client.url.includes("/whisper") && "focus" in client) {
          return client.focus();
        }
      }
      // Otherwise open a new window
      if (clients.openWindow) {
        return clients.openWindow(targetUrl);
      }
    })
  );
});
