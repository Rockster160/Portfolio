# Manual evaluation harness for Buddy's prose and tool selection.
#
# Deliberately NOT a spec. These make real, billed calls to OpenAI and their
# output is judged by eye, not asserted — putting that in `rspec` would make the
# suite slow, flaky, and expensive. Specs cover the plumbing offline via
# FakeBuddyClient; this covers "does it still sound like Buddy and reach for the
# right tool".
#
#   # Canned scenarios that exercise the rules most likely to regress:
#   bx rails buddy:eval
#
#   # One sentence per tool, checking the right tool is the one reached,
#   # then the turns that have already gone wrong once:
#   bx rails buddy:eval_tools
#   bx rails "buddy:eval_tools[idea]"    # just the tools whose name matches
#   bx rails buddy:tool_coverage         # free: does every tool have a sentence?
#
#   # Only the ones that have gone wrong before:
#   bx rails buddy:eval_edges
#   bx rails "buddy:eval_edges[timer]"   # matches tool, prod id, or the sentence
#
#   # One ad-hoc message:
#   bx rails "buddy:eval_one[I just took the recycling out]"
#
#   # Replay real messages from a conversation (source is read-only):
#   bx rails "buddy:replay[123,20]"
#
#   # Wipe the eval threads and their usage rows when they get noisy:
#   bx rails buddy:eval_clear
#
# EVERY run writes tmp/buddy_eval/report.md and prints the path. It holds the
# probes that missed, the turns that tripped a mechanical check, and — for a
# scenario run, which has no automatic verdict at all — every turn beside the
# sentence saying what a pass looks like. It's written to be handed straight to
# a coding agent, which is the only form in which a run's findings survive: a
# terminal scrollback gets judged once and then scrolls away.
#
# Every run writes into a dedicated per-theme "Eval" conversation so the
# back-and-forth is readable in the app afterwards, and so the spend is
# ATTRIBUTED. These are real, billed calls; before this they left no trace, and
# a few afternoons of tuning could quietly outspend a month of actual use with
# nothing in `buddy:cost` to show for it. Usage rows are written with
# `kind: :eval` so they never contaminate the real per-turn numbers.
#
# What still does NOT happen: the turn runs through the client directly rather
# than Buddy::GPT::Turn, so no proposals, moods, memories, or tool EXECUTIONS
# are created. Tools are resolved (so the model sees real "no chore matches
# that" errors) and then stopped.
#
# Set BUDDY_EVAL_PERSIST=0 to go back to leaving no trace at all.

require Rails.root.join("lib/buddy_eval_world")
require Rails.root.join("lib/buddy_eval_report")
require Rails.root.join("lib/buddy_eval_needs")

# The behaviors most worth eyeballing after a prompt or model change, and what
# a PASS looks like for each.
#
# `want:` used to be a trailing comment, which meant the run printed a reply
# with nothing to hold it against and the report couldn't say anything at all
# about a scenario turn. It's data now: the terminal still shows it beside the
# reply, and it goes into the report so the agent reading it is judging against
# the same sentence a person would have.
#
# The second half is drawn from real conversations rather than invented, because
# the invented set missed whole categories: bare-duration timers, undo and
# correction, retroactive completion, pebble rewards, and history questions that
# need chore_progress instead of get_context (which only knows about today).
# For the genuine article, use `bx rails "buddy:replay[<conversation_id>,30]"`.
BUDDY_EVAL_SCENARIOS = [
  # --- core logging and action ---
  { say: "hey", want: "get_context + a short briefing, WITH prose" },
  { say: "morning!", want: "the same, and the greeting matches the actual hour" },
  { say: "just finished a 14oz cup of water", want: "checks chores_all before falling back to log_event" },
  { say: "took the recycling out twice", want: "complete_chore count 2, NEVER log_event" },
  { say: "ate a sandwich", want: "log_event, an ingestion" },
  { say: "I alphabetized the spice rack", want: "no chore matches, so create_chore + complete_chore" },
  { say: "did 20 pushups", want: "log_event with a count" },
  { say: "add oat milk to the groceries", want: "add_list_item" },

  # --- reminders, timed and conditional ---
  { say: "remind me to call mom at 6", want: "ONE schedule_reminder, at the next 6 that hasn't happened" },
  { say: "remind me to grab my rx next time I'm at Costco", want: "remind_when, not schedule_reminder" },
  { say: "5m", want: "a bare duration is a timer, set without interrogation" },
  {
    say:  "remind me once Chelsea gets back home to switch the music",
    want: "remind_when on her arriving, which resolves through her car",
  },

  # --- correction and undo, which real use is full of ---
  { say: "I accidentally logged a Strawberry Celsius this morning", want: "delete_event, never a second log" },
  { say: "actually mark that as done about an hour ago", want: "complete_chore with a PAST `at`" },
  {
    say:  "no, 10p means 10 pebbles as the reward",
    want: "reads Np as a reward, and never says it can't set one",
  },

  # --- chore setup with household shorthand ---
  {
    say:  "add a new chore for filling the kitty litter, sub of refill item, for 2p",
    want: "create_chore under that parent, reward 2",
  },

  # --- lookups that today's context can't answer ---
  { say: "does it show that I got a car wash yesterday?", want: "chore_progress or search_events, NOT get_context" },
  { say: "how many celsius did I drink last month?", want: "search_events with a timestamp bound, never a guess" },
  { say: "how's the weather right now? I may take the bike", want: "check_weather" },

  # --- the printer, where guessing a file name costs hours ---
  { say: "print that phone thing from earlier again", want: "print_history FIRST, and only then the reprint" },
  { say: "how long did that vase print take?", want: "print_history, and never an invented duration" },

  # --- conversation and boundaries ---
  {
    say:  "what's that detached mini house that butlers usually have called?",
    want: "just answers, no tools",
  },
  { say: "can you run a script to fix my chores?", want: "refuses warmly. No code, no \"let me run\"" },
  { say: "today was genuinely rough", want: "a mood AND warm prose, never an empty bubble" },
  { say: "I always drink oat milk lattes", want: "remember" },
  { say: "what time is it?", want: "12-hour local, never UTC" },
].freeze

# One sentence per registered tool, and the tool it has to reach.
#
# The scenarios above ask "does this still sound like Buddy". This asks the
# other question, which nothing was asking: given a plain sentence, does the
# model pick the RIGHT tool? A description that reads beautifully and never
# gets chosen is worth nothing, and the failure is invisible from the inside -
# the reply is fluent, something happens, and it's the wrong something. Every
# real mis-selection this year (a reminder where a cycle was asked for, an
# immediate list-add where a delay was asked for) looked fine in prose.
#
# The table is keyed by tool name so `buddy:tool_coverage` can hold it against
# the registry: a tool nobody wrote a sentence for is a tool nobody knows the
# model can find. Adding a tool without adding a line here fails that check
# before a penny is spent.
#
# Entry is the sentence, or a hash:
#   say:   what the person says
#   with:  other tools that must ALSO be called for this to be right
#   avoid: tools that must NOT be called (the near-miss it gets confused with)
#   needs: a precondition in the acting user's real data. A miss on one of
#          these is reported apart from the rest, because "no idea to defer"
#          and "reached for the wrong tool" are different problems and only one
#          of them is about the description.
BUDDY_TOOL_PROBES = {
  # --- logging, chores, lists ---
  log_event:              { say: "ate a sandwich", avoid: %i[complete_chore] },
  complete_chore:         {
    say:          "took the recycling out twice",
    avoid:        %i[log_event],
    needs:        :recycling_chore,
    run:          true,
    baseline:     ->(u) { BuddyEvalNeeds.completions(u, /recycl/i) },
    effect_label: "the recycling chore didn't get marked twice",
    effect:       ->(u, before) { BuddyEvalNeeds.completions(u, /recycl/i) - before.to_i == 2 },
  },
  create_chore:           "add a new chore for filling the kitty litter every Sunday",
  edit_chore:             { say: "rename the recycling chore to bins", needs: :recycling_chore },
  edit_chore_completion:  { say: "add a note to the water chore I ticked off earlier - hint raspberry", needs: :water_completion },
  # Runs for real and checks the row is gone. Resolving is not the same as the
  # completion going away, and prod 3171 is what the gap between those looks
  # like — reported as pulled down over something that was only ever proposed.
  undo_chore_completion:  {
    say:          "I marked the recycling done by mistake, take it back off",
    needs:        :recycling_completion,
    run:          true,
    baseline:     ->(u) { BuddyEvalNeeds.completions(u, /recycl/i) },
    effect_label: "the recycling completion is still there",
    effect:       ->(u, before) { BuddyEvalNeeds.completions(u, /recycl/i) == before.to_i - 1 },
  },
  chore_progress:         "did I get all my dailies done yesterday?",
  withdraw_pebbles:       "took 20 pebbles for the arcade",
  # "this morning" is a claim about the clock, and asked at half past midnight
  # it's a claim about a morning that hasn't happened. The tool is what's being
  # tested, not time parsing.
  delete_event:           { say: "I logged a Strawberry Celsius by accident earlier, get rid of it", needs: :celsius_today },
  edit_event:             { say: "that sandwich I logged was actually at 1", needs: :sandwich_today },
  search_events:          "how many celsius did I drink last month?",
  add_list_item:          {
    say:          "add hazelnut creamer to the groceries",
    run:          true,
    avoid:        %i[schedule_list_items],
    effect_label: "hazelnut creamer isn't on the list",
    effect:       ->(u) { ListItem.where(list_id: u.lists.reload.map(&:id)).any? { |i| i.name.to_s.match?(/hazelnut/i) } },
  },
  schedule_list_items:    {
    say:   "every night at 9 add bins out and lock up to the groceries list",
    avoid: %i[add_list_item schedule_reminder request_feature],
  },
  remove_list_item:       { say: "take the oat milk off the groceries", needs: :oat_milk_listed },
  edit_list_item:         { say: "flag the oat milk on the groceries as important", needs: :oat_milk_listed },

  # --- time: the four that get confused with each other ---
  set_timer:              {
    say:          "5m",
    avoid:        %i[schedule_reminder alarm],
    run:          true,
    effect_label: "no five-minute countdown was actually started",
    effect:       ->(u) { u.timers.exists?(kind: :countdown, duration_ms: 300_000) },
  },
  alarm:                  { say: "wake me at 6:30 tomorrow", avoid: %i[schedule_reminder set_timer] },
  schedule_reminder:      { say: "remind me to call mom at 6", avoid: %i[alarm add_agenda_item] },
  remind_when:            { say: "remind me to grab my rx next time I'm at Costco", avoid: %i[schedule_reminder] },
  move_reminder:          { say: "move the tomato reminder to 3", needs: :pending_reminder },
  cancel_reminder:        { say: "never mind the vet reminder, drop it", needs: :vet_reminder },
  list_reminders:         "what reminders do I have?",
  cancel_timer:           "cancel all my timers",
  check_anchor:           "when's sunset?",

  # --- calendar ---
  add_agenda_item:        { say: "put dinner with Sam on the calendar Thursday at 7", avoid: %i[schedule_reminder] },
  edit_agenda_item:       { say: "move my dentist appointment to 3", needs: :dentist_on_calendar },
  search_agenda:          "when's my next dentist appointment?",
  today_briefing:         "give me my Today briefing",

  # --- the house, the printer, the Mac ---
  # Named down to the exact fan on purpose. Their house has a Great Fan and a
  # HASS Fan, and "the fan" between two of them is a question rather than a
  # call - which is its own probe, below, and a pass when it's asked.
  call_jil_function:      { say: "turn the great room fan to low", needs: :fan_fn },
  schedule_function:      { say: "play the Whisper nap sound at 11 tonight", avoid: %i[call_jil_function], needs: :light_fn },
  trigger_jil_task:       { say: "chill mode", needs: :jil_trigger },
  # A SCOPE, which is what this tool takes, and no `needs:` at all — a trigger
  # is an announcement, so it does not matter whether anything is listening.
  # Asked with a NAME it correctly reached for schedule_function instead.
  schedule_trigger:       { say: "tomorrow at 8pm fire the villager:car:charged trigger" },
  mac_command:            "turn the monitors off at the desk",
  print_again:            { say: "print the vase again", needs: :printer_reachable },
  print_history:          { say: "what did I print yesterday?", avoid: %i[print_again] },
  printer_control:        { say: "preheat the printer", avoid: %i[print_again], needs: :printer_reachable },

  # --- other people ---
  message_partner:        "let Chelsea know I fed the dog",
  ask_partner:            { say: "ask Chelsea what she wants for dinner", avoid: %i[message_partner] },
  ask_partner_choice:     { say: "ask Chelsea whether she'd rather do dishes or mop", avoid: %i[ask_partner] },
  ask_partner_multi:      { say: "ask Chelsea which of these she's up for tonight - dishes, laundry, vacuuming - she can pick as many as she likes", avoid: %i[ask_partner ask_partner_choice] },
  # Seeds its own question one turn before reading it. A relay is answerable on
  # the NEXT thing the person says and passed over after that, so one built at
  # world time is already stale by the time this probe runs.
  relay_answer:           {
    say:   "tell her tacos",
    needs: :open_relay_question,
    seed:  ->(user, convo) {
      partner = user.chore_household&.members&.detect { |m| m.id != user.id }
      next if partner.nil?

      BuddyRelay.create!(
        from_user: partner, to_user: user, to_conversation: convo,
        body: "What do you want for dinner?", kind: :ask_open,
        status: :delivered, delivered_at: 1.minute.ago
      )
    },
  },
  ask_me:                 "add whatever I say next to my grocery list - ask me what it is first",

  # --- deliveries ---
  track_delivery:         "I ordered a bookshelf, should be here Friday",
  check_deliveries:       "what packages are on their way?",
  update_delivery:        { say: "the desk is coming Friday now", needs: :desk_delivery },
  delivery_arrived:       { say: "the desk got here", needs: :desk_delivery },

  # --- things held for them ---
  # Deliberately not the greenhouse: that one is already stashed, so "I keep
  # meaning to sort out the greenhouse" is a thing to READ back, and read_idea
  # was the right answer to a probe that scored it wrong.
  stash_idea:             { say: "I keep meaning to redo the pantry shelves", avoid: %i[add_list_item schedule_reminder] },
  elaborate_idea:         { say: "about that greenhouse - it should probably be solar", needs: :greenhouse_idea },
  read_idea:              { say: "remind me what that greenhouse thing was about", needs: :greenhouse_idea },
  finish_idea:            { say: "the greenhouse is sorted, I did it", needs: :greenhouse_idea },
  drop_idea:              { say: "forget the greenhouse thing", needs: :greenhouse_idea },
  defer_idea:             { say: "bring the greenhouse one back up next week", needs: :greenhouse_idea },
  move_idea:              { say: "move the greenhouse one over to home", needs: :greenhouse_idea },
  search_ideas:           "did I ever hand you anything about redoing the gutters?",

  # --- what it knows ---
  search_memories:        { say: "what do you know about my sister?", avoid: %i[search_conversations] },
  search_conversations:   { say: "what did we actually say about the kitchen backsplash a few weeks back?", avoid: %i[search_memories search_ideas] },
  define_term:            "when I say the plunge I mean the trailhead in Alpine",
  forget_term:            { say: "bakkie doesn't mean that any more, drop it", needs: :bakkie_defined },

  # --- routines and wiring ---
  save_routine:           "when I say prep my printer, turn it on, wait a minute, then preheat it",
  run_routine:            { say: "run my wind-down", needs: :wind_down_routine },
  edit_routine:           { say: "in my wind-down, make the timer 20 minutes instead of 10", avoid: %i[save_routine], needs: :wind_down_routine },
  forget_routine:         { say: "delete my wind-down routine, I don't use it", needs: :wind_down_routine },
  link_records:           { say: "from now on, whenever I log a Strawberry Celsius, tick off my water chore", needs: :water_chore },
  unlink_records:         { say: "logging coffee shouldn't tick off the chore any more", needs: :coffee_pairing },

  # --- the inventory: physical things in labelled boxes ---
  # The one this whole family gets confused with is `lists`. "Add batteries to
  # the shopping list" and "the batteries are in the tool cubes" are the same
  # three words about two different subsystems, so every probe here names the
  # list tool it must not reach for.
  search_inventory:       { say: "where did I put the camp stove?", avoid: %i[search_events search_memories], needs: :camp_stove_filed },
  add_inventory_item:     {
    say:          "the lantern lives in the camping tote now",
    avoid:        %i[add_list_item stash_idea],
    needs:        :camping_tote,
    run:          true,
    effect_label: "the lantern didn't get filed in the camping tote",
    effect:       ->(u) { u.boxes.reload.any? { |b| b.name.to_s.match?(/lantern/i) } },
  },
  edit_inventory_item:    {
    say:          "the headlamp isn't in the tote any more, it's out on the attic shelf",
    avoid:        %i[add_inventory_item edit_list_item],
    needs:        :headlamp_filed,
    run:          true,
    effect_label: "the headlamp is still filed inside the camping tote",
    effect:       ->(u) { u.boxes.reload.detect { |b| b.name.to_s.match?(/headlamp/i) }&.hierarchy.to_s.match?(/attic shelf > headlamp/i) },
  },
  remove_inventory_item:  { say: "the camp stove is gone, we gave it away - take it off the inventory", avoid: %i[remove_list_item edit_inventory_item], needs: :camp_stove_filed },
  show_inventory_image:   { say: "show me the photo of the camping tote", avoid: %i[search_inventory view_image], needs: :tote_photo },
  # `view_image` is the one it gets confused with, and the difference is whether
  # the picture is still in the thread. `view_image` opens one it can see a
  # bracket for; this searches the ones it can't.
  find_photo:             {
    say:   "did I ever send you a picture of the router label?",
    avoid: %i[view_image show_inventory_image search_inventory search_memories],
    needs: :described_photo,
  },
  # Seeds the photo one turn before asking, because "this is the camping tote"
  # is only a sensible thing to say when a picture has just arrived. Without
  # one the honest answer is a question, and the probe would be scoring the
  # absence of an image rather than the tool.
  attach_inventory_image: {
    say:   "that one's the camping tote, hang onto it",
    avoid: %i[view_image stash_idea],
    needs: :camping_tote,
    seed:  ->(user, convo) {
      message = convo.byte_messages.create!(
        user: user, direction: :outbound, state: :sent, body: "",
        metadata: { "kind" => "buddy" },
      )
      message.files.attach(
        io: StringIO.new(BuddyEvalWorld::EVAL_JPEG), filename: "tote.jpg", content_type: "image/jpeg",
      )
      message
    },
  },

  # --- prompts, the app itself, the edges ---
  answer_prompt:          { say: "answer my check-in for me - say I slept fine", needs: :pending_prompt },
  skip_prompt:            { say: "skip that check-in for now", needs: :pending_prompt },
  set_font_size:          "this text is too small, bump it up",
  check_weather:          "how's the weather right now? I may take the bike",
  undo:                   { say: "undo that", needs: :undoable_in_thread },
  request_feature:        { say: "can you order me a pizza?", avoid: %i[call_jil_function trigger_jil_task] },
}.freeze

# Tools an `effect:` probe is allowed to actually RUN.
#
# Allowlist, never a denylist. Everything here writes a row and stops there;
# the reason message_partner and print_again aren't on it isn't that nobody
# got round to them, it's that a run of the eval suite must never text
# Chelsea or put a file on the printer, and a denylist gets that wrong the
# first time somebody adds a tool.
BUDDY_EVAL_EXECUTABLE = %i[
  log_event
  delete_event
  edit_event
  complete_chore
  create_chore
  edit_chore
  undo_chore_completion
  edit_chore_completion
  add_list_item
  remove_list_item
  edit_list_item
  add_inventory_item
  edit_inventory_item
  remove_inventory_item
  set_timer
  cancel_timer
  alarm
  schedule_reminder
  cancel_reminder
  move_reminder
  define_term
  forget_term
  stash_idea
  elaborate_idea
  finish_idea
  drop_idea
  defer_idea
  move_idea
  save_routine
  forget_routine
  link_records
  unlink_records
  remember
  set_font_size
  track_delivery
  update_delivery
].freeze

# Calling one of these alongside the right tool is ordinary - the model looks
# things up before it acts - so they never count as "called something else".
BUDDY_EVAL_READERS = %i[
  get_context read_prompt view_image read_listener_guide set_mood add_note remember
].freeze

# The ones that have already gone wrong, in the words they went wrong in.
#
# The table above asks whether each tool is REACHABLE. This asks the harder
# question: between two tools that both look right, does it pick the one that
# isn't a bug? Every entry is a real turn - the prod ids are the messages, and
# `note` is what actually happened. None of them was a fluent-sounding failure;
# every one of them read perfectly and did the wrong thing.
#
# Same fields as the table above, plus:
#   order:      tools that must be called in this relative order. This is the
#               whole of the deferred-action family: the wait has to be SET
#               before the thing it's holding, and a turn that does them the
#               other way round has already done the thing.
#   args:       { tool => { arg => value | /regex/ } } the call must carry.
#   never_args: the same, for what it must NOT carry.
#   once:       the expected tool must be called exactly once. Two calls that
#               each look right is its own failure mode, and every other check
#               here passes it.
#   tool: :none where the right answer is a QUESTION and any tool call is the
#               failure.
#   allow:      tools that DON'T count against a `tool: :none` probe, for a turn
#               with two right answers. Asked to watch for somebody else getting
#               home, asking WHICH sensor marks it and filing it as a gap are
#               both fine; setting a watch on the wrong person is not, and
#               that's still what `avoid:` is for.
BUDDY_EDGE_PROBES = [
  # --- a thing put off, which is the one that keeps coming back -------------
  {
    case:  "prod 3897",
    say:   "add oat milk to my grocery list in 2 minutes",
    tool:  :set_timer,
    with:  %i[add_list_item],
    order: %i[set_timer add_list_item],
    args:  { set_timer: { then_continue: true } },
    note:  "the item went on the list on the spot; the time was read as noise",
  },
  {
    case:  "the same shape, taking something away",
    say:   "take the oat milk off my grocery list in five minutes",
    tool:  :set_timer,
    with:  %i[remove_list_item],
    order: %i[set_timer remove_list_item],
    args:  { set_timer: { then_continue: true } },
    needs: :oat_milk_listed,
    note:  "doing it now is the opposite of what was asked",
  },
  {
    case:  "prod 4081",
    say:   "play the Whisper nap sound in 2 minutes",
    tool:  :schedule_function,
    avoid: %i[call_jil_function],
    needs: :whisper_sound_fn,
    note:  "the sound played in the room two minutes early - a wait can't hold " \
           "a tool that runs inside the turn, and the queue behind it was empty",
  },
  {
    case:  "prod 3562",
    say:   "play the nap sound at 11 tonight",
    tool:  :schedule_function,
    avoid: %i[call_jil_function],
    needs: :whisper_sound_fn,
    note:  "it went off sixteen minutes early next to a sleeping dog",
  },
  {
    case:        "prod 4446",
    say:         "play the Whisper nap sound at 9:40, and turn the office light on then too",
    tool:        :schedule_function,
    needs:       :whisper_sound_fn,
    never_reply: /snag|immediate action|instead of something|put (?:it|them) on the clock|i.ll need to use/i,
    note:        "both rows were created and both fired, and the reply said " \
                 "\"tiny snag though - I found the Tesla tools, and they ran as " \
                 "immediate actions\" and offered to do what it had already done",
  },

  # --- a repeating thing is a RULE, not the one date in front of you --------
  {
    case:  "prod 4462-4471",
    say:   "move the pilaf dinner over to the shared calendar",
    tool:  :edit_agenda_item,
    args:  { edit_agenda_item: { series: true } },
    needs: :pilaf_series,
    note:  "five dinners went on as weekly series; moving the one materialized " \
           "Monday leaves the rule on the old calendar and it is back there " \
           "next week",
  },
  {
    case:        "the same five dinners, the turn before",
    say:         "add dinner to the Dinners calendar on Monday at 6",
    tool:        :add_agenda_item,
    never_reply: /added.{0,40}dinners calendar|on the dinners calendar/i,
    note:        "there is no Dinners calendar - all five landed on the default " \
                 "one and the reply named Dinners, because the model read back " \
                 "the argument it passed instead of the receipt it got",
  },

  # --- a rhythm they act on, versus a nudge on a clock ----------------------
  {
    case:  "Eve asked Suki for a work/break cycle",
    say:   "let's do 30 minutes on, 10 off",
    tool:  :set_timer,
    avoid: %i[schedule_reminder alarm],
    args:  { set_timer: { repeat: true, break_minutes: 10 } },
    note:  "she was promised the cycle and given a reminder every 30 minutes, " \
           "which fires whether or not she's back at the desk",
  },
  {
    case:  "the printer cycle",
    say:   "I need to check my printer every 30 minutes until the print finishes",
    tool:  :set_timer,
    avoid: %i[schedule_reminder],
    args:  { set_timer: { repeat: true } },
    note:  "went out as a reminder every 30 minutes ending at 11:59pm - an hour " \
           "the person never named, and a seventeen-hour overnight gap",
  },
  {
    case:  "prod 4332, the same cycle offered instead of built",
    say:   "I need to check the printer every 10 minutes until the print finishes",
    tool:  :set_timer,
    avoid: %i[schedule_reminder],
    args:  { set_timer: { repeat: true } },
    once:  true,
    note:  "the right mechanism, described accurately, and then parked: \"I can " \
           "set the 10-minute check-in rhythm and stop it when the print " \
           "finishes if you want\". The next message was \"Yes, that's what I " \
           "asked for\" - a whole turn spent agreeing with themselves. A stated " \
           "need with the interval and the stop condition both named has nothing " \
           "left to ask about",
  },

  # --- a job to get to, versus a fact about them ----------------------------
  {
    case:  "prod 4340",
    say:   "Also, need to remember that Jil needs things like daytime",
    tool:  :stash_idea,
    avoid: %i[remember define_term],
    note:  "the opening words reach straight for `remember` and the sentence is " \
           "about Jil - neither the person nor the companion - so it was filed " \
           "as a preference, which is a rule about how to behave with nothing in " \
           "it to do. Told plainly \"it's not for you\", the reply claimed it had " \
           "been added to the existing pile entry and nothing was written at all",
  },

  # --- who a message is for, and when it leaves -----------------------------
  {
    case:  "prod 3303",
    # Chelsea's words originally, and the eval speaks as Rocco — asked as-is it
    # got "I'm not sure who you mean by Rocco", which is the right answer to
    # the wrong question.
    say:   "tell Chelsea I'll make supper at 6:00 tonight",
    tool:  :message_partner,
    avoid: %i[schedule_reminder],
    note:  "held until 6:00, which told him at supper time that supper was at " \
           "supper time. The clock time was part of the note, not the send time",
  },
  {
    case:  "the same words, framed as the delay",
    say:   "remind Chelsea tomorrow at 4pm that I'm leaving",
    tool:  :schedule_reminder,
    avoid: %i[message_partner],
    args:  { schedule_reminder: { notify: /chelsea/i } },
    note:  "here the time IS the instruction, and it's hers rather than theirs",
  },
  {
    case: "prod 2547",
    say:  "send a reminder to Chelsea tomorrow morning that we need to book the vet",
    tool: :schedule_reminder,
    args: { schedule_reminder: { notify: /chelsea/i } },
    note: "set for the asker instead, so the person who had to act never heard",
  },
  {
    case:       "prod 3449",
    say:        "at noon please ping me when it's time to do the plant check",
    tool:       :schedule_reminder,
    never_args: { schedule_reminder: { text: /ping me|remind me/i } },
    note:       "stored verbatim, so at noon it arrived as a message asking them " \
                "to ask you, at the moment they were meant to be told what to do",
  },

  # --- a name that is most of a longer name ---------------------------------
  {
    case:       "prod 4495",
    say:        "Log load dishwasher",
    tool:       :complete_chore,
    never_args: { complete_chore: { chore: /unload/i } },
    needs:      :dish_chores,
    note:       "`Unload Dishwasher` was marked done, which is the opposite job - " \
                "\"unload dishwasher\" CONTAINS \"load dishwasher\", and the two she " \
                "plausibly meant were both sitting in the roster",
  },

  # --- a house command with no verb in it -----------------------------------
  {
    case: "prod 4518",
    say:  "Monitors off",
    tool: :mac_command,
    note: "answered \"Monitors are dark\" off a single API call with no byte_actions " \
          "row at all; the retry a minute later, after he said so, took three calls " \
          "and produced the chip",
  },

  # --- the camera: seeing something, versus being told when ----------------
  {
    case:  "prod 3789, 3728, 3751",
    say:   "show me the last person that rang the doorbell",
    tool:  :call_jil_function,
    needs: :camera_fn,
    note:  "three separate turns answered \"I can't pull that up from here\" " \
           "with the function sitting unused in the index",
  },
  {
    case:  "prod 3743",
    say:   "let me know the next time somebody comes to the door",
    tool:  :remind_when,
    avoid: %i[call_jil_function],
    note:  "the same nouns pointed forward are a watch, not a look",
  },
  {
    case:  "prod 4721",
    say:   "what's going on in the backyard?",
    tool:  :call_jil_function,
    needs: :camera_fn,
    note:  "no verb of seeing anywhere in it, so the camera arm never fired; " \
           "answered \"the backyard camera still isn't handing over a frame\" " \
           "with nothing called, off a thread full of yesterday's failures",
  },

  # --- a list that has to repeat -------------------------------------------
  {
    case:  "prod 4749",
    say:   "I want those three items added to the Before Bed list every day at 9pm",
    tool:  :schedule_list_items,
    avoid: %i[request_feature add_list_item schedule_reminder],
    args:  { schedule_list_items: { repeat: /daily/i } },
    note:  "answered \"I can't make list items recur on a schedule\" and filed a " \
           "feature request, over a reminder row that has stored a tool call " \
           "and fired it with no model turn all along",
  },
  # The other side of the same change: a scheduling tool in the index must not
  # swallow the ordinary one-off add, which has the receipt and the undo on it.
  {
    case:  "the one-off it must not swallow",
    say:   "add oat milk to the shopping list",
    tool:  :add_list_item,
    avoid: %i[schedule_list_items call_jil_function],
    note:  "a WHEN is the whole difference between the two",
  },

  # --- a receipt for something that never ran ------------------------------
  {
    case: "prod 3236, 2054",
    say:  "print that again",
    tool: :print_again,
    # NOT `with: print_history`. The tool's own description says to omit `file`
    # when they mean the last thing printed, which is what "print that again"
    # means — the probe was asking for a lookup the design says to skip. What
    # went wrong in prod was the RECEIPT: a success announced off a call that
    # hadn't run, which `broken_calls` and the unbacked-claim flag now catch.
    note: "\"Yessss, the printer's running the last file again\" off a single " \
          "call with nothing run. Third time for that same request",
  },
  {
    case:  "prod 1146",
    say:   "turn the fan to low",
    tool:  :call_jil_function,
    needs: :fan_fn,
    note:  "\"Done. Fan's on low now.\" with no tool use anywhere",
  },
  {
    case:  "prod 3171",
    say:   "I don't need to water the front flower bed any more",
    tool:  :cancel_reminder,
    needs: :flower_bed_reminder,
    note:  "reported as pulled down over a cancel that was only ever proposed; " \
           "it went off again the next morning and every morning after",
  },

  # --- looking something up rather than answering from the air -------------
  {
    case:  "prod 2710, 2712",
    say:   "did that game_tray-vase print ever finish?",
    tool:  :print_history,
    avoid: %i[print_again],
    note:  "\"No print record for game_tray-vase either\", then four seconds " \
           "later \"Found it.\" Neither had looked",
  },
  {
    case:  "prod 4020",
    say:   "what's happening tomorrow?",
    avoid: %i[today_briefing],
    tool:  :get_context,
    note:  "answered with \"that Today briefing reminder is still sitting there " \
           "from this morning\", hours after it had run",
  },
  {
    case:  "the briefing tool's own rule",
    say:   "what's on today?",
    tool:  :get_context,
    avoid: %i[today_briefing],
    note:  "calling the briefing here posts a second whole briefing, and the " \
           "turn that receives it has the same reason to post a third",
  },
  {
    case:        "prod 2612",
    say:         "how do I see my agenda?",
    # What went wrong was an INVENTED place, not the act of naming one. The
    # `app_pages` section exists to answer exactly this, and it now hands over
    # the real link — so the probe checks that the page it names is one that
    # exists, rather than insisting the agenda be read out loud instead.
    tool:        :get_context,
    avoid:       %i[request_feature],
    never_reply: /agenda tab|tab in byte|in the byte app/i,
    note:        "sent them hunting for an \"Agenda tab in Byte\" that has " \
                 "never existed, with the real page sitting in app_pages",
  },

  {
    case:  "prod 4642-4646",
    say:   "what are my top level boxes?",
    tool:  :search_inventory,
    args:  { search_inventory: { inside: /top|everything|root/i } },
    needs: :camp_stove_filed,
    note:  "\"I tried that and it needs a thing to look for, not just the box " \
           "list\" - and it was right. TOP_LEVEL_WORDS existed and was wired " \
           "only into moving something OUT of a box, so there was no name for " \
           "the root and the whole inventory was unlistable",
  },

  # --- correcting a record, rather than writing a second one ---------------
  {
    case:  "prod 2440",
    say:   "add a note to the water completion from earlier - hint raspberry",
    tool:  :edit_chore_completion,
    avoid: %i[log_event complete_chore],
    needs: :water_completion,
    note:  "a note on an existing completion became a second completion",
  },
  {
    case:  "prod 3495",
    say:   "here's the tracking for the mattress, 1Z999AA10123456784",
    tool:  :update_delivery,
    avoid: %i[track_delivery],
    needs: :mattress_delivery,
    note:  "the number landed nowhere, leaving a row that knew it and couldn't use it",
  },
  {
    case:  "prod 2364",
    say:   "push the tomato one an hour later",
    tool:  :move_reminder,
    avoid: %i[cancel_reminder schedule_reminder],
    needs: :tomato_reminder,
    note:  "answered with \"couldn't find that reminder to move it\"",
  },
  {
    case:  "the chore/event fork",
    say:   "just finished a 14oz cup of water",
    tool:  :complete_chore,
    avoid: %i[log_event],
    needs: :water_chore,
    note:  "logged as a loose event beside the chore it was meant to tick off",
  },

  # --- one of a thing, said once -------------------------------------------
  {
    case: "eval run, 20 Aug, at 7:49pm",
    say:  "remind me to call mom at 6",
    tool: :schedule_reminder,
    once: true,
    note: "two of them, 6:00 tonight and 6:00 tomorrow. Tonight's six had gone " \
          "an hour and a half earlier, so one was a nudge that could never fire " \
          "and the other was the one they asked for",
  },
  {
    case:       "eval run, 20 Aug",
    say:        "remind me once Chelsea gets back home to switch the music",
    # THE PROBE WAS WRONG, three runs in a row, and the model was right.
    #
    # It expected `remind_when`, on a scenario-table comment saying her arrival
    # "resolves via her car". Nothing in this house reports Chelsea arriving:
    # every `travel:*` listener is the ASKER's own phone and car, and there is
    # no sensor, task or trigger keyed to her. So there is no watch to set, and
    # `request_feature` is the honest answer — which is what it kept giving.
    #
    # Two tool descriptions had already been edited to satisfy the probe before
    # anyone checked. Both are corrected; this is here so the assumption can't
    # come back.
    tool:       :none,
    allow:      %i[request_feature],
    avoid:      %i[schedule_reminder],
    never_args: { remind_when: { trigger: "arrive" } },
    note:       "`arrive` is the asker's own phone and car. Pointed at another " \
                "person's name it fires when THEY get home, which is a wrong " \
                "reminder rather than a missing one",
  },
  {
    case: "eval run, 20 Aug",
    say:  "hey",
    tool: :none,
    # This probe used to demand `get_context` and was WRONG: the persona says a
    # bare hello is "pure conversation - no tools, no context read", because a
    # hello touches none of their data and reciting the day's chores at someone
    # who said hi is not an answer. The eval found the probe, not the bug.
    note: "a hello is a hello. Pulling the day's chores and agenda to recite " \
          "at somebody who said \"hey\" answers a question they didn't ask",
  },
  {
    case:       "eval run, 20 Aug",
    say:        "no, 10p means 10 pebbles as the reward",
    tool:       :remember,
    never_args: { remember: { expires_in: /\Anull\z/i } },
    note:       "the fact landed, carrying the STRING \"null\" as its expiry - " \
                "which is not the same as no expiry, and is a date nothing can read",
  },

  # --- a verb that isn't a file --------------------------------------------
  {
    case:  "prod 4164",
    say:   "preheat printer",
    tool:  :printer_control,
    avoid: %i[print_again],
    needs: :printer_reachable,
    note:  "reached print_again with no `file`, which means the last thing " \
           "printed, and started a 40-minute vase that had to be cancelled at " \
           "the machine. Then apologised twice without offering to stop it, and " \
           "never preheated",
  },

  # --- a question with two windows in it -----------------------------------
  {
    case:  "prod, 20 Aug",
    say:   "How much Celsius did I drink last month vs this one?",
    tool:  :search_events,
    needs: :celsius_today,
    note:  "\"I couldn't find any Celsius entries to total up\" over fifty-eight " \
           "of them. The month bound went into the query and `days` stayed at " \
           "fourteen, and the two were ANDed - so the floor excluded the whole " \
           "month being asked about. Fixed in Buddy::EventSearch; this is here " \
           "so the next thing that clips a window is caught by a sentence and " \
           "not by somebody noticing",
  },

  # --- a word taught once, understood cold ---------------------------------
  #
  # `steps:` is several turns in a row, each one a cold start - no history, the
  # prompt rebuilt from nothing, which is exactly what a /reset is. The whole
  # probe sits in a transaction that always rolls back, so a term taught here
  # isn't taught for good.
  {
    case:  "a term is only learned if it comes back",
    note:  "teaching one and never reading it back tests the write and nothing " \
           "else. The glossary is built into the prompt, so a term that lands " \
           "and doesn't reach the next turn is a live failure nobody would see",
    steps: [
      {
        say:          "when I say the plunge I mean the trailhead up in Alpine",
        tool:         :define_term,
        run:          true,
        effect_label: "the plunge never made it into the glossary",
        effect:       ->(u) {
          u.chore_household && HouseholdGlossaryTerm.where(chore_household: u.chore_household).any? { |t|
            t.term.to_s.match?(/plunge/i)
          }
        },
      },
      {
        say:         "how long does it take to get to the plunge?",
        tool:        :none,
        # What a FAILURE looks like, rather than what a pass has to say. It
        # answered "About 2 hours total, including travel" — which proves it
        # knew the word — and a check for /alpine|trailhead/ marked that wrong.
        never_reply: /what.{0,20}plunge|which plunge|not sure what|don.t know what/i,
      },
    ],
  },

  # --- agreeing is not teaching --------------------------------------------
  {
    case:  "prod 4317-4322",
    note:  "`dealeo` was learned, refined fifty seconds later when she described " \
           "the sing-song, then written a THIRD time on a bare \"You got it!\" - " \
           "same meaning, same aliases, nothing changed. That put a third card up " \
           "and a third thank-you under it, the last one reciting the tool's own " \
           "line back at her: \"tucked in for everyone, so nobody has to puzzle " \
           "over it again\"",
    steps: [
      {
        say:          "dealeo just means deal, with a sing-song eooo on the end",
        tool:         :define_term,
        run:          true,
        effect_label: "dealeo never made it into the glossary",
        effect:       ->(u) {
          u.chore_household && HouseholdGlossaryTerm.where(chore_household: u.chore_household).any? { |t|
            t.term.to_s.match?(/dealeo/i)
          }
        },
      },
      {
        say:   "You got it!",
        tool:  :none,
        avoid: %i[define_term],
      },
    ],
  },

  # --- where the right answer is a question --------------------------------
  {
    case:         "prod 1146",
    say:          "turn the fan to low",
    # There is a Great Fan and a HASS Fan covering two rooms, so "the fan" is
    # a choice. Picking one is fine; picking one SILENTLY is not, because the
    # person can't tell which room just changed. So: make the call, and say
    # which fan in the reply.
    tool:         :call_jil_function,
    needs:        :fan_fn,
    expect_reply: /living room|great|master|bedroom|office/i,
    note:         "answered \"Done. Fan's on low now.\" with no tool use at all. " \
                  "With three fans, a reply that doesn't name one is unfalsifiable " \
                  "even when a call did happen",
  },
  {
    case:         "prod 4556-4592",
    say:          "I opened lists and found a list that names most items in groups, ex. Fruits, " \
                  "veggies etc, so I went through that whole thing and checked the items I need " \
                  "today, but now I can't find the list of items I checked!",
    tool:         :none,
    expect_reply: /\?/,
    never_reply:  /(?:that|this)\s+(?:sounds\s+like|is|would\s+be|will\s+be)\s+(?:the|your)\b/i,
    note:         "the same list under the same store section, six times over " \
                  "twenty-five minutes, each one after a message contradicting it - " \
                  "she was in the shop, and it was Listonic on her phone the whole " \
                  "time. Nothing here groups by food type or has pictures, and both " \
                  "of those were in her first two messages",
  },
  # --- the answer is the link, and it has to be the RIGHT link -------------
  {
    case:         "prod 4831",
    say:          "can you send me a link to my grocery list?",
    # Nothing to call: handing over a link is prose, and the retraction guard
    # standing down on this shape is half the fix. The other half is the URL.
    tool:         :none,
    needs:        :grocery_list,
    # Anything AFTER `/lists/` is the whole assertion, and the old behaviour
    # has nothing there: an index link is `.../lists` and stops. Deliberately
    # NOT a `never_reply` on the bare index - offering both is a fine answer,
    # and a harness that fails one is reporting a problem nobody has.
    expect_reply: %r{/lists/\d+},
    note:         "answered with the list INDEX - `[Doctor!](https://ardesian.com/lists)` - " \
                  "because app_pages carried the index and nothing carried the " \
                  "list's own page. A wrong link looks exactly like a working " \
                  "one until it's tapped",
  },
  {
    case: "Whisper sleeps twice a day",
    say:  "let me know when Whisper goes to bed",
    tool: :none,
    note: "her nap as often as her bedtime. Picking one silently sets a watch " \
          "that fires at the wrong end of the day, or eight hours late, and " \
          "from outside that looks exactly like a dog who didn't sleep",
  },
].freeze

namespace :buddy do
  desc "Run Buddy against canned scenarios and print replies + tool calls (REAL API CALLS)"
  task eval: :environment do
    reset_run!
    user = User.me
    with_world(user) {
      puts banner("Buddy eval — #{BUDDY_EVAL_SCENARIOS.length} scenarios")
      BUDDY_EVAL_SCENARIOS.each { |scenario| evaluate(scenario[:say], user: user, probe: scenario) }
    }
    finish_report
  end

  desc "Run Buddy against one message (REAL API CALL). Pass a theme to run as Moss."
  task :eval_one, [:message, :theme] => :environment do |_t, args|
    abort "usage: bx rails \"buddy:eval_one[your message]\" or \"buddy:eval_one[msg,moss]\"" if args[:message].blank?

    reset_run!
    theme = args[:theme].presence || "byte"
    puts banner("Buddy eval — single message as #{theme}")
    evaluate(args[:message], theme: theme)
    finish_report
  end

  desc "Run the canned scenarios as Moss/Chelsea instead of Byte/Rocco (REAL API CALLS)"
  task eval_moss: :environment do
    reset_run!
    user = User.me
    with_world(user) {
      puts banner("Moss eval — #{BUDDY_EVAL_SCENARIOS.length} scenarios")
      BUDDY_EVAL_SCENARIOS.each { |scenario| evaluate(scenario[:say], user: user, theme: "moss", probe: scenario) }
    }
    finish_report
  end

  desc "Say one sentence per tool and check the right tool was reached (REAL API CALLS)"
  task :eval_tools, [:filter] => %i[environment tool_coverage] do |_t, args|
    probes = BUDDY_TOOL_PROBES.select { |name, _| args[:filter].blank? || name.to_s.include?(args[:filter].to_s) }
    abort "no tool matches #{args[:filter].inspect}" if probes.empty?

    reset_run!
    user  = User.me
    edges = args[:filter].blank? ? BUDDY_EDGE_PROBES : []
    stats[:probe_total] = probes.length + edges.sum { |p| p[:steps]&.length || 1 }

    with_world(user) {
      puts banner("Buddy tool selection — #{stats[:probe_total]} checks")
      probes.each { |name, entry|
        tool = Buddy::Tools[name]
        # Not offered to this person, so the model was never shown it and a miss
        # would say nothing about the description.
        unless Buddy::Features.allows_tool?(user, tool)
          stats[:probe_skipped] << "#{name} (#{Buddy::Features.label_for(tool[:feature])} is off)"
          stats[:probe_total]   -= 1
          next
        end

        probe = entry.is_a?(Hash) ? entry.merge(tool: name) : { say: entry, tool: name }
        run_probe(user, probe)
      }
      run_edge_probes(user, args[:filter]) if args[:filter].blank?
    }
    finish_report
  end

  desc "Replay the turns that have already gone wrong, and check they go right (REAL API CALLS)"
  task :eval_edges, [:filter] => :environment do |_t, args|
    reset_run!
    user = User.me
    with_world(user) {
      puts banner("Buddy edge cases — turns that have gone wrong before")
      run_edge_probes(user, args[:filter], count: true)
    }
    finish_report
  end

  desc "Build the eval world and leave it standing, to poke at Buddy by hand"
  task eval_world: :environment do
    world = BuddyEvalWorld.build!(User.me)
    puts "Built: #{world.summary.join(", ")}"
    puts "It stays until `bx rails buddy:eval_world_clear`."
  end

  desc "Remove whatever the eval world left behind (safe to run any time)"
  task eval_world_clear: :environment do
    puts "Removed #{BuddyEvalWorld.sweep!} eval-world records."
  end

  desc "Check every registered tool has an eval probe (no API calls)"
  task tool_coverage: :environment do
    known   = Buddy::Tools.registry.keys
    missing = known - BUDDY_TOOL_PROBES.keys
    unknown = BUDDY_TOOL_PROBES.keys - known

    # A tool with no sentence is a tool nobody has ever checked the model can
    # find, and it fails here rather than after 68 billed calls.
    puts "\e[31mno eval probe for: #{missing.sort.join(", ")}\e[0m" if missing.any?
    puts "\e[31mprobe for a tool that no longer exists: #{unknown.sort.join(", ")}\e[0m" if unknown.any?
    abort "add a line to BUDDY_TOOL_PROBES in lib/tasks/buddy_eval.rake" if missing.any? || unknown.any?

    bad = probe_table_problems
    if bad.any?
      puts "\e[31m#{bad.map { |b| "  #{b}" }.join("\n")}\e[0m"
      abort "fix the probe tables in lib/tasks/buddy_eval.rake"
    end

    puts "\e[32mall #{known.length} tools have an eval probe\e[0m"
    puts "\e[32m#{BUDDY_EDGE_PROBES.sum { |p| p[:steps]&.length || 1 }} edge checks, all well-formed\e[0m"
  end

  desc "Replay the last N real user messages from a conversation (REAL API CALLS, read-only)"
  task :replay, [:conversation_id, :limit] => :environment do |_t, args|
    abort "usage: bx rails \"buddy:replay[<conversation_id>,<limit>]\"" if args[:conversation_id].blank?

    reset_run!
    convo = ByteConversation.find(args[:conversation_id])
    limit = (args[:limit].presence || 20).to_i
    bodies = convo.byte_messages
      .where(direction: :outbound)
      .order(created_at: :desc)
      .limit(limit)
      .pluck(:body)
      .reverse
      .compact_blank

    puts banner("Buddy replay — conversation #{convo.id} (#{convo.user.first_name}), #{bodies.length} messages")
    bodies.each { |text| evaluate(text, user: convo.user, theme: convo.buddy_theme) }
    finish_report
  end

  desc "Report Buddy's model spend over the last N days (default 30). Reads only."
  task :cost, [:days] => :environment do |_t, args|
    days  = (args[:days].presence || 30).to_i
    since = days.days.ago
    rows  = BuddyUsage.since(since)

    if rows.none?
      puts "No recorded Buddy usage in the last #{days} days."
      next
    end

    money = ->(micros) { Buddy::GPT::Pricing.format_micros(micros) }

    puts banner("Buddy spend — last #{days} days")
    puts "kind        calls        input       cached     output       cost"
    rows.group(:kind).pluck(
      :kind, Arel.sql("COUNT(*)"), Arel.sql("SUM(input_tokens)"),
      Arel.sql("SUM(cached_input_tokens)"), Arel.sql("SUM(output_tokens)"), Arel.sql("SUM(cost_micros)")
    ).each { |kind, calls, input, cached, output, cost|
      puts format("%-10s %6d %12d %12d %10d %10s", kind, calls, input, cached, output, money.call(cost))
    }

    # Eval spend counts toward the total like everything else — it's the same
    # money out the same door. The `kind` breakdown above is where it shows up
    # on its own; `env` is where the machine shows up, now that spend from the
    # laptop is synced in rather than stranded in whatever database it ran
    # against. Suite rows are the one thing left out: the fake client invents
    # its token counts, so they are not money.
    billed = rows.billed
    by_env = billed.group(:env).sum(:cost_micros)
    if by_env.length > 1
      puts "-" * 66
      puts "by env: #{by_env.map { |e, c| "#{e} #{money.call(c)}" }.join("  ")}"
    end

    total  = billed.spend_micros
    input  = billed.sum(:input_tokens)
    cached = billed.sum(:cached_input_tokens)
    turns  = billed.turn.count
    puts "-" * 66
    puts "total: #{money.call(total)} over #{billed.count} calls (#{turns} turns)"
    # All-in: total spend over turn count, so each turn carries its share of the
    # compaction that keeps it cheap. That is the number that predicts the bill.
    puts "per turn all-in: #{money.call(turns.zero? ? 0 : total / turns)}"
    puts "projected 30d: #{money.call((total / days.to_f * 30).round)}"

    # The single most useful health number here. Buddy's ~23k-token prompt +
    # schema prefix is stable, so this should sit high; if it drops, input cost
    # goes up roughly tenfold for the same conversation.
    rate = input.zero? ? 0 : (cached * 100.0 / input)
    flag = rate < 60 ? " \e[33m<- low, prefix is being invalidated\e[0m" : ""
    puts "prompt cache hit rate: #{rate.round(1)}%#{flag}"

    by_model = billed.group(:model).sum(:cost_micros)
    puts "by model: #{by_model.map { |m, c| "#{m} #{money.call(c)}" }.join("  ")}" if by_model.length > 1
  end

  desc "Show the most expensive Buddy turns over the last N days (default 7)"
  task :cost_top, [:days, :limit] => :environment do |_t, args|
    days  = (args[:days].presence || 7).to_i
    limit = (args[:limit].presence || 15).to_i

    rows = BuddyUsage.turn.since(days.days.ago)
      .where.not(byte_message_id: nil)
      .group(:byte_message_id)
      .order(Arel.sql("SUM(cost_micros) DESC"))
      .limit(limit)
      .sum(:cost_micros)

    if rows.empty?
      puts "No recorded Buddy turns in the last #{days} days."
      next
    end

    puts banner("Priciest Buddy turns — last #{days} days")
    ByteMessage.where(id: rows.keys).index_by(&:id).then { |msgs|
      rows.each { |message_id, cost|
        body = msgs[message_id]&.body.to_s.gsub(/\s+/, " ")
        puts format("%10s  %s", Buddy::GPT::Pricing.format_micros(cost), body.truncate(90))
      }
    }
  end

  # The spend survives this: every call was written to the usage spool as it
  # happened, so clearing the local rows drops the conversation, not the money.
  desc "Delete the eval conversations and their usage rows"
  task eval_clear: :environment do
    convos = ByteConversation.evals
    spend  = BuddyUsage.eval.spend_micros
    rows   = BuddyUsage.eval.count
    messages = ByteMessage.where(byte_conversation_id: convos.select(:id)).count

    BuddyUsage.eval.delete_all
    convos.destroy_all # takes their messages with them

    puts "Cleared #{messages} eval messages and #{rows} usage rows " \
         "(#{Buddy::GPT::Pricing.format_micros(spend)} of recorded spend)."
  end

  # ---- internals -----------------------------------------------------------

  # Everything about a probe that can be checked without spending anything.
  #
  # A `needs:` that no longer names a real precondition silently becomes "not
  # answerable" forever; a `run:` on a tool that isn't executable silently
  # verifies nothing. Both read as passing runs, which is the failure mode this
  # whole file exists to stop, so they fail here instead — free, and before the
  # first billed call.
  def probe_table_problems
    all = BUDDY_TOOL_PROBES.map { |name, entry|
      entry.is_a?(Hash) ? entry.merge(tool: name) : { say: entry, tool: name }
    } + BUDDY_EDGE_PROBES
    all += BUDDY_EDGE_PROBES.flat_map { |p| Array(p[:steps]) }

    out = []
    all.each { |probe|
      what = probe[:case] || probe[:tool] || probe[:say]
      if probe[:needs] && !BuddyEvalNeeds.known?(probe[:needs])
        out << "#{what}: needs :#{probe[:needs]}, which isn't in lib/buddy_eval_needs.rb"
      end
      if probe[:run] && probe[:tool] && BUDDY_EVAL_EXECUTABLE.exclude?(probe[:tool])
        out << "#{what}: run: true on #{probe[:tool]}, which isn't in BUDDY_EVAL_EXECUTABLE"
      end
      out << "#{what}: effect: with no effect_label to report" if probe[:effect] && probe[:effect_label].blank?
      if probe[:effect]&.arity == 2 && probe[:baseline].nil?
        out << "#{what}: effect: takes a baseline and the probe has no baseline: to read one"
      end
      out << "#{what}: effect: without run: true, so nothing will have happened" if probe[:effect] && !probe[:run]
    }
    BUDDY_EDGE_PROBES.each { |probe|
      next if probe[:case].present? && probe[:note].present?

      out << "#{probe[:say] || probe[:steps]&.first&.dig(:say)}: an edge probe needs a case: and a note:"
    }
    out
  end

  # One world, built before anything is said and taken back down afterwards -
  # the same shape a spec's setup has, and for the same reason. Without it a
  # third of the sweep asks about records that aren't there, and reports the
  # answer as an unanswerable rather than as a pass or a fail.
  #
  # BUDDY_EVAL_WORLD=0 runs against whatever is really in the database, which
  # is what you want when the question is "does it work with MY data".
  def with_world(user)
    if ENV["BUDDY_EVAL_WORLD"] == "0"
      puts "\e[90mrunning against the real database — `needs:` probes will mostly be unanswerable\e[0m"
      return yield
    end

    world = BuddyEvalWorld.build!(user)
    puts "\e[90mworld: #{world.summary.join(", ")}\e[0m"
    stats[:world] = world.summary
    yield
  ensure
    # In an ensure so an interrupt still cleans up. Anything a hard kill leaves
    # behind is on the manifest, and the next run sweeps it before building.
    puts "\e[90mworld: removed #{world.teardown!} records\e[0m" if world
  end

  # Every run ends here, scenarios included. A scenario run has no automatic
  # verdict to report, which was the reason it didn't write one — but "no
  # verdict" is exactly when a written-down transcript is worth having, because
  # the judging is the part a person (or an agent) still has to do, and doing it
  # from a terminal scrollback means doing it once and losing it.

  # Actually do the thing, so `effect:` has something to look at.
  #
  # A resolved call is a proposal descriptor and nothing more — the row appears
  # on screen with a checkbox and the work happens when it's tapped. Every
  # probe until now stopped at "which tool", which is the cheap half: it can't
  # tell a complete_chore that marked the chore from one that resolved to the
  # wrong chore and marked that instead.
  #
  # This is the tapping, in the same two moves ProposalExecutor makes: re-run
  # the confirm to get the resolved payload, then dispatch. Only inside the
  # rolled-back transaction a `steps:` probe runs in, and only for the tools
  # above.
  def execute_calls(user, conversation, calls)
    calls.each { |call| execute_call(user, conversation, call) }
  end

  # Per call, so a name the tool can't match stops that one and not the four
  # behind it.
  def execute_call(user, conversation, call)
    tool = Buddy::Tools[call[:name].to_sym]
    return if tool.nil? || BUDDY_EVAL_EXECUTABLE.exclude?(call[:name].to_sym)
    return if Buddy::Tools.answers?(tool) # already ran inside resolve_call

    args = Buddy::Tools.normalize_function_arguments(tool, call[:arguments])
    payload, errors = Buddy::Tools.validate_payload(tool, args, zone: Buddy::Day.zone(user))
    return if errors.any?

    ctx      = Buddy::ToolContext.new(user, conversation: conversation)
    confirm  = tool[:confirm].call(payload, ctx)
    resolved = payload.merge(confirm[:resolved] || {})
    # `count` dispatches that many times, exactly as ProposalExecutor does —
    # "took the recycling out twice" is two completions, and a single dispatch
    # would let an effect that counts them pass on half the work.
    times    = (resolved[Buddy::Tools::COUNT_ARG] || 1).to_i.clamp(1, 20)
    outcome  = nil
    times.times { outcome = Buddy::Tools.dispatch(tool, resolved, ctx) }

    call[:eval_ok] = false if outcome[:ok] == false
    call[:eval_error] ||= outcome[:error]
    puts "  \e[90m ran #{call[:name]}#{" x#{times}" if times > 1}#{" — #{outcome[:error]}" if outcome[:error]}\e[0m"
  rescue StandardError => e
    call[:eval_ok]    = false
    call[:eval_error] = e.message
    puts "  \e[33m! #{call[:name]} wouldn't run: #{e.class}: #{e.message}\e[0m"
  end

  # A probe that is several turns, each one starting from nothing.
  #
  # The question these answer is continuity: a term defined in one turn has to
  # be understood in the NEXT one, and the next one is a cold start — no
  # history, the prompt rebuilt from scratch — which is exactly what a /reset
  # is. So step one runs for real and step two is asked as though it had never
  # met the person.
  #
  # The whole probe sits in a transaction that is always rolled back, so a term
  # taught here is not taught for good. Two consequences worth knowing: the
  # thread messages for these turns roll back with it, so a steps probe leaves
  # nothing to scroll; and the usage rows are held back and written afterwards,
  # because the spend is real whatever happens to the rows.
  def run_isolated(user, probe)
    # Outside the transaction: created in it, it would roll back and take the
    # deferred usage rows with it.
    convo = eval_conversation(user, "byte")
    steps = probe[:steps].presence || [probe]

    defer_usage {
      ActiveRecord::Base.transaction {
        steps.each_with_index { |step, i|
          merged = probe.slice(:case, :note, :needs).merge(step)
          merged[:case] = "#{probe[:case]} · #{i + 1} of #{steps.length}" if steps.length > 1
          stats[:probe_index] += 1 if i.positive?
          # Seeded one turn before it's read, which for a relay is the only
          # time it counts as open.
          step[:seed]&.call(user, convo)
          @baseline = step[:baseline]&.call(user)
          evaluate(step[:say], user: user, probe: merged)
        }
        raise ActiveRecord::Rollback
      }
    }
  end

  # Usage rows written after the transaction they were earned in, rather than
  # inside it. The tokens were spent either way and `buddy:cost` has to say so.
  def defer_usage
    @deferred_usage = []
    yield
  ensure
    pending = @deferred_usage
    @deferred_usage = nil
    Array(pending).each { |row| write_usage(row) }
  end

  def write_usage(row)
    BuddyUsage.record!(row[:result], user: row[:user], kind: :eval, conversation: row[:conversation])
  rescue StandardError => e
    puts "  \e[33m! usage not recorded: #{e.class}: #{e.message}\e[0m"
  end

  def finish_report
    puts summary
    puts probe_summary

    md, json = BuddyEvalReport.new(
      failures:   stats[:report],
      prose:      stats[:prose],
      transcript: stats[:transcript],
      unmet:      stats[:probe_unmet],
      skipped:    stats[:probe_skipped],
      passed:     stats[:probe_pass],
      world:      stats[:world],
    ).write!(at: Time.current)

    wrong = stats[:report].length + stats[:prose].length
    puts "\n\e[32mNothing mechanical to fix.\e[0m" if wrong.zero?
    puts "\n\e[1m#{wrong} to fix.\e[0m" if wrong.positive?
    puts "  #{md}   \e[90m← paste this into an agent\e[0m"
    puts "  #{json}"
  end

  def run_edge_probes(user, filter, count: false)
    # Includes the STEP sentences: a `steps:` probe has no `say` of its own, so
    # `eval_edges[plunge]` matched nothing and quietly ran no probes at all.
    probes = BUDDY_EDGE_PROBES.select { |p|
      haystack = [p[:tool], p[:case], p[:say], *Array(p[:steps]).map { |st| st[:say] }].join(" ")
      filter.blank? || haystack.include?(filter.to_s)
    }
    return puts "no edge case matches #{filter.inspect}" if probes.empty?

    stats[:probe_total] = probes.sum { |p| p[:steps]&.length || 1 } if count
    puts banner("#{probes.length} of them") if filter.present?
    probes.each { |probe|
      tool = (Buddy::Tools[probe[:tool]] unless probe[:tool].nil? || probe[:tool] == :none)
      if tool && !Buddy::Features.allows_tool?(user, tool)
        stats[:probe_skipped] << "#{probe[:tool]} (#{Buddy::Features.label_for(tool[:feature])} is off)"
        stats[:probe_total]   -= 1
        next
      end

      # The incident is printed with the probe rather than only on a failure:
      # reading what it did last time is most of what makes the reply legible.
      puts "\n\e[90m#{probe[:case]}: #{probe[:note]}\e[0m"
      run_probe(user, probe)
    }
  end

  # One probe, however many turns it takes.
  #
  # Most are a single message against the standing world. A probe that seeds
  # something of its own, runs its calls for real, or spans several turns needs
  # those writes visible to itself and to nothing afterwards, so it goes in a
  # transaction that is always rolled back.
  def run_probe(user, probe)
    stats[:probe_index] += 1
    return run_isolated(user, probe) if isolated?(probe)

    evaluate(probe[:say], user: user, probe: probe)
  end

  def isolated?(probe)
    probe[:steps].present? || probe[:seed] || probe[:run] || probe[:effect]
  end

  # A run's own state, cleared at the top of every task.
  #
  # Rake tasks memoize into the file's main object, which is fine for one
  # invocation per process and wrong the moment there are two: a second run in
  # the same process inherited the first one's counters AND its memoized eval
  # conversation, which by then could be a row that no longer existed.
  def reset_run!
    @stats = nil
    @eval_conversations = nil
    @deferred_usage = nil
    @baseline = nil
  end

  def stats
    @stats ||= {
      turns:         0,
      tool_calls:    0,
      no_tool:       0,
      elapsed:       0.0,
      cost_micros:   0,
      flags:         [],
      probe_pass:    0,
      probe_fail:    [],
      probe_unmet:   [],
      probe_skipped: [],
      probe_total:   0,
      probe_index:   0,
      report:        [],
      prose:         [],
      transcript:    [],
      last_reply:    nil,
    }
  end

  def evaluate(text, user: User.me, theme: "byte", probe: nil)
    convo  = eval_conversation(user, theme)
    client = Buddy::GPT::Client.new
    tools  = [
      Buddy::GPT::ContextTool.schema,
      Buddy::GPT::PromptTool.schema,
      Buddy::GPT::ImageTool.schema,
      *Buddy::SideEffects.function_schemas(theme: theme),
      # Scoped to the acting user, so an eval run as someone with a feature
      # switched off scores what they'd actually get.
      *Buddy::Tools.function_schemas(user: user),
    ]
    # The conversation's theme carries its own voice now, so a Moss run gets
    # Chelsea's regardless of which user is acting.
    instructions = Buddy::Personality.for(
      user,
      conversation: convo,
      at_glance:    { user: user.first_name, pet_expression: "neutral" },
    )
    readers = {
      Buddy::GPT::ContextTool::NAME => Buddy::GPT::ContextTool.new(user, convo),
      Buddy::GPT::PromptTool::NAME  => Buddy::GPT::PromptTool.new(user, convo),
      Buddy::GPT::ImageTool::NAME   => Buddy::GPT::ImageTool.new(user, convo),
    }

    # Each scenario is judged on its own, so the model only ever sees this one
    # message — the persisted thread is a record of the run, not its history.
    inbound = persist_prompt(convo, user, text)
    bubble  = persist_reply(convo, user, inbound)

    input   = [{ role: :user, content: text }]
    started = Time.current
    reply   = String.new(encoding: "UTF-8")
    calls   = []

    # Mirrors Buddy::GPT::Turn#converse, minus persistence and side effects: the
    # model calls a tool and stays quiet, the call is answered, and it speaks on
    # the round after. A turn that needs no tool ends in one call.
    spoken = nil
    rounds = 0
    nudged = false
    seen   = Set.new
    loop do
      rounds += 1
      result = client.stream(instructions: instructions, input: input, tools: tools)
      # Before the ok check: a failed or truncated response still consumed
      # tokens and still bills.
      record_usage(result, user, convo, bubble)
      unless result[:ok]
        spoken = "[ERROR: #{result[:error]}]"
        break
      end

      round_text = result[:text].to_s.strip
      # Last round wins, and a discarded lead-in is not fed back - same as Turn.
      spoken = round_text if round_text.present?
      calls.concat(result[:tool_calls])

      if result[:tool_calls].empty?
        # Mirrors Turn: a reply claiming an action nothing backs up buys exactly
        # one corrective round to go make the call it skipped.
        break if nudged || calls.any?

        nudge = eval_nudge(text, spoken.to_s, user)
        break if nudge.nil?

        nudged = true
        input += [{ role: :developer, content: nudge }]
        next
      end
      break if rounds >= Buddy::GPT::Turn::MAX_ROUNDS

      prior = seen.dup
      result[:tool_calls].each do |call|
        input += [
          {
            type:      :function_call,
            call_id:   call[:call_id],
            name:      call[:name].to_s,
            arguments: JSON.generate(call[:arguments]),
          },
          {
            type:    :function_call_output,
            call_id: call[:call_id],
            output:  eval_tool_output(call, readers, user, convo, prior, seen),
          },
        ]
      end
    end
    body, mood = displayed(spoken)
    reply << body
    finish_reply(bubble, reply.strip, calls)

    # Before the verdict, because `effect:` asks the database whether the thing
    # actually happened and nothing has happened yet.
    execute_calls(user, convo, calls) if probe && probe[:run]

    elapsed = Time.current - started
    record(calls, elapsed)
    report(text, reply.strip, calls, elapsed, bubble, probe, mood, user)
  rescue StandardError => e
    # With the frame. Thirty-four turns of one run died on the same line and the
    # message alone ("undefined method for [...]:Array") took a long time to
    # place — a crashed turn is already the most expensive kind to debug,
    # because it's the one with no probe output under it at all.
    where = e.backtrace.grep(%r{/(app|lib)/}).first(3).map { |l| l.sub(Rails.root.to_s + "/", "") }
    puts "  \e[31mCRASHED\e[0m #{e.class}: #{e.message}"
    where.each { |line| puts "    \e[90m#{line}\e[0m" }
  end

  # The corrective round, as far as this harness can mirror it.
  #
  # Turn spends ONE round on whichever of half a dozen arms trips first. Most
  # read the reply and are pure functions of text; the rest need a live
  # conversation (a disputed action, an undo regret) and can't be staged here.
  # The three below are the ones that can, and leaving the camera arm out cost
  # a real false failure: "show me the last person that rang the doorbell"
  # answered from a sensor reading and was scored a miss, when production would
  # have stopped it and pointed at the camera function.
  def eval_nudge(asked, spoken, user)
    return Buddy::GPT::Turn::RETRY_NUDGE if Buddy::GPT::Turn.unbacked_claim(spoken)
    return Buddy::GPT::Turn::UNFILED_OFFER_NUDGE if Buddy::GPT::Turn.unfiled_offer?(spoken)
    return Buddy::GPT::Turn::POINTER_NUDGE if spoken.strip.match?(Buddy::GPT::Turn::DANGLING_POINTER_RX)
    return eval_camera_nudge(user) if camera_look?(asked, user)

    nil
  end

  def camera_look?(asked, user)
    looked = Buddy::GPT::Turn::CAMERA_LOOK_RX.match?(asked.to_s)
    scened = Buddy::GPT::Turn::CAMERA_SCENE_RX.match?(asked.to_s)
    return false unless looked || scened
    return false if asked.to_s.match?(Buddy::GPT::Turn::CAMERA_WATCH_RX)

    camera_functions(user).any?
  end

  def camera_functions(user)
    @camera_functions ||= {}
    @camera_functions[user.id] ||= Task.where(user: user, buddy_enabled: true, enabled: true).select { |t|
      t.name.to_s.match?(/camera/i) && t.listener.to_s.start_with?("function")
    }.map(&:name)
  end

  def eval_camera_nudge(user)
    names = camera_functions(user).map { |n| "`#{n}`" }.to_sentence
    <<~TXT
      STOP. They asked to SEE something, and a camera is what shows it.

      #{names} #{"is".pluralize(camera_functions(user).length)} in your `jil_functions` index right now. Call `call_jil_function` with `expect_result: true` and answer from what comes back.
    TXT
  end

  # What the person would actually have SEEN, and the face it set on the way.
  #
  # A reply leading with `[[mood:happy]]` is the supported protocol: Turn reads
  # it, applies the expression, and strips it before the words broadcast. This
  # harness doesn't go through Turn, so it was judging text nobody would ever
  # be shown — 18 of 26 turns flagged "stray marker" for a marker production
  # consumes, and two flags that were real got lost in the noise. The stray
  # check still stands for a marker that ISN'T leading, which is what it was
  # written for.
  def displayed(text)
    raw  = text.to_s
    mood = raw[Buddy::GPT::Turn::LEADING_MOOD_RX, 1]
    body = Buddy::GPT::Turn.normalize_dashes(raw.sub(Buddy::GPT::Turn::LEADING_MOOD_RX, ""))
    [body, mood]
  end

  # What the model gets back for each call. Reads return real context, and
  # everything else goes through the SAME resolver production uses
  # (Buddy::GPT::Turn.resolve_tool), so an eval sees the real "no chore matches
  # that" errors. Resolving stops short of executing, so an eval still never
  # logs a chore or messages a partner for real.
  def eval_tool_output(call, readers, user, conversation, prior, seen)
    name = call[:name].to_sym
    reader = readers[name]
    return reader.call(call[:arguments]) if reader
    return JSON.generate({ ok: true }) if Buddy::SideEffects.handles?(name)

    tool = Buddy::Tools[name]
    return JSON.generate({ ok: false, error: "no tool named #{name}" }) if tool.nil?

    # An ANSWERING tool runs inside resolve_call - that's what makes it an
    # answer - and the handful that also `act` really do the thing: print_again
    # puts a file on the printer, call_jil_function starts the car. An eval is
    # scoring which tool got picked, and this file has always said nothing is
    # executed, so those are answered as though they had run. BUDDY_EVAL_LIVE=1
    # to let them through when the point is the round trip itself.
    if Buddy::Tools.acts?(tool) && ENV["BUDDY_EVAL_LIVE"] != "1"
      return JSON.generate(note_outcome(call, stubbed_act(tool, call, user, conversation)))
    end

    result, signature = Buddy::GPT::Turn.resolve_call(tool, call, user: user, conversation: conversation)
    # Same cross-round repeat detection Turn does, so an eval doesn't report a
    # duplicate call that production would have ignored.
    return JSON.generate(Buddy::GPT::Turn::DUPLICATE_ACK) if signature && prior.include?(signature)

    seen << signature if signature
    JSON.generate(note_outcome(call, result))
  end

  # An acting tool, resolved for real and stopped short of the thing it does.
  #
  # This used to hand back `note: "(eval) resolved but not run"`, and the model
  # read that exactly as written: "turn the fan to low" came back with the
  # right tool and the reply "Hmm, that one didn't actually land." The harness
  # was manufacturing the failure it was there to detect.
  #
  # So the confirm runs — it's a pure lookup, which is why ProposalBuilder can
  # re-run it later — and a call that RESOLVES reads as success. A fuzzy name
  # that matches nothing, or matches two things, still comes back as the error
  # it really is, which is the half worth keeping.
  def stubbed_act(tool, call, user, conversation)
    args = Buddy::Tools.normalize_function_arguments(tool, call[:arguments])
    payload, errors = Buddy::Tools.validate_payload(tool, args, zone: Buddy::Day.zone(user))
    return { ok: false, error: errors.join("; ") } if errors.any?

    ctx     = Buddy::ToolContext.new(user, conversation: conversation)
    confirm = tool[:confirm].call(payload, ctx)
    { ok: true, status: "ok", ran: true, summary: confirm[:summary].to_s.presence }.compact
  rescue StandardError => e
    { ok: false, error: e.message }
  end

  # Hangs the outcome off the call itself, so a verdict can tell a tool that
  # was reached from a tool that was reached and then failed.
  def note_outcome(call, result)
    shape = result.is_a?(Hash) ? result : {}
    call[:eval_ok]    = shape[:ok] != false && shape["ok"] != false
    call[:eval_error] = shape[:error] || shape["error"]
    result
  end

  def persist?
    ENV["BUDDY_EVAL_PERSIST"] != "0"
  end

  # One reusable thread per user+theme, so runs accumulate into something you can
  # scroll rather than scattering. Flagged `eval` in metadata: ByteConversation
  # keeps these out of `default_for`, so topping the list by recency can't make
  # an eval run start catching real inbound messages.
  def eval_conversation(user, theme)
    return scratch_conversation(user, theme) unless persist?

    @eval_conversations ||= {}
    @eval_conversations[[user.id, theme.to_s]] ||= (
      name = "Eval · #{theme.to_s == "moss" ? "Moss" : "Byte"}"
      user.byte_conversations.evals.find_by(name: name) ||
        user.byte_conversations.create!(
          name: name, mode: :buddy, buddy_theme: theme, metadata: { "eval" => true },
        )
    )
  end

  # Used when persistence is off. `new` (not `create!`) so nothing can leak into
  # the real thread list even if a callback fires.
  def scratch_conversation(user, theme)
    ByteConversation.new(
      user:             user,
      mode:             :buddy,
      buddy_theme:      theme,
      buddy_expression: "neutral",
      metadata:         { "eval" => true },
    )
  end

  # The scenario, as though the person had typed it.
  def persist_prompt(convo, user, text)
    return nil unless persist?

    convo.byte_messages.create!(
      user: user, direction: :outbound, state: :sent, body: text,
      metadata: { "source" => "eval" }
    )
  end

  # Minted before the loop, exactly like Turn does, so per-round usage rows have
  # a message to hang off and `buddy:cost_top` can rank eval turns too.
  def persist_reply(convo, user, inbound)
    return nil unless persist?

    convo.byte_messages.create!(
      user: user, direction: :inbound, state: :streaming, body: "…",
      metadata: { "kind" => "buddy", "source" => "eval", "in_reply_to" => inbound&.id }.compact
    )
  end

  def finish_reply(reply, spoken, calls)
    return if reply.nil?

    reply.update!(
      state:        :delivered,
      body:         spoken.to_s.presence || "(no prose)",
      delivered_at: Time.current,
      metadata:     reply.metadata.merge(
        "usage"      => BuddyUsage.rollup_for_message(reply),
        "eval_calls" => calls.map { |c| { "name" => c[:name].to_s, "arguments" => c[:arguments] } },
      ).compact,
    )
    # A quiet second line listing what it reached for. Worded as "would call"
    # because nothing was executed — an eval that reads like a receipt would be
    # claiming things happened that didn't.
    return if calls.empty?

    reply.byte_conversation.byte_messages.create!(
      user:         reply.user,
      direction:    :inbound,
      state:        :delivered,
      body:         "would call: #{calls.map { |c| "#{c[:name]}(#{(c[:arguments] || {}).to_json})" }.join("  ")}",
      metadata:     { "kind" => "buddy_receipt", "source" => "eval" },
      delivered_at: Time.current,
    )
  end

  def record_usage(result, user, convo, reply)
    return unless persist?
    # Inside a rolled-back steps probe: held and written once it's over.
    return @deferred_usage << { result: result, user: user, conversation: convo } if @deferred_usage

    BuddyUsage.record!(result, user: user, kind: :eval, conversation: convo, message: reply)
  rescue StandardError => e
    puts "  \e[33m! usage not recorded: #{e.class}: #{e.message}\e[0m"
  end

  def record(calls, elapsed)
    stats[:turns]      += 1
    stats[:tool_calls] += calls.length
    stats[:no_tool]    += 1 if calls.empty?
    stats[:elapsed]    += elapsed
  end

  def report(prompt, reply, calls, elapsed, bubble=nil, probe=nil, mood=nil, user=nil)
    counter = "[#{stats[:probe_index]}/#{stats[:probe_total]}] " if probe && stats[:probe_total].positive?
    puts
    puts "\e[36m▸ #{counter}#{"#{probe[:tool]}: " if probe && probe[:tool]}#{prompt}\e[0m"
    puts "  \e[90mwant: #{probe[:want]}\e[0m" if probe && probe[:want].present?
    puts "  #{reply.presence || "(no prose)"}"
    puts "  \e[90m face: #{mood}\e[0m" if mood.present?

    if calls.any?
      calls.each { |c|
        # `reply` is already printed above as the spoken line; showing it again in
        # the args just buries the actual arguments.
        args = (c[:arguments] || {}).except(Buddy::Tools::REPLY_ARG.to_s)
        puts "  \e[35m→ #{c[:name]}(#{args.to_json})\e[0m"
      }
    else
      puts "  \e[90m→ no tool calls\e[0m"
    end

    flags = warnings(reply, calls)
    flags.each { |w|
      puts "  \e[33m! #{w}\e[0m"
      stats[:flags] << w
    }
    stats[:last_reply] = reply
    transcribe(prompt, reply, calls, probe, mood, flags)
    verdict(probe, calls, user) if probe && probe[:tool]

    # Per-scenario cost, so an expensive one is obvious as it scrolls past
    # rather than only in the total at the end.
    cost = bubble && BuddyUsage.where(byte_message_id: bubble.id).spend_micros
    stats[:cost_micros] += cost.to_i if cost
    money = cost ? "  #{Buddy::GPT::Pricing.format_micros(cost)}" : ""
    puts "  \e[90m#{elapsed.round(2)}s#{money}\e[0m"
  end

  # Every turn goes down, whether or not anything about it could be checked
  # automatically.
  #
  # A tool probe gets a verdict. A scenario gets `want:` and a person's
  # judgement, and that judgement IS the scenario run — before this, a run
  # printed 26 replies, scrolled away, and left the report with nothing to say
  # about any of them. Written down, the same material goes into the report as
  # a transcript an agent can read against what a pass looks like.
  def transcribe(prompt, reply, calls, probe, mood, flags)
    row = {
      "said"  => prompt,
      "want"  => probe && probe[:want],
      "reply" => reply.presence,
      "mood"  => mood,
      "calls" => calls_phrase(calls).presence,
      "flags" => flags,
      "tool"  => probe && probe[:tool]&.to_s,
    }.compact
    stats[:transcript] << row
    stats[:prose] << row if flags.any?
  end

  def calls_phrase(calls)
    calls.map { |c|
      "#{c[:name]}(#{(c[:arguments] || {}).except(Buddy::Tools::REPLY_ARG.to_s).to_json})"
    }.join("  ")
  end

  # Did that sentence reach the tool it was written for? A near miss is the
  # interesting result and gets named: reaching for `schedule_reminder` when the
  # person asked for a rhythm is a wrong answer that reads perfectly.
  def verdict(probe, calls, user=nil)
    user  ||= User.me
    named   = calls.map { |c| c[:name].to_sym }
    acting  = named - BUDDY_EVAL_READERS
    quiet   = probe[:tool] == :none
    missed  = (quiet ? [] : [probe[:tool], *Array(probe[:with])] - named)
    wrong   = Array(probe[:avoid]) & named
    wrong  += acting - Array(probe[:allow]) if quiet
    line    = "#{quiet ? "no tool" : probe[:tool]} — #{probe[:say]}"
    shape   = out_of_order(probe, named) + repeated(probe, named) + bad_args(probe, calls) +
      broken_calls(probe, calls) + unmatched_reply(probe) + missed_effect(probe, user)

    if missed.empty? && wrong.empty? && shape.empty?
      stats[:probe_pass] += 1
      landed = " and it landed" if probe[:effect]
      puts "  \e[32m✓ #{quiet ? "asked instead of guessing" : "reached #{probe[:tool]}"}#{landed}\e[0m"
      return
    end

    instead = acting.presence
    # "looked and didn't act" is its own outcome and used to print as a bare
    # "missed move_reminder", which reads like nothing happened at all. Reading
    # the context and then declining to act is the most common near-miss there
    # is, and naming it is what separates "couldn't find the tool" from
    # "couldn't find the record".
    looked  = (named & BUDDY_EVAL_READERS).presence
    detail  = [
      ("missed #{missed.join(", ")}" if missed.any?),
      ("called #{wrong.join(", ")} instead" if wrong.any?),
      ("called #{instead.join(", ")}" if wrong.empty? && missed.any? && instead),
      ("no tool at all" if named.empty? && !quiet),
      ("only looked (#{looked.join(", ")}) and left it there" if missed.any? && instead.nil? && looked),
      *shape,
    ].compact.join("; ")

    # A miss on a probe whose precondition genuinely isn't there says nothing
    # about the description — there was no idea to defer.
    #
    # `needs:` is a KEY into BuddyEvalNeeds now, and BuddyEvalNeeds goes and
    # LOOKS. It was a sentence taken on trust, which was fine while the
    # preconditions really were absent and became wrong the moment the world
    # started building them: the 21 Aug run filed ten real failures — the
    # recycling chore, the tomato reminder, the greenhouse idea — as missing
    # data that was in the database while it said so.
    if probe[:needs] && missed.any?
      met = BuddyEvalNeeds.met(probe[:needs], user)
      if met != true
        why  = BuddyEvalNeeds.label(probe[:needs])
        why += " — live state, nothing to seed" if met.nil?
        stats[:probe_unmet] << "#{line} (needs #{why})"
        puts "  \e[33m? #{detail} — needs #{why}\e[0m"
        return
      end
    end

    stats[:probe_fail] << "#{line} → #{detail}"
    # The same failure again, with everything a person (or an agent) would
    # otherwise have to go and look up: what it said while doing the wrong
    # thing, the arguments it passed, and the file that owns the wording that
    # decided. See BuddyEvalReport.
    stats[:report] << {
      "expected" => (quiet ? "no tool" : probe[:tool].to_s),
      "said"     => probe[:say],
      "wanted"   => wanted_phrase(probe),
      "detail"   => detail,
      "calls"    => calls_phrase(calls),
      "case"     => probe[:case],
      "note"     => probe[:note],
      "files"    => tool_files(probe),
      "reply"    => stats[:last_reply],
      "needs"    => (BuddyEvalNeeds.label(probe[:needs]) if probe[:needs]),
    }.compact
    puts "  \e[31m✗ #{detail}\e[0m"
  end

  def wanted_phrase(probe)
    return "no tool at all — the request is ambiguous and the answer is a question" if probe[:tool] == :none

    [
      [probe[:tool], *Array(probe[:with])].compact.join(" + "),
      ("exactly once" if probe[:once]),
      ("in that order" if probe[:order].present?),
      ("carrying #{probe[:args].values.map(&:to_json).join(", ")}" if probe[:args].present?),
      ("never carrying #{probe[:never_args].values.map(&:to_json).join(", ")}" if probe[:never_args].present?),
      ("and never #{Array(probe[:avoid]).join(", ")}" if probe[:avoid].present?),
    ].compact.join(", ")
  end

  # Where the wording that decided this actually lives. Every tool named in the
  # probe, not only the expected one: a sentence that reaches the wrong tool is
  # a boundary between two descriptions, and it is as often the other one that
  # claims too much.
  def tool_files(probe)
    named = [probe[:tool], *Array(probe[:with]), *Array(probe[:avoid])].compact.uniq
    named.filter_map { |name|
      path = "app/service/buddy/tools/#{name}.rb"
      path if Rails.root.join(path).exist?
    }
  end

  # The right tool, called, and answered with an error.
  #
  # This was scoring as a pass, which is how "turn the fan to low" came back
  # green while the reply said "that one didn't actually land". Tool selection
  # was right and nothing else was: the call was made, the resolver couldn't
  # find the function, and the probe reported success. A probe that can't
  # actually run its tool is measuring nothing, and almost always the fix is a
  # missing record rather than a word in a description.
  def broken_calls(probe, calls)
    wanted = [probe[:tool], *Array(probe[:with])].compact
    calls.filter_map { |call|
      next unless wanted.include?(call[:name].to_sym)
      next if call[:eval_ok] != false

      "#{call[:name]} came back: #{call[:eval_error].to_s.truncate(120)}"
    }
  end

  # What it SAID, for the turns where the words are the point — a term defined
  # a moment ago has to come back understood, and "I don't know that one" is
  # the failure even when no tool was needed either way.
  # Two shapes, and the second is usually the honest one: `expect_reply:` says
  # what a pass has to contain, `never_reply:` says what a failure looks like.
  # A term taught last turn can come back understood in any number of sentences,
  # and only one of them mentions the place by name — asserting the words is
  # asserting a particular reply rather than the understanding behind it.
  def unmatched_reply(probe)
    said = stats[:last_reply].to_s
    out  = []
    want = probe[:expect_reply]
    nope = probe[:never_reply]
    out << "said #{said.truncate(120).inspect}, which doesn't match #{want.inspect}" if want && !want.match?(said)
    out << "said #{said.truncate(120).inspect}, which is #{nope.inspect}" if nope&.match?(said)
    out
  end

  # Did the thing actually happen? Tool choice is the cheap half of the
  # question. `effect:` runs after the call has been dispatched for real (see
  # execute_calls) and asks the database whether the chore is marked, the timer
  # is the length they asked for, the term is in the glossary.
  # A two-argument effect is handed what `baseline:` read BEFORE the turn, which
  # is what lets it count. "Took the recycling out twice" against a household
  # that already had one completion today is three, and a check for "at least
  # two" passes on one.
  def missed_effect(probe, user)
    check = probe[:effect]
    return [] if check.nil?
    return [] if check.arity == 1 ? check.call(user) : check.call(user, @baseline)

    ["nothing landed: #{probe[:effect_label] || "the effect check came back false"}"]
  end

  # The right tools in the wrong order, which for a deferred action is the whole
  # bug: the wait has to exist before the thing it's holding, and a turn that
  # calls them the other way round has already done the thing.
  def out_of_order(probe, named)
    wanted = Array(probe[:order]).select { |tool| named.include?(tool) }
    return [] if wanted.length < 2

    seen = named.select { |tool| wanted.include?(tool) }.uniq
    return [] if seen == wanted

    ["called #{seen.join(" then ")} — that order does it before the wait"]
  end

  # The right tool, twice. Two calls that each look right pass every other check
  # here: "remind me to call mom at 6" came back with one for tonight's six,
  # which had already gone, and one for tomorrow's.
  def repeated(probe, named)
    return [] unless probe[:once]

    wanted = [probe[:tool], *Array(probe[:with])].compact
    named.tally.filter_map { |tool, n|
      "called #{tool} #{n} times — they asked for one" if n > 1 && wanted.include?(tool)
    }
  end

  # The right tool carrying the wrong arguments. `repeat` missing off a cycle,
  # `notify` missing off somebody else's reminder, and the reminder text that
  # was the person's request rather than the nudge, all read as a pass without
  # this.
  def bad_args(probe, calls)
    checks = [[probe[:args], false], [probe[:never_args], true]]
    checks.flat_map { |table, forbidden|
      (table || {}).flat_map { |tool, wanted|
        call = calls.find { |c| c[:name].to_sym == tool.to_sym }
        next [] if call.nil?

        args = (call[:arguments] || {}).transform_keys(&:to_s)
        wanted.filter_map { |arg, want|
          got = args[arg.to_s]
          hit = want.is_a?(Regexp) ? want.match?(got.to_s) : got.to_s == want.to_s
          next if hit != forbidden

          "#{tool}(#{arg}: #{got.inspect})#{" — should not #{want.inspect}" if forbidden}" \
            "#{" — wanted #{want.inspect}" unless forbidden}"
        }
      }
    }
  end

  def probe_summary
    fails = stats[:probe_fail]
    unmet = stats[:probe_unmet]
    tried = stats[:probe_pass] + fails.length + unmet.length
    return "" if tried.zero? && stats[:probe_skipped].empty?

    [
      "\ntool selection: #{stats[:probe_pass]}/#{tried} reached the right tool",
      fails.any? ? "\e[31m#{fails.map { |f| "  ✗ #{f}" }.join("\n")}\e[0m" : nil,
      unmet.any? ? "\e[33mnot answerable from this person's data:\n#{unmet.map { |u| "  ? #{u}" }.join("\n")}\e[0m" : nil,
      stats[:probe_skipped].any? ? "\e[90mnot offered: #{stats[:probe_skipped].join(", ")}\e[0m" : nil,
    ].compact.join("\n")
  end

  # Cheap mechanical checks for the tone rules that are actually checkable. The
  # judgement calls (warmth, not-a-receipt, fourth wall) still need human eyes.
  def warnings(reply, calls=[])
    out = []
    # The worst failure Buddy has, and the only one that is invisible from
    # outside: the words say it's done and nothing ran. The turn already buys
    # one corrective round for this (RETRY_NUDGE); reaching here means it took
    # the round and still didn't call anything.
    if calls.empty? && Buddy::GPT::Turn.unbacked_claim(reply)
      out << "claims it did something, with no tool call behind it"
    end

    # No em-dash check: Buddy::GPT::Turn.normalize_dashes takes them out on the
    # way to the person now, and `displayed` applies the same thing here. A flag
    # for something already corrected is noise in a report meant to be acted on.
    out << "stray marker left in output" if reply.match?(/\[\[/)
    out << "starts lowercase (forced-lowercase style)" if reply.match?(/\A[a-z]/)
    out << "mentions 'the context'" if reply.match?(/\bthe context\b/i)
    out << "claims to run something" if reply.match?(/let me (run|check the schema)/i)
    out << "code block in a Buddy reply" if reply.include?("```")
    out << "long (#{reply.length} chars)" if reply.length > 600
    out
  end

  def banner(title)
    "\n\e[1m#{title}\e[0m\n#{"=" * 60}"
  end

  def summary
    avg   = stats[:turns].zero? ? 0 : (stats[:elapsed] / stats[:turns])
    spend = stats[:cost_micros]
    money = Buddy::GPT::Pricing.method(:format_micros)
    per   = stats[:turns].zero? ? 0 : spend / stats[:turns]
    [
      "\n#{"=" * 60}",
      "turns: #{stats[:turns]}  tool calls: #{stats[:tool_calls]}  " \
      "silent turns: #{stats[:no_tool]}  avg: #{avg.round(2)}s",
      persist? ? "spend: #{money.call(spend)} this run (#{money.call(per)}/turn) — `bx rails buddy:cost` for the running total" : "\e[90mnot persisted (BUDDY_EVAL_PERSIST=0)\e[0m",
      stats[:flags].any? ? "\e[33mflags: #{stats[:flags].tally.map { |f, n| "#{f} x#{n}" }.join(", ")}\e[0m" : "\e[32mno mechanical flags\e[0m",
      hand_over_spend,
    ].compact.join("\n")
  end

  # The eval is where nearly all local spend comes from, and it is billed to the
  # same account as everything else — so production's total was short by however
  # much of it happened. Sending it here rather than leaving a command to
  # remember: the run has just finished, the money has just been spent, and the
  # spool line for every call was written as the call happened.
  #
  # Never fatal. A sync that can't reach production leaves the file exactly where
  # it was and says so; the spend is not lost and the next run picks it up.
  def hand_over_spend
    return nil unless persist?

    waiting = Buddy::UsageSpool.pending
    return nil if waiting.empty?

    money = Buddy::GPT::Pricing.method(:format_micros)
    total = waiting.sum { |row| row[:cost_micros].to_i }
    result = Buddy::UsageSync.call
    "handed #{result[:created]} calls (#{money.call(total)}) to production" \
      "#{" — #{result[:duplicate]} were already there" if result[:duplicate].to_i.positive?}"
  rescue StandardError => e
    "\e[33mspend not handed over (#{e.class}: #{e.message}) — " \
      "#{Buddy::UsageSpool.pending.length} calls still in the spool, `bx rails buddy:usage_sync` to retry\e[0m"
  end
end
