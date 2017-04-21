$(document).ready(function() {
  if ($('.list-container').length > 0) {

    reorderList = function() {
      $('.list-item-container').sort(function (a, b) {
        var contentA = parseInt($(a).attr("data-sort-order"));
        var contentB = parseInt($(b).attr("data-sort-order"));
        return (contentA < contentB) ? -1 : (contentA > contentB) ? 1 : 0;
      })
    };
    reorderList();

    App.messages = App.cable.subscriptions.create({
      channel: "ListChannel",
    }, {
      connected: function() {},
      disconnected: function() {},
      received: function(data) {
        var updated_list = $(data.list_html);
        var updated_names = updated_list.map(function() { return $(this).find(".item-name").text(); });

        var new_items = updated_list.filter(function() {
          var item_name = $(this).find(".item-name").text();
          return $('.list-items .list-item-container .item-name:contains("' + item_name + '")').length == 0;
        })
        $('.list-items').append(new_items);

        $(".list-items .list-item-container").each(function() {
          var current_item = $(this);
          var item_name = current_item.find(".item-name").text();
          if (updated_names.toArray().includes(item_name)) {
            $(this).find("input[type=checkbox]").prop("checked", false);
          } else {
            $(this).find("input[type=checkbox]").prop("checked", true);
          }
        })

        reorderList();
      }
    });

  }
})
