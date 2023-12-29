export default class BowlingCalculator {
  static calc(frames) {
    // `frames` is a flattened array of every frame. ["X", "", 9, "/", 5, "-"]
    // Strikes should always be followed by an empty string (non-10th) to represent no second throw
    // Use "X", "/", "-" for strike, spare, gutter
    // Other values should be integers (not strings of numbers)
    let totalScore = 0
    let frameTotals = []

    for (let i=0; i<frames.length; i+=2) {
      if (i >= 20) continue

      let frameNum = clamp(Math.floor(i/2), 0, 9) + 1
      let frame = [frames[i], frames[i+1], frames[i+2]].slice(0, frameNum < 10 ? 2 : 3)

      frame.forEach((toss, idx) => {
        let tossScore = scoreFromToss(idx, frame)
        frameScore += tossScore

        if (frameNum < 10) {
          let nextFrame = frames.slice(i+2, i+4)
          if (toss == "X" || toss == "/") { // Double next throw
            frameScore += scoreFromToss(0, nextFrame)
          }
          if (toss == "X") { // Double following next throw
            if (nextFrame[1] == "") { // Next is strike, so jump to following
              nextFrame = frames.slice(i+4, i+6)
              frameScore += scoreFromToss(0, nextFrame)
            } else {
              frameScore += scoreFromToss(1, nextFrame)
            }
          }
        }

        frameTotals.push(frameScore)
        totalScore += frameScore
      })
    }

    return {
      frames: frameTotals,
      total: totalScore
    }
  }

  static scoreFromToss(tossIdx, tosses) {
    const toss = tosses[tossIdx]
    if (!toss) return 0
    if (toss === "-") return 0
    if (toss === "X") return 10
    if (toss === "/") return 10 - scoreFromToss(tossIdx-1, tosses)
    return parseInt(toss)
  }
}
