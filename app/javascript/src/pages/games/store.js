// In-memory store for the ONE play this phone is driving (the live Play
// page is the only page that needs client state at all - everything else
// is a plain server-rendered page). A single mutable `activePlay` with its
// rolls/scores inlined; no subscribe/notify, since play_page.js re-renders
// itself explicitly after each action rather than observing the store.
export class GameStore {
  constructor() {
    this.activePlay = null; // { ...play attrs, rolls: [], scores: [], action_log: [] }
    this.playerColors = {};
  }

  setActivePlay(play) {
    this.activePlay = play;
  }

  patchActivePlay(patch) {
    if (!this.activePlay) return;
    Object.assign(this.activePlay, patch);
  }

  addRoll(roll) {
    if (!this.activePlay) return;
    this.activePlay.rolls = this.activePlay.rolls || [];
    this.activePlay.rolls.push(roll);
  }

  addScore(score) {
    if (!this.activePlay) return;
    this.activePlay.scores = this.activePlay.scores || [];
    this.activePlay.scores.push(score);
  }

  // Void by client_uuid - the record stays, just marked. Used for both the
  // optimistic local update and reconciling the server's own copy.
  voidByUuid(kind, clientUuid) {
    if (!this.activePlay) return;
    const list = kind === "roll" ? this.activePlay.rolls : this.activePlay.scores;
    const row = (list || []).find((r) => r.client_uuid === clientUuid);
    if (row) row.voided_at = row.voided_at || new Date().toISOString();
  }

  liveRolls() {
    return (this.activePlay?.rolls || []).filter((r) => !r.voided_at);
  }

  setPlayerColors(map) {
    this.playerColors = map || {};
  }
}
