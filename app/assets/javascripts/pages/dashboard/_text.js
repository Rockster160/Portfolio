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
    var spaces = (width - Text.clean(text).length) / 2

    return " ".repeat(spaces) + text + " ".repeat(spaces)
  }
  Text.justify = function(...args) {
    var width = single_width
    if (typeof args[0] == "number") { width = args.shift() }

    var text_length = Text.clean(args.join("")).length
    var spaces = (width - text_length) / (args.length - 1)

    return args.map(function(text) { return text + " ".repeat(spaces) }).join("").replace(/\s+$/, "")
  }
  Text.clean = function(text) {
    return text.replaceAll(/<.*?>/gi, "")
  }
  Text.escape = function(text) {
    text = Text.escapeHtml(text)
    text = Text.escapeEmoji(text)
    text = Text.escapeSpecial(text)

    return text
  }
  Text.numberedList = function(list) {
    if (typeof list == "string") { list = list.split("\n") }

    // Remove previous numbers, if present
    return list.map(function(line, idx) {
      return (idx+1) + ". " + line.replace(/^\d+\. /, "")
    })
  }
  Text.color = function(color, text) {
    return "<color style=\"color: " + color + ";\">" + text + "</color>"
  }
  Text.animate = function(text) {
    if (!text || text.length <= 1) { return text }
    return "<textanimate steps=\"" + text + "\">" + text.slice(0, 1) + "</textanimate>"
  }
  Text.progressBar = function(percent, opts) {
    opts = opts || {}
    opts.open_char     = Text.animate(opts.hasOwnProperty("open_char") ? opts.open_char : "[")
    opts.progress_char = Text.animate(opts.hasOwnProperty("progress_char") ? opts.progress_char : "=")
    opts.current_char  = Text.animate(opts.hasOwnProperty("current_char") ? opts.current_char : ">")
    opts.empty_char    = Text.animate(opts.hasOwnProperty("empty_char") ? opts.empty_char : " ")
    opts.close_char    = Text.animate(opts.hasOwnProperty("close_char") ? opts.close_char : "]")
    opts.post_text     = opts.post_text || ""
    opts.width = (opts.width || single_width)
    
    if (percent <= 1) { opts.current_char = opts.empty_char }
    if (percent >= 99) { opts.current_char = opts.progress_char }
    if (opts.open_char) { opts.width -= 1 }
    if (opts.current_char) { opts.width -= 1 }
    if (opts.close_char) { opts.width -= 1 }
    if (opts.post_text) {
      opts.post_text = " " + opts.post_text
      opts.width -= opts.post_text.length
    }

    var per_px = (100 / opts.width)
    var progress = Math.round(percent / per_px)
    progress = progress > 0 ? progress : 0
    var remaining = opts.width - progress
    remaining = remaining > 0 ? remaining : 0

    return [
      opts.open_char,
      opts.progress_char.repeat(progress),
      opts.current_char,
      opts.empty_char.repeat(remaining),
      opts.close_char,
      opts.post_text,
    ].join("")
  }
  Text.escapeHtml = function(text) {
    var allowed_tags = [
      "e",
      "es",
      "color",
      "textanimate",
    ]
    var joined_tags = allowed_tags.map(function(tag) { return tag + "\\b|\\/" + tag + "\\b"  }).join("|")
    var html_regex = new RegExp("\\<\\/?([^(" + joined_tags + ")])", "gi");
    text = text.replaceAll(html_regex, "&lt;$1")

    return text
  }
  Text.escapeEmoji = function(text) {
    if (!text || text.length == 0) { return text }

    var token = undefined
    do { token = Math.random().toString(36).substr(2) } while(text.includes(token))

    var hold = {}, i = 0
    var subbed_text = text.replace(/<e>.*?<\/e>/ig, function(found, found_idx, full_str) {
      var replace = token + "(" + (i+=1) + ")"
      hold[replace] = found
      return replace
    })

    var emoRegex = new RegExp(emojiPattern, "g")
    var escaped = subbed_text.replaceAll(emoRegex, function(found) {
      return "<e>" + found + "</e>"
    })

    for (const [token, emoji] of Object.entries(hold)) {
      escaped = escaped.replace(token, emoji)
    }
    return escaped
  }
  Text.escapeSpecial = function(text) {
    if (!text || text.length == 0) { return text }
    var allowed_tags = [
      "e",
      "es",
      "textanimate",
    ]
    var joined_tags = allowed_tags.map(function(tag) { return "<" + tag + "\\b.*?>.*?</" + tag + ">" }).join("|")

    var token = undefined
    do { token = Math.random().toString(36).substr(2) } while(text.includes(token))

    var hold = {}, i = 0
    var joined_regex = new RegExp("(" + joined_tags + ")", "gi")
    var subbed_text = text.replaceAll(joined_regex, function(found, found_idx, full_str) {
      var replace = token + "(" + (i+=1) + ")"
      hold[replace] = found
      return replace
    })

    var special_regex = /[^\d\w\s\!\@\#\$\%\^\&\*\(\)\+\=\-\[\]\\\'\;\,\.\/\{\}\|\\\"\:\<\>\?\~]+/gi
    var escaped = subbed_text.replaceAll(special_regex, function(found) {
      if (found.charCodeAt(0) == 65039) { return "" }

      return "<es>" + found + "</es>"
    })

    for (const [token, special_char] of Object.entries(hold)) {
      escaped = escaped.replace(token, special_char)
    }
    return escaped
  }


  Text.prototype.center = function(opt_text) {
    return Text.center(this.text || opt_text, this.width)
  }
  Text.prototype.justify = function(...args) {
    return Text.justify(...[this.width].concat(args))
  }

  setInterval(function() {
    $("textanimate").each(function() {
      var ele = $(this)
      var steps = ele.attr("steps").split("")
      var current_step = parseInt(ele.attr("step") || 0)
      var next_step = current_step + 1
      if (next_step > steps.length - 1) { next_step = 0 }

      ele.text(steps[next_step]).attr("step", next_step)
    })
  }, 100)
})
