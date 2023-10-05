// console.log("Loaded Service Worker!")
var urlB64ToUint8Array = function(base64String) {
  var padding = '='.repeat((4 - (base64String.length % 4)) % 4)
  var base64 = (base64String + padding).replace(/\-/g, '+').replace(/_/g, '/')
  var rawData = atob(base64)
  var outputArray = new Uint8Array(rawData.length)
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i)
  }
  return outputArray
}

var safeParse = function(json) {
  try {
    return JSON.parse(json)
  } catch {
    return json
  }
}

var saveSubscription = async function(subscription) {
  var base_server_url = self.location.origin
  var subscription_path = "/push_notification_subscribe"

  var notification_data = JSON.parse(JSON.stringify(subscription)) // Dup the subscription
  Object.assign(notification_data, { sub_auth: (new URLSearchParams(self.location.search)).get("auth") })
  // console.log("Auth: ", notification_data.sub_auth)
  // console.log(JSON.stringify(notification_data))

  var response = await fetch(base_server_url + subscription_path, {
    method: "post",
    headers: {
      "Content-Type": "application/json",
    },
    body: JSON.stringify(notification_data),
  })

  return response.json()
}

async function showLocalNotification(swRegistration, data) {
  // console.log("data", data)
  var title = data.title || "Ardesian"
  data.icon = data.icon || "/favicon/favicon.ico"
  // https://developer.mozilla.org/en-US/docs/Web/API/notification
  swRegistration.showNotification(title, data)
}

self.addEventListener("activate", async function() {
  try {
    var applicationServerKey = urlB64ToUint8Array("BO7gUf6gNtfyxWRaYVjmL38uqi8TGKZZ9Fw7tEKzxCosTAtTERuv2ohHEiNB21CBs7ue5eOWMe2p4jtZjZTTAFU=")
    var options = { applicationServerKey, userVisibleOnly: true }
    var subscription = await self.registration.pushManager.subscribe(options)
    // console.log(JSON.stringify(subscription))
    var response = await saveSubscription(subscription)
    // console.log("[ServiceWorker] Subscribe: ", response)
  } catch (err) {
    console.log("[ServiceWorker] Error: ", err)
  }
})

self.addEventListener("push", function(evt) {
  if (evt.data) {
    // console.log("[ServiceWorker] Push evt!", evt.data)
    var data = safeParse(evt.data.text())
    evt.waitUntil(showLocalNotification(self.registration, data))
  } else {
    console.log("[ServiceWorker] Push event but no data")
  }
})

self.addEventListener("notificationclick", function(evt) {
  // console.log("[Service Worker] Notification click Received.")
  var data = evt.notification.data || {}

  evt.notification.close()

  evt.waitUntil(clients.matchAll({
    type: "window"
  }).then(function(clientList) {
    for (var i = 0; i < clientList.length; i++) {
      var client = clientList[i]
      if (client.url == "/" && "focus" in client) { client.focus() }
    }
    if (clients.openWindow) { return clients.openWindow(data.url || "/") }
  }))
})
