import { parser } from "./random/js_chance_generator"

// TODO: parser.token should be uniq on the page
$(document).ready(function() {
  if ($(".ctr-tasks.act-index").length == 0) { return }
  let rawVals = ["bool", "str", "num"]

  let displaySelectTemplate = function(select) {
    let wrapper = select.parentElement
    if (select.value == "input" && wrapper.children.length == 1) {
      // Array and hash have to be built- can't do them inline
      // ANY cannot be done inline

      let blocktype = select.getAttribute("blocktype")
      let template = document.querySelector("#" + blocktype)
      let clone = template.content.cloneNode(true)

      wrapper.appendChild(clone)
    } else if (wrapper.children.length > 1) {
      $(wrapper).children(":not(.block-select)").remove()
    }
  }

  let attachSelectEvents = function() {
    $(".item-name select.block-select").each(function() {
      if (this.value == "input" && this.getAttribute("unattached")) {
        this.removeAttribute("unattached")
        this.addEventListener("change", function() {
          displaySelectTemplate(this)
        })
        this.dispatchEvent(new Event("change"))
      }
    })
  }

  let resetDropdowns = function() {
    let tokens = Array.from($(".token").map(function(idx) {
      return {
        token: this.textContent,
        pos: idx,
        scope: "", // - maybe the closest token it is inside?
        type: "any",
      }
    }))
    let token_names = tokens.map(function(token) { return token.token })

    $(".item-name select.block-select").each(function(a) {
      let select = $(this)
      let existing_options = Array.from(select.children("option").map(function() {
        let option = $(this)

        if (this.textContent == "input") { return }

        // Should not find tokens below current
        // Should not find tokens out of scope (inside an unrelated block)
        // * Should not find own token
        if (token_names.indexOf(this.textContent) < 0) {
          option.remove()
        } else {
          return this.textContent
        }
      }))
      tokens.forEach(function(token) {
        // Should only find tokens that match the desired type
        if (existing_options.indexOf(token.token) < 0) {
          let option = document.createElement("option")
          option.textContent = token.token
          select.append(option)
        }
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
        // Add the draggable handler here
        // Also add any fields or configurable data
        // Anything with blocks (if, loops, etc...)
        //   Have a start and close "card"/cell/row with a sneaky left border so it appears like a big
        //   "C" - allow items to be dropped inside of this. - Act as nested sortable lists
      },
      stop: function(event, ui) {
        let container = $(ui.helper)
        let item = container.find(".list-item")
        let name_wrapper = item.find(".item-name")
        name_wrapper.html("")
        item.addClass("nohover") // Stops highlight on hover
        container.attr("style", "") // Clear draggable styles (position and width/height)

        let [type, datum] = JSON.parse(item.attr("data"))
        item.prepend(`<span class="token">${parser.token()}</span>`)
        item.prepend(`<span class="type">${type}</span>`)

        datum.forEach(function(data) {
          if (Array.isArray(data)) {
            let dropdown = $("<select>")
            data.forEach(function(item) {
              dropdown.append(`<option name="${item}">${item}</option>`)
            })
            name_wrapper.append(dropdown)
          }
          if (data.return) { item.prepend(`<span class="return">=> ${data.return}</span>`) }
          if (data.block) { name_wrapper.append(`
            <span class="select-wrapper">
              <select type="select" class="block-select" unattached=true blocktype="${data.block}">
                ${data.optional && '<option value="">{None}</option>'}
                ${rawVals.indexOf(data.block) >= 0 && '<option value="input">input</option>'}
              </select>
            </span>
          `) }
          if (data == "content") {
            // name_wrapper.append(`<span>${data}</span>`)
            name_wrapper.append('<div class="tasks"></div>')
            initInteractivity()
          } else if (String(data) === data) {
            name_wrapper.append(`<span>${data}</span>`)
          }

          // if (data && typeof data === "object" && !Array.isArray(data)) {
          //
          // }
          resetDropdowns()
        })

        // if (name_wrapper.html() == "") { name_wrapper.html(type) }

        // :content,
        // { block: :num, name: :amount },
        // { num: :second, default: :current },
        // [:seconds, :minutes, :hours, :days, :weeks, :months, :years],

        // for (const [key, value] of Object.entries(data)) {
        //   if (key == "return") {
        //   } else if (key == "") {
        //   }
        // }
      },
    })

    $(".tasks").sortable({
      handle: ".list-item-handle",
      connectWith: ".tasks",
      placeholder: "list-item-placeholder",
      stop: function(event, ui) {
        resetDropdowns()
      }
    })
  }
  initInteractivity()
})


// TODO:
/*
Save blocks as they change - live save? Or only save on "submit"? Maybe save drafts?
Show temp variables in function list
Add sneaky values in function list items that will expand into fields when moved to workspace
*/
