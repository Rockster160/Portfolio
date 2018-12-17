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
  this.val = parseInt(this.current)
  return this.val
}
Roll.prototype.evaluateDice = function() {
  while(true) {
    var dice = new Dice(this.current)

    if (dice.isValid()) {
      dice.throw()
      this.dice.push(dice)
      this.current = this.current.replace(dice.raw, dice.val)
      this.iterate("Dice(" + dice.raw + ")", dice)
    } else {
      break
    }
  }
}
Roll.prototype.evaluateMath = function() {
  this.current = this.current.replace(/(\d+)(\()/g, "$1*$2")

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

    this.current = this.current.repeatReplace(/\((\d+)\)/, "$1")
    this.iterate("Parens")
  }
}
Roll.prototype.performMath = function(mathScope, operator, description) {
  if (mathScope.indexOf(operator) >= 0) {
    var mathApplied = mathScope.repeatReplace(new RegExp("\\d+\\" + operator + "\\d+"), function(found) {
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
  var die_regex = /(\d*)d(\d*%?)((?:[\-\+]?[!HKL]\d*)*)/i

  if (die_regex.test(raw_str || "")) {
    var matchGroup = die_regex.exec(raw_str)
    this.raw = matchGroup[0]
    this.roll_count = matchGroup[1] == "%" ? 100 : parseInt(matchGroup[1] || 1)
    this.face_count = parseInt(matchGroup[2] || 6)

    this.parseOptions(matchGroup[3])
  }
}
Dice.prototype.parseOptions = function(raw_opts) {
  var exploderRegex = /([\-\+]?)\!(\d*)/i,
  highGroupRegex = /(\-)?[HK](\d*)/i
  lowGroupRegex = /(\-)?[L](\d*)/i

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
  min = min || 1
  max = max || 6
  return Math.floor(Math.random() * max) + min
}
Dice.prototype.throw = function() {
  if (!this.raw) { return }
  this.rolls = []
  var actual_rolls = []
  var roll_value = 0
  var possible_rolls = Array.range(1, this.face_count)
  if (possible_rolls.subtract(this.options.drop_values).length == 0) { this.options.drop_values = [] }
  if (possible_rolls.subtract(this.options.explode_values).length == 0) { this.options.explode_values = [] }
  console.log(this.options);

  for(var i=0; i<this.roll_count; i++) {
    var single_roll = this.rand(1, this.face_count)
    roll_value += single_roll
    this.rolls.push(single_roll.toString())
    actual_rolls.push(single_roll)

    var previous_roll = single_roll
    while (this.options.explode_values.includes(previous_roll)) {
      var previous_roll = this.rand(1, this.face_count)
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
var addToHistory = function(detail, value) {
  if (value == undefined || value.length == 0 || isNaN(value)) { return }
  var row = $("<tr>")
  row.append($("<td>").text(detail))
  row.append($("<td>").text(value))
  $(".history table").prepend(row)
}
var selectFromRandomSet = function(value_set) {
  value_set = value_set.toString()
  var splitter = "\n"
  if (value_set.indexOf(splitter) == -1) { splitter = "|" }
  if (value_set.indexOf(splitter) == -1) { splitter = "," }
  var stripped_set = value_set.split(splitter).map(function(val) {
    return val.trim()
  })
  var rand_val = stripped_set[Math.floor(Math.random() * stripped_set.length)]
  addToHistory(value_set, rand_val)
  $(".result").text(rand_val)
  $(".description").text("")
  return rand_val
}
var rollDiceNotation = function(dice_notation_val) {
  var roll = new Roll(dice_notation_val)
  roll.calculate()
  lastRoll = roll
  if (isNaN(roll.val)) {
    console.log(roll.val);
    $(".result").text("Invalid syntax")
    return
  } else {
    $(".result").text(roll.val)
  }
  addToHistory(roll.raw, roll.val)
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

$(document).on("submit", "#random-generation-form", function(evt) {
  evt.preventDefault()
  if ($("#set").val().trim().length > 0) {
    selectFromRandomSet($("#set").val())
  } else {
    rollDiceNotation($("#dice_notation").val())
  }
  return false
}).on("click", ".submit", function(evt) {
  evt.preventDefault()
  $(this).closest("form").submit()
  return false
})
