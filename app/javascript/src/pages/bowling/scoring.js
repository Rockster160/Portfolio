import BowlingCalculator from "./calculator"

export default class Scoring {
  constructor(bowlers) {
    this.bowler = bowlers
    this.calculator = BowlingCalculator
  }
}
