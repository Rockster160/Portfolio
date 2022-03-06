$(".ctr-dashboard").ready(function() {
  var single_width = 26

  Text = function() {}
  Text.new = function(data) {
    if (typeof data == "string") {
      this.text = data
      this.width = single_width
    } else if (typeof data == "number") {
      this.width = data
      this.text = ""
    } else if (typeof data == "object") {
      this.width = data.width
      this.text = data.text || ""
    }
  }


  Text.center = function(text, width) {
    width = width || single_width
    var spaces = (width - text.length) / 2

    return " ".repeat(spaces) + text + " ".repeat(spaces)
  }
  Text.justify = function(...args) {
    // var args = [].concat.call(arguments)
    var width = single_width
    if (typeof args[0] == "number") { width = args.shift }

    var text_length = args.reduce(function(a, b) { return (a.length || 0) + b.length })
    var spaces = (width - text_length) / (args.length - 1)

    return args.map(function(text) { return text + " ".repeat(spaces) }).join("").replace(/\s+$/, "")
  }


  Text.prototype.center = function(opt_text) {
    Text.center(this.text || opt_text, this.width)
  }
  Text.prototype.justify = function() {
    // var args = [].concat.call(arguments)
    // this.width, arguments
    // Text.justify.apply(null, this.width, arguments)
  }

  puts = function(...things) {
    things.forEach(function(arg, idx) {
      console.log("out", idx, arg);
    })
  }

  // puts = function() {
  //   var args = [].concat.call(arguments)
  //   args.forEach(function(arg, idx) {
  //     console.log("out", idx, arg);
  //   })
  // }
  // st = function() {
  //   var thing = "thing"
  //   var arr = ["a", "b", "c"]
  //
  //   puts.apply(null, thing, arr)
  // }
})
