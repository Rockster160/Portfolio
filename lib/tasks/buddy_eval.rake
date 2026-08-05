# Manual evaluation harness for Buddy's prose and tool selection.
#
# Deliberately NOT a spec. These make real, billed calls to OpenAI and their
# output is judged by eye, not asserted — putting that in `rspec` would make the
# suite slow, flaky, and expensive. Specs cover the plumbing offline via
# FakeBuddyClient; this covers "does it still sound like Buddy and reach for the
# right tool".
#
#   # Canned scenarios that exercise the rules most likely to regress:
#   rake buddy:eval
#
#   # One ad-hoc message:
#   rake "buddy:eval_one[I just took the recycling out]"
#
#   # Replay real messages from a conversation (source is read-only):
#   rake "buddy:replay[123,20]"
#
#   # Wipe the eval threads and their usage rows when they get noisy:
#   rake buddy:eval_clear
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

# The behaviors most worth eyeballing after a prompt or model change. The
# trailing comment on each is what a PASS looks like.
#
# The second half is drawn from real conversations rather than invented, because
# the invented set missed whole categories: bare-duration timers, undo and
# correction, retroactive completion, pebble rewards, and history questions that
# need chore_progress instead of get_context (which only knows about today).
# For the genuine article, use `rake "buddy:replay[<conversation_id>,30]"`.
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

  def stats
    @stats ||= { turns: 0, tool_calls: 0, no_tool: 0, elapsed: 0.0, cost_micros: 0, flags: [] }
  end

  def evaluate(text, user: User.me, theme: "byte")
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
    report(text, reply.strip, calls, elapsed, bubble)
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

  def report(prompt, reply, calls, elapsed, bubble=nil)
    puts
    puts "\e[36m▸ #{prompt}\e[0m"
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

    # Per-scenario cost, so an expensive one is obvious as it scrolls past
    # rather than only in the total at the end.
    cost = bubble && BuddyUsage.where(byte_message_id: bubble.id).spend_micros
    stats[:cost_micros] += cost.to_i if cost
    money = cost ? "  #{Buddy::GPT::Pricing.format_micros(cost)}" : ""
    puts "  \e[90m#{elapsed.round(2)}s#{money}\e[0m"
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
