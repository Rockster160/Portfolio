import { Roll, Dice } from "./roll"

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
