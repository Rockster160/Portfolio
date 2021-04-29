$(".ctr-calcs.act-show").ready(function() {
  var $screen = $(".screen"), $prev = $(".prev"), copy = "0", unit = null

  function UnitNum(raw_num) {
    this.raw = raw_num
    this.unit = null

    this.inches = 0
    this.feet = 0
    this.miles = 0

    this.millimeters = 0
    this.meters = 0
    this.centimeters = 0
    this.kilometers = 0

    this.unitless = 0

    this.value = 0

    this.interpret()
  }
  UnitNum.safeFloat = function(str) {
    var num = parseFloat(str)

    if (isNaN(num)) {
      return null
    } else {
      return num
    }
  }
  UnitNum.prototype.parse = function() {
    var num = this.raw
    if (typeof num == "number") { return this.unitless = num }

    var feet_match = num.match(/(\d+)(?:\s*)(?:ft\b|\'|f(?:ee|oo)t\b)/i) || {}
    this.feet = UnitNum.safeFloat(feet_match[1]) || 0
    num = num.replace(feet_match[0], "")

    var inches_match = num.match(/(\d+)(?:\s*)(?:in\b|\"|inch(?:es)?\b)/i) || {}
    this.inches = UnitNum.safeFloat(inches_match[1]) || 0
    num = num.replace(inches_match[0], "")

    var miles_match = num.match(/(\d+)(?:\s*)(?:mi\b|\"|miles?\b)/i) || {}
    this.miles = UnitNum.safeFloat(miles_match[1]) || 0
    num = num.replace(miles_match[0], "")

    var millimeters_match = num.match(/(\d+)(?:\s*)(?:mm\b|millimeters?\b)/i) || {}
    this.millimeters = UnitNum.safeFloat(millimeters_match[1]) || 0
    num = num.replace(millimeters_match[0], "")

    var meters_match = num.match(/(\d+)(?:\s*)(?:m\b|meters?\b)/i) || {}
    this.meters = UnitNum.safeFloat(meters_match[1]) || 0
    num = num.replace(meters_match[0], "")

    var centimeters_match = num.match(/(\d+)(?:\s*)(?:cm\b|centimeters?\b)/i) || {}
    this.centimeters = UnitNum.safeFloat(centimeters_match[1]) || 0
    num = num.replace(centimeters_match[0], "")

    var kilometers_match = num.match(/(\d+)(?:\s*)(?:km\b|kilometers?\b)/i) || {}
    this.kilometers = UnitNum.safeFloat(kilometers_match[1]) || 0
    num = num.replace(kilometers_match[0], "")

    this.unitless = UnitNum.safeFloat(num) || 0
  }
  UnitNum.prototype.interpret = function() {
    this.parse()

    var new_unit = ""
    var num = this.unitless

    var ins = 0
    ins += this.miles * 63360
    ins += this.feet * 12
    ins += this.inches

    var mms = 0
    mms += this.millimeters
    mms += this.meters * 1000
    mms += this.centimeters * 10
    mms += this.kilometers * 1000000

    if (ins == 0 && mms == 0) {
      new_unit = null
      num += ins + (mms * 25.4)
    } else if (ins >= mms) {
      if (this.feet > 0) {
        new_unit = "ft in"
      } else {
        new_unit = "in"
      }

      num += ins + (mms * 25.4)
    } else if (mms > ins) {
      if (this.feet > 0) {
        new_unit = "m mm"
      } else {
        new_unit = "mm"
      }

      num += mms + (ins / 25.4)
    }

    this.unit = new_unit
    this.value = num
  }
  UnitNum.prototype.format = function() {
    // TODO: Split out something like 4'11" 1/16
    var num = this.value
    if (!this.unit) { return num }

    var pieces = []
    switch(this.unit) {
      case "ft in":
        var ft = Math.floor(num / 12)
        num -= ft * 12
        if (ft > 0) { pieces.push(ft.toString() + "\'") }
        if (num > 0) { pieces.push(num.toString() + "\"") }
        return pieces.join(" ")
        break
      case "in":
        return num.toString() + "\""
        break
      case "m mm":
        var m = Math.floor(num / 1000)
        num -= m * 1000
        if (m > 0) { pieces.push(m.toString() + "m") }
        if (num > 0) { pieces.push(num.toString() + "mm") }
        return pieces.join(" ")
        break
      case "mm":
        return num.toString() + "mm"
        break
    }

    console.log("Unit not found: ", unit);
    return num
  }

  function Screen() {}
  Screen.num = function(txt) {
    if (txt == undefined) {
      return $screen.val()
    } else {
      $screen.val(txt)
    }
  }
  Screen.append = function(txt) {
    if (Screen.num() == "0") { Screen.num("") }

    Screen.num(Screen.num() + txt)
  }
  Screen.del = function() {
    Screen.num(Screen.num().slice(0, -1))
  }
  Screen.clear = function() {
    Screen.num("")
  }

  function Prev() {}
  Prev.num = function(txt) {
    if (txt == undefined) {
      return $prev.find(".num").text()
    } else {
      return $prev.find(".num").text(txt)
    }
  }
  Prev.op = function(txt) {
    if (txt == undefined) {
      return $prev.find(".op").text()
    } else {
      return $prev.find(".op").text(txt)
    }
  }
  Prev.clear = function(op) {
    Prev.num("")
    Prev.op("")
  }

  function Calc() {}
  Calc.op = function(op) {
    if (Screen.num() == "") {
      // No op
    } else if (Prev.num() == "") {
      Prev.num((new UnitNum(Screen.num()).format()))
      Screen.clear()
    } else {
      var calc = Screen.num()
      var valA = (new UnitNum(Prev.num()))
      var valB = (new UnitNum(Screen.num()))

      switch(Prev.op()) {
        case "+":
          calc = Calc.add(valA.value, valB.value)
          break;
        case "-":
          calc = Calc.subt(valA.value, valB.value)
          break;
        case "×":
        case "*":
          calc = Calc.mult(valA.value, valB.value)
          break;
        case "÷":
        case "/":
          calc = Calc.div(valA.value, valB.value)
          break;
        case "^":
          calc = Calc.exp(valA.value, valB.value)
          break;
        case "√":
          calc = Calc.sqrt(valA.value, valB.value)
          break;
      }
      var newVal = new UnitNum(calc)
      if (Prev.op() == "") {
        newVal.unit = valB.unit
      } else {
        newVal.unit = valA.unit || valB.unit
      }
      // TODO: Determine new unit by checking existing ones

      Prev.num(newVal.format())
      Screen.clear()
    }

    Prev.op(op)
  }
  Calc.add = function(valA, valB) {
    return valA + valB
  }
  Calc.subt = function(valA, valB) {
    return valA - valB
  }
  Calc.mult = function(valA, valB) {
    return valA * valB
  }
  Calc.div = function(valA, valB) {
    return valA / valB
  }
  Calc.exp = function(valA, valB) {
    return Math.pow(valA, valB)
  }
  Calc.sqrt = function(valA, valB) {
    return Math.sqrt(valA, valB)
  }
  Calc.clear = function() {
    if (Screen.num() == "") {
      Prev.clear()
    } else {
      Screen.clear()
    }
  }
  Calc.copy = function() {
    if (Screen.num().length > 0) {
      copy = Screen.num()
    } else {
      copy = Prev.num()
    }

    $(".clipboard").find("span").text(copy)

    if (copy.length > 0) {
      $(".clipboard").removeClass("hidden")
    } else {
      $(".clipboard").addClass("hidden")
    }
  }
  Calc.equal = function() {
    Calc.op("")
  }

  $(document).on("click", "[data-enter]", function() {
    Screen.append(this.dataset.enter)
  }).on("click", "[data-replace]", function() {
    Screen.num(this.dataset.replace)
  }).on("click", "[data-clear]", function() {
    Calc.clear()
  }).on("click", "[data-del]", function() {
    Screen.del()
  }).on("click", "[data-op]", function() {
    Calc.op(this.dataset.op)
  }).on("click", "[data-cp]", function() {
    Calc.copy()
  }).on("click", "[data-pst]", function() {
    Screen.num(copy)
  }).on("click", "[data-eq]", function() {
    Calc.equal()
  }).on("click", "[data-square]", function() {
    Calc.op("^")
    Screen.num(2)
    Calc.equal()
  }).on("click", "[data-plmn]", function() {
    if (Screen.num()[0] == "-") {
      Screen.num(Screen.num().slice(1, -1))
    } else {
      Screen.num("-" + Screen.num())
    }
  })

  $(document).on("keydown", ".screen", function(evt) {
    switch(evt.key) {
      case "+":
      case "-":
      case "/":
      case "*":
        Calc.op(evt.key)
        evt.preventDefault();
        break;
      case "=":
      case "Enter":
        Calc.equal()
        evt.preventDefault();
        break;
      case "Escape":
      case "Clear":
        Calc.clear()
        evt.preventDefault();
        break;
    }
  })
})
