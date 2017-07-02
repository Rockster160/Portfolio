$('.ctr-little_worlds.act-character_builder').ready(function() {

  $('.character-form > .options-container').removeClass("hidden")

  showStackForOption = function(option) {
    $(".options-container").addClass("hidden")
    $('.character-form > .options-container').removeClass("hidden")
    if ($(option).hasClass("selected")) {
      $('.options-container[data-option-stack="' + $(option).attr("data-option-stack") + '"]').removeClass("hidden")
    }
    $(option).parents().each(function() {
      $(this).removeClass("hidden").addClass("current-scope")
    })
  }

  getCurrentClothing = function() {
    var clothing_stack = $('.option.selected[data-bottom-stack="true"]').map(function() { return $(this).attr("data-option-stack") })
    return $([]) // FIXME
  }

  setNewClothing = function() {
    var url = $(".character-form").attr("data-change-url"), clothing = getCurrentClothing().toArray()

    $.post(url, {clothing: clothing}).success(function(data) {
      console.log("HTML", data.html);
      console.log("JSON", data.json);
      $('.character').html(data.html)
      // Update `selected` boxes
    })
  }

  $('.option').click(function() {
    $(this).siblings().each(function() {
      $(this).removeClass("selected");
      $(this).children().each(function() {
        if ($(this).attr("data-bottom-stack") != "true") {
          $(this).removeClass("selected");
        }
      })
    })
    $(this).toggleClass("selected")
    if ($(this).attr("data-bottom-stack") == "true") {
      setNewClothing()
    }
    showStackForOption(this)
  })

})
