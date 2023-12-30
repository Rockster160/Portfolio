import Bowler from "./bowler"
import Game from "./game"
import { buttons } from "./buttons"
import { events } from "./events"

window.onload = function() {
  if (document.querySelector(".bowling-game-form")) {
    window.game = undefined
    window.game = new Game(document.querySelector(".bowling-game-form"))
    window.bowlers = Array.from(document.querySelectorAll(".bowler")).map(bowler => new Bowler(bowler))
    game.bowlers = window.bowlers

    window.me = game.bowlers[0]
    game.start()
    buttons()
    events()
  }
}
