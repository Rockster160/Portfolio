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

  const csrfToken = (document.querySelector("meta[name=csrf-token]") || {}).content

  // A save from a page that stays put: JSON both ways, and the server's
  // message as the error when it refuses.
  function request(url, method, body) {
    const form = body instanceof FormData
    return fetch(url, {
      method: method,
      headers: Object.assign(
        { "Accept": "application/json", "X-CSRF-Token": csrfToken },
        form ? {} : { "Content-Type": "application/json" },
      ),
      body: form ? body : (body ? JSON.stringify(body) : undefined),
    }).then(function(response) {
      return response.json().catch(function() { return {} }).then(function(reply) {
        if (!response.ok) throw new Error(reply.message || "Not saved")
        return reply
      })
    })
  }

  // Login: hand the new device token to the app.
  const signedIn = document.querySelector("[data-buddy-signed-in]")
  if (signedIn && BuddyApp.native()) {
    BuddyApp.call("signedIn", JSON.parse(signedIn.dataset.buddySignedIn)).catch(failed)
  }

  // Inside the app, ‹ goes back to the app screen it came from: Buddy, or the
  // settings a page was opened from. A page opened straight from a widget or a
  // notification came from nowhere, so ‹ opens its parent in its place.
  function cameFromAppPage() {
    if (!document.referrer) return false
    try {
      const from = new URL(document.referrer)
      const site = location.hostname.replace(/^byte\./, "")
      if (from.hostname !== site && from.hostname !== "byte." + site) return false

      if (from.hostname === "byte." + site && from.pathname === "/") return true

      return /^\/(app\/|account\/app_devices)/.test(from.pathname)
    } catch (error) {
      return false
    }
  }

  $(document).on("click", "[data-back]", function(evt) {
    if (!BuddyApp.native()) return

    evt.preventDefault()
    if (cameFromAppPage() && window.history.length > 1) {
      window.history.back()
    } else {
      window.location.replace(this.href)
    }
  })

  // A phone's settings save as they change. The control greys out until the
  // server answers with what it saved, and then shows that; a save that fails
  // puts the control back the way it was.
  const settings = document.querySelector("[data-buddy-settings]")
  if (settings) {
    // Every input of one option: a switch, a row of choices, or a set of pills.
    function inputsFor(name) {
      return Array.from(settings.querySelectorAll("[name]")).filter(function(input) { return input.name === name })
    }

    function read(inputs) {
      const first = inputs[0]
      if (first.name.endsWith("[]")) return inputs.filter(function(input) { return input.checked }).map(function(input) { return input.value })
      if (first.type === "radio") return (inputs.find(function(input) { return input.checked }) || {}).value
      if (first.type === "checkbox") return first.checked
      return first.value
    }

    function write(inputs, value) {
      const first = inputs[0]
      if (first.name.endsWith("[]")) {
        const picked = (value || []).map(String)
        inputs.forEach(function(input) { input.checked = picked.includes(input.value) })
      } else if (first.type === "radio") {
        inputs.forEach(function(input) { input.checked = input.value === String(value) })
      } else if (first.type === "checkbox") {
        first.checked = value === true || value === "true"
      } else {
        first.value = value
      }
    }

    const saved = {}
    function remember(root) {
      root.querySelectorAll("[name^='preferences[']").forEach(function(input) {
        saved[input.name] = read(inputsFor(input.name))
      })
    }
    remember(settings)

    // Swaps `node` for `fresh` without moving what's on screen: a card above
    // the view that grows or shrinks would otherwise push everything below it,
    // and the app's web view doesn't anchor the scroll by itself.
    function replaceInPlace(node, fresh) {
      const before = node.getBoundingClientRect().bottom
      node.replaceWith(fresh)
      if (before > 0) return

      window.scrollBy(0, fresh.getBoundingClientRect().bottom - before)
    }

    // The feature shows as on, its options open, the moment Allow is tapped;
    // iOS can take a while to answer (Location asks twice). Refused, it goes
    // back. Allowed, only the options are fetched again, for what the phone
    // has just sent (its calendars and lists).
    $(settings).on("click", "[data-buddy-allow]", function() {
      const button = this
      const key = button.dataset.buddyAllow
      const panel = document.getElementById("feature-" + key)
      const toggle = panel.querySelector("[name='features[]']")
      const options = panel.querySelector("[data-buddy-options]")
      const note = panel.querySelector("[data-buddy-permission-note]")

      function show(allowed) {
        button.hidden = allowed
        if (note) note.hidden = allowed
        options.hidden = !allowed
        toggle.disabled = !allowed
        toggle.checked = allowed
      }

      show(true)
      BuddyApp.call("requestPermission", { feature: key }).then(function(reply) {
        if (reply && reply.state !== "granted") {
          show(false)
          if (reply.state === "denied") {
            button.remove()
            if (note) note.textContent = "Denied in iOS Settings"
          }
          return
        }

        return fetch(window.location.href, { headers: { "Accept": "text/html" } }).then(function(response) {
          return response.text()
        }).then(function(page) {
          const fresh = new DOMParser().parseFromString(page, "text/html")
          const freshOptions = fresh.querySelector("#feature-" + key + " [data-buddy-options]")
          const current = panel.querySelector("[data-buddy-options]")
          if (!freshOptions || !current || freshOptions.innerHTML === current.innerHTML) return

          replaceInPlace(current, freshOptions)
          remember(freshOptions)
        })
      }).catch(function(error) {
        show(false)
        failed(error)
      })
    })

    settings.addEventListener("change", function(evt) {
      const input = evt.target
      let inputs, body, savedValue
      if (input.name === "features[]") {
        inputs = [input]
        body = { feature: input.value, on: input.checked }
        savedValue = function(reply) { return reply.features.includes(input.value) }
      } else {
        const key = (input.name.match(/^preferences\[(\w+)\]/) || [])[1]
        if (!key) return

        inputs = inputsFor(input.name)
        body = { preferences: { [key]: read(inputs) } }
        savedValue = function(reply) { return reply.preferences[key] }
      }
      const before = input.name === "features[]" ? !input.checked : saved[input.name]
      inputs.forEach(function(each) { each.disabled = true })
      request(settings.dataset.buddySettings, "PATCH", body).then(function(reply) {
        saved[input.name] = savedValue(reply)
        write(inputs, saved[input.name])
      }).catch(function(error) {
        write(inputs, before)
        failed(error)
      }).finally(function() {
        inputs.forEach(function(each) { each.disabled = false })
      })
    })

    // A task on the phone this page is open on runs straight away; anything
    // else goes to the phone through a push.
    $(settings).on("click", "[data-buddy-post]", function() {
      const button = this
      const task = button.dataset.buddyTask
      button.disabled = true
      const sent = task && html.classList.contains("buddy-this-device")
        ? BuddyApp.call("runTask", { task: task }).then(function() { return { message: "Done" } })
        : request(button.dataset.buddyPost, "POST")
      sent.then(function(reply) { addFlashNotice(reply.message) }).catch(failed).finally(function() {
        button.disabled = false
      })
    })
  }

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
      const shown = { replied: result.reply || "Sent", sent: "Sent", opened: "Opened" }
      answer.textContent = shown[result.status] || "Queued, sends when it can"
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
        const input = field.parentNode.querySelector("[data-hot-link-icon]")
        input.value = name
        field.querySelector("[data-symbol]").dataset.symbol = name
        field.querySelector("[data-symbol-name]").textContent = symbols[name] || name
        paint(field)
        input.dispatchEvent(new Event("change", { bubbles: true }))
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

    // The list saves as it's edited, all of it each time since its order is
    // part of it. A row with no title is still being filled in and waits. A
    // change made while a save is out goes in the next one.
    const form = hotLinks.closest("form")
    const saved = hotLinks.querySelector("[data-hot-links-saved]")
    const blankRow = hotLinks.querySelector("[data-hot-link-new]")
    const template = blankRow && blankRow.cloneNode(true)
    let saving = false
    let again = false

    function rowButtons() {
      const buttons = element("div", "panel-buttons")
      const up = element("button", "panel-btn", "Move up")
      up.type = "button"
      up.dataset.hotLinkUp = ""
      const remove = element("button", "panel-btn panel-btn-danger", "Remove")
      remove.type = "button"
      remove.dataset.hotLinkRemove = ""
      buttons.append(up, remove)
      return buttons
    }

    // A saved link's row says what it is: its icon on its color, its title,
    // and what a tap does. It follows the fields as they're edited.
    function summarize(row) {
      const summary = row.querySelector("[data-hot-link-toggle]")
      if (!summary) return

      const kind = row.querySelector("[data-hot-link-kind]")
      summary.querySelector("[data-hot-link-summary-title]").textContent = row.querySelector("[name$='[title]']").value
      summary.querySelector("[data-hot-link-summary-kind]").textContent = kind.options[kind.selectedIndex].text
      row.style.setProperty("--hot-link-color", row.querySelector("[data-hot-link-color]").value)
      const icon = row.querySelector("[data-hot-link-icon-pick] [data-symbol]")
      summary.querySelector("[data-symbol]").replaceWith(icon.cloneNode(true))
    }

    function summaryFor(row) {
      const summary = element("button", "buddy-app-hot-link-summary")
      summary.type = "button"
      summary.dataset.hotLinkToggle = ""
      summary.setAttribute("aria-expanded", "false")
      const badge = element("span", "buddy-app-hot-link-badge")
      badge.appendChild(element("span", "panel-symbol"))
      badge.firstChild.dataset.symbol = ""
      const text = element("span", "panel-setting-text")
      const title = element("span", "panel-setting-title")
      title.dataset.hotLinkSummaryTitle = ""
      const kind = element("span", "panel-setting-sub")
      kind.dataset.hotLinkSummaryKind = ""
      text.append(title, kind)
      summary.append(badge, text)
      row.prepend(summary)
      summarize(row)
    }

    // A new row that saved folds into the list as a row of its own, and a
    // fresh blank form takes its place while there's room.
    function settle(links) {
      const titled = Array.from(hotLinks.querySelectorAll("[data-hot-link]")).filter(function(row) {
        return row.querySelector("[name$='[title]']").value.trim() !== ""
      })
      titled.forEach(function(row, index) {
        if (!links[index]) return

        row.querySelector("[name$='[id]']").value = links[index].id
        if (!row.hasAttribute("data-hot-link-new")) return

        row.removeAttribute("data-hot-link-new")
        row.className = "buddy-app-hot-link"
        const heading = row.querySelector(":scope > .panel-setting-title")
        if (heading) heading.remove()
        const editor = row.querySelector("[data-hot-link-editor]")
        editor.appendChild(rowButtons())
        editor.hidden = true
        summaryFor(row)
        saved.appendChild(row)
        saved.hidden = false
        if (template && links.length < Number(hotLinks.dataset.hotLinksMax)) {
          const fresh = template.cloneNode(true)
          const index = "hot_links[" + Date.now() + "]"
          fresh.querySelectorAll("[name]").forEach(function(input) {
            input.name = input.name.replace(/^hot_links\[\d+\]/, index)
          })
          hotLinks.appendChild(fresh)
          showFields(fresh)
        }
      })
    }

    function save(changed) {
      if (saving) {
        again = true
        return
      }
      saving = true
      if (changed) changed.classList.add("is-saving")
      request(form.action, "POST", new FormData(form)).then(function(reply) {
        settle(reply.hot_links || [])
      }).catch(failed).finally(function() {
        if (changed) changed.classList.remove("is-saving")
        saving = false
        if (again) {
          again = false
          save()
        }
      })
    }

    form.addEventListener("submit", function(evt) {
      evt.preventDefault()
      save()
    })
    $(hotLinks).on("change", "input, select, textarea", function() {
      const row = this.closest("[data-hot-link]")
      if (this.matches("[data-hot-link-kind]")) showFields(row)
      summarize(row)
      save(this)
    })
    $(hotLinks).on("click", "[data-hot-link-toggle]", function() {
      const open = this.getAttribute("aria-expanded") !== "true"
      this.setAttribute("aria-expanded", String(open))
      this.closest("[data-hot-link]").querySelector("[data-hot-link-editor]").hidden = !open
    })
    $(hotLinks).on("click", "[data-hot-link-remove]", function() {
      this.closest("[data-hot-link]").remove()
      saved.hidden = !saved.querySelector("[data-hot-link]")
      save()
    })
    $(hotLinks).on("click", "[data-hot-link-up]", function() {
      const row = this.closest("[data-hot-link]")
      if (!row.previousElementSibling) return

      row.parentNode.insertBefore(row, row.previousElementSibling)
      save()
    })
  }
})
