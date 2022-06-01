$(document).ready(function() {
  if ($(".ctr-colors.act-index").length == 0) { return }

  $('.colorpicker').spectrum({
    change: function(spectrumColor) {
      $(this).parents(".form-field").find(".color-field").val(spectrumColor.toHexString().toUpperCase());
    }
  })

  $('.color-field').blur(function() {
    $(this).parents(".form-field").find(".colorpicker").spectrum("set", $(this).val());
  })

  $('.random-color').click(function(evt) {
    evt.preventDefault();
    var rand_str = ["#"], possible = "0123456789ABCDEF"
    for (var i=0; i<6; i++) {
      var chosen = possible.charAt(Math.floor(Math.random() * possible.length));
      rand_str.push(chosen);
    }
    $(this).parents('.form-field').children(".color-field").val(rand_str.join(""));
    $(this).parents('.form-field').children(".color-field").blur();
    $("#color-form").submit();
    return false;
  })

  $("#color-form").submit(function(evt) {
    evt.preventDefault();
    $.get($(this).attr("action"), $(this).serialize()).done(function(data) {
      $('.colors-container').html(data);
      generateColorPreviews();
    })
    return false;
  })

  generateColorPreviews = function() {
    $("color").each(function() {
      $(this).css({ "background-color": $(this).text().trim() });
    })
  }
  $('.color-field').blur()
  generateColorPreviews();

})
