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
    SVG.raw = spaceFix
    $("#svg-box").html(SVG.raw)
  })
  // TODO: try/catch parsing errors, and instead display an error on screen
  // TODO: Toggle text wrap
  // TODO: Prettify input
})

window.onbeforeunload = function() {
  var inputElement = document.getElementById("svg-raw")
  var enteredText = (inputElement.textContent || inputElement.innerText)
  if (enteredText !== null && enteredText.length > 0) { localStorage.setItem("svg", enteredText) }
}
window.onload = function() {
  var enteredText = localStorage.getItem("svg")
  if (enteredText !== null) { document.getElementById("svg-raw").textContent = enteredText }
  $("#svg-raw").change()
}
