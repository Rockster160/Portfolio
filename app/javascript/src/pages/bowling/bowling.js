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

    // game.bowlers.forEach(bowler => {
    //   bowler?.frames?.forEach(frame => {
    //     if (frame && !frame.isLastFrame) {
    //       frame.fillRandom()
    //       applyFrameModifiers(frame)
    //     }
    //   })
    // })
    // game.filled = true

    game.nextShot()
  }
}
// ===== Todo:
// Save scores!
// Show Stats
// Add / Sub bowlers
// Edit names?
// Absent / Skip are broken
// Need to rememeber absent/skip on next game and pre-apply it
// Add subs
// Lane talk
// Card Point
// Total Scores
// Frame Scores
// Score button interface (no pins)
// Delete score/frame button


// ===== Tests:
// Pin Interface:
  // Click + Drag across pins, should only toggle the same direction as the first pin
  // Should NOT be able to toggle pins that are fallen "before" (first shot of the frame)
  // Editing prior frames
  // Editing future frames
// Scores for current frame, total, and handicap
// Button interface for setting
// Buggy
// Drink
// Closed
// Perfect
