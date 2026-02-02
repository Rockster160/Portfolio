// import { registerNotifications } from "./push_subscribe.js";
// document.on "click", ".subscribe", registerNotifications

export default function registerNotifications() {
  if ("serviceWorker" in navigator && "PushManager" in window) {
    // Register the service worker
    navigator.serviceWorker
      .register("/push_worker.js")
      .then((registration) => {
        console.log(
          "[Push API] Service Worker registered with scope:",
          registration.scope,
        );
        // Request permission for notifications
        return Notification.requestPermission();
      })
      .then((permission) => {
        if (permission !== "granted") {
          throw new Error("[Push API] Permission not granted for Notification");
        }

        // Get the subscription
        return navigator.serviceWorker.ready;
      })
      .then((registration) => {
        const subscribeOptions = {
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(
            "BO7gUf6gNtfyxWRaYVjmL38uqi8TGKZZ9Fw7tEKzxCosTAtTERuv2ohHEiNB21CBs7ue5eOWMe2p4jtZjZTTAFU=",
          ),
        };
        // Subscribe to push notifications
        return registration.pushManager.subscribe(subscribeOptions);
      })
      .then((subscription) => {
        console.log(
          "[Pus h API] Push Notification Subscription:",
          subscription,
        );
        // Send the subscription details to the server using fetch API
        return fetch("/push_notification_subscribe", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            JarvisPushVersion: "2",
            // "UserJWT": window.jwt,
          },
          body: JSON.stringify(subscription),
          credentials: "same-origin",
        });
      })
      .then((response) => {
        if (!response.ok) {
          response
            .json()
            .then((data) => {
              console.log("[Push API] Server error: ", data);
              throw new Error(
                "[Push API] Failed to send subscription object to server",
              );
            })
            .catch(() => {
              response.text().then((msg) => {
                console.log("[Push API] Server message: ", msg);
              });
            });
          throw new Error(
            "[Push API] Failed to send subscription object to server",
          );
        }
        console.log(
          "[Push API] Subscription object sent to server successfully.",
        );
      })
      .catch((error) => {
        console.error(
          "[Push API] Error during service worker registration:",
          error,
        );
      });
  } else {
    console.warn(
      "[Push API] Service Worker and Push Messaging is not supported by your browser.",
    );
  }
}

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding)
    .replace(/\-/g, "+")
    .replace(/_/g, "/");
  const rawData = window.atob(base64);
  const outputArray = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i);
  }

  return outputArray;
}
