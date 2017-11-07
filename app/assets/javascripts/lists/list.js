$('.ctr-lists').ready(function() {

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

  $(".lists").sortable({
    handle: ".list-item-handle",
    update: function(evt, ui) {
      var list_order = $(this).children().map(function() { return $(this).attr("data-list-id") })
      var url = $(this).attr("data-reorder-url")
      var params = { list_ids: list_order.toArray() }
      $.post(url, params)
    }
  })

  $('.new-list-item-form').submit(function(e) {
    e.preventDefault()
    $(window).animate({ scrollTop: window.scrollHeight }, 300)
    $.post(this.action, $(this).serialize())
    $('.new-list-item').val("")
    return false
  })

  $(document).on('change', '.list-item-checkbox', function() {
    var checkbox = $(this)
    if (this.checked) {
      $.ajax({ type: "DELETE", url: $(this).attr("data-checked-url") })
    } else {
      $.post($(this).attr("data-create-url"), {id: $(this).parents(".list-item-container").attr("data-item-id")})
    }
  })

})
