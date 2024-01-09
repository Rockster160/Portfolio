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
    //       // frame.fillRandom()
    //       frame.firstShot.score = "X"
    //       applyFrameModifiers(frame)
    //     }
    //   })
    // })
    // game.filled = true

    game.nextShot()
  }
}

// ===== BUG:

// ===== Todo: (Don't delete, just check)
// Test interactions on iPad
// Save scores!
// Edit names/bowlers (including average/hdcp?)
// Reorder bowlers via drag & drop (after clicking the edit btn)
// Absent / Skip
//   * Should remember the status on the next game
// Add subs
//   * New Sub bowler (with JUST average OR hdcp)
//   * Existing Sub bowler
// Add/Remove bowlers from lane
// Lane talk
//   * Auto pull in lane from cache
// Card Point
//   * Tap on bowler name
// Score button interface (no pins)
//   * Num keys should also work
// Add button somewhere to remove a bowler
// Add button somewhere to clear an entire bowler scores
// Add ability to dump in scores from the console to pre-load them
// Team total scores
// Enemy Scores
//   * Need a better place for these that don't mess up the page layout.
//   * Enemy chart should show comparison totals (+- points)
// Live submit- don't reload page until results are saved
// √ Show Stats
//√ Make sure Num keys work! + Backspace, /, X, etc
//√ Total Score
//√ Max Score
//√ Frame Scores
//√ Delete score/frame button
//√ Arrow keys should be able to go between shots/frames/bowlers


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
