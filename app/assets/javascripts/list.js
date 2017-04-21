$(document).ready(function() {

  $('.new-list-item-form').submit(function(e) {
    e.preventDefault();
    $.post(this.action, $(this).serialize()).success(function(data) {
      setTimeout(function() {
        $("html, body").animate({scrollTop: $('.list-items').height() + "px"}, 300);
      }, 500);
    })
    $('.new-list-item').val("");
    return false;
  })

  $(document).on('change', '.list-item-checkbox', function() {
    var checkbox = $(this)
    if (this.checked) {
      $.ajax({
        url: $(this).attr("data-destroy-url"),
        type: "DELETE"
      })
    } else {
      $.ajax({
        url: $(this).attr("data-create-url"),
        type: "POST",
        data: {list_item: {name: this.value}, as_json: true},
        success: function(data) {
          new_name = "list_item[" + data.id + "]";
          new_destroy_url = checkbox.attr("data-create-url") + "/" + data.id;
          checkbox.attr("name", new_name);
          checkbox.attr("data-destroy-url", new_destroy_url);
        }
      })
    }

  })

})
