$('.ctr-lists.act-show').ready(function() {

  var list_id = $(".list-container").attr("data-list-id")

  reorderList = function() {
    var ordered_list = $(".list-items .list-item-container").sort(function (a, b) {
      var contentA = parseInt($(a).attr("data-sort-order"))
      var contentB = parseInt($(b).attr("data-sort-order"))
      return (contentA < contentB) ? -1 : ((contentA > contentB) ? 1 : 0)
    })
    $(".list-items").html(ordered_list)
  }

  App.messages = App.cable.subscriptions.create({
    channel: "ListChannel",
    channel_id: "list_" + list_id
  }, {
    connected: function() {
      var url = $(".list-items").attr("data-update-url")
      $.post(url, {}).success(function() { $(".list-error").addClass("hidden") })
    },
    disconnected: function() {
      $(".list-error").removeClass("hidden")
    },
    received: function(data) {
      var updated_list = $(data.list_html)
      var updated_list_ids = updated_list.map(function() { return $(this).attr("data-item-id") })

      var new_items = updated_list.filter(function() {
        var item_id = $(this).attr("data-item-id")
        if (item_id == undefined || item_id.length == 0) { return false }

        var matching_items = $('.list-items .list-item-container[data-item-id=' + item_id + ']')
        if ($(this).attr("data-badge") !== undefined) {
          matching_items.attr("data-badge", "")
        } else {
          matching_items.removeAttr("data-badge")
        }
        matching_items.attr("data-badge") // Update sort order of already found item
        matching_items.attr("data-sort-order", $(this).attr("data-sort-order")) // Update sort order of already found item
        matching_items.find(".item-name").html($(this).find(".item-name").text())
        return matching_items.length == 0
      })
      $('.list-items').append(new_items)

      $(".list-items .list-item-container").each(function() {
        var current_item = $(this)
        var item_id = current_item.attr("data-item-id")
        if (updated_list_ids.toArray().includes(item_id)) {
          // Item exists, uncheck to show it's not deleted
          $(".list-item-container[data-item-id=" + item_id + "] input[type=checkbox]").prop("checked", false)
        } else {
          // Item does not exist, check to show it's deleted.
          $(".list-item-container[data-item-id=" + item_id + "] input[type=checkbox]").prop("checked", true)
        }
      })

      $(".important-list-items").html("")
      $("[data-badge]").each(function() { return $(".important-list-items").append($(this).clone()) })

      reorderList()
    }
  })

})
