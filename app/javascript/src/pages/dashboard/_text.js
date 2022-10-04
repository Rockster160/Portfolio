import { emoji_regex } from "./emoji_regex"
import { text_height, single_width, cells, registered_cells } from "./vars"

export function Text() {}
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
  spaces = spaces < 0 ? 0 : spaces
  var new_line = " ".repeat(spaces) + text + " ".repeat(spaces)

  return new_line + " ".repeat(width > new_line.length ? 1 : 0)
}
Text.overlay = function(top_text, bottom_text) {
  var length = [top_text.length, bottom_text.length].sort()[1]
  var new_text_arr = []
  var top_chars = top_text.padEnd(length, " ").split(""), bot_chars = bottom_text.padEnd(length, " ").split("")
  for (var i = 0; i < length; i++) {
    var top_char = top_chars[i]
    new_text_arr.push(top_char == " " ? bot_chars[i] : top_char)
  }
  return new_text_arr.join("")
}
Text.justify = function(...args) {
  var width = single_width
  if (typeof args[0] == "number") { width = args.shift() }

  var text_length = Text.clean(args.join("")).length
  var spaces = (width - text_length) / (args.length - 1)
  spaces = spaces < 0 ? 0 : spaces

  let text = args.map(function(text) {
    return text + " ".repeat(spaces)
  }).join("")

  if (spaces > 0) {
    return text.slice(0, -spaces)
  } else {
    return text
  }
}
Text.trunc = function(str, num) {
  str = String(str)
  if (str.length <= num) { return str }

  return str.slice(0, num - 3) + "..."
}
Text.clean = function(text) {
  text = Text.escape(text)
  text = Text.markup(text)
  text = text.replaceAll(/<e>.*?<\/e>/gi, "  ")
  text = text.replaceAll(/<i.*?>.*?<\/i>/gi, "  ")
  text = text.replaceAll(/<img.*?\>/gi, "  ")
  text = text.replaceAll(/<es>.*?<\/es>/gi, " ")
  text = text.replaceAll(/<.*?>/gi, "")

  return text
}
Text.escape = function(text) {
  text = String(text)
  text = Text.escapeHtml(text)

  return text
}
Text.numberedList = function(list) {
  if (typeof list == "string") { list = list.split("\n") }

  return list.map(function(line, idx) {
    // Remove previous numbers, if present
    // Then add the new numbers
    return (idx+1) + ". " + line.replace(/^\d+\. /, "")
  })
}
Text.hr = function() {
  return "[hr]"
}
Text.bold = function(text) {
  if (!text || text.length < 1) { return text }

  return "[bold]" + text + "[/bold]"
}
Text.color = function(color, text) {
  if (!text || text.length < 1) { return text }

  return "[color " + color + "]" + text + "[/color]"
}
Text.bgColor = function(color, text) {
  if (!text || text.length < 1) { return text }

  return "[bg " + color + "]" + text + "[/bg]"
}
Text.img = function(url) {
  if (!url || url.length < 1) { return url }

  return "[img " + url + "]"
}
Text.animate = function(text) {
  if (!text || text.length <= 1) { return text }

  return "[ani \"" + text + "\"]"
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
  return text.replaceAll("<", "&lt;")
}
Text.escapeSpecial = function(text) {
  if (!text || text.length == 0) { return text }
  var allowed_tags = ["e", "es"]
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

  var special_regex = /[^\d\w\s\!\@\#\$\%\^\&\*\(\)\+\=\-\[\]\\\'\;\,\.\/\{\}\|\\\"\:\<\>\?\~\▁\▂\▃\▄\▅\▆\▇\█]+/gi
  var escaped = subbed_text.replaceAll(special_regex, function(found) {
    if (found.charCodeAt(0) == 65039) { return "" }

    return "<es>" + found + "</es>"
  })

  for (const [token, special_char] of Object.entries(hold)) {
    escaped = escaped.replace(token, special_char)
  }
  return escaped
}
Text.escapeEmoji = function(text) {
  // return text
  if (!text || text.length == 0) { return text }

  var token = undefined
  do { token = Math.random().toString(36).substr(2) } while(text.includes(token))

  var hold = {}, i = 0
  var subbed_text = text.replace(/<e>.*?<\/e>/ig, function(found, found_idx, full_str) {
    var replace = token + "(" + (i+=1) + ")"
    hold[replace] = found
    return replace
  })
  subbed_text = subbed_text.replaceAll(emoji_regex, function(found) {
    if (/𐄂|✓/.test(found)) { return found }
    return "<e>" + found + "</e>"
  })

  for (const [token, emoji] of Object.entries(hold)) {
    subbed_text = subbed_text.replace(token, emoji)
  }
  return subbed_text
}
Text.markup = function(text) {
  text = Text.escapeEmoji(text)
  text = Text.escapeSpecial(text)
  text = text.replaceAll(/\[hr]/gi, "-".repeat(single_width))
  text = text.replaceAll(/\[bg (.*?)\](.*?)\[\/bg\]/gi, "<span style=\"background-color: $1;\">$2</span>")
  text = text.replaceAll(/\[color (.*?)\](.*?)\[\/color\]/gi, "<span style=\"color: $1;\">$2</span>")
  text = text.replaceAll(/\[e\](.*?)\[\/e\]/gi, "<e>$1</e>")
  text = text.replaceAll(/\[bold\](.*?)\[\/bold\]/gi, "<b>$1</b>")
  text = text.replaceAll(/\[ani \"(.*?)\"\]/gi, "<textanimate steps=\"$1\"> </textanimate>")
  text = text.replaceAll(/\[img (.*?)\]/gi, "<span class=\"dashboard-img-wrapper\"><img src=\"$1\"\/></span>")
  text = text.replaceAll(/\[ico (.*?)\]/gi, "<i class=\"$1\"></i>")

  return text
}
Text.fixHeight = function(line) {
  return line
}
Text.filterOrder = function(text, options, transformer) {
  if (!text || text.trim().length <= 0) { return options }
  transformer = transformer || function() { return this }
  text = text.toLowerCase().trim()
  var results = {}
  var found = []

  options.forEach(function(option) {
    var word = transformer.call(option)
    var compare = word.toLowerCase().trim()
    var score = 0

    if (compare == text) { score += 1000000 }
    if (compare.indexOf(text) == 0) { score += 100000 }
    if (compare.indexOf(text) >= 0) { score += 10000 }

    var last_idx = -1
    var word_length = word.length
    var bad_word = false
    text.split("").forEach(function(letter) {
      if (bad_word) { return }
      var at = compare.indexOf(letter)
      if (at == -1) {
        bad_word = true
        score = 0
        return
      }

      score += word_length - at
      if (at >= last_idx) { score += word_length - at }
      compare = compare.replace(letter, "")
    })

    if (score > 0) {
       found.push(option)
       results[word] = score
     }
  })

  return found.sort(function(a, b) {
    var aOrder = results[transformer.call(a)]
    var bOrder = results[transformer.call(b)]

    if (aOrder < bOrder) {
      return 1
    } else if (aOrder > bOrder) {
      return -1
    } else { // equal
      return 0
    }
  })
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
