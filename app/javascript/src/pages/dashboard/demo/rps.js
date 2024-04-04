import { Text } from "../_text"
import { dash_colors } from "../vars"

(function() {
  var render = function(cell) {
    var lines = []
    lines.push(Text.justify("  You", "CPU  "))
    lines.push(Text.justify("   " + cell.data.player_wins, cell.data.cpu_wins + "   "))
    lines.push("-".repeat(32))
    cell.data.history.slice(-10).reverse().forEach(function(line) {
      lines.push(line)
    })

    cell.lines(lines)
  }

  Cell.register({
    title: "Rock-Paper-Scissors",
    wrap: true,
    reloader: function() {
      var cell = this
      // Ran immediately when cell loads, and also any time .reload is called
      cell.data.player_wins = 0
      cell.data.cpu_wins = 0
      cell.data.history = ["Play by clicking this cell, then typing 'rock', 'paper', or 'scissors' and hitting enter"]
      render(cell)
    },
    autocomplete_options: function() {
      return ["rock", "paper", "scissors"]
    },
    command: function(msg) {
      var cell = this
      var choice = msg.trim().toLowerCase().slice(0, 1)
      var choices = ["r", "p", "s"]
      if (!choices.includes(choice)) {
        cell.data.history.push("'" + msg + "' is not a valid choice. Please enter one of 'rock', 'paper', or 'scissors'")
        return render(cell)
      }
      var choice_map = {
        r: Emoji.rock, // 🪨
        p: Emoji.page_with_curl, // 📃
        s: Emoji.scissors // ✂️
      }

      function playerWin() {
        cell.data.player_wins += 1
        var line = Text.justify("  " +  choice_map[choice], Text.green("You Win! "), choice_map[cpu_choice] + "  ")
        cell.data.history = cell.data.history || []
        cell.data.history.push(line)
      }
      function draw() {
        var line = Text.justify("  " +  choice_map[choice], Text.yellow("Draw!"), choice_map[cpu_choice] + "  ")
        cell.data.history.push(line)
      }
      function playerLose() {
        cell.data.cpu_wins += 1
        var line = Text.justify("  " +  choice_map[choice], Text.red("You Lose!"), choice_map[cpu_choice] + "  ")
        cell.data.history.push(line)
      }

      var cpu_choice = choices[Math.floor(Math.random() * choices.length)]
      if (choice == cpu_choice) {
        draw()
      } else if (choice == "r") {
        if (cpu_choice == "p") {
          playerLose()
        } else if (cpu_choice == "s") {
          playerWin()
        }
      } else if (choice == "p") {
        if (cpu_choice == "r") {
          playerLose()
        } else if (cpu_choice == "s") {
          playerWin()
        }
      } else if (choice == "s") {
        if (cpu_choice == "r") {
          playerWin()
        } else if (cpu_choice == "p") {
          playerLose()
        }
      }

      render(cell)
    }
  })
})()
