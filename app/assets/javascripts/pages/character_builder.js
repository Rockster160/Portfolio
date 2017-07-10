$(".ctr-little_worlds.act-character_builder").ready(function() {

  var currentCharacter = {}, shouldUpdateForm = true

  // $(".character-form > .options-container").removeClass("hidden")
  //
  // showCurrentScope = function() {
  //   $(".options-container").addClass("hidden")
  //   $(".character-form > .options-container").removeClass("hidden")
  //   $(".current-scope").removeClass("hidden")
  //   $(".current-scope").each(function() {
  //     $('.options-container[data-option-stack="' + $(this).attr("data-option-stack") + '"]').removeClass("hidden")
  //   })
  // }
  //
  // characterWithOption = function(option) {
  //   var character = { gender: undefined, body: undefined, clothing: {} }
  //
  //   if ($(option).hasClass("selected")) {
  //     var optionComponent = componentFromStackStr($(option).attr("data-option-stack"))
  //     character = addComponentToCharacter(character, optionComponent, {override: true})
  //   }
  //
  //   $('.option.selected[data-bottom-stack="true"]').each(function() {
  //     var component = componentFromStackStr($(this).attr("data-option-stack"))
  //     character = addComponentToCharacter(character, component)
  //   })
  //
  //   return character
  // }
  //
  // componentFromStackStr = function(stack_str) {
  //   var pieces = stack_str.split(" ")
  //   return { gender: pieces[0], placement: pieces[1], type: pieces[2], color: pieces[3] }
  // }
  //
  // addComponentToCharacter = function(character, component, options) {
  //   options = options || {}
  //   override = options.override || false
  //
  //   if (override) {
  //     character.gender = component.gender
  //     if (component.placement == "body") {
  //       character.body = component.type
  //     } else {
  //       character.clothing[component.placement] = { type: component.type, color: component.color }
  //     }
  //   } else {
  //     character.gender = character.gender || component.gender
  //     if (component.placement == "body") {
  //       character.body = character.body || component.type
  //     } else {
  //       character.clothing[component.placement] = character.clothing[component.placement] || {}
  //       character.clothing[component.placement].type = character.clothing[component.placement].type || component.type
  //       character.clothing[component.placement].color = character.clothing[component.placement].color || component.color
  //     }
  //   }
  //
  //   return character
  // }
  //
  // selectOptionAndParents = function(option) {
  //   $(option).addClass("selected")
  //   $(option).parents().andSelf().each(function() {
  //     $(this).siblings('.option[data-option-stack="' + $(this).attr("data-option-stack") + '"]').addClass("selected")
  //   })
  // }
  //
  //
  //
  // setNewCharacter = function(selected_option) {
  //   var character = characterWithOption(selected_option)
  //
  //   getNewCharacter({character: character})
  // }
  //
  // getNewCharacter = function(params) {
  //   var url = $(".character-form").attr("data-change-url")
  //
  //   $.post(url, params || {}).success(function(data) {
  //     $(".character").html(data.html)
  //     updateCharacter(data.json)
  //   })
  // }
  //
  // selectOption = function(option) {
  //   if ($(option).attr("data-bottom-stack") == "true") {
  //     $(option).siblings().removeClass("selected")
  //     $(option).toggleClass("selected")
  //     if ($(option).parents('[data-required="true"]').length != 0) { $(option).addClass("selected") }
  //   }
  // }
  //
  // updateScopeForOption = function(option) {
  //   var hadScope = $(option).hasClass("current-scope")
  //
  //   $(".current-scope").removeClass("current-scope")
  //   $(option).parentsUntil(".character-form").each(function() {
  //     $('[data-option-stack="' + $(this).attr("data-option-stack") + '"]').addClass("current-scope")
  //   })
  //
  //   if (!hadScope) { $(option).addClass("current-scope") }
  //   if ($(option).attr("data-bottom-stack") == "true") {
  //     $(option).removeClass("current-scope")
  //     setNewCharacter(option)
  //   }
  //
  //   showCurrentScope()
  // }
  //
  // $(".option").click(function() {
  //   selectOption(this)
  //   updateScopeForOption(this)
  // })
  selectOnlyOption = function(option_selector) {
    $(option_selector).parentsUntil("select").find("option").prop("selected", false).attr("selected", false).removeAttr("selected").each(function() { console.log($(this).val());})
    // $(option_selector).prop("selected", true).change()
    // $(option_selector).attr("selected", "selected").change()
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
  console.log(currentCharacter.clothing)

})
