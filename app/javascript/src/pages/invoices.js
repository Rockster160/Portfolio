// The invoice editor saves as it's typed in, a moment after the last key, and
// swaps in the sheet the server drew from what it saved. Saves go one at a
// time, in order, so a slow reply never draws over a newer one.
(function() {
  let timer = null
  let chain = Promise.resolve()

  function csrfToken() {
    return (document.querySelector("meta[name=csrf-token]") || {}).content
  }

  function collect(form) {
    const value = function(name) { return form.querySelector("[name=" + name + "]").value }
    const rows = Array.from(form.querySelectorAll("[data-invoice-item]"))

    return {
      invoice: {
        number:    value("number"),
        issued_on: value("issued_on"),
        due_on:    value("due_on"),
        sender:    value("sender"),
        recipient: value("recipient"),
        notes:     value("notes"),
        items:     rows.map(function(row) {
          const field = function(name) { return row.querySelector("[data-field=" + name + "]").value }
          return { description: field("description"), quantity: field("quantity"), rate: field("rate") }
        }),
      },
    }
  }

  function send(form, keepalive) {
    return fetch(form.dataset.invoiceForm, {
      method:    "PATCH",
      keepalive: keepalive,
      headers:   {
        "Accept":       "application/json",
        "Content-Type": "application/json",
        "X-CSRF-Token": csrfToken(),
      },
      body: JSON.stringify(collect(form)),
    })
  }

  function save(form) {
    clearTimeout(timer)
    timer = null
    chain = chain.then(function() {
      return send(form, false).then(function(response) {
        return response.json().catch(function() { return {} }).then(function(reply) {
          if (!response.ok) throw new Error(reply.message || "Not saved")

          const sheet = document.querySelector("[data-invoice-sheet]")
          if (sheet && reply.sheet) sheet.innerHTML = reply.sheet

          const number = form.querySelector("[name=number]")
          if (reply.number && number !== document.activeElement) number.value = reply.number
        })
      })
    }).catch(function(error) {
      addFlashAlert(error.message)
    })
    return chain
  }

  function queue(form) {
    clearTimeout(timer)
    timer = setTimeout(function() { save(form) }, 400)
  }

  document.addEventListener("input", function(evt) {
    const form = evt.target.closest("[data-invoice-form]")
    if (form) queue(form)
  })

  document.addEventListener("click", function(evt) {
    const form = document.querySelector("[data-invoice-form]")

    if (evt.target.closest("[data-invoice-item-add]")) {
      const template = form.querySelector("[data-invoice-item-template]")
      const list = form.querySelector("[data-invoice-items]")
      list.appendChild(template.content.cloneNode(true))
      list.lastElementChild.querySelector("[data-field=description]").focus()
      save(form)
      return
    }

    const remove = evt.target.closest("[data-invoice-item-remove]")
    if (remove) {
      remove.closest("[data-invoice-item]").remove()
      save(form)
      return
    }

    // Print waits for whatever was just typed to land first.
    const print = evt.target.closest("[data-invoice-print]")
    if (print && form && timer) {
      evt.preventDefault()
      save(form).then(function() { window.location = print.href })
      return
    }

    if (evt.target.closest("[data-invoice-print-now]")) window.print()
  })

  // Leaving with a save still waiting sends it on the way out.
  window.addEventListener("pagehide", function() {
    const form = document.querySelector("[data-invoice-form]")
    if (form && timer) send(form, true)
  })
})()
