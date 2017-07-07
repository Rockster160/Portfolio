$('.ctr-little_worlds.act-character_builder').ready(function() {

  var currentCharacter = {}

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
  //     $('.character').html(data.html)
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
  // $('.option').click(function() {
  //   selectOption(this)
  //   updateScopeForOption(this)
  // })
  updateFormToMatchCharacter = function() {
    var gender = currentCharacter.gender, body = currentCharacter.body, clothing = currentCharacter.clothing
    // TODO This should properly update the form based on the json that was returned.
    // Set Gender, toggle visibilty of gender html, etc.
  }

  updateCharacter = function(character_json, character_html) {
    $("code.json-placeholder p").html(JSON.stringify(character_json, undefined, 4))
    currentCharacter = character_json
    updateFormToMatchCharacter()
    $('.character').html(character_html)
  }

  $(".character-form").disableSelection();
  $(".character-form").change(function(evt) {
    $(this).submit()
  })
  $(".character-form").submit(function(evt) {
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
    $select.children("option:selected").prop('selected', false)
    var new_option = selected.next("option") || $select.children("option").first()
    new_option.prop("selected", true)
    $select.change()
    return false
  })

  $(".arrow-prev").click(function(evt) {
    evt.preventDefault()
    var $select = $(this).parent().find("select")
    var selected = $select.children("option:selected").first()
    $select.children("option:selected").prop('selected', false)
    var new_option = selected.prev("option") || $select.children("option").last()
    new_option.prop("selected", true)
    $select.change()
    return false
  })

  $(".random-clothes").click(function(evt) {
    evt.preventDefault()
    $.post($('.character-form').attr("action"), {random: true}, function(data) {
      updateCharacter(data.json, data.html)
    })
    return false
  })

})
