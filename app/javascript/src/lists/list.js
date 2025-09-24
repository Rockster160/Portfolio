var heldListItem, heldListItemTimer, clearListItemTimer, clearListActive

function parseParams(str) {
  var pieces = str.split("&"), data = {}, i, parts;
  for (i = 0; i < pieces.length; i++) {
    parts = pieces[i].split("=");
    if (parts.length < 2) {
      parts.push("");
    }
    data[decodeURIComponent(parts[0])] = decodeURIComponent(parts[1]);
  }
  return data;
}
params = parseParams(window.location.search.slice(1))
clearListActive = params.clear == "1"
// import listWS from "./list_channel"

$(document).on("keyup", "input.filterable", function() {
  var currentText = $(this).val().toLowerCase().replace(/^( *)|( *)$/g, "").replace(/ +/g, " ")

  if (currentText.length == 0) {
    $(".list-item-container").removeClass("hidden")
  } else {
    $(".list-item-container").each(function() {
      var option_with_category = $(this).find(".list-item-config .category").text() + " " + $(this).find(".item-name").text()
      var optionText = option_with_category.toLowerCase().replace(/^( *)|( *)$/g, "").replace(/ +/g, " ")
      if (optionText.indexOf(currentText) >= 0) {
        $(this).removeClass("hidden")
      } else {
        $(this).addClass("hidden")
      }
    })
  }
})

clearRemovedItems = function() {
  if (clearListActive) {
    clearTimeout(clearListItemTimer)
    clearListItemTimer = setTimeout(function() {
      $(".list-item-checkbox:checked").each(function() {
        $(this).closest(".list-item-container").remove()
      })
    }, 3000)
  }
}

let __dragPos = { x: 0, y: 0 }
function __trackPointer(e) {
  let t = e.touches && e.touches[0]
  __dragPos.x = (t ? t.pageX : e.pageX)
  __dragPos.y = (t ? t.pageY : e.pageY)
}

function __maybeSnapToEdges($item) {
  let $root = $(".list-items")
  if ($root.length == 0) return false

  let r = $root[0].getBoundingClientRect()
  let y = __dragPos.y - window.scrollY
  let threshold = 24

  if (y < r.top + threshold) {
    $item.detach().prependTo($root)
    return true
  }
  if (y > r.bottom - threshold) {
    $item.detach().appendTo($root)
    return true
  }
  return false
}

function __maybeSnapIntoEmptySection($item) {
  let cx = __dragPos.x - window.scrollX
  let cy = __dragPos.y - window.scrollY
  let el = document.elementFromPoint(cx, cy)
  let $tab = $(el).closest(".list-section-tab")
  if ($tab.length == 0) return false

  let $bucket = $tab.children(".section-items").first()
  if ($bucket.children(".list-item-container").length == 0) {
    $item.detach().prependTo($bucket)
    return true
  }
  return false
}

function buildFullOrder() {
  let out = []
  $(".list-items").children(".list-item-container, .list-section-tab").each(function() {
    let $el = $(this)
    if ($el.is(".list-item-container")) {
      out.push({ type: "item", id: $el.data("itemId") })
      return
    }
    let sid = $el.data("sectionId")
    let items = $el.find("> .section-items > .list-item-container")
      .map(function() { return { type: "item", id: $(this).data("itemId") } })
      .toArray()
    out.push({ type: "section", id: sid, items })
  })
  return out
}

function debounce(fn, ms) {
  let t
  return function() { clearTimeout(t); t = setTimeout(fn, ms) }
}
const persistLater = debounce(function() {
  let url = $(".list-items").data("updateUrl")
  if (!url) return
  $.ajax({
    url,
    type: "POST",
    data: JSON.stringify({ ordered: buildFullOrder() }),
    contentType: "application/json; charset=UTF-8",
    dataType: "json"
  })
}, 60)

function initSortables() {
  $(".list-items, .section-items").each(function() {
    if ($(this).data("ui-sortable")) $(this).sortable("destroy")
  })

  $(".list-items, .section-items").sortable({
    connectWith: ".list-items, .section-items",
    items: "> .list-item-container",
    handle: ".list-item-handle",
    cancel: "input,textarea,button,.list-item-field,.list-item-category-field",
    tolerance: "pointer",
    // helper: "clone", appendTo: "body",
    zIndex: 10000,
    forcePlaceholderSize: true,
    placeholder: "drag-placeholder",

    start: function(e, ui) {
      $(".list-item-container .list-item-field:not(.hidden)").blur()
      beginDragUX()
      $(document).on("mousemove touchmove", __trackPointer)
      ui.placeholder.height(ui.item.outerHeight())
    },

    update: function(evt, ui) {
      // honor "drop after section" stripe intent (from earlier patch)
      let $item = $(ui.item)
      let afterSid = $item.data("__dropAfterSection")
      if (afterSid) {
        let $tab = $('.list-section-tab[data-section-id="' + afterSid + '"]')
        $item.detach().insertAfter($tab)
        $item.removeData("__dropAfterSection")
      }
      if (ui.sender) return
      persistLater()
    },

    receive: function() { persistLater() },

    stop: function(e, ui) {
      let $item = $(ui.item)

      // snap to edges if pointer is above top / below bottom of root
      if (!__maybeSnapToEdges($item)) {
        // if we dropped on a section header and it’s empty, drop "into" it
        __maybeSnapIntoEmptySection($item)
      }

      $(document).off("mousemove touchmove", __trackPointer)
      document.dispatchEvent(new Event("lists:persist-order"))
      endDragUX()
    }
  })
}

function beginDragUX() {
  if (!$(".list-items").children(".__top-drop").length) {
    let $top = $('<div class="__top-drop" aria-hidden="true">').prependTo(".list-items")
    $top.droppable({
      accept: ".list-item-container",
      tolerance: "pointer",
      greedy: true,
      hoverClass: "section-outside-hover",
      drop: function(evt, ui) {
        ui.draggable.detach().insertAfter($top) // insert at top
        document.dispatchEvent(new Event("lists:persist-order"))
        document.dispatchEvent(new Event("lists:rebind"))
      }
    })
  }
  // make tabs droppable only during a drag
  $(".list-section-tab").each(function() {
    let $tab = $(this)
    if ($tab.data("__tabDropInit")) return
    $tab.data("__tabDropInit", true)

    $tab.droppable({
      accept: ".list-item-container",
      tolerance: "pointer",
      greedy: true,
      hoverClass: "section-hover",
      drop: function(evt, ui) {
        let $bucket = $tab.children(".section-items").first()
        ui.draggable.detach().prependTo($bucket)
        document.dispatchEvent(new Event("lists:persist-order"))
        document.dispatchEvent(new Event("lists:rebind"))
      }
    })
    $(".section-items:empty").addClass("__empty-target")
  })

  // create a temporary "below section" drop zone after each tab
  $(".list-section-tab").each(function() {
    let $tab = $(this)
    if ($tab.next().hasClass("__below-drop")) {
      $tab.next().addClass("__active")
      return
    }

    let $dz = $('<div class="__below-drop __active" aria-hidden="true">')
      .insertAfter($tab)

    $dz.droppable({
      accept: ".list-item-container",
      tolerance: "pointer",
      greedy: true,
      hoverClass: "section-outside-hover",
      drop: function(evt, ui) {
        // mark intent: place after this section (outside)
        ui.draggable.data("__dropAfterSection", $tab.data("sectionId"))
      }
    })
  })
}

function endDragUX() {
  // remove temporary spacing and dropzones
  $(".section-items").removeClass("__drag-open")
  $(".list-section-tab").each(function() {
    let $tab = $(this)
    if ($tab.data("ui-droppable")) { $tab.droppable("destroy") }
    $tab.removeData("__tabDropInit")
  })
  $(".__top-drop").each(function() {
    let $el = $(this)
    if ($el.data("ui-droppable")) $el.droppable("destroy")
    $el.remove()
  })
  $(".__below-drop").each(function() {
    let $dz = $(this)
    if ($dz.data("ui-droppable")) { $dz.droppable("destroy") }
    $dz.remove()
  })
  $(".section-items").removeClass("__drag-open __empty-target")
}

function initDroppables() {
  // drop on the tab puts item at top of its section
  $(".list-section-tab").each(function() {
    let $tab = $(this)
    if ($tab.data("droppableInit")) return
    $tab.data("droppableInit", true)

    $tab.droppable({
      accept: ".list-item-container",
      tolerance: "pointer",
      greedy: true,
      hoverClass: "section-hover",
      drop: function(evt, ui) {
        let $bucket = $tab.children(".section-items").first()
        ui.draggable.detach().prependTo($bucket)
        document.dispatchEvent(new Event("lists:persist-order"))
        // rebind because DOM moved
        document.dispatchEvent(new Event("lists:rebind"))
      }
    })
  })

  // create a slim dropzone *after* each section to drop outside/below it
  $(".list-section-tab").each(function() {
    let $tab = $(this)
    if ($tab.next().hasClass("section-outside-drop")) return

    let sid = $tab.data("sectionId")
    let $dz = $('<div class="section-outside-drop" aria-hidden="true">')
      .attr("data-section-id", sid)
      .insertAfter($tab)

    $dz.droppable({
      accept: ".list-item-container",
      tolerance: "pointer",
      greedy: true,
      hoverClass: "section-outside-hover",
      drop: function(evt, ui) {
        // insert immediately after the section tab (outside the section)
        ui.draggable.detach().insertAfter($tab)
        document.dispatchEvent(new Event("lists:persist-order"))
        document.dispatchEvent(new Event("lists:rebind"))
      }
    })
  })
}

$(document).ready(function() {
  if ($(".ctr-lists, .ctr-list_items").length == 0) { return }

  setImportantItems = function() {
    $(".important-list-items").html("")
    $(".list-item-config .important").closest(".list-item-container").each(function() {
      return $(".important-list-items").append($(this).clone())
    })
  }

  $(".lists").sortable({
    handle: ".list-item-handle",
    start: function() {
      $(".list-item-container .list-item-field:not(.hidden)").blur()
    },
    update: function(evt, ui) {
      var list_order = $(this).children().map(function() { return $(this).attr("data-list-id") })
      var url = $(this).attr("data-reorder-url")
      var args = { list_ids: list_order.toArray() }
      $.post(url, args)
    }
  })
  initSortables()
  initDroppables()

  $(".new-list-item-form").submit(function(e) {
    e.preventDefault()
    let input = $(".new-list-item").val()

    if (input == "") {
      $(".new-list-item").val("")
      return false
    }
    if (input == ".clear") {
      $(".new-list-item").val("")
      clearListActive = true
      return false
    }
    if (input == ".reload") {
      $(".new-list-item").val("")
      return window.location.reload(true)
    }
    $(window).animate({ scrollTop: window.scrollHeight }, 300)
    $.post(this.action, $(this).serialize())

    // Add a placeholder
    let template = document.getElementById("list-item-template")
    let clone = template.content.firstElementChild.cloneNode(true)
    clone.querySelector(".item-name").innerText = input
    clone.classList.add("item-placeholder")
    $(".list-items").prepend(clone)

    $(".new-list-item").val("")
    return false
  })

  $(document).on("change", ".list-item-container .list-item-checkbox", function(evt) {
    var $itemField = $(this).closest(".list-item-container").find(".list-item-field")
    if (!$itemField.hasClass("hidden")) {
      $(this).prop("checked", false)
      evt.preventDefault()
      return false
    }
    var item_id = $(this).closest("[data-item-id]").attr("data-item-id")
    $(".list-item-container[data-item-id=" + item_id + "] input[type=checkbox]").prop("checked", this.checked)
    listWS.perform("receive", { list_item: { id: item_id, checked: this.checked } })
    clearRemovedItems()
  }).on("change", ".list-item-options .list-item-checkbox", function(evt) {
    var args = {}
    args.id = $(this).parents(".list-item-options").attr("data-item-id")
    args[$(this).attr("name")] = this.checked

    $.ajax({
      url: $(this).attr("data-submit-url"),
      type: "PATCH",
      data: args
    })
  })

  $(document).on("keyup", ".list-item-field, .list-item-category-field", function(evt) {
    if (evt.which == keyEvent("ENTER")) { $(this).blur() }
  }).on("click", ".category-btn", function(evt) {
    var evtContainer = $(evt.target).closest(".list-item-container")
    if (evtContainer) {
      evt.stopPropagation()
      if (evtContainer.hasClass("ui-sortable-helper")) { return }
      var $itemName = evtContainer.find(".item-name")
      var $itemCategory = evtContainer.find(".list-item-config .category")
      var $itemField = evtContainer.find(".list-item-category-field")
      $itemName.addClass("hidden")
      $itemField.val($itemCategory.text())
      $itemField.removeClass("hidden")
      setTimeout(function() { $itemField.focus() }, 0)
    }
  }).on("blur", ".list-item-field, .list-item-category-field", function() {
    var $container = $(this).closest(".list-item-container"),
      submitUrl = $container.attr("data-item-url"),
      updatedName = $(this).val(),
      $itemName = $container.find(".item-name"),
      $itemField = $(this),
      args = {}

    $itemName.data().raw = updatedName
    $itemName.val(updatedName)
    $itemName.removeClass("hidden")
    $itemField.addClass("hidden")

    var fieldName = $(this).attr("name")
    args.list_item = {}
    args.list_item[fieldName] = updatedName

    $.ajax({
      url: submitUrl,
      type: "PUT",
      data: args
    })
  })

  $(document).on("mousedown touchstart", ".list-item-container[data-editable]", function(evt) {
    var evtContainer = $(evt.target).closest(".list-item-container")
    if (evtContainer) {
      heldListItem = evtContainer
      heldListItemTimer = setTimeout(function() {
        if (evtContainer.hasClass("ui-sortable-helper")) { return }
        var $itemName = heldListItem.find(".item-name")
        var $itemField = heldListItem.find(".list-item-field")
        $itemName.addClass("hidden")
        $itemField.val($itemName.data().raw)
        $itemField.removeClass("hidden")
        $itemField.focus()
      }, 700)
    }
  }).on("mousemove scroll", function(evt) {
    if (!heldListItem) { return }
    if (heldListItem.attr("data-item-id") != $(evt.target).closest(".list-item-container").attr("data-item-id")) {
      heldListItem = null
      clearTimeout(heldListItemTimer)
    }
  }).on("mouseup touchend", function(evt) {
    $(".list-item-field:not(.hidden)").focus()
    heldListItem = null
    clearTimeout(heldListItemTimer)
  })

  setImportantItems()
  document.addEventListener("lists:rebind", function() {
    initSortables()
    initDroppables()
  })
})
