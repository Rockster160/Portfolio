import BowlingCalculator from "./calculator"
import LiveStats from "./live_stats"
import Rest from "./rest"

export default class Scoring {
  constructor(bowlers) {
    this.bowler = bowlers
    this.calculator = BowlingCalculator
  }

  static updateBowler(bowler) {
    if (!bowler?.frames) { return }

    let shot_scores = this.bowlerScores(bowler)
    let scoring = BowlingCalculator.score(shot_scores)
    scoring.frames.forEach((frameScore, idx) => {
      bowler.frames[idx+1].display = frameScore
    })
    for (let i=scoring.frames?.length || []; i<10; i++) {
      bowler.frames[i+1].display = ""
    }
    bowler.currentScore = scoring.total
    bowler.maxScore = scoring.max

    this.updateTotals()
  }

  static updateTotals() {
    let teamTotal = 0
    let teamHdcp = 0

    let frameNum = game.earliestFrame()?.frameNum || 10
    game.eachBowler(bowler => {
      // parseInt should happen in the accessor somehow
      if (bowler.active) {
        teamTotal += parseInt(bowler.currentScore)
        teamHdcp += parseInt(bowler.hdcp)
      } else {
        let absentMax = parseInt(bowler.absentScore) || 0
        let absentFrameAvg = Math.floor(absentMax / 10)
        let currentAbsentScore = absentFrameAvg * frameNum

        teamTotal += parseInt(currentAbsentScore)
        teamHdcp += parseInt(bowler.hdcp)
      }
    })

    let totalText = teamHdcp > 0 ? `${teamTotal} | ${teamTotal + teamHdcp}` : `${teamTotal}`
    document.querySelector(".team-total").innerText = totalText
  }

  static bowlerScores(bowler) {
    let scores = []
    bowler.eachFrame(frame => {
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

  static generateStats() {
    LiveStats.generate()
  }

  static submit(callback) {
    let form = document.querySelector("form.bowling-game-form")
    Rest.patch(form.action, new FormData(form), callback)
  }
}
