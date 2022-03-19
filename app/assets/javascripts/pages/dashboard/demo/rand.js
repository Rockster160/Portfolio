$(".ctr-dashboard").ready(function() {
  var render = function(cell) {
    var lines = []
    lines.push(cell.line(0))
    lines.push("-".repeat(32))
    cell.data.history.slice(-10).reverse().forEach(function(line) {
      lines.push(Text.center(line))
    })

    cell.lines(lines)
  }

  var random = function(array) {
    return array[Math.floor(Math.random() * array.length)]
  }

  var deck = function() {
    return ["♠", Text.color(dash_colors.red, "♥"), Text.color(dash_colors.red, "♦"), "♣"].map(function(suit) {
      return [...Array(13).keys()].map(function(num) {
        num += 1
        if (num == 1) { num = "A" }
        if (num == 11) { num = "J" }
        if (num == 12) { num = "Q" }
        if (num == 13) { num = "K" }
        return num + suit
      })
    }).flat()
  }

  Cell.init({
    x: 3,
    y: 3,
    title: "Random",
    text: Text.color(dash_colors.yellow, ".8ball .die .coin .draw .shuffle"),
    commands: {
      "8ball": function() {
        this.data.history.push(random([
          "It is certain.",
          "It is decidedly so.",
          "Without a doubt.",
          "Yes - definitely.",
          "You may rely on it.",
          "As I see it, yes.",
          "Most likely.",
          "Outlook good.",
          "Yes.",
          "Signs point to yes.",
          "Reply hazy, try again.",
          "Ask again later.",
          "Better not tell you now.",
          "Cannot predict now.",
          "Concentrate and ask again.",
          "Don't count on it.",
          "My reply is no.",
          "My sources say no.",
          "Outlook not so good.",
          "Very doubtful.",
        ]))
        render(this)
      },
      die: function() {
        this.data.history.push(random([1, 2, 3, 4, 5, 6]))
        render(this)
      },
      coin: function() {
        this.data.history.push(random(["Heads", "Tails"]))
        render(this)
      },
      draw: function() {
        var cell = this
        if (cell.data.cards.length == 0) {
          cell.data.history.push("No cards left! Call " + Text.color(dash_colors.yellow, ".shuffle"))
          return render(cell)
        }
        var card = random(cell.data.cards)
        cell.data.cards = cell.data.cards.filter(function(deck_card) {
          return deck_card != card
        })
        cell.data.history.push(card + " (" + cell.data.cards.length + " left)")

        render(cell)
      },
      shuffle: function() {
        this.data.cards = deck()
        this.data.history.push("Shuffled the cards! 52 remain.")
        render(this)
      },
    },
    reloader: function() {
      // Ran immediately when cell loads, and also any time .reload is called
      this.data.history = ["Click this cell, then type one of the above commands."]
      this.data.cards = deck()
      render(this)
    },
    command: function(msg) {
      var res = (new Roll(msg)).calculate()
      this.data.history.push(Text.justify("   " + res, Text.color("grey", Text.trunc(msg + "   ", 12))))
      render(this)
    }
  })
})
