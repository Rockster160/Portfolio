// TODO:
/*
input raw: :empty -- invalid
Show temp variables in function list
// Block: :any should be invalid when empty
// All blocks should be invalid when/if empty unless optional (invalid if/when there are no possible options)
// On load, collect all of the existing tokens and store them in the `tokens` array
*/

import { render, templates, tokenSelector } from "./templates"
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
  let displayDynamicSelect = function(select) {
    let wrapper = select.parentElement
    // if (select.value == "&lt;dynamic&gt;") console.log("is dynamic");
    // if (wrapper.querySelectorAll(".block-select").length == 0) console.log("no block-select");
    if (select.value == "&lt;dynamic&gt;" && wrapper.querySelectorAll(".block-select").length == 0) {
      // console.log("add dynamic");
      wrapper.appendChild(tokenSelector())
      initInteractivity()
    } else {
      // console.log("remove dynamic");
      $(wrapper).children(".block-select").remove()
    }
  }

  let attachSelectEvents = function() {
    $(".item-name select.block-select").each(function() {
      if (this.value == "input" && this.getAttribute("unattached")) {
        this.removeAttribute("unattached")
        this.addEventListener("change", function() {
          initInteractivity()
          displaySelectTemplate(this)
        })
        this.dispatchEvent(new Event("change"))
      }
    })
  }
  document.addEventListener("change", function(evt) {
    // console.log("change");
    if (evt.target.classList?.contains("dynamic-select")) {
      // console.log("dynamic");
      displayDynamicSelect(evt.target)
    }
  })
  document.addEventListener("change", function(e) {
    disableRunButton("change")
  }, { once: true })

  let removeOrInvalidOpt = function(select, option) {
    if (select.val() == option.val()) {
      if (!(select.hasClass("optional") && option.text() == "{None}")) {
        select.addClass("invalid")
      }
    } else {
      option.remove()
    }
  }

  let itemParents = function(element) {
    for (var parents = []; element; element = element.parentElement) {
      if (element.classList?.contains("list-item")) {
        parents.push(element)
      }
    }

    return parents.reverse()
  }

  let toggleCronInput = function() {
    $(".cron-input").toggleClass("hidden", $(".cron-input-select").val() != "cron")
  }
  $(".cron-input-select").change(toggleCronInput)
  toggleCronInput()

  let parentTokens = function(item) {
    // Does not include current token
    return itemParents(item).slice(0, -1).map(parent => parent.querySelector(".token").innerText)
  }

  let resetDropdowns = function() {
    // Maybe use this to figure out what tokens are being used on the page?
    let usedtokens = Array.from($(".token").map(function(idx) {
      return {
        item: this.parentElement,
        token: this.textContent,
        idx: idx,
        parentTokens: parentTokens(this),
        type: this.parentElement.querySelector(".return").getAttribute("blocktype"),
      }
    }))
    let token_names = usedtokens.map(function(tokendata) { return tokendata.token })

    $(".item-name select.block-select").each(function() {
      let select = $(this)
      let thisToken = select.closest(".list-item").find(".token").get(0).textContent
      let selectParentTokens = parentTokens(select.get(0))
      select.removeClass("invalid")

      let available_tokens = usedtokens.filter(function(tokendata) {
        // Token hasn't been executed yet. Not available for use
        if (token_names.indexOf(thisToken) <= tokendata.idx) { return }
        // Token is an ancestor - hasn't been executed yet
        if (selectParentTokens.includes(tokendata.token)) { return }
        // Types have to match (or be ANY)
        if (select.attr("blocktype") != tokendata.type && select.attr("blocktype") != "any") { return }
        // Make sure scope matches -- Has a shared ancestor
        if (tokendata.parentTokens.length > 0) {
          let sharedParents = tokendata.parentTokens.filter(token => selectParentTokens.includes(token))
          if (sharedParents.length == 0) { return }
        }

        return true
      }).map(tokendata => tokendata.token)

      // Existing options -- removing current options that are no longer valid
      let existing_options = Array.from(select.children("option").map(function() {
        let option = $(this)
        let optionVal = this.textContent

        if (optionVal == "input") { return } // Ignore the magic "input" value
        if (available_tokens.indexOf(optionVal) < 0) {
          removeOrInvalidOpt(select, option) // Token no longer exists (block was deleted)
        } else {
          return this.textContent
        }
      }))
      available_tokens.forEach(function(token) {
        // Option is already there. Don't add it again.
        if (existing_options.indexOf(token) >= 0) { return }

        let option = document.createElement("option")
        option.textContent = token
        select.append(option)
      })
      if (select.children("option").length == 0 && !select.hasClass("optional")) {
        select.addClass("invalid")
      }
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

        disableRunButton("drag")
        initInteractivity()
      },
    })

    $(".tasks").sortable({
      handle: ".list-item-handle",
      connectWith: ".tasks",
      connectToSortable: ".tree .lists .list-item-container",
      placeholder: "list-item-placeholder",
      stop: function(event, ui) {
        disableRunButton("sort")
        resetDropdowns()
      }
    })
  }
  initInteractivity()

  let disableRunButton = function(name) {
    $(".run-task")
      .attr("disabled", "disabled")
      .addClass("disabled")
      .removeAttr("data-remote")
      .removeAttr("href")
    $(".config-btn")
      .attr("disabled", "disabled")
      .addClass("disabled")
      .removeAttr("data-modal")
      .removeAttr("href")
  }

  let collectBlocksFromList = function(tasksNode) {
    return Array.from(tasksNode.querySelectorAll(":scope > .list-item-container > .list-item")).map(function(nestedItem) {
      let blocks = collectBlockData(nestedItem)
      if (Array.isArray(blocks.data) && blocks.data.length == 1 && Array.isArray(blocks.data[0])) {
        blocks.data = blocks.data[0]
      }
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
            option: (block.querySelector(".block-select") || block.querySelector("select"))?.value,
            selected: block.querySelector("select")?.value,
            raw: rawval,
          }
        }
      })
    }
  }

  document.addEventListener("click", function(evt) {
    if (evt.target.parentElement?.classList?.contains("delete")) {
      disableRunButton("delete")
      evt.target.closest(".list-item-container").remove()
    }
  })

  $(document).on("keyup", "input.filter-tree", function() {
    let wrapper = $(".tree .lists")
    var currentText = $(this).val().toLowerCase().replace(/^( *)|( *)$/g, "").replace(/ +/g, " ")

    if (currentText.length == 0) {
      wrapper.find("h3, .list-item-container").removeClass("hidden")
    } else {
      wrapper.find(".list-item-container").each(function() {
        var option_with_category = $(this).attr("data-group") + " " + $(this).find(".item-name").text()
        var optionText = option_with_category.toLowerCase().replace(/^( *)|( *)$/g, "").replace(/ +/g, " ")
        $(this).toggleClass("hidden", optionText.indexOf(currentText) < 0)
      })
      wrapper.find("h3").each(function() {
        let visible = wrapper.find(`.list-item-container:not(.hidden)[data-group="${$(this).attr("data-group")}"]`)
        $(this).toggleClass("hidden", visible.length == 0)
      })
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
    datainput.setAttribute("name", "jarvis_task[tasks]")
    datainput.classList.add("data-field")
    datainput.value = JSON.stringify(data)
    form.appendChild(datainput)

    let nameinput = document.createElement("input")
    nameinput.setAttribute("type", "hidden")
    nameinput.setAttribute("name", "jarvis_task[name]")
    nameinput.classList.add("data-field")
    nameinput.value = document.querySelector("[name='jarvis_task[name]']").value
    form.appendChild(nameinput)

    let body = new FormData(form)
    let json = JSON.stringify(Object.fromEntries(body))

    fetch(form.getAttribute("action"), {
      method: form.querySelector("[name=_method]")?.value?.toUpperCase() || form.getAttribute("method"),
      body: new FormData(form),
      headers: {
        "Accept": "application/json"
      }
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
      JSON.parse($(this).attr("data-tasks"))?.forEach(function(task) {
        if (!task.type) { return } // Skip empty
        let populated_block = templates.block(task.type, task)
        tokens.push(task.token)
        container.append(populated_block)
      })
      container.removeAttribute("data-tasks")
    })

    initInteractivity()
  } while ($("[data-tasks]").length > 0);
  $(".dynamic-select").each(function() {
    let select = this
    displayDynamicSelect(this)
  })
})
