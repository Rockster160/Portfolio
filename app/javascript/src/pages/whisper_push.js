// Whisper Push Notification Module
// Mirrors the Jarvis push subscription logic for consistency

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

async function getWhisperRegistration() {
  if (!("serviceWorker" in navigator)) return null;
  return navigator.serviceWorker.getRegistration("/whisper");
}

async function getWhisperSubscription() {
  const registration = await getWhisperRegistration();
  if (!registration) return null;
  return registration.pushManager.getSubscription();
}

export async function checkWhisperNotificationStatus() {
  if (!("serviceWorker" in navigator) || !("Notification" in window)) {
    return "unsupported";
  }

  if (Notification.permission === "denied") {
    return "denied";
  }

  try {
    const subscription = await getWhisperSubscription();
    return subscription ? "subscribed" : "unsubscribed";
  } catch (e) {
    return "unsubscribed";
  }
}

export async function registerWhisperNotifications() {
  if (!("serviceWorker" in navigator) || !("PushManager" in window)) {
    return { success: false, error: "unsupported" };
  }

  try {
    // Register the Whisper service worker
    await navigator.serviceWorker.register("/whisper_worker.js", {
      scope: "/whisper",
    });

    // Request notification permission
    const permission = await Notification.requestPermission();
    if (permission !== "granted") {
      return { success: false, error: "permission_denied" };
    }

    // Wait for the service worker to be ready and get the active registration
    const registration = await navigator.serviceWorker.ready;

    // Subscribe to push notifications using the ready registration
    const subscription = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY),
    });

    // Send subscription to server - use JSON.stringify(subscription) like Jarvis does
    // This ensures proper base64url encoding of keys
    const subscriptionData = subscription.toJSON();
    subscriptionData.channel = "whisper";

    const response = await fetch("/push_notification_subscribe", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        JarvisPushVersion: "2",
      },
      body: JSON.stringify(subscriptionData),
      credentials: "same-origin",
    });

    if (response.ok) {
      return { success: true };
    } else {
      // Server failed - roll back browser subscription to keep states in sync
      await subscription.unsubscribe();
      return { success: false, error: "server_error" };
    }
  } catch (error) {
    // Clean up browser subscription on any error
    const sub = await getWhisperSubscription();
    if (sub) await sub.unsubscribe();
    return { success: false, error: error.message };
  }
}

export async function unregisterWhisperNotifications() {
  try {
    const subscription = await getWhisperSubscription();
    if (subscription) {
      // Notify server to clear the subscription
      const subscriptionData = subscription.toJSON();
      subscriptionData.channel = "whisper";

      await fetch("/push_notification_unsubscribe", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify(subscriptionData),
        credentials: "same-origin",
      }).catch(() => {}); // Don't fail if server request fails

      await subscription.unsubscribe();
    }
    return { success: true };
  } catch (error) {
    return { success: false, error: error.message };
  }
}
