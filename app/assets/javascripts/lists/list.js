var heldListItem, heldListItemTimer

$(".ctr-lists, .ctr-list_items").ready(function() {

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
      var params = { list_ids: list_order.toArray() }
      $.post(url, params)
    }
  })
  $(".list-items").sortable({
    handle: ".list-item-handle",
    start: function() {
      $(".list-item-container .list-item-field:not(.hidden)").blur()
    },
    update: function(evt, ui) {
      var list_item_order = $(this).children().filter(function() {
        var checked = $(this).children("input").prop("checked")
        var permanent = $(this).find(".list-item-config .locked").length > 0
        var removed = checked && !permanent
        return !removed
      }).map(function() { return $(this).attr("data-item-id") })

      var url = $(this).attr("data-update-url")
      var params = { list_item_order: list_item_order.toArray() }
      $.post(url, params)
    }
  })

  $(".new-list-item-form").submit(function(e) {
    e.preventDefault()
    $(window).animate({ scrollTop: window.scrollHeight }, 300)
    $.post(this.action, $(this).serialize())
    $(".new-list-item").val("")
    return false
  })

  $(document).on("keyup", "input.new-list-item", function() {
    var currentText = $(this).val().toLowerCase().replace(/^( *)|( *)$/g, "").replace(/ +/g, " ")

    if (currentText.length == 0) {
      $(".list-item-container").removeClass("hidden")
    } else {
      $(".list-item-container").each(function() {
        var optionText = $(this).find(".item-name").text().toLowerCase().replace(/^( *)|( *)$/g, "").replace(/ +/g, " ")
        if (optionText.indexOf(currentText) >= 0) {
          $(this).removeClass("hidden")
        } else {
          $(this).addClass("hidden")
        }
      })
    }
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
    
    $.ajax({
      type: "PATCH",
      url: $(this).attr("data-checked-url"),
      data: {
        id: $(this).parents(".list-item-container").attr("data-item-id"),
        list_item: { checked: this.checked }
      }
    })
  }).on("change", ".list-item-options .list-item-checkbox", function(evt) {
    var params = {}
    params.id = $(this).parents(".list-item-options").attr("data-item-id")
    params[$(this).attr("name")] = this.checked

    $.ajax({
      url: $(this).attr("data-submit-url"),
      type: "PATCH",
      data: params
    })
  })

  $(document).on("keyup", ".list-item-field", function(evt) {
    if (evt.which == keyEvent("ENTER")) { $(this).blur() }
  }).on("blur", ".list-item-field", function() {
    var $container = $(this).closest(".list-item-container"),
      submitUrl = $container.attr("data-item-url"),
      updatedName = $(this).val(),
      $itemName = $container.find(".item-name"),
      $itemField = $container.find(".list-item-field")

    $itemName.val(updatedName)
    $itemName.removeClass("hidden")
    $itemField.addClass("hidden")

    $.ajax({
      url: submitUrl,
      type: "PUT",
      data: {
        list_item: {
          name: updatedName
        }
      }
    })
  })

  $(document).on("mousedown touchstart", ".list-item-container", function(evt) {
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
      }, 1000)
    }
  }).on("mousemove", function(evt) {
    if (!heldListItem) { return }
    if (heldListItem.attr("data-item-id") != $(evt.target).closest(".list-item-container").attr("data-item-id")) {
      heldListItem = null
      clearTimeout(heldListItemTimer)
    }
  }).on("mouseup touchend", function(evt) {
    heldListItem = null
    clearTimeout(heldListItemTimer)
  })

  setImportantItems()
})
