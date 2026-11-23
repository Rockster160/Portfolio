// The Buddy app's pages. Inside the app, `window.BuddyNative` is set before the
// page loads and `buddy` is a message handler whose replies come back as
// promises; that's how a page reaches what lives only on the phone (the send
// queue, permissions, what's being shared). Elsewhere the same pages say to
// open them in the app.
BuddyApp = {
  native: function() {
    return !!(window.BuddyNative && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.buddy)
  },
  call: function(name, args) {
    return window.webkit.messageHandlers.buddy.postMessage({ name: name, args: args || {} })
  },
  // The site's modal holding a panel dialog, answering true or false;
  // closing it any other way is a no.
  confirm: function(message) {
    return new Promise(function(resolve) {
      const modal = $(
        "<div class='modal modal-wrapper hidden' tabindex='-1'>" +
          "<div class='modal-content panel-app panel-dialog'>" +
            "<h3 class='panel-dialog-title'>Are you sure?</h3>" +
            "<p></p>" +
            "<div class='panel-buttons'>" +
              "<button type='button' class='panel-btn' data-answer='no'>Cancel</button>" +
              "<button type='button' class='panel-btn panel-btn-primary' data-answer='yes'>OK</button>" +
            "</div>" +
          "</div>" +
        "</div>"
      )
      let answer = false
      modal.find("p").text(message)
      modal.on("click", "[data-answer]", function(evt) {
        evt.stopPropagation()
        answer = this.dataset.answer === "yes"
        hideModal(modal)
      })
      modal.on("modal.hidden", function() {
        resolve(answer)
        setTimeout(function() { modal.remove() }, 400)
      })
      $("body").append(modal)
      showModal(modal)
    })
  },
}

// Inside the app, a link's data-confirm asks in the site's modal instead of the
// phone's alert, and alert() shows as the site's flash.
if (BuddyApp.native()) {
  window.alert = function(message) { addFlashNotice(String(message)) }

  document.addEventListener("click", function(evt) {
    const target = evt.target.closest && evt.target.closest("[data-confirm]")
    if (!target) return

    evt.preventDefault()
    evt.stopImmediatePropagation()
    const message = target.getAttribute("data-confirm")
    BuddyApp.confirm(message).then(function(confirmed) {
      if (!confirmed) return

      target.removeAttribute("data-confirm")
      target.click()
      target.setAttribute("data-confirm", message)
    })
  }, true)
}

$(document).ready(function() {
  const html = document.documentElement
  if (BuddyApp.native()) html.classList.add("buddy-native")

  const page = document.querySelector("[data-buddy-device]")
  if (page && BuddyApp.native() && String(window.BuddyNative.deviceId) === page.dataset.buddyDevice) {
    html.classList.add("buddy-this-device")
  }

  function element(tag, className, text) {
    const node = document.createElement(tag)
    if (className) node.className = className
    if (text !== undefined && text !== null) node.textContent = text
    return node
  }

  function when(at) {
    const date = new Date(at)
    return isNaN(date) ? "" : date.toLocaleString()
  }

  function failed(error) {
    addFlashAlert((error && error.message) || String(error))
  }

  // Login: hand the new device token to the app.
  const signedIn = document.querySelector("[data-buddy-signed-in]")
  if (signedIn && BuddyApp.native()) {
    BuddyApp.call("signedIn", JSON.parse(signedIn.dataset.buddySignedIn)).catch(failed)
  }

  // Permission features: asking happens on the phone, then the page reloads to
  // show what iOS said.
  $(document).on("click", "[data-buddy-allow]", function() {
    const button = this
    button.disabled = true
    BuddyApp.call("requestPermission", { feature: button.dataset.buddyAllow }).then(function() {
      window.location.reload()
    }).catch(function(error) {
      button.disabled = false
      failed(error)
    })
  })

  // A device task on the phone this page is open on runs straight away
  // instead of going through a push.
  $(document).on("click", "[data-buddy-task]", function(evt) {
    if (!html.classList.contains("buddy-this-device")) return

    evt.preventDefault()
    BuddyApp.call("runTask", { task: this.dataset.buddyTask }).then(function() {
      addFlashNotice("Done")
    }).catch(failed)
  })

  function exchange(list, kind, text, reply) {
    const row = element("div", "panel-row")
    row.appendChild(element("div", "panel-row-title", (kind === "command" ? "Command: " : "Buddy: ") + text))
    const answer = element("div", "buddy-app-reply", reply)
    row.appendChild(answer)
    list.prepend(row)
    return answer
  }

  function send(args, list) {
    const answer = exchange(list, args.kind, (args.prefix || "") + args.text, args.inline ? "Sending…" : "Queued")
    return BuddyApp.call("send", args).then(function(result) {
      answer.textContent = result.status === "replied" ? (result.reply || "Sent.") : "Queued, sends when it can"
    }).catch(function(error) {
      answer.textContent = (error && error.message) || String(error)
    })
  }

  // Commands: the console, the queue and the activity log.
  const commands = document.querySelector("[data-buddy-commands]")
  if (commands && BuddyApp.native()) {
    const consoleForm = commands.querySelector("[data-buddy-console]")
    const exchanges = commands.querySelector("[data-buddy-exchanges]")
    const outbox = commands.querySelector("[data-buddy-outbox]")
    const activity = commands.querySelector("[data-buddy-activity]")

    consoleForm.addEventListener("submit", function(evt) {
      evt.preventDefault()
      const input = consoleForm.querySelector("[name=text]")
      const text = input.value.trim()
      if (!text) return

      input.value = ""
      send({
        kind:   consoleForm.querySelector("[name=kind]:checked").value,
        text:   text,
        inline: consoleForm.querySelector("[name=inline]").checked,
      }, exchanges)
    })

    function renderOutbox() {
      BuddyApp.call("outbox").then(function(items) {
        outbox.innerHTML = ""
        if (items.length === 0) outbox.appendChild(element("div", "panel-empty", "Nothing waiting"))
        items.forEach(function(item) {
          const row = element("div", "panel-row")
          const head = element("div", "panel-row-head")
          head.appendChild(element("div", "panel-row-title", item.summary))
          if (item.state === "rejected") {
            const retry = element("button", "panel-row-action", "↻")
            retry.type = "button"
            retry.setAttribute("aria-label", "Retry")
            retry.addEventListener("click", function() { BuddyApp.call("outboxRetry", { id: item.id }).catch(failed) })
            head.appendChild(retry)
          }
          const remove = element("button", "panel-row-action", "×")
          remove.type = "button"
          remove.setAttribute("aria-label", "Delete")
          remove.addEventListener("click", function() { BuddyApp.call("outboxRemove", { id: item.id }).catch(failed) })
          head.appendChild(remove)
          row.appendChild(head)
          const detail = [when(item.pressed_at), item.source]
          if (item.attempts > 0) detail.push(item.attempts + (item.attempts === 1 ? " try" : " tries"))
          row.appendChild(element("div", "panel-row-detail", detail.join(" · ")))
          if (item.last_error) {
            row.appendChild(element("div", item.state === "rejected" ? "panel-row-error" : "panel-row-detail", item.last_error))
          }
          outbox.appendChild(row)
        })
      }).catch(failed)
    }

    function renderActivity() {
      BuddyApp.call("activity").then(function(entries) {
        activity.innerHTML = ""
        if (entries.length === 0) activity.appendChild(element("div", "panel-empty", "Nothing yet"))
        entries.forEach(function(entry) {
          const row = element("div", "panel-row")
          row.appendChild(element("div", null, entry.text))
          row.appendChild(element("div", "panel-row-detail", when(entry.at) + " · " + entry.process))
          activity.appendChild(row)
        })
      }).catch(failed)
    }

    commands.querySelector("[data-buddy-outbox-flush]").addEventListener("click", function() {
      BuddyApp.call("outboxFlush").catch(failed)
    })
    commands.querySelector("[data-buddy-activity-details]").addEventListener("toggle", function() {
      if (this.open) renderActivity()
    })
    commands.querySelector("[data-buddy-activity-clear]").addEventListener("click", function() {
      BuddyApp.call("clearActivity").then(renderActivity).catch(failed)
    })
    window.addEventListener("buddy:outbox", renderOutbox)
    renderOutbox()
  }

  // The quick prompt a hot link or widget opens.
  const compose = document.querySelector("[data-buddy-compose]")
  if (compose) {
    const options = JSON.parse(compose.dataset.buddyCompose)
    const exchanges = compose.querySelector("[data-buddy-exchanges]")

    compose.addEventListener("submit", function(evt) {
      evt.preventDefault()
      if (!BuddyApp.native()) return

      const input = compose.querySelector("[name=text]")
      const typed = input.value.trim()
      if (!typed) return

      input.value = ""
      send({
        kind:   options.send_as,
        text:   typed,
        prefix: options.prefix,
        inline: options.inline,
        data:   options.data,
      }, exchanges)
    })
    compose.querySelector("[data-buddy-close]").addEventListener("click", function() {
      if (window.history.length > 1) {
        window.history.back()
      } else {
        window.location.href = "/byte"
      }
    })
  }

  // The share sheet: what's being shared comes from the extension, and the
  // extension sends it once a destination is picked.
  const share = document.querySelector("[data-buddy-share]")
  if (share && BuddyApp.native()) {
    const list = share.querySelector("[data-buddy-share-items]")

    BuddyApp.call("shareItems").then(function(shared) {
      const has = { text: false, place: false }
      const rows = element("div", "panel-rows")
      shared.items.forEach(function(item) {
        const row = element("div", "panel-row")
        if (item.image) {
          const image = element("img", "buddy-app-shared-image")
          image.src = item.image
          row.appendChild(image)
        }
        if (item.place) {
          has.place = true
          row.appendChild(element("div", "panel-row-title", item.place.name || "A place"))
          if (item.place.address) row.appendChild(element("div", "panel-row-detail", item.place.address))
        }
        if (item.text || item.url) {
          has.text = true
          row.appendChild(element("div", null, item.url || item.text))
        }
        rows.appendChild(row)
      })
      list.appendChild(rows)
      share.querySelectorAll("[data-buddy-share-needs]").forEach(function(button) {
        button.classList.toggle("hidden", !has[button.dataset.buddyShareNeeds])
      })
    }).catch(failed)

    $(share).on("click", "[data-buddy-share-to]", function() {
      share.querySelectorAll("button").forEach(function(button) { button.disabled = true })
      BuddyApp.call("share", {
        destination: this.dataset.buddyShareTo,
        caption:     share.querySelector("[data-buddy-share-caption]").value.trim(),
      }).catch(failed)
    })
    $(share).on("click", "[data-buddy-share-cancel]", function() {
      BuddyApp.call("cancelShare").catch(failed)
    })
  }

  // Hot link icons are SF Symbols, the only icons the app icon's menu can show.
  // The phone draws the previews; a browser elsewhere shows the names.
  const symbolsRoot = document.querySelector("[data-hot-link-symbols]")
  if (symbolsRoot) {
    const symbols = JSON.parse(symbolsRoot.dataset.hotLinkSymbols)
    const previews = {}

    function loadPreviews(names) {
      const missing = names.filter(function(name) { return !(name in previews) })
      if (!BuddyApp.native() || missing.length === 0) return Promise.resolve()

      const color = getComputedStyle(symbolsRoot).getPropertyValue("--panel-text").trim()
      return BuddyApp.call("symbols", { names: missing, color: color }).then(function(images) {
        Object.assign(previews, images)
      }).catch(failed)
    }

    function paint(root) {
      root.querySelectorAll("[data-symbol]").forEach(function(holder) {
        holder.replaceChildren()
        const src = previews[holder.dataset.symbol]
        if (!src) return

        const image = element("img")
        image.src = src
        image.alt = ""
        holder.appendChild(image)
      })
    }

    function tile(name, label) {
      const button = element("button", "panel-symbol-tile")
      button.type = "button"
      button.dataset.pick = name
      button.dataset.search = (label + " " + name).toLowerCase()
      const preview = element("span", "panel-symbol")
      preview.dataset.symbol = name
      button.appendChild(preview)
      button.appendChild(element("span", null, label))
      return button
    }

    function openPicker(field) {
      const modal = $(
        "<div class='modal modal-wrapper hidden' tabindex='-1'>" +
          "<div class='modal-content panel-app panel-dialog'>" +
            "<input type='search' placeholder='Search' autocomplete='off' autocapitalize='none'>" +
            "<div class='panel-symbol-grid'></div>" +
          "</div>" +
        "</div>"
      )
      const grid = modal.find(".panel-symbol-grid")[0]
      Object.entries(symbols).forEach(function([name, label]) { grid.appendChild(tile(name, label)) })
      modal.find("input").on("input", function() {
        const query = this.value.trim().toLowerCase()
        grid.querySelectorAll("[data-pick]").forEach(function(button) {
          button.classList.toggle("hidden", query !== "" && !button.dataset.search.includes(query))
        })
      })
      modal.on("click", "[data-pick]", function(evt) {
        evt.stopPropagation()
        const name = this.dataset.pick
        field.parentNode.querySelector("[data-hot-link-icon]").value = name
        field.querySelector("[data-symbol]").dataset.symbol = name
        field.querySelector("[data-symbol-name]").textContent = symbols[name] || name
        paint(field)
        hideModal(modal)
      })
      modal.on("modal.hidden", function() { setTimeout(function() { modal.remove() }, 400) })
      $("body").append(modal)
      showModal(modal)
      modal.find("input").trigger("focus")
      loadPreviews(Object.keys(symbols)).then(function() { paint(grid) })
    }

    const shown = Array.from(document.querySelectorAll("[data-symbol]"), function(holder) { return holder.dataset.symbol })
    loadPreviews(Array.from(new Set(shown))).then(function() { paint(document) })
    // Stopped outright: the site's own click-outside handler on the document
    // would otherwise close the picker on the click that opened it.
    $(document).on("click", "[data-hot-link-icon-pick]", function(evt) {
      evt.stopImmediatePropagation()
      openPicker(this)
    })
  }

  // Hot links: each row shows only the fields its kind of action uses, and the
  // hidden ones are disabled so they don't send a second value.
  const hotLinks = document.querySelector("[data-hot-links]")
  if (hotLinks) {
    const labels = {
      command:  "Command",
      buddy:    "Message",
      trigger:  "Trigger",
      check_in: "Prompt ID",
      open:     "Path",
      url:      "Link",
    }

    function showFields(row) {
      const kind = row.querySelector("[data-hot-link-kind]").value
      row.querySelectorAll("[data-hot-link-for]").forEach(function(field) {
        const shown = field.dataset.hotLinkFor.split(" ").includes(kind)
        field.classList.toggle("hidden", !shown)
        field.querySelectorAll("input, select, textarea").forEach(function(input) { input.disabled = !shown })
      })
      const label = row.querySelector("[data-hot-link-label]")
      if (label) label.textContent = labels[kind] || "Value"
    }

    hotLinks.querySelectorAll("[data-hot-link]").forEach(showFields)
    $(hotLinks).on("change", "[data-hot-link-kind]", function() {
      showFields(this.closest("[data-hot-link]"))
    })
    $(hotLinks).on("click", "[data-hot-link-remove]", function() {
      this.closest("[data-hot-link]").remove()
    })
    $(hotLinks).on("click", "[data-hot-link-up]", function() {
      const row = this.closest("[data-hot-link]")
      if (row.previousElementSibling) row.parentNode.insertBefore(row, row.previousElementSibling)
    })
  }
})
