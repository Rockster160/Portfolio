import BowlingCalculator from "./calculator"

export default class Scoring {
  constructor(bowlers) {
    this.bowler = bowlers
    this.calculator = BowlingCalculator
  }

  static updateBowler(bowler) {
    let shot_scores = this.bowlerScores(bowler)
    let scoring = BowlingCalculator.score(shot_scores)
    // return {
    //   frames: frameTotals,
    //   total: totalScore,
    //   max: maxScore,
    // }
    scoring.frames.forEach((frameScore, idx) => {
      bowler.frames[idx+1].score = frameScore
    })
    bowler.currentScore = scoring.total
    bowler.maxScore = scoring.max
  }

  static bowlerScores(bowler) {
    let scores = []
    bowler.frames.forEach(frame => {
      if (!frame) { return }
      let frameIdx = frame.frameNum - 1
      if (frame.complete || frame.firstShot.complete) {
        scores[frameIdx*2] = frame.firstShot.score || ""
      }
      if (frame.complete || frame.secondShot.complete) {
        scores[(frameIdx*2)+1] = frame.secondShot.score || ""
      }
      if (frame.isLastFrame) {
        if (frame.complete || frame.thirdShot.complete) {
          scores[(frameIdx*2)+2] = frame.thirdShot.score || ""
        }
      }
    })
    return scores
  }
}
