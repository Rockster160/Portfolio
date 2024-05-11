self.addEventListener("install", evt => {
  console.log("Service worker installed:", evt);
});

self.addEventListener("activate", evt => {
  console.log("Service worker activated:", evt);
});

self.addEventListener("push", evt => {
  console.log("Push notification received:", evt);
  const data = evt.data ? evt.data.json() : {};
  data.icon = data.icon || "/favicon/favicon.ico";

  let badgeCount = parseInt(data.data.count)
  if (navigator.setAppBadge) {
    if (badgeCount > 0) {
      navigator.setAppBadge(badgeCount);
    } else {
      navigator.clearAppBadge();
    }
  }

  // https://developer.mozilla.org/en-US/docs/Web/API/notification
  if (data.title || data.body) {
    evt.waitUntil(self.registration.showNotification(data.title, data))
  }
});

self.addEventListener("notificationclick", evt => {
  console.log("Push notification clicked:", evt);
  evt.notification.close(); // Close the notification
  // Perform an action or navigate to a page
  evt.waitUntil(
    clients.matchAll({ type: "window" }).then(clientList => {
      for (const client of clientList) {
        if (client.url === "/" && "focus" in client) {
          return client.focus();
        }
      }
      if (clients.openWindow) {
        return clients.openWindow(evt.notification.data.url || '/');
      }
    })
  );
});
