// TODO:
/*
Save blocks as they change - live save? Or only save on "submit"? Maybe save drafts?
Show temp variables in function list
// Block: :any should be invalid when empty
// All blocks should be invalid when/if empty unless optional (invalid if/when there are no possible options)
// On load, collect all of the existing tokens and store them in the `tokens` array
*/

import { render, templates } from "./templates"
import { genUniqToken, tokens } from "../random/js_chance_generator"

$(document).ready(function() {
  if ($(".ctr-jarvis_tasks.act-new, .ctr-jarvis_tasks.act-edit").length == 0) { return }

  let displaySelectTemplate = function(select) {
    let wrapper = select.parentElement
    if (select.value == "input" && wrapper.querySelectorAll(".raw-input").length < 1) {
      // Array and hash have to be built- can't do them inline
      // ANY cannot be done inline

      let node = render(select.getAttribute("blocktype"))
      if (node) { wrapper.appendChild(node) }
    } else if (select.value != "input" && wrapper.querySelectorAll(".raw-input").length > 0) {
      $(wrapper).children(".raw-input").remove()
    }
  }

  let attachSelectEvents = function() {
    $(".item-name select.block-select").each(function() {
      if (this.value == "input" && this.getAttribute("unattached")) {
        this.removeAttribute("unattached")
        this.addEventListener("change", function() {
          resetDropdowns()
          displaySelectTemplate(this)
        })
        this.dispatchEvent(new Event("change"))
      }
    })
  }

  let resetDropdowns = function() {
    // Maybe use this to figure out what tokens are being used on the page?
    let usedtokens = Array.from($(".token").map(function(idx) {
      return {
        token: this.textContent,
        idx: idx,
        scope: "", // - maybe the closest token it is inside?
        type: this.parentElement.querySelector(".return").getAttribute("blocktype"),
      }
    }))
    let token_names = usedtokens.map(function(token) { return token.token })

    let removeOrInvalidOpt = function(select, option) {
      if (select.val() == option.val()) {
        select.addClass("invalid")
      } else {
        option.remove()
      }
    }

    $(".item-name select.block-select").each(function() {
      let select = $(this)
      let selectToken = select.parents(".list-item").find(".token").get(0).textContent
      let currentBlockIdx = token_names.indexOf(selectToken)
      select.removeClass("invalid")

      // Existing options -- removing current options that are no longer valid
      let existing_options = Array.from(select.children("option").map(function() {
        let option = $(this)
        let optionVal = this.textContent
        let optionBlockIdx = token_names.indexOf(optionVal)

        if (optionVal == "input") { return }

        if (optionBlockIdx < 0) { // Token no longer exists (block was deleted)
          removeOrInvalidOpt(select, option)
        } else if (optionBlockIdx >= currentBlockIdx) { // Token is after current (not defined yet)
          removeOrInvalidOpt(select, option)
        } else {
          return this.textContent
        }
      }))
      usedtokens.forEach(function(token) {
        // TODO: Should not find usedtokens out of scope (inside an unrelated block)

        // Option is already there. Don't add it again.
        if (existing_options.indexOf(token.token) >= 0) { return }
        // Token hasn't been executed yet. Not available for use
        if (currentBlockIdx <= token.idx) { return }
        // Types have to match (or be ANY)
        if (select.attr("blocktype") != "any" && select.attr("blocktype") != token.type) { return }

        let option = document.createElement("option")
        option.textContent = token.token
        select.append(option)
      })
    })
    attachSelectEvents()
  }

  let initInteractivity = function() {
    resetDropdowns()
    $(".tree .lists .list-item-container").draggable({
      helper: "clone",
      connectToSortable: ".tasks",
      revert: "invalid",
      start: function(event, ui) {
        $(ui.helper).prepend('<div class="list-item-handle"><i class="fa fa-ellipsis-v"></i></div>');
      },
      stop: function(event, ui) {
        let container = $(ui.helper)
        let item = container.find(".list-item")
        let [type, datum] = JSON.parse(item.attr("data"))

        let populated_block = templates.block(type, { token: genUniqToken() })
        container.replaceWith(populated_block)

        initInteractivity()
      },
    })

    $(".tasks").sortable({
      handle: ".list-item-handle",
      connectWith: ".tasks",
      connectToSortable: ".tree .lists .list-item-container",
      placeholder: "list-item-placeholder",
      stop: function(event, ui) {
        resetDropdowns()
      }
    })
  }
  initInteractivity()

  let collectBlocksFromList = function(tasksNode) {
    return Array.from(tasksNode.querySelectorAll(":scope > .list-item-container > .list-item")).map(function(nestedItem) {
      let blocks = collectBlockData(nestedItem)
      if (Array.isArray(blocks.data[0])) { blocks.data = blocks.data[0] }
      return blocks
    })
  }

  let collectBlockData = function(listItem) {
    return {
      returntype: listItem.querySelector(":scope > .return").getAttribute("blocktype"),
      type: listItem.querySelector(":scope > .type").innerText,
      token: listItem.querySelector(":scope > .token").innerText,
      data: Array.from(listItem.querySelectorAll(":scope > .item-name > .select-wrapper, :scope > .item-name > .tasks")).map(function(block) {
        if (block.classList.contains("tasks")) {
          return collectBlocksFromList(block)
        } else if (block.classList.contains("select-wrapper")) {
          let rawinput = block.querySelector("input"), rawval;
          if (rawinput) {
            switch(rawinput.type) {
              case "checkbox": rawval = rawinput.checked; break;
              default: rawval = rawinput.value
            }
          }
          return {
            option: block.querySelector("select")?.value,
            raw: rawval,
          }
        }
      })
    }
  }

  document.addEventListener("click", function(evt) {
    if (evt.target.parentElement.classList.contains("delete")) {
      evt.target.closest(".list-item-container").remove()
    }
  })

  $(".save-task").removeAttr("data-disable-with")
  $("#task-form").submit(function(evt) {
    evt.preventDefault()
    let form = document.getElementById("task-form")
    let data = collectBlocksFromList(document.querySelector(".lists-index-container > .tasks"))

    form.querySelectorAll(".data-field").forEach(function(f) { f.remove() })

    let datainput = document.createElement("input")
    datainput.setAttribute("type", "hidden")
    datainput.setAttribute("name", "task[tasks]")
    datainput.classList.add("data-field")
    datainput.value = JSON.stringify(data)
    form.appendChild(datainput)

    let nameinput = document.createElement("input")
    nameinput.setAttribute("type", "hidden")
    nameinput.setAttribute("name", "task[name]")
    nameinput.classList.add("data-field")
    nameinput.value = document.querySelector("[name='task[name]']").value
    form.appendChild(nameinput)

    let body = new FormData(form)
    let json = JSON.stringify(Object.fromEntries(body))

    fetch(form.getAttribute("action"), {
      method: form.querySelector("[name=_method]")?.value?.toUpperCase() || form.getAttribute("method"),
      body: new FormData(form),
    }).then(function(res) {
      if (res.ok) {
        res.json().then(function(json) {
          window.location.href = json.url
        })
      }
    })
  })

  // On load, render the existing tasks
  do {
    // Loop because more "tasks"/containers are added later (arrays and conditionals)
    $("[data-tasks]").each(function() {
      let container = this
      JSON.parse($(this).attr("data-tasks")).forEach(function(task) {
        let populated_block = templates.block(task.type, task)
        tokens.push(task.token)
        container.append(populated_block)
      })
      container.removeAttribute("data-tasks")
    })
    initInteractivity()
  } while ($("[data-tasks]").length > 0);
})
