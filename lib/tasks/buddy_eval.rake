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
#   # Replay real messages from a conversation (read-only; nothing is written):
#   rake "buddy:replay[123,20]"
#
# Nothing here persists: each run builds a throwaway in-memory conversation, and
# the turn is executed through the client directly rather than through
# Buddy::GPT::Turn, so no ByteMessage rows, proposals, moods, or memories are
# created.

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
  "how's the weather right now? I may take the bike",  # check_weather

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

    if rows.count.zero?
      puts "No recorded Buddy usage in the last #{days} days."
      next
    end

    money = ->(micros) { Buddy::GPT::Pricing.format_micros(micros) }

    puts banner("Buddy spend — last #{days} days")
    puts format("%-10s %6s %12s %12s %10s %10s", "kind", "calls", "input", "cached", "output", "cost")
    rows.group(:kind).pluck(
      :kind, Arel.sql("COUNT(*)"), Arel.sql("SUM(input_tokens)"),
      Arel.sql("SUM(cached_input_tokens)"), Arel.sql("SUM(output_tokens)"), Arel.sql("SUM(cost_micros)")
    ).each { |kind, calls, input, cached, output, cost|
      puts format("%-10s %6d %12d %12d %10d %10s", kind, calls, input, cached, output, money.call(cost))
    }

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

  # ---- internals -----------------------------------------------------------

  def stats
    @stats ||= { turns: 0, tool_calls: 0, no_tool: 0, elapsed: 0.0, flags: [] }
  end

  def evaluate(text, user: User.me, theme: "byte")
    convo  = scratch_conversation(user, theme)
    client = Buddy::GPT::Client.new
    tools  = [
      Buddy::GPT::ContextTool.schema,
      *Buddy::SideEffects.function_schemas(theme: theme),
      *Buddy::Tools.function_schemas,
    ]
    # Pin the voice profile to the theme so a Moss run gets Chelsea's voice, not
    # whichever one the acting user resolves to.
    instructions = Buddy::Personality.for(
      user,
      conversation: convo,
      at_glance:    { user: user.first_name, pet_expression: "neutral" },
      tone:         (theme.to_s == "moss" ? :chelsea : :rocco),
    )
    context_tool = Buddy::GPT::ContextTool.new(user, convo)

    input   = [{ role: :user, content: text }]
    started = Time.current
    reply   = String.new(encoding: "UTF-8")
    calls   = []

    # Mirrors Buddy::GPT::Turn#converse, minus persistence and side effects: the
    # model calls a tool and stays quiet, the call is answered, and it speaks on
    # the round after. A turn that needs no tool ends in one call.
    spoken = []
    rounds = 0
    loop do
      rounds += 1
      result = client.stream(instructions: instructions, input: input, tools: tools)
      unless result[:ok]
        spoken << "[ERROR: #{result[:error]}]"
        break
      end

      round_text = result[:text].to_s.strip
      spoken << round_text if round_text.present?
      calls.concat(result[:tool_calls])

      break if result[:tool_calls].empty?
      break if rounds >= Buddy::GPT::Turn::MAX_ROUNDS

      input += [{ role: :assistant, content: round_text }] if round_text.present?
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
            output:  eval_tool_output(call, context_tool, user, convo),
          },
        ]
      end
    end
    reply << spoken.join("\n\n")

    elapsed = Time.current - started
    record(calls, elapsed)
    report(text, reply.strip, calls, elapsed)
  rescue StandardError => e
    puts "  \e[31mCRASHED\e[0m #{e.class}: #{e.message}"
  end

  # What the model gets back for each call. Reads return real context, and
  # everything else goes through the SAME resolver production uses
  # (Buddy::GPT::Turn.resolve_tool), so an eval sees the real "no chore matches
  # that" errors. Resolving stops short of executing, so an eval still never
  # logs a chore or messages a partner for real.
  def eval_tool_output(call, context_tool, user, conversation)
    name = call[:name].to_sym
    return context_tool.call(call[:arguments]) if name == Buddy::GPT::ContextTool::NAME
    return JSON.generate({ ok: true }) if Buddy::SideEffects.handles?(name)

    tool = Buddy::Tools[name]
    return JSON.generate({ ok: false, error: "no tool named #{name}" }) if tool.nil?

    JSON.generate(Buddy::GPT::Turn.resolve_tool(tool, call, user: user, conversation: conversation))
  end

  # Never saved. `new` (not `create!`) so nothing can leak into the real thread
  # list even if a callback fires.
  def scratch_conversation(user, theme)
    ByteConversation.new(
      user:             user,
      mode:             :buddy,
      buddy_theme:      theme,
      buddy_expression: "neutral",
      metadata:         {},
    )
  end

  def record(calls, elapsed)
    stats[:turns]      += 1
    stats[:tool_calls] += calls.length
    stats[:no_tool]    += 1 if calls.empty?
    stats[:elapsed]    += elapsed
  end

  def report(prompt, reply, calls, elapsed)
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
    puts "  \e[90m#{elapsed.round(2)}s\e[0m"
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
    avg = stats[:turns].zero? ? 0 : (stats[:elapsed] / stats[:turns])
    [
      "\n#{"=" * 60}",
      "turns: #{stats[:turns]}  tool calls: #{stats[:tool_calls]}  " \
      "silent turns: #{stats[:no_tool]}  avg: #{avg.round(2)}s",
      stats[:flags].any? ? "\e[33mflags: #{stats[:flags].tally.map { |f, n| "#{f} x#{n}" }.join(", ")}\e[0m" : "\e[32mno mechanical flags\e[0m",
    ].join("\n")
  end
end
