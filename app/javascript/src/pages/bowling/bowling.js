import Bowler from "./bowler"
import Game from "./game"
import { buttons } from "./buttons"
import { events } from "./events"
import { panel } from "./panel"

window.onload = function() {
  if (document.querySelector(".bowling-game-form")) {
    new Game(document.querySelector(".bowling-game-form"))

    buttons() // Event listeners for buttons and key presses
    events() // Helpers for events, also game state event callbacks
    panel() // Event listeners for sub menus and changing the bowler order and scores and such
    game.start()
    game.eachBowler(bowler => window[(bowler.bowlerName || "noname").trim().toLowerCase()] = bowler)

    // game.fillRandomUntil(9)
    // game.fillRandomUntil(9, "X")

    game.nextShot()
  }
}

window.onbeforeunload = function(evt) {
  if (!game || game.saved) { return undefined }

  return "onbeforeunload"
}

// ===== NOTE:
// Maybe have a button next to pin fall (between it and "End Game") that opens a modal that shows enemy scores
// Absent bowler should not send scores...

// ===== BUG:
// When a bowler is absent the 1st game then present the 2nd, 2nd (and 3rd) games are marked and pre-set as absent
//   * Also applies for deleting a bowler- likely a BE issue
// Empty bowler (new game new league) raising errors
// "New Bowler" on empty game did not open the modal
// New game should have an empty bowler added by default - game should not allow 0 bowlers- add a blank one if there aren't any.

// ===== TODO: (Don't delete, just check)
// "admin" interface - opens a modal with a few buttons that trigger different things
//   * Clear All Scores
//   * Resync Elements
//   * Maybe even just have a full modal that opens a JS console (and maybe shows some basic commands to remember `game.resyncElements()`, `game.clearAll()`)
// Edit name, avg, hdcp
// Somehow re-order bowlers
// Score button interface (no pins)
//   * Num keys should also work
// Add button somewhere to clear an entire bowler's scores
// Enemy Scores
//   * Need a better place for these that don't mess up the page layout.
//   * Enemy chart should show comparison totals (+- points)
// Fully hide bottom pin section to show enemy scores instead - still show stats? Also have button to toggle between that view and pin entry view
// Maybe show projections? Get average per frame and then multiply by frames left
// Full track enemy scores to properly display the frame by frame

//√ Test interactions on iPad
//√ REMEMBER! to replace other page JS (jQuery) so index and league updates still work
//√ Lane talk
//√ Remove bowlers from lane
//√   * Needs to delete the bowler from the current game on the BE
//√ Add subs
//√   * New Sub bowler (with JUST average OR hdcp)
//√   * Existing Sub bowler
//√ Add new bowler with name, avg, hdcp
//√ Add existing bowler
//√ Team total scores
//√ Live submit- don't reload page until results are saved
//√ Previous Game Scores
//√ Save when "Done editing" bowlers
//√ Save when changing lane
//√ Warn before leaving page if any changes have been made
//√ Card Point
//√ Show total &+ hdcp under max column
//√ Save scores!
//√ Absent / Skip
//√ * Should remember the status on the next game
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
