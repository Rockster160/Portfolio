$(".ctr-dashboard").ready(function() {
  var single_width = 32

  Text = function() {}
  Text.new = function(data) {
    var text = new Text()
    if (typeof data == "string") {
      text.text = data
      text.width = single_width
    } else if (typeof data == "number") {
      text.width = data
      text.text = ""
    } else if (typeof data == "object") {
      text.width = data.width
      text.text = data.text || ""
    }

    return text
  }
  Text.length = function(data) {
    return Text.new(data)
  }


  Text.center = function(text, width) {
    width = width || single_width
    var spaces = (width - text.length) / 2

    return " ".repeat(spaces) + text + " ".repeat(spaces)
  }
  Text.justify = function(...args) {
    var width = single_width
    if (typeof args[0] == "number") { width = args.shift() }

    var text_length = args.reduce(function(a, b) { return (a.length || 0) + b.length })
    var spaces = (width - text_length) / (args.length - 1)

    return args.map(function(text) { return text + " ".repeat(spaces) }).join("").replace(/\s+$/, "")
  }
  Text.escapeEmoji = function(text) {
    var token = undefined
    do { token = Math.random().toString(36).substr(2) } while(text.includes(token))
    var hold = {}
    var i = 0; token.replace(/<e>.*?<\/e>/ig, function(found, found_idx, full_str) {
      var replace = token + "(" + (i+=1) + ")"
      hold[replace] = found
      return replace
    })
    console.log(hold);

    var emoRegex = new RegExp(emojiPattern, "g")
    var escaped = text.replaceAll(emoRegex, function(found) {
      return "<e>" + found + "</e>"
    })
    // Iterate through hold and put them all back
    return escaped
  }


  Text.prototype.center = function(opt_text) {
    return Text.center(this.text || opt_text, this.width)
  }
  Text.prototype.justify = function(...args) {
    return Text.justify(...[this.width].concat(args))
  }
})
