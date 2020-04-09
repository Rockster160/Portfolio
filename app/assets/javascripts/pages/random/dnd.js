// Helper methods
Array.range = function(min, max) { var all = []; for(var i=min; i<=max; i++) { all.push(i) }; return all }
Array.prototype.sum = function() { if (this.length == 0) { return 0 } else { return this.reduce(function(a, b) { return a + b }) } }
Array.prototype.includes = function(a) { return this.indexOf(a) >= 0 }
Array.prototype.remove = function(a) { var all = this.slice(); if (all.includes(a)) { all.splice(all.indexOf(a), 1) }; return all }
Array.prototype.subtract = function(arr) { var all = this.slice(); for(var i=0; i<arr.length; i++) { all = all.remove(arr[i]) }; return all }
String.prototype.repeatReplace = function(regex, replaceWith) {
  var newStr = this
  while (regex.test(newStr)) {
    if (typeof replaceWith === "function") {
      newStr = newStr.replace(regex, replaceWith.apply(null, regex.exec(newStr)))
    } else {
      newStr = newStr.replace(regex, replaceWith)
    }
  }
  return newStr
}

// Classes
function Roll(str) {
  this.raw = str
  this.current = str
  this.dice = []
  this.iterations = []
  // this.bias = undefined // 0-1, 0.5 means equal chance to roll high
  // this.min = undefined
  // this.max = undefined
  this.val = undefined
}
Roll.prototype.calculate = function() {
  // Scan for unknown characters, imbalanced parens, etc
  if (this.val) { return this.val }
  this.current = (this.current || "").trim().replace(/ *([\+\-\*\/\(\)]+) */g, "$1").replace(/ /g, "+")
  this.iterate("Initial")
  this.evaluateDice()
  this.evaluateMath()
  this.val = parseFloat(this.current)

  return this.val
}
Roll.prototype.evaluateDice = function() {
  while(true) {
    var dice = new Dice(this.current)

    if (dice.isValid()) {
      dice.throw()
      this.dice.push(dice)
      if (this.current.indexOf("..") > 0) {
        this.current = dice.val.toString()
      } else {
        this.current = this.current.replace(dice.raw, dice.val)
      }
      this.iterate("Dice(" + dice.raw + ")", dice)
    } else {
      break
    }
  }
}
Roll.prototype.evaluateMath = function() {
  this.current = this.current.replace(/(\d+(?:\.\d+)?)(\()/g, "$1*$2")

  this.evaluateParens()

  this.performMath(this.current, "**", "Exponents")
  this.performMath(this.current, "*", "Multiplication")
  this.performMath(this.current, "/", "Division")
  this.performMath(this.current, "+", "Addition")
  this.performMath(this.current, "-", "Subtraction")
}
Roll.prototype.evaluateParens = function() {
  while(true) {
    if (this.current.indexOf("(") == -1 || this.current.indexOf(")") == -1) { break }
    var inside = this.current
    var nextClose = inside.indexOf(")")
    inside = inside.slice(0, nextClose)
    var prevOpen = inside.lastIndexOf("(")
    if (prevOpen == -1) { break }
    inside = inside.slice(prevOpen + 1, inside.length)

    inside = this.performMath(inside, "**", "Inner Exponents")
    inside = this.performMath(inside, "*", "Inner Multiplication")
    inside = this.performMath(inside, "/", "Inner Division")
    inside = this.performMath(inside, "+", "Inner Addition")
    inside = this.performMath(inside, "-", "Inner Subtraction")

    this.current = this.current.repeatReplace(/\((\d+(?:\.\d+)?)\)/, "$1")
    this.iterate("Parens")
  }
}
Roll.prototype.performMath = function(mathScope, operator, description) {
  if (mathScope.indexOf(operator) >= 0) {
    var mathApplied = mathScope.repeatReplace(new RegExp("\\d+(?:\.\d+)?\\" + operator + "\\d+(?:\.\d+)?"), function(found) {
      try {
        return eval(found)
      } catch(err) {
        console.log(description + " Error: ", err)
        return 0
      }
    })
    this.current = this.current.replace(mathScope, mathApplied)
    this.iterate(description)
    return mathApplied
  }
  return mathScope
}
Roll.prototype.iterate = function(description, dice) {
  this.iterations.push([description, this.current, dice])
}

function Dice(str) {
  this.raw = undefined
  this.rolls = []
  this.val = undefined
  this.face_count = undefined
  this.roll_count = undefined
  this.dice_min = 1
  this.options = {
    explode_values:  [],
    drop_values:     [],
    drop_high_count: 0,
    drop_low_count:  0
  }

  this.parseDetails(str)
}
Dice.prototype.isValid = function() { return !!this.raw }
Dice.prototype.parseDetails = function(raw_str) {
  if (raw_str.indexOf("..") > -1) {
    var range = raw_str.split("..")

    this.raw = range[0]
    this.roll_count = 1
    this.dice_min = range[0]
    this.face_count = range[1]
  } else {
    var die_regex = /(\d*(?:\.\d+)?)d(\d*(?:\.\d+)?%?)((?:[\-\+]?[!HKL]\d*(?:\.\d+)?)*)/i

    if (die_regex.test(raw_str || "")) {
      var matchGroup = die_regex.exec(raw_str)
      this.raw = matchGroup[0]
      this.roll_count = parseInt(matchGroup[1] || 1)
      this.face_count = matchGroup[2] == "%" ? 100 : parseInt(matchGroup[2] || 6)

      this.parseOptions(matchGroup[3])
    }
  }
}
Dice.prototype.parseOptions = function(raw_opts) {
  var exploderRegex = /([\-\+]?)\!(\d*(?:\.\d+)?)/i,
  highGroupRegex = /(\-)?[HK](\d*(?:\.\d+)?)/i
  lowGroupRegex = /(\-)?[L](\d*(?:\.\d+)?)/i

  if (exploderRegex.test(raw_opts || "")) {
    var explodeGroup = exploderRegex.exec(raw_opts)
    var modifier = explodeGroup[1], counter = parseInt(explodeGroup[2])
    if (modifier == "+") {
      counter = counter || this.face_count

      for(var i=counter; i<=this.face_count; i++) {
        this.options.explode_values.push(i)
      }
    } else if (modifier == "-") {
      counter = counter || 1

      for(var i=counter; i>=1; i--) {
        this.options.explode_values.push(i)
      }
    } else {
      this.options.explode_values.push(counter || this.face_count)
    }
  }
  if (highGroupRegex.test(raw_opts || "")) {
    var dropHighGroup = highGroupRegex.exec(raw_opts)
    var modifier = dropHighGroup[1], counter = parseInt(dropHighGroup[2] || 1)

    if (modifier == "-") {
      counter = counter || this.face_count

      for(var i=counter; i<=this.face_count; i++) {
        this.options.drop_values.push(i)
      }
    } else {
      this.options.drop_high_count = counter
    }
  }
  if (lowGroupRegex.test(raw_opts || "")) {
    var dropLowGroup = lowGroupRegex.exec(raw_opts)
    var modifier = dropLowGroup[1], counter = parseInt(dropLowGroup[2] || 1)

    if (modifier == "-") {
      counter = counter || this.face_count

      for(var i=counter; i>=1; i--) {
        this.options.drop_values.push(i)
      }
    } else {
      this.options.drop_low_count = counter
    }
  }
}
Dice.prototype.rand = function(min, max) {
  min = parseFloat(min || 1)
  max = parseFloat(max || 6)
  var min_decimals = min.toString().split(".")[1] || ""
  var max_decimals = max.toString().split(".")[1] || ""
  var dec_points = min_decimals.length
  if (max_decimals.length > min_decimals.length) { dec_points = max_decimals.length }

  var sig_fig_multiplier = "1"
  for(var i=0; i<dec_points; i++) { sig_fig_multiplier += "0" }
  sig_fig_multiplier = parseInt(sig_fig_multiplier)

  if (dec_points == 0) {
    max += 1
  } else {
    var max_offset = "0."
    for(var i=0; i<dec_points - 1; i++) { max_offset += "0" }
    max += parseFloat(max_offset + "1")
  }

  var rand = (Math.random() * (max - min)) + min
  return Math.floor((rand + Number.EPSILON) * sig_fig_multiplier) / sig_fig_multiplier
}
Dice.prototype.throw = function() {
  if (!this.raw) { return }
  this.rolls = []
  var actual_rolls = []
  var roll_value = 0
  var possible_rolls = Array.range(1, this.face_count)
  if (possible_rolls.subtract(this.options.drop_values).length == 0) { this.options.drop_values = [] }
  if (possible_rolls.subtract(this.options.explode_values).length == 0) { this.options.explode_values = [] }

  for(var i=0; i<this.roll_count; i++) {
    var single_roll = this.rand(this.dice_min, this.face_count)
    roll_value += single_roll
    this.rolls.push(single_roll.toString())
    actual_rolls.push(single_roll)

    var previous_roll = single_roll
    while (this.options.explode_values.includes(previous_roll)) {
      var previous_roll = this.rand(this.dice_min, this.face_count)
      roll_value += previous_roll
      this.rolls.push("+" + previous_roll.toString())
      actual_rolls.push(previous_roll)
    }
    if (this.options.drop_values.includes(single_roll)) {
      roll_value -= single_roll
      this.rolls.push("-" + single_roll.toString())
      actual_rolls.push(single_roll)
    }
  }
  for(var i=0; i<this.options.drop_high_count; i++) {
    var max = Math.max.apply(null, actual_rolls)
    actual_rolls = actual_rolls.remove(max)
    roll_value -= max
    this.rolls.push("-" + max.toString())
    actual_rolls.push("-" + max.toString())
  }
  for(var i=0; i<this.options.drop_low_count; i++) {
    var min = Math.min.apply(null, actual_rolls)
    actual_rolls = actual_rolls.remove(min)
    roll_value -= min
    this.rolls.push("-" + min.toString())
    actual_rolls.push("-" + min.toString())
  }

  this.val = roll_value
  return roll_value
}

// DOM interaction
var percentToDecimal = function(ratio, decimal_places) {
  decimal_places = decimal_places || 2
  return (Math.round(ratio * 10000) / 100) + "%"
}

var graphTrend = function(iteration_count) {
  var rand_str = $("#random_number").val().toString()
  var delimiter = "\n"
  if (rand_str.indexOf(delimiter) == -1) { delimiter = "|" }
  if (rand_str.indexOf(delimiter) == -1) { delimiter = "," }
  var use_set = rand_str.indexOf(delimiter) != -1

  var counter = {
    // This should predefine labels of each possible outcome
    // For dice- sort the keys at the end?
    // For sets- use the given order?
  }
  for(var i=0; i<iteration_count; i++) {
    if (use_set) {
      var rand = selectFromRandomSet(rand_str, delimiter, false)
    } else {
      var rand = rollDiceNotation(rand_str, false)
    }

    counter[rand] = counter[rand] || 0
    counter[rand] += 1
  }

  var max_count = 0, max_key = null
  Object.keys(counter).forEach(function(counter_key, idx) {
    var count = counter[counter_key]
    if (count > max_count) {
      max_key = counter_key
      max_count = count
    }
  })

  $(".description").text("")
  var temp_rows = []
  Object.keys(counter).forEach(function(counter_key, idx) {
    var count = counter[counter_key]

    var row = $("<tr>")
    row.append($("<td>").text(counter_key))
    row.append($("<td>", {style: "width: 100%;"}).html($("<span>", { class: "results-bar" }).css("width", percentToDecimal(count / max_count))))
    row.append($("<td>").text(percentToDecimal(count / iteration_count)))
    temp_rows.push(row)
  })
  var table = $("<table>")
  var sorted_rows = temp_rows.sort(function(a, b) {
    var valA = parseFloat($(a).find("td:first-of-type").text())
    var valB = parseFloat($(b).find("td:first-of-type").text())

    return valA - valB
  })
  sorted_rows.forEach(function(row) {
    table.append(row)
  })

  $(".description").append(table)
  var result_str = max_key + " (" + percentToDecimal(max_count / iteration_count) + ")"
  $(".result").text(result_str)
  addToHistory(iteration_count + "x " + rand_str, result_str)
}

var addToHistory = function(detail, value) {
  if (value == undefined || value.length == 0) { return }
  var row = $("<tr>")
  row.append($("<td>").text(detail))
  row.append($("<td>").text(value))
  $(".history table").prepend(row)
}

var generateRandomNumber = function(str, display, track) {
  str = str.toString()
  var delimiter = "\n"
  if (str.indexOf(delimiter) == -1) { delimiter = "|" }
  if (str.indexOf(delimiter) == -1) { delimiter = "," }
  if (str.indexOf(delimiter) == -1) { return rollDiceNotation(str, display, track) }

  return selectFromRandomSet(str, delimiter, display, track)
}

var selectFromRandomSet = function(value_set, delimiter, display, track) {
  var stripped_set = value_set.split(delimiter).map(function(val) {
    return val.trim()
  })
  var rand_val = stripped_set[Math.floor(Math.random() * stripped_set.length)]

  if (!display) { return rand_val }

  $(".result").text(rand_val)
  $(".description").text("")

  if (track) { addToHistory(stripped_set.join(", "), rand_val) }
}

var removeFromSet = function(val_to_remove) {
  var current_set = $("#random_number").val()
  var delimiter = "\n"
  if (current_set.indexOf(delimiter) == -1) { delimiter = "|" }
  if (current_set.indexOf(delimiter) == -1) { delimiter = "," }
  if (current_set.indexOf(delimiter) == -1) { return $("#random_number").val("") }

  var regex_val = val_to_remove.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  var regex_delim = delimiter.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
  var set_query = new RegExp("(" + regex_val + "\\s*" + regex_delim + "|" + regex_delim + "\\s*" + regex_val + ")")
  var new_set = current_set.replace(set_query, "")

  $("#random_number").val(new_set)
}

var rollDiceNotation = function(dice_notation_val, display, track) {
  var roll = new Roll(dice_notation_val)
  roll.calculate()
  lastRoll = roll

  if (!display) { return roll.val }

  if (isNaN(roll.val)) {
    $(".result").text("Invalid syntax")
    return
  } else {
    $(".result").text(roll.val)
  }
  if (track) { addToHistory(roll.raw, roll.val) }
  $(".description").text("")
  var table = $("<table>")
  for(var i=0; i<roll.iterations.length; i++) {
    var row = $("<tr>")
    var iteration = roll.iterations[i]
    var dice = iteration[2]
    var rolls = dice ? ("(" + dice.val + ") " + dice.rolls.join(" ")) : ""
    row.append($("<td>").text(iteration[0]))
    row.append($("<td>").text(iteration[1]))
    table.append(row)
    table.append($("<tr>").append($("<td>", {colspan: 2}).text(rolls)))
  }
  $(".description").append(table)
}

var cubicBezierFunction = function(axis, distance) {
  var bezierPoints = [
    { "x": 0,   "y": 0 },
    { "x": 0.20,  "y": 1 },
    { "x": 0.50,  "y": 0 },
    { "x": 1, "y": 0 }
  ]
  var X = function(i) { return bezierPoints[i]["x"] }
  var Y = function(i) { return bezierPoints[i]["y"] }
  var A = axis == "y" ? Y : X
  var t = distance

  // X(t) = (1-t)^3 * X0 + 3*(1-t)^2 * t * X1 + 3*(1-t) * t^2 * X2 + t^3 * X3
  return (Math.pow(1-t, 3) * A(0)) + (3*Math.pow(1-t, 2) * t * A(1) + 3*(1-t) * Math.pow(t, 2) * A(2)) + (Math.pow(t, 3) * A(3))
  // return (1 - t) * (1 - t) * A(0) + 2 * (1 - t) * t * A(1) + t * t * A(2)
}

var rollResults = function(str, steps, callback) {
  var step = 1 / steps, ms_multiplier = 200

  var delay = 0
  for(var i=0;i<steps;i++) {
    var next = Math.round(cubicBezierFunction("x", i * step) * ms_multiplier)
    delay += next
    setTimeout(function(t) {
      generateRandomNumber(str, true, t == (steps - 1))
      if (t == (steps - 1) && typeof callback === "function") { callback() }
    }, delay, i)
  }
}

$(document).on("submit", "#random-generation-form", function(evt) {
  evt.preventDefault()
  rollResults($("#random_number").val(), 10)
  return false
}).on("click", ".draw", function(evt) {
  evt.preventDefault()
  rollResults($("#random_number").val(), 10, function() { removeFromSet($(".result").text()) })
  return false
}).on("click", ".graph", function(evt) {
  evt.preventDefault()
  graphTrend(1000)
  return false
}).on("click", ".submit", function(evt) {
  evt.preventDefault()
  $(this).closest("form").submit()
  return false
}).on("click", ".preset", function(evt) {
  $("#random_number").val($(this).attr("data-fill-random-preset"))
  $("#random-generation-form").submit()
})
