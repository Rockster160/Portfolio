import Bowler from "./bowler"
import Game from "./game"
import { buttons } from "./buttons"
import { events } from "./events"

window.onload = function() {
  if (document.querySelector(".bowling-game-form")) {
    window.game = new Game(document.querySelector(".bowling-game-form"))

    game.start()
    buttons()
    events()
  }
}
