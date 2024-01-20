export default applyFrameModifiers = function(frame) {
  checkBuggy(frame)
  checkDrinkFrame(frame)
  checkClosedStreak(frame)
  checkPerfectStreak(frame)
}

let toggleClass = function(frame, klass, toggle) {
  if (frame) { frame.element.classList.toggle(klass, toggle) }
}

let checkBuggy = function(frame) {
  let buggyClass = "missed-drink-frame"
  let siblings = frame.activeSiblings
  let removeBuggy = () => siblings.forEach(sibling => toggleClass(sibling, buggyClass, false))

  if (siblings.length < 3) { return removeBuggy() }
  if (siblings.find(sibling => !sibling.firstShot.complete)) { return removeBuggy() }

  let strikeSiblings = siblings.filter(sibling => sibling.firstShot.knockedAll)
  if (siblings.length - 1 == strikeSiblings.length) {
    siblings.forEach(sibling => toggleClass(sibling, buggyClass, !sibling.firstShot.knockedAll))
  } else {
    removeBuggy()
  }
}

let checkDrinkFrame = function(frame) {
  let drinkClass = "drink-frame"
  let siblings = frame.activeSiblings
  let header = document.querySelector(`.bowling-header .bowling-cell[data-frame="${frame.frameNum}"]`)
  let removeDrink = () => {
    header.classList.toggle(drinkClass, false)
    siblings.forEach(sibling => toggleClass(sibling, drinkClass, false))
  }

  if (siblings.length < 3) { return removeDrink() }
  if (siblings.find(sibling => !sibling.firstShot.complete)) { return removeDrink() }

  if (siblings && siblings.every(sibling => sibling.firstShot.knockedAll)) {
    header.classList.toggle(drinkClass, true)
    siblings.forEach(sibling => toggleClass(sibling, drinkClass, true))
  } else {
    removeDrink()
  }
}

let checkClosedStreak = function(frame) {
  let closedClass = "clean-start"
  let bowler = frame.bowler
  let frames = bowler.frames
  let removeClosed = () => frames.forEach(fr => toggleClass(fr, closedClass, false))

  if (frame.incomplete) { return toggleClass(frame, closedClass, false) }
  let complete = frames.filter(fr => fr?.complete)
  if (complete && complete.every(fr => fr.isClosed)) {
    complete.forEach(fr => toggleClass(fr, closedClass, true))
  } else {
    removeClosed()
  }
}

let checkPerfectStreak = function(frame) {
  let consecClass = "consec-start"
  let bowler = frame.bowler
  let frames = bowler.frames
  frame.bowler.element.classList.toggle("perfect-game", false)
  let removeClosed = () => frames.forEach(fr => toggleClass(fr, consecClass, false))
  let strikeFrame = (fr) => fr.shots.every(shot => !shot?.complete || shot.knockedAll)

  if (frame.incomplete) { return toggleClass(frame, consecClass, false) }
  let complete = frames.filter(fr => fr?.firstShot?.complete)
  if (complete && complete.every(strikeFrame)) {
    complete.forEach(fr => toggleClass(fr, consecClass, true))
    if (complete.length == 10 && complete[9].complete) {
      frame.bowler.element.classList.toggle("perfect-game", true)
    }
  } else {
    removeClosed()
  }
}
