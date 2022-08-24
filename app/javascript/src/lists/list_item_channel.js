import consumer from "./../channels/consumer"

$(document).ready(function() {
  if ($(".ctr-list_items.act-edit").length == 0) { return }

  var list_id = $(".list-container").attr("data-list-item-id")

  consumer.subscriptions.create({
    channel: "ListItemChannel",
    channel_id: "list_item_" + list_id
  }, {
    connected: function() {
      var url = $(".list-items").attr("data-update-url")
      $.get(url, {}).done(function() { $(".list-error").addClass("hidden") })
    },
    disconnected: function() {
      $(".list-error").removeClass("hidden")
    },
    received: function(data) {
      var item = data.list_item
      if (!item) { return }
      $(".list-title").text(item.name)
      $(".list-item-checkbox[name='list_item[important]']").prop("checked", item.important)
      $(".list-item-checkbox[name='list_item[permanent]']").prop("checked", item.permanent)
      $(".list-item-options .schedule").text(item.schedule)
      if (item.countdown) {
        $(".list-item-options .countdown").attr("data-next-occurrence", item.countdown)
      } else {
        $(".list-item-options .countdown").removeAttr("data-next-occurrence")
      }
      // Should always show text field here - Update on blur
      $(".list-item-container .item-name").text(item.category || "")
      $(".list-item-container .list-item-field[name='category']").val(item.category || "")
    }
  })
})
