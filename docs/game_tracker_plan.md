# Game Tracker PWA — plan

A phone-first PWA at `/games` that sits off to the side during a board game and does
three things: records every dice roll (who, what, when) with one tap, keeps score, and
times the game. At the end it writes the result into the existing `Game` ActionEvent and
shows roll stats.

Nothing is built yet. Open questions are at the bottom; answers to those change the
build, so they come first.

---

## What exists today (and what we keep)

| Piece | Today | In the new system |
|---|---|---|
| `ActionEvent name: "Game"` | 57 rows. `notes` = game name, `data` = `{players: {"Rocco" => 55, ...}, duration: "90"}`, `timestamp` = start | **Stays the record of truth for "a game was played"**. Every finished play writes one, same shape, plus `play_id`. |
| Task 283 *Game Score Prompt* (`event:action:added name::Game`) | Creates the "Enter Scores" prompt whenever a Game event is added | Skips when `data.play_id` is present — the app already has the scores. Manual logging keeps working unchanged. |
| Tasks 284 / 285 (prompt load / submit) | Guess duration from elapsed time; parse `Name 12` lines | Untouched. |
| `pages/random/roll.js` (`Roll`, `Dice`) | Parses `2d6`, `1d20+3`, etc. | Reused for dice-spec parsing and the virtual roller. |
| Timers PWA (`offline_queue.js`, `store.js`, `timers_worker.js`, `timers.webmanifest`) | Offline-first pattern: local store, queued mutations, replay on reconnect | Copied as the skeleton for this app. |

Legacy data quirks worth knowing: names drift (`Parks & Potions` / `Parks and Potions`,
`Mycelia` / `Mycelia Cards`), and co-op games were logged as `{"": 0, "Alex": 96}`.
Templates fix the first going forward; the index offers a one-time alias merge.

---

## Data model

Four tables. Symbols for every enum (`scoring: :individual`), strings only for names.

**`game_templates`** — "Catan", set up once
- `user_id`, `name`
- `dice` (string, e.g. `"2d6"`, nullable = no dice)
- `scoring` — `:individual | :teams | :table` (table = all-as-one co-op score)
- `win` — `:high | :low | :none`
- `turn_advance` — `:each_roll | :manual` (Catan advances on every roll; some games roll several times per turn)
- `score_presets` jsonb — optional quick-add amounts (`[1, 2, 5]`)
- `last_players` jsonb — ordered `[{name, color, team}]` from the last play, so "choose game → players already there"
- `aliases` jsonb — old ActionEvent names that mean this game

**`game_plays`** — one sitting
- `user_id`, `game_template_id` (nullable for one-off games)
- `name` (copied, so renaming a template doesn't rewrite history)
- `settings` jsonb — a snapshot of the template at start (dice, scoring, win, advance). Editing settings mid-game edits this, not the template.
- `players` jsonb — ordered `[{name, color, team}]`
- `started_at`, `ended_at`, `duration_minutes` (override; nil = `ended_at - started_at`)
- `dice_mode` — `:manual | :virtual`
- `current_player_index`
- `final_scores` jsonb, `winner_names` jsonb
- `action_event_id`
- `status` — `:active | :finished | :abandoned`

**`game_rolls`**
- `game_play_id`, `player_name`, `player_index`
- `value` (the total that was recorded), `dice` (spec it was rolled against, e.g. `"2d6"` or `"1d20"` for a one-off custom roll)
- `faces` jsonb (virtual only: `[3, 4]`)
- `source` — `:button | :custom | :virtual`
- `rolled_at` — **client clock**, the moment of the tap (not when it synced)
- `client_uuid` — unique index; makes the sync idempotent
- `voided_at` — undo is a soft void, so the timeline stays honest

**`game_score_entries`** — same shape: `player_name` (or team, or `:table`), `delta`, `entered_at`, `client_uuid`, `voided_at`.

Players are free-text names with autocomplete from every name used before (game plays +
legacy event `players` keys). No link to Users/Contacts in v1.

---

## Sync: local-first, always

The phone is on a table, Wi-Fi is whatever it is. **A tap must never wait on the
network.**

- Every tap writes to the local store immediately and appends to a queue
  (`games:queue:v1`), exactly like Timers.
- The queue flushes in batches to one endpoint: `POST /games/plays/:id/sync` with
  `{rolls: [...], scores: [...], voids: [...], play: {current_player_index, ...}}`.
  The server upserts by `client_uuid`, so a replayed batch is harmless.
- A play is created client-side with its own UUID too, so even "Start game" works
  offline.
- Small "unsynced: 4" dot in the corner when the queue is non-empty; nothing else.

No ActionCable in v1 — one phone drives a game. (Question 3.)

---

## Screens

Five screens, one JS entry (`pages/games/index.js`), one manifest
(`public/games.webmanifest`, scope `/games`), one service worker
(`public/games_worker.js`).

### 1. Index — `/games`
- Big **New game** button, then template tiles sorted by last played (tap = straight to
  setup with last players loaded).
- **Resume** banner if a play is `:active`.
- History list below: date, game, duration, winner, scores. Legacy `Game` ActionEvents
  are listed in the same feed (read-only, marked as manually logged), so there's one
  history and not two.
- Filter by game; per-game page shows win counts per player and average duration.

### 2. Setup — `/games/new?template=…` (or "Play again" from a finished game)
- Game picker (template) or "one-off".
- Players: chips of recent names, tap to add **in order**; drag to reorder;
  "rotate first player" button for replays. Team picker appears only for `:teams`.
- Settings, collapsed under one row: dice spec, scoring, win, turn advance, manual vs
  virtual dice. Changing them here can optionally "save to template".
- **Start** → play is created, `started_at = now`, timer runs. That's the duration
  tracker starting.

"Play again" = new play with the same template, settings snapshot and players (first
player rotated by one, editable).

### 3. Play — the screen that matters

Portrait, fits one phone screen with no scroll at any time. Everything is reachable with
one thumb from the side.

```
┌──────────────────────────────┐
│ Catan  ⏱ 0:42      ⋯  •      │  ⋯ = menu   • = unsynced dot
├──────────────────────────────┤
│  ▶ CHELSEA              ↶    │  current player, big, in her colour
│    next: Rocco               │  tap name → pick who rolls next
├──────────────────────────────┤
│ Rocco    8   ·  12s ago      │  last 3 rolls, newest on top
│ Elias    6   ·  1m ago       │  tap a row → edit value / player / void
│ Chelsea 11   ·  2m ago       │
├──────────────────────────────┤
│  [ 2 ] [ 3 ] [ 4 ] [ 5 ]     │
│  [ 6 ] [ 7 ] [ 8 ] [ 9 ]     │  value buttons, generated from the dice spec
│  [10 ] [11 ] [12 ] [ ⋯ ]     │  ⋯ = custom value / custom die
├──────────────────────────────┤
│  [ + score ]                 │  only when score tracking is on
└──────────────────────────────┘
```

Rules for this screen:
- **Tap a value → record for the current player → advance → buzz.** One tap, no confirm.
- **Undo (↶) is always in the same place** — it voids the last entry and rewinds the
  turn. Mis-taps are the main error; fixing one must be one tap too.
- The value buttons fill the space the dice spec needs: `2d6` → 11 buttons in a 4×3
  grid; `1d6` → 6 big buttons in 2×3; `1d20` → 20 in 4×5. Above ~24 faces it falls back
  to a keypad.
- Faint expected-frequency shading on each button (7 is darkest) — optional, off by
  default.
- `⋯` on the grid: type any number, or roll against a different spec just this once
  (`1d20`, `1d6`). Recorded with that spec so stats don't mix them up.
- Tapping the player name opens a one-tap player strip — "this one's rolling instead".
  Advancing continues from whoever rolled.
- `turn_advance: :manual` adds a big **Next** button and rolls stop auto-advancing.
- **Screen Wake Lock** held while a play is active (re-acquired on visibility change).
- Haptics via `navigator.vibrate` where supported (Android). iOS ignores it; the
  button flash is the feedback there.
- `⋯` menu (top right): edit settings, edit players (add/remove/reorder mid-game),
  pause timer, switch manual/virtual, end game.

**Score (+ score):** opens a bottom sheet with the current player preselected, the
preset amounts as big buttons, a `±` field, and the running totals for everyone. One
tap on `+2` closes it. For `:teams` it picks a team; for `:table` there's no picker.
Running totals are not on the main screen unless scoring is on, and then only as a
single thin row.

### 4. Virtual dice (same screen, different bottom half)
- The value grid is replaced by one large **ROLL** button and the dice faces shown
  large after each roll (`⚂ ⚃ = 7`).
- Rolls use `crypto.getRandomValues` (not `Math.random`, which `roll.js` uses today —
  worth fixing there too).
- Recorded as `source: :virtual` with `faces`, then advance like a manual roll.
- A small "custom" chip next to ROLL rolls a one-off spec.
- Can switch to manual mid-game (someone wants to roll real dice); each roll records its
  own source.

### 5. End game
- Final scores, prefilled from the score entries (or blank). Winner computed from
  `win` + `scoring`; ties allowed; editable.
- **Start time and duration**, both editable — "we forgot to hit start" is the common
  case.
- Save → play `:finished`, ActionEvent written (see below), template's `last_players`
  updated → then the **Stats** view.
- "Play again" and "Done" buttons at the bottom.

---

## Stats

Computed in one Ruby service, `GamePlay::Stats` (spec-able, and the same code serves
the per-play page, the per-game page and the per-player all-time numbers). The end
screen fetches it after the queue flushes.

Per play:
- **Distribution chart**: actual count per value vs expected count for the dice spec
  (exact convolution for `NdM`, so `2d6` gives the triangle).
- **Per-player distribution** (small multiples, same axes).
- **Headlines**, picked by how surprising they are and capped at ~4:
  - "Rocco rolled the most 7s (6)"
  - "Chelsea rolled 11 five times — expected 1.1. About a 1-in-200 chance." (binomial
    tail probability per player × value; only reported when there are enough rolls and
    the probability is below a threshold after accounting for how many combinations
    were checked, so it doesn't call ordinary noise unlikely)
  - Whole-table fairness: chi-square goodness of fit — "the dice were fair" / "the dice
    ran hot on 6s and 8s"
  - Longest drought — "no 8 for 14 rolls"
  - Highest / lowest average roll vs expected
  - Streaks — "three 7s in a row"
  - **Turn time** — the gap between consecutive rolls gives each player's average turn
    length: "Elias takes 1m 40s a turn, the table averages 58s"
- Roll timeline (value over time, coloured by player) — small, below the fold.

All-time (per game and per player): rolls tracked, distribution across every play, win
rate, average turn time.

Charts follow the `dataviz` skill when built.

---

## Tying into the ActionEvent / Prompt tracker

On **Save** at the end of a game:

```ruby
ActionEvent.create!(
  user:, name: "Game", notes: play.name, timestamp: play.started_at,
  data: { players: { "Rocco" => 55, "Chelsea" => 38 }, duration: "90", play_id: play.id },
)
```

- `players` / `duration` match what task 285 writes today, so anything already reading
  Game events keeps working.
- `:teams` adds `teams: { "Red" => 12 }`; `:table` writes `score: 96` and players with
  `nil` scores, replacing the `{"": 0}` workaround.
- **Task 283 change:** skip the prompt when `data.play_id` is present. This is a Jil
  change, so it goes through the full workflow: `Jil::Validator.validate!` spec +
  behavioural spec (event with `play_id` → no `Prompt.create`; event without → prompt as
  before) → delete both specs → prodExec script (idempotent, prints `already applied` /
  `WROTE task 283`).
- Correcting start/duration later from the play page updates the linked ActionEvent.

Timing of the write is Question 1.

---

## Build order

Each phase ships on its own and is usable.

1. **Models + sync API** — migrations (generated, real timestamps, `RAILS_ENV=test`),
   models, `GamesController` (pages) + `Games::SyncController` (idempotent upsert by
   `client_uuid`). Request specs for replay-safety and voids.
2. **Play screen, manual entry** — the core loop: start a one-off game with typed
   players and `2d6`, tap values, auto-advance, undo, last-3 history, edit a past roll,
   override the roller, custom value. Offline queue, wake lock, manifest + worker.
   *This is the phase to try at a real game before going further.*
3. **Templates + setup + play again** — template CRUD, recent-player chips, ordering,
   teams, settings snapshot.
4. **End game + ActionEvent** — final scores, winner, time correction, ActionEvent
   write, task 283 change through the Jil workflow.
5. **Score tracking** — score sheet, presets, team/table modes.
6. **Stats** — `GamePlay::Stats` + spec, end-of-game view, per-game and per-player
   pages.
7. **History index** — merged feed with legacy events, filters, per-game page; alias
   merge for drifted names; seed templates from the distinct legacy names.
8. **Virtual dice** — ROLL mode, faces, custom spec, switch mid-game; swap `roll.js` to
   `crypto.getRandomValues`.

---

## Open questions

1. **When is the ActionEvent written?**
   - *At Save (recommended)* — one write with the final scores; task 283 skips it.
     A game that's abandoned never appears as a played game.
   - *At Start, updated at Save* — the game shows up in the event log while it's
     happening (Buddy/dashboards would see "playing Catan"), but abandoned games need
     cleaning up.
2. **Does any game need several rolls per turn, or per-die values** (e.g. Yahtzee
   keeps individual dice, some games roll two different dice and the colours matter)?
   v1 records a total per roll; per-die manual entry is a bigger UI.
3. **One device per game?** v1 assumes one phone records. A second phone watching live
   (or two people entering) means ActionCable and conflict handling.
4. **Legacy name drift** — merge `Parks & Potions`/`Parks and Potions` and
   `Mycelia`/`Mycelia Cards` into one template each by rewriting the old events'
   `notes`, or only alias them for display and leave the rows alone?
5. **Player identity** — free-text names (recommended for v1), or link names to the
   household users / Contacts so stats follow a person across spellings?
