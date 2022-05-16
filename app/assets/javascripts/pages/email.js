$(".ctr-emails.act-index").ready(function() {
  $(document).on("click", ".remote-email", function() {
    if ($(this).hasClass("archived")) {
      $(this).parents(".email-wrapper").remove()
    } else if ($(this).hasClass("read")) {
      $(this).parents(".email-wrapper").find(".email-container").removeClass("unread")
    }
  })
})

$(".ctr-emails.act-new").ready(function() {
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
