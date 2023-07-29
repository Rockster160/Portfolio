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
  $(".list-items").sortable({
    handle: ".list-item-handle",
    start: function() {
      $(".list-item-container .list-item-field:not(.hidden)").blur()
    },
    update: function(evt, ui) {
      var max_num = $(this).children().count
      var list_item_order = $(this).children().map(function() {
        $(this).attr("data-sort-order", max_num -= 1)
        return $(this).attr("data-item-id")
      })

      var url = $(this).attr("data-update-url")
      var args = { list_item_order: list_item_order.toArray() }
      $.post(url, args)
    }
  })

  $(".new-list-item-form").submit(function(e) {
    e.preventDefault()
    let input = $(".new-list-item").val()
    if (input == "") { return false }
    if (input == ".clear") {
      clearListActive = true
      $(".new-list-item").val("")
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

    // Clear out
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
        $itemField.val($itemName.text())
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
})
