# Buddy: memory merge, follow-ups, and prompt slimming

Design settled in conversation on 2026-08-18/19, and **built on 2026-08-19**.
Numbers are measured against production unless noted.

> **STATUS: implemented, not deployed.** Every section below except §7 (tool
> grouping, deliberately deferred) is written and green — 6,739 examples, 0
> failures. What remains is the deploy and one prodExec:
>
> ```
> prodExec lib/scripts/merge_buddy_ideas_into_memories.rb
> ```
>
> Run it AFTER the deploy — it needs the new columns. Until it runs, the 39
> legacy `buddy_ideas` rows are invisible to Buddy (nothing reads that table any
> more) and the 17 existing memories still read as `concept`, which means they
> stop shipping inline. The script fixes both and is idempotent.
>
> **Two deviations from this plan, both deliberate — see "Deviations" at the
> bottom.**

## Why any of this

A Buddy turn costs **~55,090 input tokens for an average 88-token reply** — 936
turns over 14 days, $16.63, with only 35,481 of the input landing in cache.
History is under a fifth of that. The rest is fixed: the system prompt and the
tool schemas, shipped whole on every turn.

`TokenEstimator::FIXED_OVERHEAD` breaks it down (measured 2026-08-05):

```
system prompt      ~25,206
registry schemas   ~18,422   (46 tools)
Turn's own tools    ~2,210   (get_context, read_prompt, view_image, …)
                   ────────
                    45,838
```

**That measurement is stale** — there are 64 tool files now, not 46, so the
schema half has grown by roughly 40% and nothing has re-measured it. Re-measure
before making decisions off these numbers, per the recipe in the constant's own
comment (against a user with every feature, taking the array from
`Turn#tools` rather than the registry).

The goal is not "send less" for its own sake. It is: keep everything Buddy can
currently do, reachable on demand, without paying for all of it on every
"morning!".

---

## 1. Prompt ordering — DONE (uncommitted)

`Buddy::Personality.for` now runs steadiest-first:

```
persona → tone profile → rules (+mood/glossary/icons) → get_context guide
   → not-wired → household roster → routines → memories
      → open loops → conversation notes → recap
         → at-a-glance counts → clock
```

The clock was line one and renders to the minute (`%-I:%M %p`), which ended the
cache prefix ahead of ~25k of text that never changes. It is now last, which is
also the most-attended position in the prompt, so the "impossible to miss" note
it used to carry is satisfied rather than traded away.

2,232 Buddy examples pass. No spec asserted ordering; they all assert content
with `include`. RuboCop reports only the pre-existing `ModuleLength` (comments
don't count toward it).

**Not verified yet:** the actual cache improvement. Watch `avg_cached` against
`avg_in` in `buddy_usages` over a day of normal use — the gap should close
toward the fixed block. Behavioral check is `rake buddy:eval` or
`rake "buddy:replay[<convo>,30]"`; both make real billed calls, so they're the
owner's to run.

---

## 2. Merge BuddyIdea + BuddyMemory into one table

**Decided.** One table for everything Buddy holds about a person. The
`BuddyIdea` UI is effectively unused and gets deleted rather than migrated.

### Shape

| Field | Notes |
|---|---|
| `type` (integer enum) | `followup`, `stash`, `concept`, `preference`, … |
| `severity` (integer 0–100) | **A scale, not an enum.** 0 = utterly unimportant, never needs raising again. 100 = the most critical thing in this person's life, genuinely front-of-mind and staying that way. The range matters because the widened capture rules (below) will produce a lot of records at the low end, and a four-value enum can't separate "worth keeping" from "worth interrupting for". |
| `priority` (integer) | **already exists** — a reinforcement counter, bumped by `reinforce!` on re-mention. Kept alongside severity; they are different axes. A dying cat is severity-high at priority 0; a preference mentioned nine times is the reverse. |
| `tags` (jsonb) | **already exists on `buddy_memories` and is empty on all 17 rows.** The primary retrieval mechanism — see below. |
| notes | optional thread (`BuddyIdeaNote`). A `concept` never grows notes; a `followup` does. One table with optional notes rather than a subtype. |
| `check_in_at`, `checked_in_at` | see §3 — both mutable, and re-armable |
| `expires_at`, `last_used_at` | already on `buddy_memories` |

The `type` enum must be **integer-backed** (project rule — never string values
on a string column). `severity` is a plain integer, so it needs a range
validation rather than an enum.

### Tags replace the recall cap

`Buddy::Personality::MEMORY_RECALL_LIMIT = 30` exists only to bound prompt size:
`memories_block` injects `for_recall.limit(30)` on every turn, ordered by
priority then recency. **Retire it in favor of tags rather than raising it.**

A cap is the wrong instrument once capture widens. It silently drops the tail,
and it drops by *reinforcement count*, so a fact mentioned once and never
repeated — which is exactly the sleeping-bags case — is first out the moment the
list grows past 30. The failure is invisible: nothing anywhere says a memory was
withheld.

So tags are wanted **now**, not once the cap is outgrown:

- **`preference`-type records ship inline every turn.** That's the always-loaded
  set, and it's small by construction.
- **Everything else is fetched by tag** when the conversation touches it —
  "camping" pulls the sleeping bags, "work" pulls the job situation. This is the
  same retrieval the follow-up compiler needs when it gathers context around a
  message, so one mechanism serves both.
- Tagging happens in the **background write** (§4), which is already reading the
  whole stretch with a cheap model. Asking it for tags costs nothing extra and
  it has far better material to tag from than a mid-turn tool call would.

### `preference` earns its own type

`preference` is the type that **stays inline in every prompt**. Everything else
is fetched or searched. This gives the always-loaded set a name, so "why is this
in every prompt" has an answer other than "it always was".

### Widened capture rules

Today `remember` says durable facts only and explicitly excludes
"conversational trivia" — which is why the sleeping-bags case can't work. An
**episode with a lesson in it** ("we forgot our sleeping bags", "the pharmacy
closes early on Sundays") is worth keeping precisely because it's useful once,
months later, in a context nobody can predict. That's a different category from
a standing preference, and the current rules have no room for the second kind.

Target behavior:

> User (months earlier): "We forgot our sleeping bags when we went camping!"
> User: "We're going camping this weekend."
> Buddy: "Don't forget your sleeping bags this time. ;)"

Note this would already work today at 17 memories against a
`MEMORY_RECALL_LIMIT` of 30 — everything is injected wholesale. Tags matter at
the point the count outgrows the cap, which is when recall has to become "what's
relevant to camping" instead of "here's all of it".

### Admin UI

Browse / edit / delete these records. Goes on the **System page**, following the
existing pattern (`system/index`, `connections`, `gpt_spending`, `banking` — a
controller action, a view, a route). **Explicitly NOT in Byte.**

### Open

- **`category` (me/home/work)**: fold into a tag, with a fixed way for the user
  to phrase something so it gets that tag automatically — or keep it as its own
  column. Either is acceptable; undecided. Three taxonomies (category + type +
  tags) is one too many, so it should not simply survive untouched.
- Full value list for `type`.
- How a record becomes "live" for §3 — an explicit `relevant_at`, or derived
  from the check-in time itself. Needed either way, since severity alone can't
  order the queue.

---

## 3. Follow-ups / check-ins

Buddy schedules a background turn to come back to something later — a concern, a
rough day, a project worth asking after.

> User: "My cat is really sick, should I take it to the hospital?"
> *(quietly notes to check on the cat in a couple of hours or tomorrow)*
> Buddy: "I'm sorry to hear that! Yes, that sounds like a good idea. I hope
> everything is okay — I'm here if you need anything."

### Firing

`check_in_at` on the merged record, **not** a `BuddyReminder` row. A reminder is
visible in `list_reminders` and in context as pending, and the person never
asked for it — a queued check-in they can see reads as a promise Buddy made,
when the whole point is that it may quietly never happen.

The delivery mechanism already exists and has **never run in production**:
`BuddyReminder(kind: :prompt)` → `ReminderFirer#deliver_prompted_reminder` →
`CompanionDelivery.deliver_prompt` seeds a hidden trigger message and lets the
model compose the line at fire time with full context. Prod has 8 reminders,
zero of kind `prompt`; 39 ideas, zero with `remind_after`. The path is built and
cold — expect to shake it out.

### Subjects: concerns are first-class

A sick cat is the central case, not an edge case. The distinction between a
`stash` and a `followup` is **how it surfaces**, not whether it deserves
attention:

- a stashed idea is *offered* in a lull ("you've been sitting on the greenhouse")
- a concern is *asked about*, at a chosen moment, and never offered as a
  spare-time suggestion

### No quota — the pending set is an input, not a cap

An earlier draft capped this at one open check-in per user. That was wrong twice
over: one person may need none while another genuinely has a sick cat *and* a
mother with a broken leg, and a floor with an empty slot in it invites the model
to invent something to fill it.

Instead, Buddy sees every pending follow-up and uses it to decide:

- **whether to schedule at all** — if an affirmation check-in is already coming,
  a second one for the same bad day is excessive
- **when** — a new higher-severity concern takes the near slot and pushes the
  lesser one to another day. Nothing is dropped; it is re-placed.
- Re-planning can happen at any point, not only at creation.

**Spacing (starting default, easy to loosen):** no two check-ins on the same
day, and never two in one sitting.

### Severity is not the running order

High severity does **not** mean "next up". Someone reporting that their mother
has surgery next week is recording something serious that isn't actionable for
six days; checking in on it tomorrow is worse than useless. Severity says *how
much this matters*; it says nothing about *when it's live*.

So placement needs its own notion of when a record becomes relevant — the date
the surgery happens, the evening after a hard day, an hour after a vet visit.
The running order is **relevance-now first, severity as the tiebreak among
things that are equally live.** A severity-90 item that isn't live yet sits
behind a severity-40 item that is.

### Placement in the day — fixed bands

Rather than deriving a slot per person, use hardcoded bands matched to what the
check-in is for:

| Band | Use |
|---|---|
| **09:00–10:00** | an hour or so after the Today summary — the "relevant today" ones |
| **13:00–16:00** | occasional, for lighter check-ins |
| **18:00–20:00** | the most common slot |
| **22:00–23:00** | occasional — general affirmations and emotional check-ins |

This is simpler than a derived profile and lands in roughly the same places. For
reference, 30 days of message history gives:

```
07–01  active every hour (peak 09–15)
02–03  ~2 messages each
04–06  nothing at all
```

so the bands sit inside real waking hours without needing to compute them. Never
fire outside a band.

### Fire-time gates

Both **recompute** rather than skip:

1. **Mid-conversation** — bump to an hour past the person's most recent message,
   then re-check. *Trap:* in `byte_messages`, `outbound` is the **person's**
   message and `inbound` is **Buddy's**. Implementing "an hour after the user's
   last message" off the enum name gets it exactly inverted.
2. **Thread moved since it was set** — the compile pass is shown every open
   follow-up by id and returns `updates` for any the conversation touched:
   - `resolved` → status `done`, check-in disarmed, nothing asks again
   - `answered` → the update lands on the thread as a note, and the check-in is
     re-armed further out (or disarmed if their update read like the end of it)
   - `dropped` → no longer worth asking about at all

   **A volunteered emotional update resolves an emotional check-in.** This is
   the case that most needs it: those check-ins get armed readily and go stale
   fastest, and the worst version of this whole feature is a companion asking
   how you're feeling six hours after you told it. A good day reported
   unprompted answers "how are they doing" completely.

   The compile only ever updates follow-ups belonging to the person whose
   conversation it is, whatever id comes back.

### Ignored dies; answered can re-arm

Both stamps are **mutable**, and the two outcomes are deliberately different:

- **Ignored** — Buddy asked, the person didn't engage. It never comes back,
  never reminds, never escalates. This is the promise that makes the whole
  feature safe to ship.
- **Answered** — the person replied, and the reply is itself new material. *"Cat
  is still in the hospital, she's doing okay for now"* is not a resolution; it's
  a reason to look in again in a couple of days. `checked_in_at` records that
  the last one happened, and `check_in_at` gets set forward again.

So `checked_in_at` is a **last-checked stamp, not a terminal seal**. What ends a
record is its status going resolved (or severity dropping to ~0), not the fact
that a check-in once fired against it. The re-arm decision is made by the same
background pass that made the original one, off the answer the person gave.

### The decision is made in the background, not by an in-the-moment tool

Do **not** ship a `check_in_on` tool for the model to call mid-turn.
`IdeaDwell`'s own header is the evidence: `elaborate_idea` shipped with an
explicit instruction to reach for it whenever someone builds on a held idea, and
a 22-minute design conversation produced zero calls, because the general "pure
conversation takes no tools" rule beat the specific instruction. The same
failure would show up here in both directions — missed when it matters, fired on
trivia.

Decide it where `IdeaDwell` already decides things: end of turn, stretch
finished, cheap model reading the whole stretch back. It judges a *completed
stretch* rather than a single message, which is the right unit.

---

## 4. Background writes

Buddy must not stall while it sorts through tools and memories. Someone who has
just said their cat is dying should not wait five minutes for a reply.

The pattern is already built and proven: `BuddyIdeaSettleWorker` → `IdeaDwell`
runs at end of turn on `gpt-5.4-mini`, reads the transcript back, writes prose,
and is entirely invisible (4 runs in 14 days, ~940 input tokens each,
effectively free).

**Generalize that worker** rather than building a second thing that looks like
it.

### Flag, then settle on quiet

1. A turn notices the message carried something worth keeping and **flags the
   conversation** (a column + a timestamp; the flag is cheap and says nothing
   about *what* was noteworthy).
2. A compile job is scheduled for roughly an hour out.
3. Every further message **pushes that time back**. The job only ever runs once
   the conversation has actually gone quiet.
4. When it runs, it gathers the context around the flagged stretch and compiles
   everything at once — memories, tags, follow-ups.

**Implementation note:** don't track and cancel Sidekiq jids. Follow
`TimerFireWorker`, which fires, compares against the stored target, and calls
`perform_at` again when it's early. Store the target time on the conversation;
the job re-reads it, reschedules if messages have landed since, and does the
work otherwise. Idempotent, no jid bookkeeping, and it survives a dropped job.

### Two end conditions, not one

`IdeaDwell`'s header argues hard against clocks — *"elapsed time says nothing
about whether a thought is finished"* — and it's right about the question it was
asking, which is whether a **subject** is done. That's what `moved_on?` answers.

"Has the conversation stopped" is a different question, and a clock is the
correct instrument for that one. The two coexist: compile on **topic move
(`moved_on?`) or on quiet (the timer), whichever comes first.** The timer alone
would hold a finished thought for an hour; `moved_on?` alone never fires for
someone who says one heavy thing and closes the app.

### One message can produce several records

This is not the exception. Real example — message 3907:

> "Just noticed that my CSCR has flared up a bit today. Likely related to the
> fact that I heard that I'll be out of a job before the end of the year."

That single message carries at least three separate things:

- **the eye condition** — a follow-up, further out
- **the stress right now** — a follow-up, soon
- **the job situation** — a durable memory *and* a later follow-up, tagged
  `work`, with real severity

So the compiler returns a **list**, not one item, and the pieces get different
severities, different tags and different check-in times from the same source
message. A design that assumes one record per message gets this case wrong in
the most visible way possible.

---

## 5. Conversation search tool

New tool: search **the current conversation, or all of the user's
conversations**.

> "What was that thing I was talking to Moss about earlier today?"
> "I told you I needed to pick up my cousins from the airport — what day?"

Feasibility is not a concern: 3,906 messages, 4.8 MB, since Jul 23, with
`index_byte_messages_on_user_id_and_created_at` already in place. Plain ILIKE is
fine for years. The DB has only `uuid-ossp` and `pg_stat_statements` — **no
`pg_trgm` or tsvector, and none needed.**

Two hard constraints:

- spans the user's own Buddy threads, **never** another user's
- skips hidden trigger messages, action chips, `buddy_activity` receipts and
  watch-fired posts — reuse the `IdeaDwell#skip?` rules. Otherwise "what did I
  say about the airport" returns quick-action prompts nobody wrote.

Model it on `search_ideas` / `Buddy::IdeaSearch` (`auto: true`, `answers: true`
— a lookup that settles inside the turn instead of raising a permission
checkbox).

---

## 6. Short-term / topic-scoped memory

Today's history is **not** "X messages" — it's everything since
`buddy_recap_at`, with `MAX_MESSAGES = 100` only as a safety net for when
compaction has been failing silently. `Compactor` fires on **size and elapsed
time** (≥20% of available window → hard; ≥10% + 20 min quiet → soft). It is
completely topic-blind.

The topic-change primitive already exists and is running: `IdeaDwell#moved_on?`
— the last 4 messages containing none of the subject's own vocabulary, counted
in **messages rather than minutes**, because *"elapsed time says nothing about
whether a thought is finished"* (a person thinking at one message an hour would
have had every message look like an ending under a clock-based rule).

Design:

- a **topic slot** on the conversation — what's being talked about right now
- invalidated by `moved_on?`
- on invalidation, the outgoing stretch distills into the merged long-term table
  (which is what `IdeaDwell` already does for ideas, generalized)
- verbatim recent messages stay underneath it, unchanged

---

## 7. Tool grouping — DEFERRED, and gated

Standing instruction: **rather ship every tool in every prompt than degrade tool
choice, logic, or behavior in any way.**

Worth being precise about the actual risk. It isn't that the model has fewer
tools in hand — it's that it **doesn't know a capability exists** and tells the
person no. The Rules already carry a scar from this: a whole paragraph about
`remind_when` accepting `trigger: "deploy"`, written because Buddy said it
couldn't do something it always could. A wrong "I can't" is the expensive
failure, because people stop asking. Lazy-loading manufactures exactly that.

So this is last, and it is empirically gated rather than argued:

```
rake buddy:eval                    # canned scenarios, each with a documented PASS
rake "buddy:replay[<convo>,30]"    # replays 30 REAL messages, read-only
```

Tools are resolved but not executed, so tool *choice* is visible without side
effects. Run the same real messages before and after; **if tool choice moves at
all, the change loses.**

Do the prompt side first — it's the bigger half (~25k vs ~18–26k), and the merge
in §2 makes `memories_block`, `open_loops_block`, `routines_block` and the
glossary fetchable instead of inline. Same win, none of this risk.

---

## Suggested order

1. ~~Prompt reorder~~ — DONE, measure the cache effect
2. ~~Merged table + migration + admin UI on the System page~~ — DONE
3. ~~Tag-based recall; retire `MEMORY_RECALL_LIMIT`; keep `preference` inline~~ —
   DONE (see Deviations for the two blocks that stayed inline)
4. ~~Conversation search tool~~ — DONE
5. ~~Background compile worker (flag → reschedule → compile a list)~~ — DONE
6. ~~Follow-ups: `check_in_at`, the re-planner, day bands, fire-time gates~~ — DONE
7. ~~Topic-scoped short-term memory~~ — DONE
8. Tool grouping — **still deferred.** Only if 1–3 leave something worth
   chasing, and only behind the eval gate.

5 was built ahead of 6: the compiler is what decides a follow-up exists, sets its
severity and tags, and re-arms it after an answer. Building the scheduler first
would have left nothing to schedule.

## Left for after the deploy

- Run the backfill (see STATUS at the top).
- Once it has run and been eyeballed at `/system/memories`: drop `buddy_ideas`
  and `buddy_idea_notes`, and delete `BuddyIdea` / `BuddyIdeaNote` plus the
  legacy `has_many :buddy_ideas` on User. Nothing else reads them.
- Re-measure `FIXED_OVERHEAD`. It's stamped 2026-08-05 at 46 tools; there are 64
  now, plus two more added here, and `memories_block` shrank.
- Watch `avg_cached` against `avg_in` in `buddy_usages` for the prompt-reorder
  payoff.

## 8. The sticky face — separate bug, same message

Message 3908 answered the CSCR / job-loss message above with the right words
(*"Oh no. That's a lot to get hit with at once. I'm sorry, that sounds really
rough."*) while wearing a **happy** expression.

The mechanism, not the one-off: `Buddy::ExpressionState` says the mood *"stays
put until something DELIBERATELY changes it"* and *"does NOT drift back to a
default on its own."* Message 3908's metadata carries no mood at all — the model
emitted no `[[mood:]]` marker and called no `set_mood` — so the face left over
from an earlier cheerful turn simply stayed on.

That is the default behavior, and it fails hardest exactly where it's most
visible: the heavier the news, the more wrong a stale grin looks. The eval shows
the model *can* do this right (`today was genuinely rough` → `set_mood(sad)`),
so there is guidance but no floor.

The background pass in §4 is the natural place to catch it — it's already
reading the stretch with a cheap model and can check the face against what was
actually said. Tradeoff worth stating: correcting after delivery moves the face
a beat late, which the personality explicitly complains about (*"instead of the
face catching up a beat late"*). A beat late still beats an hour wrong.

Worth noting alongside: that turn cost **130,048 input tokens** with only 64,512
cached — well above the 55k average, since the thread was long and pre-compact.
Real turns get much more expensive than the mean suggests.

## Deviations from this plan, and why

**1. `routines_block` and `open_loops_block` stayed inline.**

§3 of the build order called for moving the now-fetchable blocks out of the
prompt. `memories_block` moved — that's the big one, up to 30 rows of up to 500
characters each. The other two did not, and shouldn't:

- `routines_block` carries a **documented prod regression** from exactly this
  change. Its own comment: *"Routines used to be reachable only through
  `get_context`, and the rule above says not to go fetching that section on the
  chance a phrase might be one... Prod 2183: 'log cup water', against a saved
  **water cup** that marks three waters, logged one."* Moving it out is a change
  that has already been made once and reverted.
- `open_loops_block` exists to answer *"am I about to drop something?"* on turns
  where it never occurred to Buddy to ask — which is every turn where something
  actually goes missing. Behind a tool call it only surfaces once already
  remembered.

Both are small: routine names are a few words each, open loops are capped at 15
one-line entries, and both are nil for anyone with none. The cost was never in
those two.

**2. `category` kept its own column instead of folding into a tag.**

The plan left this open. It turned out to be load-bearing across the whole stash
flow — `Stash#apply_sort`, `sort_stash`, `move_idea`, `stash_idea`, the
category-labelled receipts — so folding it in meant rewriting working code for a
change nobody had decided on. It stays a column, and `MemorySearch.tagged`
matches it alongside tags, so retrieval is still one path and a caller searching
"work" needn't know which field holds the word.

## What was built where

| Piece | Lives in |
|---|---|
| Merged table | `BuddyMemory`, `BuddyMemoryNote`; 3 migrations |
| Recall | `Buddy::MemorySearch`, `search_memories` tool, `Personality#memories_block` |
| Conversation search | `Buddy::ConversationSearch`, `search_conversations` tool |
| Background compile | `Buddy::Compile`, `BuddyCompileWorker`, flagged from `TurnDispatcher` |
| Check-ins | `Buddy::CheckIns`, `BuddyCheckInWorker` |
| Topic memory | `Buddy::TopicState`, settled by `BuddyIdeaSettleWorker` |
| Admin | `SystemController#memories`, `/system/memories` |
| Backfill | `lib/scripts/merge_buddy_ideas_into_memories.rb` |

`remember` now writes `kind: :preference` so anything explicitly remembered still
ships inline exactly as before — the widened capture comes from `Buddy::Compile`
as `concept`/`followup`, tagged and reached by search. That is what makes the
merge a no-op for existing behavior.

One thing the merge made newly ambiguous and had to be fixed: `remember`'s
dedupe and `forget`'s substring match now share a table with the stash, so both
are scoped to `[:preference, :concept]`. Otherwise a remembered fact could
reinforce — and overwrite the text of — a held idea that happened to share six
words with it.
## 9. Announcements on the next Today — REMOVED

Queue a note for somebody, ride it along on their next Today briefing, said in
the companion's own words. Built, shipped, and taken back out on 19 Aug.

It never worked once. Three briefings running had the block sitting in the seed
intact — verified in the message rows, not inferred — and said nothing from it.
The block competed with ~13k characters of *forward-looking only*, *mention
fewer things*, *cut padding*, *three to five lines*, and an announcement is none
of those: not on the agenda, not still-ahead, and indistinguishable from padding
under the subtraction test. Two rounds of stronger wording changed nothing, and
moving the block last — below the rules arguing against it — cost the briefing
entirely: the reply came back as a bare offer of help with no briefing in it.

What's worth keeping from it, if this is ever tried again:

- **The delivery path was never the problem.** Both losses were on turns that
  succeeded. A deferred claim, a retry, a re-queue on failure — none of them
  would have fired, because nothing failed.
- **Verifying the reply is the only mechanism with teeth**, and it is a
  heuristic (word-stem overlap) that has to be capped or it re-says a delivered
  note every morning. That it was needed at all is the tell.
- **A briefing prompt this long has a budget.** Anything added to it is arguing
  against everything already in it, and position in the prompt decides how much
  argument comes after — not how prominent the thing is in the answer.
- If somebody needs to be told something, a message of its own says it. Folding
  it into a message whose whole design is *say less* was the wrong host.

`20260819042151` had already reached production, so removal is
`20260819065044_drop_buddy_announcements`, not a deleted file.

## 10. Pile entries that were never thoughts

About a third of the migrated stash turned out not to be ideas: repeating jobs,
one-offs naming a clock time, and bare nouns from a dictated list. The merge
didn't cause this — it was mis-filed at capture and copied across verbatim — but
`/system/memories` was the first time it was all visible at once.

**Retroactive:** `lib/scripts/tidy_misfiled_stash_memories.rb`. Four became real
recurring `BuddyReminder`s and came off the pile; ten were dropped with the
reason written onto the thread; twenty-three genuine one-off tasks were left
alone, because a task with no clock on it is exactly what a pile is for. Nothing
deleted — `status: :dropped` keeps the row visible and un-dropping is a click.

**Prospective, two halves:**

- `Buddy::Stash::TIME_BOUND_RX` + `time_bound_closing` — the counterpart to
  `RECURRING_RX`. A recurring item merely gets an OFFER, because it can wait; a
  one-off naming a moment gets SET, because "want me to set that?" answered
  twenty minutes later is a reminder that already missed.
- `Buddy::Stash.misfiled_kind` marks flagged entries `REPEATS` / `NAMES A TIME`
  inside `open_loops_block`. This is the half that matters: `destination`
  ("WHAT IS IT?") shipped 6 Aug and works, but a capture-time fix can only ever
  help things captured after it. 13 of the 15 mis-filed entries predate it, and
  nothing ever went back for them. Marking them where the pile is *already
  being read* costs nothing, needs no sweep and no clock, and gives Buddy
  somewhere to notice. Buddy is told to wait until the subject comes up rather
  than audit the pile at anybody, and to offer `drop_idea` when the moment has
  already gone. The line renders only when something is actually flagged.

Worth knowing: `destination`'s comment cites memory 58's exact sentence
("Please ping me when it's time to do that!") as the prod case that drove it —
and 58 was still sitting on the pile when this was written. The fix was real;
nothing applied it backwards.

## Announcements are mostly about the companion

The intended use is telling people what's changing about their companion, so the
prompt says those are to be spoken in the first person as a thing about itself
("I can look back through our old conversations now") and never as a release
note, an update, a feature or a version. It also asks for rough edges to be
named plainly — being told what to watch for is the reason it's worth
mentioning, and a change described as seamless is how somebody ends up believing
they broke it.

## Decided since

- **Journal** — covered by memories plus conversation search; no separate
  system. Possibly worth a small tool that lets Buddy write an explicit journal
  entry from what the person said, but nothing more.
- **Finances** — **skipped.** Went a different direction.
- **Mood/energy check-in** — covered by the memory changes; no separate trend
  work.

## Tabled deliberately

- **MealBuilder / meal logging** — valid, not now.
- **Sub-chore decomposition** — good idea; needs a confirmation step at whatever
  level. The container pattern already supports nesting with no new code.
