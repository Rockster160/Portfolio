var defaultParagraphSeparatorString = "defaultParagraphSeparator"
var formatBlock = "formatBlock"
var addPellEventListener =  function(parent, type, listener) { return parent.addEventListener(type, listener) }
var appendChild =       function(parent, child) { return parent.appendChild(child) }
var createElement =     function(tag) { return document.createElement(tag) }
var queryCommandState = function(command) { return document.queryCommandState(command) }
var queryCommandValue = function(command) { return document.queryCommandValue(command) }
// https://developer.mozilla.org/en-US/docs/Web/API/Document/execCommand#Commands
// https://codepen.io/netsi1964/full/QbLLGW
var exec = function(command, value) { return document.execCommand(command, false, value) }

var init = function(settings) {
  var actions = settings.actions
  var classes = settings.classes
  var defaultParagraphSeparator = settings[defaultParagraphSeparatorString] || "div"
  var actionbar = createElement("div")
  actionbar.className = classes.actionbar
  appendChild(settings.element, actionbar)
  var content = settings.element.content = createElement("div")
  content.contentEditable = true
  content.className = classes.content
  content.oninput = function(dict) {
    dict = dict || {}
    target = dict.target || {}
    firstChild = target.firstChild || {}
    if (firstChild && firstChild.nodeType === 3) {
      exec(formatBlock, "<" + defaultParagraphSeparator + ">")
    } else if (content.innerHTML === "<br>") {
      content.innerHTML = ""
    }
    settings.onChange(content.innerHTML)
  }
  content.onkeydown = function(evt) {
    if (evt.key === "Tab") {
      evt.preventDefault()
    } else if (evt.key === "Enter" && queryCommandValue(formatBlock) === "blockquote") {
      setTimeout(function() { exec(formatBlock, "<" + defaultParagraphSeparator + ">") }, 0)
    }
  }
  appendChild(settings.element, content)
  actions.forEach(function(action) {
    var button = createElement("button")
    button.className = classes.button
    button.innerHTML = action.icon
    button.title = action.title
    button.setAttribute("type", "button")
    button.onclick = function() {
      if (!action.result) { return }
      action.result() && content.focus()
    }

    if (action.state) {
      var handler = function() { button.classList[action.state() ? "add" : "remove"](classes.selected) }
      addPellEventListener(content, "keyup",   handler)
      addPellEventListener(content, "mouseup", handler)
      addPellEventListener(button, "click",    handler)
    }

    appendChild(actionbar, button)
  })

  if (settings.styleWithCSS) { exec("styleWithCSS") }
  exec(defaultParagraphSeparatorString, defaultParagraphSeparator)

  return settings.element
}
