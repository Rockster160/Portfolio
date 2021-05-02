$(".ctr-calcs.act-show").ready(function() {
  var $screen = $(".screen"), $prev = $(".prev"), copy = "0"

  function Fraction(str) {
    if (typeof str == "number") {
      str = str.toString()
      if (str == "NaN") { str = "0" }
    } else if (typeof str == "string") {
      // No op
    } else if (typeof str == "object" && str.constructor.name == "Fraction") {
      return str.simplify()
    } else if (isNaN(str)) {
      str = "0"
    } else {
      console.log("Invalid Fraction: ", typeof str, str);
    }

    this.raw = str

    var frac = str.split(/[÷%]/).filter(Boolean) // Removes blanks
    var mix = frac[0].split(" ").filter(Boolean)

    if (mix.length > 1) {
      this.whole = parseFloat(mix[0])
      this.numerator = parseFloat(mix[1])
    } else {
      this.whole = 0
      this.numerator = parseFloat(mix[0])
    }

    this.denominator = parseFloat(frac[1] || 1)

    this.simplify()
  }
  Fraction.isA = function(str) {
    return (typeof str == "object" && str.constructor.name == "Fraction")
  }
  Fraction.prototype.simplify = function() {
    var num = this.numerator, den = this.denominator
    var overflow = Math.floor(num / den)

    num = num - (overflow * den)

    var gcd = Fraction.gcd(num, den)

    this.whole = this.whole + overflow
    this.denominator = den / gcd
    this.numerator = num / gcd

    return this
  }
  Fraction.gcd = function(n1, n2) {
    if (n2 == 0) { return n1 }

    return Fraction.gcd(n2, n1 % n2);
  }
  Fraction.toFrac = function(num) {
    return new Fraction(num)
  }
  Fraction.prototype.toString = function() {
    var frac
    if (this.denominator == 0 || this.numerator == 0) {
      frac = ""
    } else {
      frac = this.numerator + "÷" + this.denominator
    }

    return [this.whole, frac].filter(Boolean).join(" ").trim()
  }
  Fraction.prototype.decimal = function() {
    return this.wholeNumerator() / this.denominator
  }
  Fraction.prototype.wholeNumerator = function() {
    return this.numerator + (this.whole * this.denominator)
  }
  Fraction.add = function(frac1, frac2) {
    frac1 = Fraction.toFrac(frac1)
    frac2 = Fraction.toFrac(frac2)

    var new_numerator = (frac1.wholeNumerator() * frac2.denominator) + (frac2.wholeNumerator() * frac1.denominator)
    var new_denominator = frac1.denominator * frac2.denominator

    return (new Fraction(new_numerator + "÷" + new_denominator)).simplify()
  }
  Fraction.subtract = function(frac1, frac2) {
    frac1 = Fraction.toFrac(frac1)
    frac2 = Fraction.toFrac(frac2)

    var new_numerator = (frac1.wholeNumerator() * frac2.denominator) - (frac2.wholeNumerator() * frac1.denominator)
    var new_denominator = frac1.denominator * frac2.denominator

    return (new Fraction(new_numerator + "÷" + new_denominator)).simplify()
  }
  Fraction.multiply = function(frac1, frac2) {
    frac1 = Fraction.toFrac(frac1)
    frac2 = Fraction.toFrac(frac2)

    var new_numerator = frac1.wholeNumerator() * frac2.wholeNumerator()
    var new_denominator = frac1.denominator * frac2.denominator

    return (new Fraction(new_numerator + "÷" + new_denominator)).simplify()
  }
  Fraction.divide = function(frac1, frac2) {
    frac1 = Fraction.toFrac(frac1)
    frac2 = Fraction.toFrac(frac2)
    if (frac1.wholeNumerator() == 0) { return frac1 }

    var new_numerator = frac1.wholeNumerator() * frac2.denominator
    var new_denominator = frac1.denominator * frac2.wholeNumerator()

    return (new Fraction(new_numerator + "÷" + new_denominator)).simplify()
  }
  Fraction.exponent = function(frac1, frac2) {
    frac1 = Fraction.toFrac(frac1)
    frac2 = Fraction.toFrac(frac2)

    return (new Fraction((frac1.decimal() ** frac2.decimal()).toString())).simplify()
    // var new_numerator = frac1.wholeNumerator() * frac2.denominator
    // var new_denominator = frac1.denominator * frac2.wholeNumerator()
    //
    // return new Fraction(new_numerator + "÷" + new_denominator)
  }
  // Fraction.rt = function(frac1, frac2) {
    // var new_numerator = frac1.wholeNumerator() * frac2.denominator
    // var new_denominator = frac1.denominator * frac2.wholeNumerator()
    //
    // return new Fraction(new_numerator + "÷" + new_denominator)
  // }

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
  UnitNum.prototype.parse = function() {
    var num = this.raw
    if (Fraction.isA(num)) { num = num.raw }

    if (typeof num == "number") { return this.unitless = num }
    var num_with_frac = new RegExp(/(\d+(?:\s*\d*\s*[÷%]\s*\d+)?)(?:\s*)/)

    var feet_match = num.match(num_with_frac.source + /(?:ft\b|\'|\’|\‘|f(?:ee|oo)t\b)/i) || {}
    this.feet = new Fraction(feet_match[1] || 0)
    num = num.replace(feet_match[0], "")

    var inches_match = num.match(num_with_frac.source + /(?:in\b|\"|\“|\”|inch(?:es)?\b)/i) || {}
    this.inches = new Fraction(inches_match[1] || 0)
    num = num.replace(inches_match[0], "")

    var miles_match = num.match(num_with_frac.source + /(?:mi\b|miles?\b)/i) || {}
    this.miles = new Fraction(miles_match[1] || 0)
    num = num.replace(miles_match[0], "")

    var millimeters_match = num.match(num_with_frac.source + /(?:mm\b|millimeters?\b)/i) || {}
    this.millimeters = new Fraction(millimeters_match[1] || 0)
    num = num.replace(millimeters_match[0], "")

    var meters_match = num.match(num_with_frac.source + /(?:m\b|meters?\b)/i) || {}
    this.meters = new Fraction(meters_match[1] || 0)
    num = num.replace(meters_match[0], "")

    var centimeters_match = num.match(num_with_frac.source + /(?:cm\b|centimeters?\b)/i) || {}
    this.centimeters = new Fraction(centimeters_match[1] || 0)
    num = num.replace(centimeters_match[0], "")

    var kilometers_match = num.match(num_with_frac.source + /(?:km\b|kilometers?\b)/i) || {}
    this.kilometers = new Fraction(kilometers_match[1] || 0)
    num = num.replace(kilometers_match[0], "")

    this.unitless = new Fraction(num || 0)
  }
  UnitNum.prototype.interpret = function() {
    this.parse()

    var new_unit = ""
    var num = this.unitless

    var ins = new Fraction(0)
    ins = Fraction.add(ins, Fraction.multiply(this.miles, 63360))
    ins = Fraction.add(ins, Fraction.multiply(this.feet, 12))
    ins = Fraction.add(ins, this.inches)

    var mms = new Fraction(0)
    mms = Fraction.add(mms, this.millimeters)
    mms = Fraction.add(mms, Fraction.multiply(this.meters, 1000))
    mms = Fraction.add(mms, Fraction.multiply(this.centimeters, 10))
    mms = Fraction.add(mms, Fraction.multiply(this.kilometers, 1000000))

    if (ins == 0 && mms == 0) {
      new_unit = null
      num = Fraction.add(num, Fraction.add(ins, Fraction.multiply(mms, 25.4)))
    } else if (ins >= mms) {
      if (this.feet > 0) {
        new_unit = "ft in"
      } else {
        new_unit = "in"
      }

      num = Fraction.add(num, Fraction.add(ins, Fraction.multiply(mms, 25.4)))
    } else if (mms > ins) {
      if (this.meters > 0) {
        new_unit = "m mm"
      } else {
        new_unit = "mm"
      }

      num = Fraction.add(num, Fraction.add(mms, Fraction.divide(ins, 25.4)))
    }

    this.unit = new_unit
    this.value = num
  }
  UnitNum.prototype.format = function() {
    // TODO: Split out something like 4'11" 1/16
    // 4' 11 1÷16"
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
          calc = Fraction.add(valA.value, valB.value)
          break;
        case "-":
          calc = Fraction.add(valA.value, valB.value)
          break;
        case "×":
        case "*":
          calc = Fraction.multiply(valA.value, valB.value)
          break;
        case "÷":
        case "/":
          calc = Fraction.divide(valA.value, valB.value)
          break;
        case "^":
          calc = Fraction.exponent(valA.value, valB.value)
          break;
        // case "√":
        //   calc = Calc.sqrt(valA.value, valB.value)
        //   break;
      }
      var newVal = new UnitNum(calc)
      if (Prev.op() == "") {
        newVal.unit = valB.unit
      } else {
        newVal.unit = valA.unit || valB.unit
      }

      Prev.num(newVal.format())
      Screen.clear()
    }

    Prev.op(op)
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
