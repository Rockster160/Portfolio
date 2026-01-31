// Whisper Push Notification Module

const VAPID_PUBLIC_KEY =
  "BO7gUf6gNtfyxWRaYVjmL38uqi8TGKZZ9Fw7tEKzxCosTAtTERuv2ohHEiNB21CBs7ue5eOWMe2p4jtZjZTTAFU=";

function urlBase64ToUint8Array(base64String) {
  const padding = "=".repeat((4 - (base64String.length % 4)) % 4);
  const base64 = (base64String + padding).replace(/-/g, "+").replace(/_/g, "/");
  const rawData = window.atob(base64);
  const outputArray = new Uint8Array(rawData.length);
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i);
  }
  return outputArray;
}

async function getWhisperSubscription() {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    return null;
  }

  // getRegistration takes a scope URL, not the script URL
  const registration = await navigator.serviceWorker.getRegistration("/whisper");
  if (!registration) return null;

  return registration.pushManager.getSubscription();
}

export async function checkWhisperNotificationStatus() {
  if (!("Notification" in window)) {
    return "unsupported";
  }

  if (Notification.permission === "denied") {
    return "denied";
  }

  const subscription = await getWhisperSubscription();
  return subscription ? "subscribed" : "unsubscribed";
}

export async function registerWhisperNotifications() {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    console.warn("Push notifications not supported");
    return { success: false, error: "unsupported" };
  }

  try {
    // Register the Whisper service worker
    const registration = await navigator.serviceWorker.register("/whisper_worker.js", {
      scope: "/whisper",
    });
    console.log("Whisper service worker registered:", registration);

    // Wait for the service worker to be ready
    await navigator.serviceWorker.ready;

    // Request notification permission
    const permission = await Notification.requestPermission();
    if (permission !== "granted") {
      return { success: false, error: "permission_denied" };
    }

    // Subscribe to push notifications
    const subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
    });

    // Send subscription to server with whisper channel
    const response = await fetch("/push_notification_subscribe", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        JarvisPushVersion: "2",
      },
      body: JSON.stringify({
        endpoint: subscription.endpoint,
        keys: {
          p256dh: btoa(String.fromCharCode(...new Uint8Array(subscription.getKey("p256dh")))),
          auth: btoa(String.fromCharCode(...new Uint8Array(subscription.getKey("auth")))),
        },
        channel: "whisper",
      }),
    });

    if (response.ok) {
      console.log("Whisper push subscription saved");
      return { success: true };
    } else {
      // Server failed - roll back browser subscription to keep states in sync
      console.error("Failed to save subscription:", response.status);
      await subscription.unsubscribe();
      return { success: false, error: "server_error" };
    }
  } catch (error) {
    console.error("Error registering whisper notifications:", error);
    // Try to clean up browser subscription on any error
    const sub = await getWhisperSubscription();
    if (sub) await sub.unsubscribe();
    return { success: false, error: error.message };
  }
}

export async function unregisterWhisperNotifications() {
  try {
    const subscription = await getWhisperSubscription();
    if (subscription) {
      await subscription.unsubscribe();
      console.log("Whisper push subscription removed");
    }
    return { success: true };
  } catch (error) {
    console.error("Error unregistering whisper notifications:", error);
    return { success: false, error: error.message };
  }
}
