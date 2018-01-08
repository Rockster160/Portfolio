var heldListItem, heldListItemTimer

$(".ctr-lists").ready(function() {

  $(".lists").sortable({
    handle: ".list-item-handle",
    update: function(evt, ui) {
      var list_order = $(this).children().map(function() { return $(this).attr("data-list-id") })
      var url = $(this).attr("data-reorder-url")
      var params = { list_ids: list_order.toArray() }
      $.post(url, params)
    }
  })
  $(".list-items").sortable({
    handle: ".list-item-handle",
    update: function(evt, ui) {
      var list_item_order = $(this).children().filter(function() {
        return !$(this).children("input").prop("checked")
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

  $(document).on("change", ".list-item-checkbox", function(evt) {
    var $itemField = $(this).closest(".list-item-container").find(".list-item-field")
    if (!$itemField.hasClass("hidden")) {
      $(this).prop("checked", false)
      evt.preventDefault()
      return false
    }
    var checkbox = $(this)
    if (this.checked) {
      $.ajax({ type: "DELETE", url: $(this).attr("data-checked-url") })
    } else {
      $.post($(this).attr("data-create-url"), {id: $(this).parents(".list-item-container").attr("data-item-id")})
    }
  })

  $(document).on("blur", ".list-item-field", function() {
    var $container = $(this).closest(".list-item-container")
    var submitUrl = $container.attr("data-item-url")
    var updatedName = $(this).val()

    $.ajax({
      url: submitUrl,
      type: "PUT",
      data: {
        list_item: {
          name: updatedName
        }
      },
      success: function() {
        var $itemName = $container.find(".item-name")
        var $itemField = $container.find(".list-item-field")

        $itemName.val(updatedName)
        $itemName.removeClass("hidden")
        $itemField.addClass("hidden")
      }
    })
  })

  $(document).on("mousedown touchstart", ".list-item-container", function(evt) {
    var evtContainer = $(evt.target).closest(".list-item-container")
    if (evtContainer) {
      heldListItem = evtContainer
      heldListItemTimer = setTimeout(function() {
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

})
