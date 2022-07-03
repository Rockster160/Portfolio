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
export class Roll {
  constructor(str) {
    this.raw = str
    this.current = str
    this.dice = []
    this.iterations = []
    // this.bias = undefined // 0-1, 0.5 means equal chance to roll high
    // this.min = undefined
    // this.max = undefined
    this.val = undefined
  }
  calculate() {
    // Scan for unknown characters, unbalanced parens, etc
    if (this.val) { return this.val }
    this.current = (this.current || "").trim().replace(/ *([\+\-\*\/\(\)]+) */g, "$1").replace(/ /g, "+")
    this.iterate("Initial")
    this.evaluateDice()
    this.evaluateMath()
    this.val = parseFloat(this.current)

    return this.val
  }
  evaluateDice() {
    while(true) {
      var dice = new Dice(this.current)

      if (dice.isValid()) {
        dice.toss()
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
  evaluateMath() {
    this.current = this.current.replace(/(\d+(?:\.\d+)?)(\()/g, "$1*$2")

    this.evaluateParens()

    this.performMath(this.current, "**", "Exponents")
    this.performMath(this.current, "*", "Multiplication")
    this.performMath(this.current, "/", "Division")
    this.performMath(this.current, "+", "Addition")
    this.performMath(this.current, "-", "Subtraction")
  }
  evaluateParens() {
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
  performMath(mathScope, operator, description) {
    if (mathScope.indexOf(operator) >= 0) {
      var mathApplied = mathScope.repeatReplace(new RegExp("\\d+(?:\.\d+)?\\" + operator + "\\d+(?:\.\d+)?"), function(found) {
        try {
          return (0, eval)(found)
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
  iterate(description, dice) {
    this.iterations.push([description, this.current, dice])
  }
}

export class Dice {
  constructor(str) {
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

  isValid() { return !!this.raw }
  parseDetails(raw_str) {
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
  parseOptions(raw_opts) {
    var exploderRegex = /([\-\+]?)\!(\d*(?:\.\d+)?)/i,
    highGroupRegex = /(\-)?[HK](\d*(?:\.\d+)?)/i,
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
  rand(min, max) {
    min = min || 1
    max = max || 6
    var min_decimals = min.toString().split(".")[1] || ""
    var max_decimals = max.toString().split(".")[1] || ""
    var dec_points = min_decimals.length
    if (max_decimals.length > min_decimals.length) { dec_points = max_decimals.length }
    min = parseFloat(min)
    max = parseFloat(max)

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
  toss() {
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
}
