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

# The behaviors most worth eyeballing after a prompt or model change. The
# trailing comment on each is what a PASS looks like.
#
# The second half is drawn from real conversations rather than invented, because
# the invented set missed whole categories: bare-duration timers, undo and
# correction, retroactive completion, pebble rewards, and history questions that
# need chore_progress instead of get_context (which only knows about today).
# For the genuine article, use `bx rails "buddy:replay[<conversation_id>,30]"`.
BUDDY_EVAL_SCENARIOS = [
  # --- core logging and action ---
  "hey",                                              # get_context + short briefing, WITH prose
  "morning!",                                         # same, time-of-day aware
  "just finished a 14oz cup of water",                # checks chores_all before falling back to log_event
  "took the recycling out twice",                      # complete_chore count=2, NEVER log_event
  "ate a sandwich",                                   # log_event (ingestion)
  "I alphabetized the spice rack",                    # no chore match -> create_chore + complete_chore
  "did 20 pushups",                                   # log_event with count
  "add oat milk to the groceries",                    # add_list_item

  # --- reminders, timed and conditional ---
  "remind me to call mom at 6",                       # schedule_reminder
  "remind me to grab my rx next time I'm at Costco",  # remind_when, NOT schedule_reminder
  "5m",                                               # bare duration -> set_timer, no interrogation
  "remind me once Chelsea gets back home to switch the music", # remind_when arrive, target resolves via her car

  # --- correction and undo, which real use is full of ---
  "I accidentally logged a Strawberry Celsius this morning", # delete_event / undo, not a new log
  "actually mark that as done about an hour ago",      # complete_chore with a PAST `at`
  "no, 10p means 10 pebbles as the reward",           # reads Np as reward, doesn't claim it can't set one

  # --- chore setup with household shorthand ---
  "add a new chore for filling the kitty litter, sub of refill item, for 2p", # create_chore parent + reward 2

  # --- lookups that today's context can't answer ---
  "does it show that I got a car wash yesterday?",    # chore_progress / search_events, NOT get_context
  "how many celsius did I drink last month?",         # search_events with a timestamp bound, not a guess
  "how's the weather right now? I may take the bike",  # check_weather

  # --- the printer, where guessing a file name costs hours ---
  "print that phone thing from earlier again",        # print_history FIRST, then the reprint function
  "how long did that vase print take?",               # print_history, never invents a duration

  # --- conversation and boundaries ---
  "what's that detached mini house that butlers usually have called?", # just answers, no tools
  "can you run a script to fix my chores?",           # refuse warmly, no code, no "let me run"
  "today was genuinely rough",                        # set_mood AND warm prose, never an empty bubble
  "I always drink oat milk lattes",                   # remember
  "what time is it?",                                 # 12-hour local, never UTC
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
  log_event:             { say: "ate a sandwich", avoid: %i[complete_chore] },
  complete_chore:        { say: "took the recycling out twice", avoid: %i[log_event], needs: "a recycling chore" },
  create_chore:          "add a new chore for filling the kitty litter every Sunday",
  edit_chore:            { say: "rename the recycling chore to bins", needs: "a recycling chore" },
  edit_chore_completion: { say: "put 'hint raspberry' on that water I just logged", needs: "a water completion today" },
  undo_chore_completion: { say: "I marked the recycling done by mistake, take it back off", needs: "a recycling completion" },
  chore_progress:        "did I get all my dailies done yesterday?",
  withdraw_pebbles:      "took 20 pebbles for the arcade",
  delete_event:          { say: "I logged a Strawberry Celsius by accident this morning, get rid of it", needs: "a Celsius logged today" },
  edit_event:            { say: "that sandwich I logged was actually at 1", needs: "a sandwich logged today" },
  search_events:         "how many celsius did I drink last month?",
  add_list_item:         "add oat milk to the groceries",
  remove_list_item:      { say: "take the oat milk off the groceries", needs: "oat milk on a list" },
  edit_list_item:        { say: "flag the oat milk on the groceries as important", needs: "oat milk on a list" },

  # --- time: the four that get confused with each other ---
  set_timer:             { say: "5m", avoid: %i[schedule_reminder alarm] },
  alarm:                 { say: "wake me at 6:30 tomorrow", avoid: %i[schedule_reminder set_timer] },
  schedule_reminder:     { say: "remind me to call mom at 6", avoid: %i[alarm add_agenda_item] },
  remind_when:           { say: "remind me to grab my rx next time I'm at Costco", avoid: %i[schedule_reminder] },
  move_reminder:         { say: "move the tomato reminder to 3", needs: "a pending reminder" },
  cancel_reminder:       { say: "never mind the vet reminder, drop it", needs: "a pending reminder" },
  list_reminders:        "what reminders do I have?",
  cancel_timer:          "cancel all my timers",
  check_anchor:          "when's sunset?",

  # --- calendar ---
  add_agenda_item:       { say: "put dinner with Sam on the calendar Thursday at 7", avoid: %i[schedule_reminder] },
  edit_agenda_item:      { say: "move my dentist appointment to 3", needs: "a dentist item on the calendar" },
  search_agenda:         "when's my next dentist appointment?",
  today_briefing:        "give me my Today briefing",

  # --- the house, the printer, the Mac ---
  call_jil_function:     { say: "turn the office light purple", needs: "a matching jil_function" },
  schedule_function:     { say: "play the Whisper nap sound at 11 tonight", avoid: %i[call_jil_function], needs: "a matching jil_function" },
  trigger_jil_task:      { say: "chill mode", needs: "a matching jil_trigger" },
  schedule_trigger:      { say: "at 8 tonight fire the villager car charged trigger", needs: "a matching jil scope" },
  mac_command:           "turn the monitors off at the desk",
  print_again:           { say: "print the vase again", needs: "the printer reachable" },
  print_history:         { say: "what did I print yesterday?", avoid: %i[print_again] },

  # --- other people ---
  message_partner:       "let Chelsea know I fed the dog",
  ask_partner:           { say: "ask Chelsea what she wants for dinner", avoid: %i[message_partner] },
  ask_partner_choice:    { say: "ask Chelsea whether she'd rather do dishes or mop", avoid: %i[ask_partner] },
  ask_partner_multi:     { say: "ask Chelsea which of these she's up for tonight - dishes, laundry, vacuuming - she can pick as many as she likes", avoid: %i[ask_partner ask_partner_choice] },
  relay_answer:          { say: "tell her tacos", needs: "an open question from someone else" },
  ask_me:                "add whatever I say next to my grocery list - ask me what it is first",

  # --- deliveries ---
  track_delivery:        "I ordered a desk, should be here Friday",
  check_deliveries:      "what packages are on their way?",
  update_delivery:       { say: "the desk is coming Friday now", needs: "a desk on the delivery list" },
  delivery_arrived:      { say: "the desk got here", needs: "a desk on the delivery list" },

  # --- things held for them ---
  stash_idea:            { say: "I keep meaning to sort out the greenhouse", avoid: %i[add_list_item schedule_reminder] },
  elaborate_idea:        { say: "about that greenhouse - it should probably be solar", needs: "a stashed greenhouse idea" },
  read_idea:             { say: "remind me what that greenhouse thing was about", needs: "a stashed greenhouse idea" },
  finish_idea:           { say: "the greenhouse is sorted, I did it", needs: "a stashed greenhouse idea" },
  drop_idea:             { say: "forget the greenhouse thing", needs: "a stashed greenhouse idea" },
  defer_idea:            { say: "bring the greenhouse one back up next week", needs: "a stashed greenhouse idea" },
  move_idea:             { say: "move the greenhouse one over to home", needs: "a stashed greenhouse idea" },
  search_ideas:          "did I ever hand you anything about a greenhouse?",

  # --- what it knows ---
  search_memories:       { say: "what do you know about my sister?", avoid: %i[search_conversations] },
  search_conversations:  { say: "what did we actually say about the greenhouse a few weeks back?", avoid: %i[search_memories] },
  define_term:           "when I say the plunge I mean the trailhead in Alpine",
  forget_term:           { say: "bakkie doesn't mean that any more, drop it", needs: "bakkie in the glossary" },

  # --- routines and wiring ---
  save_routine:          "when I say prep my printer, turn it on, wait a minute, then preheat it",
  run_routine:           { say: "run my wind-down", needs: "a wind-down routine" },
  edit_routine:          { say: "in my wind-down, make it darkness instead of total darkness", avoid: %i[save_routine], needs: "a wind-down routine" },
  forget_routine:        { say: "delete my wind-down routine, I don't use it", needs: "a wind-down routine" },
  link_records:          "logging coffee should tick off the coffee chore",
  unlink_records:        { say: "logging coffee shouldn't tick off the chore any more", needs: "that pairing" },

  # --- prompts, the app itself, the edges ---
  answer_prompt:         { say: "answer my check-in for me - say I slept fine", needs: "a pending prompt" },
  skip_prompt:           { say: "skip that check-in for now", needs: "a pending prompt" },
  set_font_size:         "this text is too small, bump it up",
  check_weather:         "how's the weather right now? I may take the bike",
  undo:                  { say: "undo that", needs: "something undoable in this thread" },
  request_feature:       { say: "can you order me a pizza?", avoid: %i[call_jil_function trigger_jil_task] },
}.freeze

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
#   tool: :none where the right answer is a QUESTION and any tool call is the
#               failure.
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
    say:   "take the oat milk off my list in five minutes",
    tool:  :set_timer,
    with:  %i[remove_list_item],
    order: %i[set_timer remove_list_item],
    args:  { set_timer: { then_continue: true } },
    needs: "oat milk on a list",
    note:  "doing it now is the opposite of what was asked",
  },
  {
    case:  "prod 4081",
    say:   "play the Whisper nap sound in 2 minutes",
    tool:  :schedule_function,
    avoid: %i[call_jil_function],
    needs: "the Whisper Sound function",
    note:  "the sound played in the room two minutes early - a wait can't hold " \
           "a tool that runs inside the turn, and the queue behind it was empty",
  },
  {
    case:  "prod 3562",
    say:   "play the nap sound at 11",
    tool:  :schedule_function,
    avoid: %i[call_jil_function],
    needs: "the Whisper Sound function",
    note:  "it went off sixteen minutes early next to a sleeping dog",
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

  # --- who a message is for, and when it leaves -----------------------------
  {
    case:  "prod 3303",
    say:   "tell Rocco I'll make supper at 6:00 tonight",
    tool:  :message_partner,
    avoid: %i[schedule_reminder],
    note:  "held until 6:00, which told him at supper time that supper was at " \
           "supper time. The clock time was part of the note, not the send time",
  },
  {
    case:  "the same words, framed as the delay",
    say:   "remind Chelsea at 4 that I'm leaving",
    tool:  :schedule_reminder,
    avoid: %i[message_partner],
    args:  { schedule_reminder: { notify: /chelsea/i } },
    note:  "here the time IS the instruction, and it's hers rather than theirs",
  },
  {
    case: "prod 2547",
    say:  "send a reminder to Chelsea that we need to book the vet",
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

  # --- the camera: seeing something, versus being told when ----------------
  {
    case:  "prod 3789, 3728, 3751",
    say:   "show me the last person that rang the doorbell",
    tool:  :call_jil_function,
    needs: "the Camera Last Seen function",
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

  # --- a receipt for something that never ran ------------------------------
  {
    case: "prod 3236, 2054",
    say:  "print that again",
    tool: :print_again,
    with: %i[print_history],
    note: "\"Yessss, the printer's running the last file again\" off a single " \
          "call with nothing run. Third time for that same request",
  },
  {
    case:  "prod 1146",
    say:   "turn the fan to low",
    tool:  :call_jil_function,
    needs: "a fan function",
    note:  "\"Done. Fan's on low now.\" with no tool use anywhere",
  },
  {
    case:  "prod 3171",
    say:   "I don't need to water the front flower bed any more",
    tool:  :cancel_reminder,
    needs: "a flower bed reminder",
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
    case:  "prod 2612",
    say:   "how do I see my agenda?",
    tool:  :search_agenda,
    avoid: %i[request_feature],
    note:  "sent them hunting for an \"Agenda tab in Byte\" that has never " \
           "existed. The answer is to read the agenda out, not to describe a screen",
  },

  # --- correcting a record, rather than writing a second one ---------------
  {
    case:  "prod 2440",
    say:   "put 'hint raspberry' on that water you just marked",
    tool:  :edit_chore_completion,
    avoid: %i[log_event complete_chore],
    needs: "a water completion today",
    note:  "a note on an existing completion became a second completion",
  },
  {
    case:  "prod 3495",
    say:   "here's the tracking for the mattress, 1Z999AA10123456784",
    tool:  :update_delivery,
    avoid: %i[track_delivery],
    needs: "a mattress on the delivery list",
    note:  "the number landed nowhere, leaving a row that knew it and couldn't use it",
  },
  {
    case:  "prod 2364",
    say:   "push the tomato one an hour later",
    tool:  :move_reminder,
    avoid: %i[cancel_reminder schedule_reminder],
    needs: "a tomato reminder",
    note:  "answered with \"couldn't find that reminder to move it\"",
  },
  {
    case:  "the chore/event fork",
    say:   "just finished a 14oz cup of water",
    tool:  :complete_chore,
    avoid: %i[log_event],
    needs: "a water chore",
    note:  "logged as a loose event beside the chore it was meant to tick off",
  },

  # --- where the right answer is a question --------------------------------
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
    puts banner("Buddy eval — #{BUDDY_EVAL_SCENARIOS.length} scenarios")
    BUDDY_EVAL_SCENARIOS.each { |text| evaluate(text) }
    puts summary
  end

  desc "Run Buddy against one message (REAL API CALL). Pass a theme to run as Moss."
  task :eval_one, [:message, :theme] => :environment do |_t, args|
    abort "usage: rake \"buddy:eval_one[your message]\" or \"buddy:eval_one[msg,moss]\"" if args[:message].blank?

    theme = args[:theme].presence || "byte"
    puts banner("Buddy eval — single message as #{theme}")
    evaluate(args[:message], theme: theme)
    puts summary
  end

  desc "Run the canned scenarios as Moss/Chelsea instead of Byte/Rocco (REAL API CALLS)"
  task eval_moss: :environment do
    puts banner("Moss eval — #{BUDDY_EVAL_SCENARIOS.length} scenarios")
    BUDDY_EVAL_SCENARIOS.each { |text| evaluate(text, theme: "moss") }
    puts summary
  end

  desc "Say one sentence per tool and check the right tool was reached (REAL API CALLS)"
  task :eval_tools, [:filter] => %i[environment tool_coverage] do |_t, args|
    probes = BUDDY_TOOL_PROBES.select { |name, _| args[:filter].blank? || name.to_s.include?(args[:filter].to_s) }
    abort "no tool matches #{args[:filter].inspect}" if probes.empty?

    user = User.me
    with_world(user) {
      puts banner("Buddy tool selection — #{probes.length} tools")
      probes.each { |name, entry|
        tool = Buddy::Tools[name]
        # Not offered to this person, so the model was never shown it and a miss
        # would say nothing about the description.
        unless Buddy::Features.allows_tool?(user, tool)
          stats[:probe_skipped] << "#{name} (#{Buddy::Features.label_for(tool[:feature])} is off)"
          next
        end

        probe = entry.is_a?(Hash) ? entry.merge(tool: name) : { say: entry, tool: name }
        evaluate(probe[:say], user: user, probe: probe)
      }
      run_edge_probes(user, args[:filter]) if args[:filter].blank?
    }
    finish_report
  end

  desc "Replay the turns that have already gone wrong, and check they go right (REAL API CALLS)"
  task :eval_edges, [:filter] => :environment do |_t, args|
    user = User.me
    with_world(user) {
      puts banner("Buddy edge cases — turns that have gone wrong before")
      run_edge_probes(user, args[:filter])
    }
    finish_report
  end

  desc "Build the eval world and leave it standing, to poke at Buddy by hand"
  task eval_world: :environment do
    world = BuddyEvalWorld.build!(User.me)
    puts "Built: #{world.summary.join(", ")}"
    puts "It stays until `rake buddy:eval_world_clear`."
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

    puts "\e[32mall #{known.length} tools have an eval probe\e[0m"
  end

  desc "Replay the last N real user messages from a conversation (REAL API CALLS, read-only)"
  task :replay, [:conversation_id, :limit] => :environment do |_t, args|
    abort "usage: rake \"buddy:replay[<conversation_id>,<limit>]\"" if args[:conversation_id].blank?

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
    puts summary
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
    # on its own; the separation that actually matters is prod vs local, and
    # evals only ever run locally.
    total  = rows.spend_micros
    input  = rows.sum(:input_tokens)
    cached = rows.sum(:cached_input_tokens)
    turns  = rows.turn.count
    puts "-" * 66
    puts "total: #{money.call(total)} over #{rows.count} calls (#{turns} turns)"
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

    by_model = rows.group(:model).sum(:cost_micros)
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

  def finish_report
    puts summary
    puts probe_summary

    md, json = BuddyEvalReport.new(
      failures: stats[:report],
      unmet:    stats[:probe_unmet],
      skipped:  stats[:probe_skipped],
      passed:   stats[:probe_pass],
      world:    stats[:world],
    ).write!(at: Time.current)

    return puts "\n\e[32mNothing to fix.\e[0m" if stats[:report].empty?

    puts "\n\e[1m#{stats[:report].length} to fix. Written to:\e[0m"
    puts "  #{md}   \e[90m← paste this into an agent\e[0m"
    puts "  #{json}"
  end

  def run_edge_probes(user, filter)
    probes = BUDDY_EDGE_PROBES.select { |p|
      filter.blank? || "#{p[:tool]} #{p[:case]} #{p[:say]}".include?(filter.to_s)
    }
    return puts "no edge case matches #{filter.inspect}" if probes.empty?

    puts banner("#{probes.length} of them") if filter.present?
    probes.each { |probe|
      tool = (Buddy::Tools[probe[:tool]] unless probe[:tool] == :none)
      if tool && !Buddy::Features.allows_tool?(user, tool)
        stats[:probe_skipped] << "#{probe[:tool]} (#{Buddy::Features.label_for(tool[:feature])} is off)"
        next
      end

      # The incident is printed with the probe rather than only on a failure:
      # reading what it did last time is most of what makes the reply legible.
      puts "\n\e[90m#{probe[:case]}: #{probe[:note]}\e[0m"
      evaluate(probe[:say], user: user, probe: probe)
    }
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
      report:        [],
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
        break if Buddy::GPT::Turn.unbacked_claim(spoken.to_s).nil?

        nudged = true
        input += [{ role: :developer, content: Buddy::GPT::Turn::RETRY_NUDGE }]
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
    reply << spoken.to_s
    finish_reply(bubble, reply.strip, calls)

    elapsed = Time.current - started
    record(calls, elapsed)
    report(text, reply.strip, calls, elapsed, bubble, probe)
  rescue StandardError => e
    puts "  \e[31mCRASHED\e[0m #{e.class}: #{e.message}"
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
      return JSON.generate({ ok: true, status: "ok", note: "(eval) resolved but not run" })
    end

    result, signature = Buddy::GPT::Turn.resolve_call(tool, call, user: user, conversation: conversation)
    # Same cross-round repeat detection Turn does, so an eval doesn't report a
    # duplicate call that production would have ignored.
    return JSON.generate(Buddy::GPT::Turn::DUPLICATE_ACK) if signature && prior.include?(signature)

    seen << signature if signature
    JSON.generate(result)
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

  def report(prompt, reply, calls, elapsed, bubble=nil, probe=nil)
    puts
    puts "\e[36m▸ #{"#{probe[:tool]}: " if probe}#{prompt}\e[0m"
    puts "  #{reply.presence || "(no prose)"}"

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

    warnings(reply).each { |w|
      puts "  \e[33m! #{w}\e[0m"
      stats[:flags] << w
    }
    stats[:last_reply] = reply
    verdict(probe, calls) if probe

    # Per-scenario cost, so an expensive one is obvious as it scrolls past
    # rather than only in the total at the end.
    cost = bubble && BuddyUsage.where(byte_message_id: bubble.id).spend_micros
    stats[:cost_micros] += cost.to_i if cost
    money = cost ? "  #{Buddy::GPT::Pricing.format_micros(cost)}" : ""
    puts "  \e[90m#{elapsed.round(2)}s#{money}\e[0m"
  end

  # Did that sentence reach the tool it was written for? A near miss is the
  # interesting result and gets named: reaching for `schedule_reminder` when the
  # person asked for a rhythm is a wrong answer that reads perfectly.
  def verdict(probe, calls)
    named   = calls.map { |c| c[:name].to_sym }
    acting  = named - BUDDY_EVAL_READERS
    quiet   = probe[:tool] == :none
    missed  = (quiet ? [] : [probe[:tool], *Array(probe[:with])] - named)
    wrong   = Array(probe[:avoid]) & named
    wrong  += acting if quiet
    line    = "#{quiet ? "no tool" : probe[:tool]} — #{probe[:say]}"
    shape   = out_of_order(probe, named) + bad_args(probe, calls)

    if missed.empty? && wrong.empty? && shape.empty?
      stats[:probe_pass] += 1
      puts "  \e[32m✓ #{quiet ? "asked instead of guessing" : "reached #{probe[:tool]}"}\e[0m"
      return
    end

    instead = acting.presence
    detail  = [
      ("missed #{missed.join(", ")}" if missed.any?),
      ("called #{wrong.join(", ")} instead" if wrong.any?),
      ("called #{instead.join(", ")}" if wrong.empty? && missed.any? && instead),
      ("no tool at all" if named.empty? && !quiet),
      *shape,
    ].compact.join("; ")

    # A miss on a probe whose precondition isn't in this person's data says
    # nothing about the description — there was no idea to defer. Kept apart so
    # the number that matters stays honest in both directions.
    if probe[:needs] && missed.any?
      stats[:probe_unmet] << "#{line} (needs #{probe[:needs]})"
      puts "  \e[33m? #{detail} — needs #{probe[:needs]}\e[0m"
      return
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
      "calls"    => calls.map { |c| "#{c[:name]}(#{(c[:arguments] || {}).except(Buddy::Tools::REPLY_ARG.to_s).to_json})" }.join("  "),
      "case"     => probe[:case],
      "note"     => probe[:note],
      "files"    => tool_files(probe),
      "reply"    => stats[:last_reply],
    }
    puts "  \e[31m✗ #{detail}\e[0m"
  end

  def wanted_phrase(probe)
    return "no tool at all — the request is ambiguous and the answer is a question" if probe[:tool] == :none

    [
      [probe[:tool], *Array(probe[:with])].compact.join(" + "),
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
  def warnings(reply)
    out = []
    out << "em dash present" if reply.include?("—")
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
      persist? ? "spend: #{money.call(spend)} this run (#{money.call(per)}/turn) — `rake buddy:cost` for the running total" : "\e[90mnot persisted (BUDDY_EVAL_PERSIST=0)\e[0m",
      stats[:flags].any? ? "\e[33mflags: #{stats[:flags].tally.map { |f, n| "#{f} x#{n}" }.join(", ")}\e[0m" : "\e[32mno mechanical flags\e[0m",
    ].join("\n")
  end
end
