$('.ctr-lists.act-show').ready(function() {

  var list_id = $(".list-container").attr("data-list-id");

  reorderList = function() {
    var ordered_list = $('.list-item-container').sort(function (a, b) {
      var contentA = parseInt($(a).attr("data-sort-order"));
      var contentB = parseInt($(b).attr("data-sort-order"));
      return (contentA < contentB) ? -1 : ((contentA > contentB) ? 1 : 0);
    })
    $(".list-items").html(ordered_list);
  };
  reorderList();

  App.messages = App.cable.subscriptions.create({
    channel: "ListChannel",
    channel_id: "list_" + list_id
  }, {
    connected: function() {
      var url = $(".list-items").attr("data-update-url");
      $.post(url, {}).success(function() { $(".list-error").addClass("hidden") });
    },
    disconnected: function() {
      console.log("Disconnected!");
      $(".list-error").removeClass("hidden");
    },
    received: function(data) {
      var updated_list = $(data.list_html);
      var updated_names = updated_list.map(function() { return $(this).find(".item-name").text(); });

      var new_items = updated_list.filter(function() {
        var item_name = $(this).find(".item-name").text();
        if (item_name == undefined || item_name.trim().length == 0) { return false; }

        var existing_items = $('.list-items .list-item-container .item-name:contains("' + item_name + '")').parents(".list-item-container");
        existing_items.attr("data-sort-order", $(this).attr("data-sort-order"));
        existing_items.attr("data-item-id", $(this).attr("data-item-id"));
        return existing_items.length == 0;
      })
      $('.list-items').append(new_items);

      if (new_items.length > 0) {
        $("html, body").animate({scrollTop: $('.list-items').height() + "px"}, 300);
      }

      $(".list-items .list-item-container").each(function() {
        var current_item = $(this);
        var item_name = current_item.find(".item-name").text();
        if (updated_names.toArray().includes(item_name)) {
          // Item exists, uncheck to show it's not deleted
          $(this).find("input[type=checkbox]").prop("checked", false);
        } else {
          // Item does not exist, check to show it's deleted.
          $(this).find("input[type=checkbox]").prop("checked", true);
        }
      })

      reorderList();
    }
  });

})
