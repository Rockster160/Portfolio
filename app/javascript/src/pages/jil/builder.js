/*
//------------------ TODO ------------------
Show temp variables in function list
// Block: :any should be invalid when empty
// input: :raw should be invalid when empty
// All blocks should be invalid when/if empty unless optional
// All blocks should be invalid if/when there are no possible options unless optional
// On load, collect all of the existing tokens and store them in the `tokens` array
*/

import { render, templates, tokenSelector } from "./templates"
import { genUniqToken, tokens } from "../random/js_chance_generator"

$(document).ready(function() {
  if ($(".ctr-jarvis_tasks.act-new, .ctr-jarvis_tasks.act-edit").length == 0) { return }

  $(".drawer-tree .tab").on("click touchstart", function() {
    $(".drawer-tree").removeClass("collapsed")
  })
  $(".function-container").on("click touchend", function() {
    $(".drawer-tree").addClass("collapsed")
  })

  // Adds a field for inputting a simple value (str, toggle/bool, integer, etc) inline without use of a var
  let displaySelectTemplate = function(select) {
    let wrapper = select.parentElement
    if (select.value == "input" && wrapper.querySelectorAll(".raw-input").length < 1) {
      // Array and hash have to be built- can't do them inline
      // ANY cannot be done inline

      let node = render(select.getAttribute("blocktype"))
      if (wrapper.getAttribute("blockdata")) {
        let preset = JSON.parse(wrapper.getAttribute("blockdata")).default
        node.value = preset || ""
      }
      if (node) { wrapper.appendChild(node) }
    } else if (select.value != "input" && wrapper.querySelectorAll(".raw-input").length > 0) {
      $(wrapper).children(".raw-input").remove()
    }
  }
  // Dynamic selects allow a user to select an item from a dropdown using a block rather than hard-coding/selecting an option
  let displayDynamicSelect = function(select) {
    let wrapper = select.parentElement
    if (select.value == "&lt;dynamic&gt;" && wrapper.querySelectorAll(".block-select").length == 0) {
      wrapper.appendChild(tokenSelector(select.getAttribute("dynamic_raw")))
      initInteractivity()
    } else {
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
    if (evt.target.classList?.contains("dynamic-select")) {
      displayDynamicSelect(evt.target)
    }
    if (evt.target.classList?.contains("block-select")) {
      attachSelectEvents()
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

  // Populate available tokens
  // Mark "invalid" if bad token chosen or no token selected/available
  let resetDropdowns = function() {
    // Maybe use this to figure out what tokens are being used on the page?
    // Collect all possible tokens, as well as where they are defined
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

    // PopulateOptions
    // Iterate through each dropdown, add available tokens and mark invalid status
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
        // If none of the above apply, this token is available for this dropdown
        return true
      }).map(tokendata => tokendata.token)

      // Existing options -- removing current options that are no longer valid
      let existing_options = Array.from(select.children("option").map(function() {
        let option = $(this)
        let optionVal = this.textContent

        if (optionVal == "input") { return } // Ignore the magic "input" value
        if (optionVal == "{None}" && select.hasClass("optional")) { return } // Ignore the empty/optional - probably don't want to hardcode the {None}?
        if (available_tokens.indexOf(optionVal) < 0) {
          removeOrInvalidOpt(select, option) // Token no longer exists (block was deleted)
        } else {
          return this.textContent
        }
      }))

      // Add tokens that aren't already in the list
      available_tokens.forEach(function(token) {
        // Option is already there. Don't add it again.
        if (existing_options.indexOf(token) >= 0) { return }

        let option = document.createElement("option")
        option.textContent = token
        select.append(option)
      })
      // TODO: Order tokens by reverse order of when they appear on the page
      // Mark invalid if no option selected
      // Check? Should not remove invalid class from an optional select that's chosen a
      //   non-existent token
      if (select.children("option").length == 0 && !select.hasClass("optional")) {
        select.addClass("invalid")
      }
    })
    attachSelectEvents()
  }

  let initInteractivity = function() {
    resetDropdowns()
    $(".drawer-tree .lists .list-item-container").draggable({
      helper: "clone",
      connectToSortable: ".tasks",
      revert: "invalid",
      handle: ".handle",
      start: function(event, ui) {
        $(".tasks.ui-sortable:not(.lists)").addClass("pending-drop")
        $(ui.helper).prepend('<div class="list-item-handle"><i class="fa fa-ellipsis-v"></i></div>');
      },
      stop: function(event, ui) {
        $(".pending-drop").removeClass("pending-drop")
        if ($(ui.helper).parents(".drawer-tree").length > 0) { return }
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
      connectToSortable: ".drawer-tree .lists .list-item-container",
      placeholder: "list-item-placeholder",
      start: function(event, ui) {
        // $(this).closest(".list-item-container").addClass("tasks-drag-over")
        $(".tasks.ui-sortable:not(.lists)").addClass("pending-drop")
      },
      over: function(event, ui) {
        // $(this).closest(".list-item-container").addClass("tasks-drag-over")
      },
      out: function(event, ui) {
        // $(this).closest(".list-item-container").removeClass("tasks-drag-over")
      },
      stop: function(event, ui) {
        $(".pending-drop").removeClass("pending-drop")
        // $(".tasks-drag-over").removeClass("tasks-drag-over")
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
          let rawinput = block.querySelector(".raw-input"), rawval;
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

  let renameToken = function(scope, old_name, new_name) {
    scope.find("[token='" + old_name + "']").attr("token", new_name)
    scope.find(".token:contains('" + old_name + "')").text(new_name)
    scope.find("option[value='" + old_name + "']").text(new_name)
    scope.find("option[value='" + old_name + "']").val(new_name)
  }

  document.addEventListener("click", function(evt) {
    if ($(evt.target).closest("span.token").length > 0) {
      let wrapper = $(evt.target).closest("span.token")
      let newname = window.prompt("Enter new token name", wrapper.text().replace(/\:var$/, ""))
      if (newname != null && newname.length > 2) {
        renameToken(wrapper.closest(".tasks"), wrapper.text(), newname + ":var")
      }
    }
    if (evt.target.parentElement?.classList?.contains("delete")) {
      disableRunButton("delete")
      evt.target.closest(".list-item-container").remove()
    }
    if ($(evt.target).closest(".duplicate").length > 0) {
      disableRunButton("duplicate")
      // let data = collectBlockData(evt.target.closest(".list-item"))
      // let node = render(select.getAttribute("blocktype"))
      // Recursively go through all node.data {type:block} and do the same
      // Because we're re-rendering, don't need to rename tokens?

      let original = $(evt.target.closest(".list-item-container"))
      let clone = original.clone()

      clone.find("[token]").each(function() {
        renameToken(clone, this.getAttribute("token"), genUniqToken())
      })
      original.after(clone)
      initInteractivity()
    }
  })

  $(document).on("keyup", "input.filter-drawer-tree", function() {
    let wrapper = $(".drawer-tree .lists")
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
