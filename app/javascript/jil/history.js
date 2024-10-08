export default class History {
  static states = [];
  static currentIdx = 0;
  static maxStates = 100;

  static add(newState) {
    if (this.states.length > 0) {
      const last = this.states[this.states.length-1]
      if (last == newState) { return }
    }
    this.states = this.states.slice(0, this.maxStates-1).slice(0, this.currentIdx + 1);
    this.states.push(newState);
    this.currentIdx = this.states.length - 1;
  }

  static getState() {
    return this.states[this.currentIdx]
  }

  static undo() {
    if (this.currentIdx > 0) {
      this.currentIdx--;
    }
    return this.getState();
  }

  static redo() {
    if (this.currentIdx < this.states.length - 1) {
      this.currentIdx++;
    }
    return this.getState();
  }
}
