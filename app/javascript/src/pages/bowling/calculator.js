export default class BowlingCalculator {
  static score(frames, includePerfect) {
    // `frames` is a flattened array of every frame. ["X", "", 9, "/", 5, "-"]
    // Strikes should always be followed by an empty string (non-10th) to represent no second throw
    // Use "X", "/", "-" for strike, spare, gutter
    // Other values should be integers (not strings of numbers)
    let totalScore = 0
    let maxScore = 0
    let frameTotals = []
    let maxThrows = 21
    let calc = this

    let clamp = (number, min, max) => Math.max(min, Math.min(number, max))
    let perfectFrame = (frame, frameNum) => {
      let perfect = Array.from(
        { length: frameNum == 10 ? 3 : 2 },
        (value, idx) => frameNum == 10 ? "X" : (idx % 2 === 1 ? "X" : "")
      )
      return perfect.map((shot, idx) => {
        if (frame[idx] !== undefined) { return frame[idx] }
        if (frameNum < 10) {
          if (idx == 0) { return "X" }
          return frame[idx-1] == "X" || frame[idx-1] === undefined ? "" : "/"
        } else { // 10th
          // Can always return X because the 10th doesn't do any future calcs
          if (idx == 0) { return "X" }
          let closedBefore = frame[idx-1] == "X" || frame[idx-1] == "/" || !frame[idx-1]
          if (idx == 1) { return closedBefore ? "X" : "/" }
          return closedBefore ? "X" : null
        }
      })
    }

    let endFrame = includePerfect ? maxThrows : frames.length
    for (let i=0; i<endFrame; i+=2) {
      if (i >= 20) continue

      let frameNum = clamp(Math.floor(i/2), 0, 9) + 1
      let frame = [frames[i], frames[i+1], frames[i+2]].slice(0, frameNum < 10 ? 2 : 3)
      if (includePerfect) { frame = perfectFrame(frame, frameNum) }

      let frameScore = 0
      frame.forEach((toss, idx) => {
        let tossScore = calc.scoreFromToss(idx, frame)
        frameScore += tossScore

        if (frameNum < 10) {
          let nextFrame = frames.slice(i+2, i+4)
          if (includePerfect) { nextFrame = perfectFrame(nextFrame, frameNum+1) }

          if (toss == "X" || toss == "/") { // Double next throw
            frameScore += calc.scoreFromToss(0, nextFrame)
          }
          if (toss == "X") { // Double following next throw
            if (nextFrame[1] == "") { // Next is strike, so jump to following
              nextFrame = frames.slice(i+4, i+6)
              if (includePerfect) { nextFrame = perfectFrame(nextFrame, frameNum+1) }
              frameScore += calc.scoreFromToss(0, nextFrame)
            } else {
              frameScore += calc.scoreFromToss(1, nextFrame)
            }
          }
        }
      })

      frameTotals.push(frameScore)
      totalScore += frameScore
    }

    // return this.score(frames, true)
    return {
      frames: this.cumulativeSumArray(frameTotals),
      total: totalScore,
      max: includePerfect ? null : this.score(frames, true).total,
    }
  }

  static scoreFromToss(tossIdx, tosses) {
    const toss = tosses[tossIdx]
    if (!toss) return 0
    if (toss === "-") return 0
    if (toss === "X") return 10
    if (toss === "/") return 10 - this.scoreFromToss(tossIdx-1, tosses)
    return parseInt(toss)
  }

  static cumulativeSumArray(arr) {
    return arr.reduce((acc, val, idx) => {
      if (idx === 0) {
        acc.push(val)
      } else {
        acc.push(val + acc[idx - 1])
      }
      return acc
    }, [])
  }

  static absentScore(absentMax, frameNum) {
    absentMax = parseInt(absentMax) || 0
    let absentFrameAvg = Math.floor(absentMax / 10)
    let currentAbsentScore = absentFrameAvg * frameNum
    let frames = Array.from({ length: frameNum }, (_, idx) => (idx+1) * absentFrameAvg)
    if (frameNum == 10) {
      frame[9] = absentMax
      currentAbsentScore = absentMax
    }

    return {
      frames: frames,
      total: currentAbsentScore,
      max: absentMax,
    }
  }
}
