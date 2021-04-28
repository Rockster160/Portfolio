$(".ctr-calcs.act-show").ready(function() {
  var $screen = $(".screen"), $prev = $(".prev"), copy = "0", unit = null

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
  Prev.store = function(op) {
    Prev.num(Screen.num())
    Prev.op(op)

    Screen.clear()
  }
  Prev.clear = function(op) {
    Prev.num("")
    Prev.op("")
  }

  function Calc() {}
  Calc.safeFloat = function(str) {
    var num = parseFloat(str)

    if (isNaN(num)) {
      return null
    } else {
      return num
    }
  }
  Calc.compress = function() {
    
  }
  Calc.interpret = function(num) {
    // TODO: Read something like 4'11" 1/16 and convert to a number
    var vals = {}

    var feet_match = num.match(/(\d+)(?:\s*)(?:\bft\b|\'|\bf(?:ee|oo)t\b)/i)
    vals.feet = Calc.safeFloat(feet[1])
    num.replace(feet[0], "")

    var inches_match = num.match(/(\d+)(?:\s*)(?:\bin\b|\"|\binch(?:es)?\b)/i)
    vals.inches = Calc.safeFloat(inches[1])
    num.replace(feet[0], "")

    var miles_match = num.match(/(\d+)(?:\s*)(?:\bmi\b|\"|\bmiles?\b)/i)
    vals.miles = Calc.safeFloat(miles[1])
    num.replace(feet[0], "")

    var millimeters_match = num.match(/(\d+)(?:\s*)(?:\bmm\b|\bmillimeters?\b)/i)
    vals.millimeters = Calc.safeFloat(millimeters[1])
    num.replace(feet[0], "")

    var meters_match = num.match(/(\d+)(?:\s*)(?:\bm\b|\bmeters?\b)/i)
    vals.meters = Calc.safeFloat(meters[1])
    num.replace(feet[0], "")

    var centimeters_match = num.match(/(\d+)(?:\s*)(?:\bcm\b|\bcentimeters?\b)/i)
    vals.centimeters = Calc.safeFloat(centimeters[1])
    num.replace(feet[0], "")

    var kilometers_match = num.match(/(\d+)(?:\s*)(?:\bkm\b|\bkilometers?\b)/i)
    vals.kilometers = Calc.safeFloat(kilometers[1])
    num.replace(feet[0], "")

    vals.unitless = Calc.safeFloat(num)

    if (isNaN(int)) {
      return 0
    } else {
      return int
    }
  }
  Calc.format = function(num) {
    return num
    // TODO: Split out something like 4'11" 1/16
  }
  Calc.op = function(op) {
    if (Screen.num() == "") {
      // No op
    } else if (Prev.num() == "") {
      Prev.num(Calc.interpret(Screen.num()))
      Screen.clear()
    } else {
      var calc = Screen.num()

      switch(Prev.op()) {
        case "+":
        calc = Calc.add()
        break;
        case "-":
        calc = Calc.subt()
        break;
        case "×":
        case "*":
        calc = Calc.mult()
        break;
        case "÷":
        case "/":
        calc = Calc.div()
        break;
        case "^":
        calc = Calc.exp()
        break;
        case "√":
        calc = Calc.sqrt()
        break;
      }

      Prev.num(calc)
      Screen.clear()
    }

    Prev.op(op)
  }
  Calc.add = function() {
    return Calc.interpret(Prev.num()) + Calc.interpret(Screen.num())
  }
  Calc.subt = function() {
    return Calc.interpret(Prev.num()) - Calc.interpret(Screen.num())
  }
  Calc.mult = function() {
    return Calc.interpret(Prev.num()) * Calc.interpret(Screen.num())
  }
  Calc.div = function() {
    return Calc.interpret(Prev.num()) / Calc.interpret(Screen.num())
  }
  Calc.exp = function() {
    return Math.pow(Calc.interpret(Prev.num()), Calc.interpret(Screen.num()))
  }
  Calc.sqrt = function() {
    return Math.sqrt(Calc.interpret(Prev.num()), Calc.interpret(Screen.num()))
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
