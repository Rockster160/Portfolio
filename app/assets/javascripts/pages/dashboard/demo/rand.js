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
    return ["♠", "♥", "♦", "♣"].map(function(suit) {
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
    x: 4,
    y: 2,
    title: "Random",
    text: Text.color("yellow", ".8ball .die .coin .draw .shuffle"),
    commands: {
      "8ball": function(cell) {
        cell.data.history.push(random([
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
        render(cell)
      },
      die: function(cell) {
        cell.data.history.push(random([1, 2, 3, 4, 5, 6]))
        render(cell)
      },
      coin: function(cell) {
        cell.data.history.push(random(["Heads", "Tails"]))
        render(cell)
      },
      draw: function(cell) {
        if (cell.data.cards.length == 0) {
          cell.data.history.push("No cards left! Call " + Text.color("yellow", ".shuffle"))
          return render(cell)
        }
        var card = random(cell.data.cards)
        cell.data.cards = cell.data.cards.filter(function(deck_card) {
          return deck_card != card
        })
        cell.data.history.push(card + " (" + cell.data.cards.length + " left)")

        render(cell)
      },
      shuffle: function(cell) {
        cell.data.cards = deck()
        cell.data.history.push("Shuffled the cards! 52 remain.")
        render(cell)
      },
    },
    reloader: function(cell) {
      // Ran immediately when cell loads, and also any time .reload is called
      cell.data.history = ["Click this cell, then type one of the above commands."]
      cell.data.cards = deck()
      render(cell)
    },
    command: function(msg, cell) {
      cell.data.history.push(Text.color("red", "Oops! You forgot the . before your command."))
      render(cell)
    }
  })
})
