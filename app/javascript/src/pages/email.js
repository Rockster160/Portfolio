import { defaultParagraphSeparatorString,
formatBlock,
addPellEventListener,
appendChild,
createElement,
queryCommandState,
queryCommandValue,
exec,
init } from "../support/pell"

$(document).ready(function() {
  if ($(".ctr-emails.act-index").length == 0) { return }

  $(document).on("click", ".remote-email", function() {
    if ($(this).hasClass("archived")) {
      $(this).parents(".email-wrapper").remove()
    } else if ($(this).hasClass("read")) {
      $(this).parents(".email-wrapper").find(".email-container").removeClass("unread")
    }
  })

  var runSearch = function() {
    var url = new URL(window.location.href)
    url.searchParams.set("q", $(".search").val())
    window.location.href = url.href
  }

  let updateFilters = function() {
    let text = $(".search").val()
    $(".email-filter").each(function() {
      if (text.includes($(this).attr("data-filter"))) {
        $(this).addClass("active")
      } else {
        $(this).removeClass("active")
      }
    })
  }
  updateFilters()

  $(document).on("submit", ".search", function(evt) {
      evt.preventDefault()
      runSearch()
  }).on("keyup", ".search", function(evt) {
    updateFilters()
  }).on("keydown", ".search", function(evt) {
    if (evt.key == "Enter") {
      runSearch()
    }
  }).on("click", ".search-button", function(evt) {
    runSearch()
  }).on("click", ".email-filter", function(evt) {
    let filter_val = $(this).attr("data-filter")

    $(".email-filter[data-filter!='" + filter_val + "']").each(function() {
      let regex = new RegExp($(this).attr("data-filter") + " ?", "i")
      $(".search").val($(".search").val().replace(regex, ""))
      $(this).removeClass("active")
    })

    if ($(this).hasClass("active")) {
      let regex = new RegExp(filter_val + " ?", "i")
      $(".search").val($(".search").val().replace(regex, ""))
    } else {
      $(".search").val(filter_val + " " + $(".search").val())
    }

    updateFilters()
  })

  // Clicking a tag on a row searches for it instead of opening the email.
  $(document).on("click", ".email-tag", function(evt) {
    evt.preventDefault()
    evt.stopPropagation()
    let tag = $(this).attr("data-tag")
    $(".search").val(/\s/.test(tag) ? "tag:\"" + tag + "\"" : "tag:" + tag)
    runSearch()
  })

  let updateSelection = function() {
    let selected = $(".email-select:checked").length
    $(".email-batch-selected-option").text("Selected (" + selected + ")")
    $(".email-batch-target").val(selected > 0 ? "selected" : "page")
    $(".email-select-page").prop("checked", selected > 0 && selected == $(".email-select").length)
  }

  $(document).on("change", ".email-select", updateSelection)
  .on("change", ".email-select-page", function() {
    $(".email-select").prop("checked", $(this).prop("checked"))
    updateSelection()
  })

  $(document).on("click", ".email-batch", function() {
    let bar = $(".email-batch-bar")
    let operation = $(this).attr("data-operation")
    let target = $(".email-batch-target").val()
    let body = { operation: operation }

    if (target == "all") {
      body.all = true
      body.q = bar.attr("data-query")
    } else {
      let checkboxes = target == "selected" ? $(".email-select:checked") : $(".email-select")
      body.ids = checkboxes.map(function() { return $(this).val() }).toArray()
      if (body.ids.length == 0) { return }
    }

    if (operation == "add_tags" || operation == "remove_tags") {
      let tags = window.prompt((operation == "add_tags" ? "Add" : "Remove") + " tags (comma separated)")
      if (!tags || !tags.trim()) { return }
      body.tags = tags
    }

    if (target == "all" && !window.confirm("Apply to all " + bar.attr("data-total") + " matching emails?")) {
      return
    }

    let csrf = document.querySelector("meta[name='csrf-token']")
    fetch(bar.attr("data-batch-url"), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Accept": "application/json",
        "X-CSRF-Token": csrf ? csrf.content : "",
      },
      body: JSON.stringify(body),
    }).then(function(res) {
      return res.json().then(function(json) {
        if (!res.ok) { throw new Error(json.error || "Batch change failed") }
        window.location.reload()
      })
    }).catch(function(err) {
      window.alert(err.message)
    })
  })
})

$(document).ready(function() {
  if ($(".ctr-emails.act-new").length == 0) { return }
  function addRecipients() {
    var emailMatch = $("#temp-emails").val().match(/[^@\s]+@[^@\s]+/)
    if (!emailMatch || emailMatch.length == 0) { return }
    var newEmail = emailMatch[0]

    var tag = $("<span>", {class: "email"}).appendTo($(".entered-emails")).text(newEmail)
    var removeTag = $("<span>", {class: "remove-tag"}).appendTo(tag).text("X")
    $("#temp-emails").val("")
    $("#csv-emails").val($(".entered-emails .email").map(function() {
      return $(this).text().slice(0, -1)
    }).toArray().join(","))
  }

  $(document).on("click", ".remove-tag", function() {
    $(this).parent().remove()
  })

  $("#temp-emails").on("blur", addRecipients).on("keyup", function(evt) {
    if (keyIsPressed(evt, "TAB") || keyIsPressed(evt, "SPACE") || keyIsPressed(evt, "ENTER")) {
      addRecipients()
    }
  })

  $(".email-form-wrapper form input").on("keypress", function(evt) {
    if (keyIsPressed(evt, "ENTER")) {
      evt.preventDefault()
    }
  })

  var editor = init({
    element: document.getElementById('pell'),
    onChange: function(html) {
      $(".html-output").val(html).text(html)
    },
    defaultParagraphSeparator: '',
    styleWithCSS: true,
    actions: [
      {
        icon: '<b>B</b>',
        title: 'Bold',
        state: function() {queryCommandState('bold') },
        result: function() { exec('bold') }
      },
      {
        icon: '<i>I</i>',
        title: 'Italic',
        state: function() {queryCommandState('italic') },
        result: function() { exec('italic') }
      },
      {
        icon: '<u>U</u>',
        title: 'Underline',
        state: function() {queryCommandState('underline') },
        result: function() { exec('underline') }
      },
      {
        icon: '<strike>S</strike>',
        title: 'Strike-through',
        state: function() {queryCommandState('strikeThrough') },
        result: function() { exec('strikeThrough') }
      },
      {
        icon: 'A<b>+</b>',
        title: 'Increase font size',
        state: function() { queryCommandState('fontSize') },
        result: function() { exec('fontSize', Math.min(Number(queryCommandValue('FontSize')) + 1, 7)) }
      },
      {
        icon: 'A<b>-</b>',
        title: 'Decrease font size',
        state: function() { queryCommandState('fontSize') },
        result: function() { exec('fontSize', Math.max(Number(queryCommandValue('FontSize')) - 1, 1)) }
      },
      {
        icon: '|--',
        title: 'Align Left',
        state: function() { queryCommandState('textAlign') },
        result: function() { exec('JustifyLeft') }
      },
      {
        icon: '-|-',
        title: 'Centered',
        state: function() { queryCommandState('textAlign') },
        result: function() { exec('JustifyCenter') }
      },
      {
        icon: '--|',
        title: 'Align Right',
        state: function() { queryCommandState('textAlign') },
        result: function() { exec('JustifyRight') }
      },
      {
        icon: '1.',
        title: 'Ordered List',
        result: function() { exec('insertOrderedList') }
      },
      {
        icon: '&#8226;',
        title: 'Unordered List',
        result: function() { exec('insertUnorderedList') }
      },
      {
        icon: '&#8213;',
        title: 'Horizontal Line',
        result: function() { exec('insertHorizontalRule') }
      },
      {
        icon: '&#128279;',
        title: 'Link',
        result: function() {
          var url = window.prompt('Enter the link URL')
          if (url) { exec('createLink', url) }
        },
      },
      {
        icon: '&#128247;',
        title: 'Image',
        result: function() {
          var url = window.prompt('Enter the image URL')
          if (url) { exec('insertImage', url) }
        }
      },
      {
        icon: '&lt;/&gt;',
        title: 'HTML',
        result: function() {
          var content = window.prompt('Paste in your HTML')
          if (content) { exec('insertHTML', content) }
        }
      }
    ],
    classes: {
      actionbar: "email-actions",
      button:    "email-action-btn default",
      content:   "email-editor",
      selected:  "email-selected"
    }
  })

  editor.content.innerHTML = $("#pell").attr("data-prefilled-mail")
})
