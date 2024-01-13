import Bowler from "./bowler"
import Game from "./game"
import { buttons } from "./buttons"
import { events } from "./events"

window.onload = function() {
  if (document.querySelector(".bowling-game-form")) {
    new Game(document.querySelector(".bowling-game-form"))

    buttons()
    events()
    game.start()
    game.eachBowler(bowler => window[bowler.bowlerName.trim().toLowerCase()] = bowler)

    // game.fillRandomUntil(9)
    // game.fillRandomUntil(9, "X")

    game.nextShot()
  }
}

// ===== NOTE:
// Maybe have a button next to pin fall (between it and "End Game") that opens a modal that shows enemy scores
// Absent bowler should not send scores...

// ===== BUG:

// ===== Todo: (Don't delete, just check)
// Save when "Done editing" bowlers
// Save when changing lane
// Warn before leaving page if any changes have been made
// Test interactions on iPad
// Edit names/bowlers (including average/hdcp?)
// Previous Game Scores
// Reorder bowlers via drag & drop (after clicking the edit btn)
// Add subs
//   * New Sub bowler (with JUST average OR hdcp)
//   * Existing Sub bowler
// Add/Remove bowlers from lane
// Lane talk
//   * Auto pull in lane from cache
// Score button interface (no pins)
//   * Num keys should also work
// Add button somewhere to remove a bowler
// Add button somewhere to clear an entire bowler scores
// Add ability to dump in scores from the console to pre-load them
// Team total scores
// Live submit- don't reload page until results are saved
// Enemy Scores
//   * Need a better place for these that don't mess up the page layout.
//   * Enemy chart should show comparison totals (+- points)
// √ Card Point
//√ Show total &+ hdcp under max column
//√ Save scores!
//√ Absent / Skip
//  * Should remember the status on the next game
//√ Show Stats
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
