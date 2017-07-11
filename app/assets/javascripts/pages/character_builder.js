$(".ctr-little_worlds.act-character_builder").ready(function() {

  var currentCharacter = {}, shouldUpdateForm = true

  selectOnlyOption = function(option_selector) {
    if ($(option_selector).length == 0) { return }
    $(option_selector).parents("select").find("option").prop("selected", false).attr("selected", false).removeAttr("selected")
    $(option_selector).parents("select")[0].selectedIndex = -1
    $(option_selector).attr("selected", "selected").prop("selected", true).change()
  }

  updateFormToMatchCharacter = function() {
    shouldUpdateForm = false
    var gender = currentCharacter.gender, body = currentCharacter.body, clothing = currentCharacter.clothing
    $(".gender-picker").prop("checked", false)
    $('.gender-picker[value="' + gender + '"]').prop("checked", true)
    $(".gender-options").addClass("hidden")
    $("." + gender + "-options").removeClass("hidden")

    $(Object.keys(currentCharacter.clothing)).each(function() {
      var type = this.toString(), article = currentCharacter.clothing[this]
      var article_type = article.type, article_color = article.color
      if (type == "hair" || type == "beard") {
        selectOnlyOption("select[name='character[female][" + type + "]'] option[value='" + article_type + "']")
        selectOnlyOption("select[name='character[male][" + type + "]'] option[value='" + article_type + "']")
        selectOnlyOption("select[name='character[female][" + type + "_color]'] option[value='" + article_color + "']")
        selectOnlyOption("select[name='character[male][" + type + "_color]'] option[value='" + article_color + "']")
      } else {
        selectOnlyOption("select[name='character[female][" + type + "]'] option[value='" + article_color + "']")
        selectOnlyOption("select[name='character[male][" + type + "]'] option[value='" + article_color + "']")
      }
    })

    shouldUpdateForm = true
  }

  updateCharacter = function(character_json, character_html) {
    $("code.json-placeholder p").html(JSON.stringify(character_json, undefined, 4))
    currentCharacter = character_json
    updateFormToMatchCharacter()
    $(".character").html(character_html)
  }

  $(".character-form").disableSelection().change(function(evt) {
    if (shouldUpdateForm) {
      $(this).submit()
    }
  }).submit(function(evt) {
    evt.preventDefault()
    $.post($(this).attr("action"), $(this).serialize(), function(data) {
      updateCharacter(data.json, data.html)
    })
    return false
  })

  $(".arrow-next").click(function(evt) {
    evt.preventDefault()
    var $select = $(this).parent().find("select")
    var selected = $select.children("option:selected").first()
    selectOnlyOption(selected.next("option")[0] || $select.children("option").first())
    return false
  })

  $(".arrow-prev").click(function(evt) {
    evt.preventDefault()
    var $select = $(this).parent().find("select")
    var selected = $select.children("option:selected").first()
    selectOnlyOption(selected.prev("option")[0] || $select.children("option").last())
    return false
  })

  $(".random-clothes").click(function(evt) {
    evt.preventDefault()
    $.post($(".character-form").attr("action"), {random: true}, function(data) {
      updateCharacter(data.json, data.html)
    })
    return false
  })

  currentCharacter = JSON.parse($('.character-form').attr("data-initial-json"))
  updateFormToMatchCharacter()

})
