function checkPushAPI() {
  if (!("serviceWorker" in navigator)) {
    console.log("[Push API] No Service Worker support!")
    return false
  }

  if (!("PushManager" in window)) {
    console.log("[Push API] No Push API support!")
    return false
  }

  return true
}

async function registerServiceWorker() {
  var sub_auth = document.querySelector("[data-sub-auth]").getAttribute("data-sub-auth")
  if (sub_auth.length == 0) { return false }
  var swRegistration = await navigator.serviceWorker.register("/push_worker.js" + "?auth=" + sub_auth)
  return swRegistration
}

async function requestNotificationPermission() {
  let permission = await window.Notification.requestPermission()
  // value of permission can be 'granted', 'default', 'denied'
  if (permission == "granted") {
    // User accepted notifications
    return true
  } else if (permission == "denied") {
    // User denied notifications
    return false
  } else if (permission == "default") {
    // User dismissed without responding
    return
  }
}

export async function registerNotifications() {
  if (checkPushAPI()) {
    console.log("[Push API] Support!")

    var permissionGranted = await requestNotificationPermission()
    if (permissionGranted) {
      // console.log("[Push API] Permission Granted!")
      var registration = await registerServiceWorker()
      // if (registration) { console.log("[Push API] Registered!") }
      console.log("[Push API] registration", registration)
      if (!registration) { return console.log("[Push API] Failed to Register") }
    } else {
      console.log("[Push API] Permission rejected")
    }
  } else {
    console.log("[Push API] Unsupported Browser")
  }
}

// Click button to register for notifications
// registerNotifications()
