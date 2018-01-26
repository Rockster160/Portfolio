$(".ctr-svg_editors").ready(function() {
  SVG = {
    raw: null,
    current_id: null
    // function to return pieces
  }

  $("#svg-raw").on("blur paste keyup input change", function() {
    var enteredText = this.textContent || this.innerText,
      spaceFix = enteredText.replace(/\s/g, " "),
      noJS = spaceFix.replace(/<script/g, "")
    // $("#svg-raw").html($("#svg-raw").html().replace(/^([^\<]*?)\n/g, "<div>$1</div>"))
    SVG.raw = spaceFix
    $("#svg-box").html(SVG.raw)
  })

  $(document).on("click", "#svg-box path", function() {
    console.log(this);
    // Display the control points for these
  })

  // TODO: try/catch parsing errors, and instead display an error on screen
  // TODO: Toggle text wrap
  // TODO: Prettify input
})

window.onbeforeunload = function() {
  $("#svg-box").html($("#svg-box").html().replace(/\<div\>/g, "").replace(/\<\/div\>/g, "\n"))
  var inputElement = document.getElementById("svg-raw")
  var enteredText = (inputElement.textContent || inputElement.innerText)
  if (enteredText !== null && enteredText.length > 0) { localStorage.setItem("svg", enteredText) }
}
window.onload = function() {
  var enteredText = localStorage.getItem("svg")
  if (enteredText !== null) { document.getElementById("svg-raw").textContent = enteredText }
  $("#svg-raw").change()
}
