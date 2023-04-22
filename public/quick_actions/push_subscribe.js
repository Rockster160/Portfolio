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

function registerServiceWorker() {
  var sub_auth = document.querySelector("[data-sub-auth]").getAttribute("data-sub-auth")
  if (sub_auth.length == 0) { return false }
  var swRegistration = navigator.serviceWorker.register("/push_worker.js" + "?auth=" + sub_auth)
  return swRegistration
}

function requestNotificationPermission() {
  var permission = window.Notification.requestPermission()
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

export function registerNotifications() {
  if (checkPushAPI()) {
    // console.log("[Push API] Support!")

    var registration = registerServiceWorker()
    // if (registration) { console.log("[Push API] Registered!") }
    // console.log("[Push API] registration", registration)
    if (!registration) { return console.log("[Push API] Failed to Register") }

    var permissionGranted = requestNotificationPermission()
    // if (permissionGranted) { console.log("[Push API] Permission Granted!") }
  } else {
    console.log("[Push API] Unsupported Browser")
  }
}

// Click button to register for notifications
// registerNotifications()
