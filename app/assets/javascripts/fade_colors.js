$(document).ready(function() {

  $("#color-form").submit(function(evt) {
    evt.preventDefault();
    $.get($(this).attr("action"), $(this).serialize()).success(function(data) {
      $('.colors-container').html(data);
      generateColorPreviews();
    })
    return false;
  })

  generateColorPreviews = function() {
    $("color").each(function() {
      $(this).append($("<div>", { class: "color-preview", style: "background-color: " + $(this).text().trim() }));
    })
  }
  generateColorPreviews();

})
