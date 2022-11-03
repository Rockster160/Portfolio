import { parser } from "./random/js_chance_generator"
// console.log(parser.token());

$(document).ready(function() {
  if ($(".ctr-tasks.act-index").length == 0) { return }

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
      container.attr("style", "") // Clear draggable styles (position and width/height)

      let [type, datum] = JSON.parse(item.attr("data"))
      item.prepend(`<span class="token">${parser.token()}</span>`)
      item.prepend(`<span class="type">${type}</span>`)

      datum.forEach(function(data) {
        if (data.return) { item.prepend(`<span class="return">=> ${data.return}</span>`) }
        if (data.block) { name_wrapper.append(`<select type="select"><option>task</option></select>`) }
        if (String(data) === data) { name_wrapper.append(`<span>${data}</span>`) }
        // if (data && typeof data === "object" && !Array.isArray(data)) {
        //
        // }
      })

      // if (name_wrapper.html() == "") { name_wrapper.html(type) }

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

  $(".tasks.lists").sortable({
    handle: ".list-item-handle",
  })
})


// TODO:
/*
Save blocks as they change - live save? Or only save on "submit"? Maybe save drafts?
Show temp variables in function list
Add sneaky values in function list items that will expand into fields when moved to workspace
*/
