import consumer from "./../channels/consumer"

$(document).ready(function() {
  if ($(".ctr-lists.act-show").length == 0) { return }

  var list_id = $(".list-container").attr("data-list-id")

  reorderList = function() {
    var original_order = $(".list-items .list-item-container").map(function() { return $(this).attr("data-item-id") })
    var ordered_list = $(".list-items .list-item-container").sort(function(a, b) {
      var contentA = parseInt($(a).attr("data-sort-order"))
      if ($(a).find(".list-item-checkbox").prop("checked")) { contentA += 0.1 }
      var contentB = parseInt($(b).attr("data-sort-order"))
      if ($(b).find(".list-item-checkbox").prop("checked")) { contentB += 0.1 }

      return (contentA < contentB) ? 1 : ((contentA > contentB) ? -1 : 0)
    })
    var new_order = ordered_list.map(function() { return $(this).attr("data-item-id") })

    if (!original_order.toArray().eq(new_order.toArray())) {
      $(".list-items").html(ordered_list)
    }
  }

  listWS = consumer.subscriptions.create({
    channel: "ListHtmlChannel",
    channel_id: "list_" + list_id
  }, {
    connected: function() {
      var url = $(".list-items").attr("data-update-url")
      $.post(url, {}).done(function() { $(".list-error").addClass("hidden") })
      // $.rails.refreshCSRFTokens()
    },
    disconnected: function() {
      $(".list-error").removeClass("hidden")
    },
    received: function(data) {
      var updated_list = $(data.list_html)
      var updated_list_ids = updated_list.map(function() { return $(this).attr("data-item-id") })

      $(".item-placeholder").each(function() {
        let item = this
        let name = $(item).find(".item-name").text()

        let new_item = updated_list.find(function() {
          return $(this).find(".item-name").text() == name
        })
        if (new_item) {
          item.replaceWith(new_item)
          // $(item).attr("data-item-id", $(new_item).attr("data-item-id")).removeClass("item-placeholder")
        }
      })

      var new_items = updated_list.filter(function() {
        var item_id = $(this).attr("data-item-id")
        if (item_id == undefined || item_id.length == 0) { return false }

        var matching_items = $('.list-items .list-item-container[data-item-id=' + item_id + ']')
        // Add Config icons
        if ($(this).find(".list-item-config .important").length > 0) {
          if (matching_items.find(".list-item-config .important").length == 0) { matching_items.find(".list-item-config").append($("<div>", {class: "important"})) }
        } else {
          matching_items.find(".list-item-config .important").remove()
        }
        if ($(this).find(".list-item-config .locked").length > 0) {
          if (matching_items.find(".list-item-config .locked").length == 0) { matching_items.find(".list-item-config").append($("<div>", {class: "locked"})) }
        } else {
          matching_items.find(".list-item-config .locked").remove()
        }
        if ($(this).find(".list-item-config .recurring").length > 0) {
          if (matching_items.find(".list-item-config .recurring").length == 0) { matching_items.find(".list-item-config").append($("<div>", {class: "recurring"})) }
        } else {
          matching_items.find(".list-item-config .recurring").remove()
        }
        // Update Category of existing item
        var new_category = $(this).find(".list-item-config .category").text() || ""
        matching_items.find(".list-item-config .category").text(new_category)
        // Update sort order of already found item
        matching_items.attr("data-sort-order", $(this).attr("data-sort-order"))
        // Update name correctly
        matching_items.find(".item-name").html($(this).find(".item-name").html()) // .replace("<", "&lt;")

        // Define whether it's checked or not - Only update if not locked
        if ($(this).find(".list-item-config .locked").length == 0) {
          matching_items.find(".list-item-checkbox").prop("checked", $(this).find(".list-item-checkbox").prop("checked"))
        }
        return matching_items.length == 0
      })
      $(".list-items").append(new_items)

      $(".list-items .list-item-container").each(function() {
        var current_item = $(this)
        var item_id = current_item.attr("data-item-id")
        if ($(this).find(".list-item-config .locked").length > 0) { return }
        if (!updated_list_ids.toArray().includes(item_id)) {
          // Item does not exist, check to show it's deleted.
          $(".list-item-container[data-item-id=" + item_id + "] input[type=checkbox]").prop("checked", true)
        }
      })

      clearRemovedItems()
      setImportantItems()
      reorderList()
    }
  })

})
