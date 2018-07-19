$(".ctr-svg_editors").ready(function() {
  SVG = {
    raw: null,
    current_id: null
    // function to return pieces
  }

  // TODO: try/catch parsing errors, and instead display an error on screen
  // TODO: Toggle text wrap
  // TODO: Prettify input
  window.onbeforeunload = function() {
    $("#svg-box").html($("#svg-box").html().replace(/\<div\>/g, "").replace(/\<\/div\>/g, "\n"))
    var enteredText = $("#svg-raw").val()
    if (enteredText.length > 0) { localStorage.setItem("svg", enteredText) }
  }
  window.onload = function() {
    var enteredText = localStorage.getItem("svg")
    if (enteredText !== null) { $("#svg-raw").html(enteredText) }
    $("#svg-raw").change()
  }

  lastCursorStart = undefined, lastCursorEnd = undefined;
  function setCursorPosition(element) {
    var el = $(element).get(0)
    if ('selectionStart' in el) {
      lastCursorStart = el.selectionStart
      lastCursorEnd = el.selectionEnd
    } else if ('selection' in document) {
      el.focus()
      var selection = document.selection.createRange()
      var selectionLength = document.selection.createRange().text.length
      selection.moveStart('character', -el.value.length)
      lastCursorStart = el.selectionStart
      lastCursorEnd = el.selectionEnd
    } else {
      setCursorPosition(element.target)
    }
  }

  inject = function(text) {
    var svg_field = $("#svg-raw")
    var select_start = lastCursorStart || svg_field.val().indexOf("</svg>") || svg_field.val().length
    var select_end = lastCursorEnd || svg_field.val().indexOf("</svg>") || svg_field.val().length

    svg_field.val(svg_field.val().substring(0, select_start) + text + svg_field.val().substring(select_end, svg_field.val().length))
    draw()
    svg_field.focus()
  }

  draw = function() {
    var svg_field = $("#svg-raw")
    var text = svg_field.val()
    var spaceFix = text.replace(/\s/g, " ")
    var noJS = spaceFix.replace(/<script/g, "")
    SVG.raw = noJS
    $("#svg-box").html(SVG.raw)
  }

  $("#svg-raw")
    .on("keyup focus click", setCursorPosition)
    .on("blur paste keyup input change", draw)
    .on("keydown", function(evt) {
      if (evt.which == keyEvent("TAB")) {
        var cIndex = this.selectionStart;
        this.value = [this.value.slice(0, cIndex), "  ", this.value.slice(cIndex)].join('');
        event.stopPropagation()
        event.preventDefault()
        this.selectionStart = cIndex + 2
        this.selectionEnd = cIndex + 2
        lastCursorStart = this.selectionStart
        lastCursorEnd = this.selectionEnd
      }
    })

  $(".controls button").click(function(evt) {
    evt.preventDefault()
    var btn_val = this.value
    inject(btn_val)
    if (btn_val.indexOf("|") >= 0) {
      var svg_field = $("#svg-raw")
      var full_text = svg_field.val()
      var line_index = full_text.indexOf(btn_val) + btn_val.indexOf("|")
      svg_field.get(0).selectionStart = line_index
      svg_field.get(0).selectionEnd = line_index + 1
    }
  })

  $(document).on("click", "#svg-box path", function() {
    console.log(this)
    // Display the control points for these
  })
  // TODO: When tab is pressed, if there are only whitespaces to the left, indent 2 more
  // Otherwise, jump between the next "" or ><

})
