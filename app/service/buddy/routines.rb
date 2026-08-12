module Buddy
  # Named sequences of Buddy tool calls - "prep my printer" is power the printer
  # on, wait a minute, then preheat.
  #
  # A routine holds nothing new: its steps are the same [{ tool_name:, payload: }]
  # markers Buddy::GPT::Turn hands Buddy::ProposalBuilder for a live call, so
  # running one is a REPLAY through the ordinary path. The queue in
  # ProposalBuilder already orders steps, splits them at the first gate, and
  # holds the tail behind a `set_timer` wait, which is the whole reason a
  # routine can span a delay without any machinery of its own.
  #
  # Steps store the ARGUMENTS a request became, never the ids confirm resolved
  # them to (see sanitize). Every run re-resolves "Printer - Power On" against
  # the tasks that exist today.
  module Routines
    module_function

    # The tool the model calls to run one. Its calls never reach ProposalBuilder
    # as themselves: Turn#build_proposals swaps each one for the steps it names.
    RUNNER = :run_routine

    # How far back `capture` will look for calls to save. Generous, because
    # "save that as X" often comes a couple of messages after the thing itself.
    CAPTURE_WINDOW = 40

    def find(user, name)
      wanted = name.to_s.downcase.strip
      return nil if wanted.empty?

      rows = user.buddy_routines.enabled.ordered.to_a
      rows.find { |r| r.name.downcase == wanted } ||
        rows.find { |r| r.name.downcase.start_with?(wanted) } ||
        rows.find { |r| r.name.downcase.include?(wanted) } ||
        rows.find { |r| wanted.include?(r.name.downcase) } ||
        by_words(rows, wanted)
    end

    # Same words, any order. People don't say a name back the way they typed it
    # - "water cup" gets asked for as "cup water" or "log cup water" - and every
    # branch above is a substring test, which a transposition slips straight
    # past.
    #
    # A routine matches when ALL of its words are somewhere in what was asked,
    # and the one with the most words wins so a two-word name beats a one-word
    # name sitting inside the same phrase. Nothing looser than that: this runs
    # a whole saved sequence, so a wrong guess does several things nobody asked
    # for.
    def by_words(rows, wanted)
      asked = words(wanted)
      return nil if asked.empty?

      rows.select { |r|
        parts = words(r.name)
        parts.any? && (parts - asked).empty?
      }.max_by { |r| words(r.name).length }
    end

    def words(str)
      str.to_s.downcase.scan(/[a-z0-9]+/)
    end

    # Words a person wraps a routine's name in without meaning anything else by
    # it. Deliberately tiny: every word added here is a word that stops counting
    # as content, and the whole test below is that there IS no other content.
    NAME_FILLER = %w[run please my the a do go now ok okay].freeze

    # The routine the message IS, as opposed to the one it might be about.
    #
    # `find` above is fuzzy on purpose - by the time it runs, something has
    # already decided a routine was meant and it only needs the row. Nothing has
    # decided anything here, so this is much stricter: drop the filler and what
    # remains must be exactly the routine's own words, in any order and nothing
    # besides. **good night** matches "Good night" and "good night!"; it does
    # not match "have a good night" or "what does my good night routine do",
    # because both carry content the name doesn't account for.
    #
    # Prod 3392: "Good night" - as literal a match to a saved name as exists -
    # got a warm goodnight and no routine, and the person had to ask for the
    # monitors by hand afterwards, by which point the other half of the routine
    # was never going to run at all. The name was in the prompt and matching it
    # was left entirely to reading, which works right up until it doesn't.
    def named_outright(user, text)
      return nil unless user.respond_to?(:buddy_routines)

      asked = words(text) - NAME_FILLER
      return nil if asked.empty?

      user.buddy_routines.enabled.ordered.to_a.find { |r| words(r.name).sort == asked.sort }
    end

    # The markers a call expands into, or nil when the call isn't a routine run.
    # Turn asks this in two places - once to work out which gate the turn opens
    # on, and once to build the proposals - so the lookup lives here rather than
    # being spelled out at both call sites.
    def expand(user, tool, payload)
      return nil unless runner?(tool)

      routine = find(user, payload[:name])
      return [] if routine.nil?

      routine.markers
    end

    def runner?(tool)
      tool.is_a?(Hash) && tool[:name] == RUNNER
    end

    # Run one directly, with no model turn - what a tap on the Quick grid does.
    # Same replay through ProposalBuilder that a spoken "run my wind-down" gets;
    # the only thing skipped is the model deciding to call `run_routine`, which
    # on a button has already been decided.
    #
    # Nobody writes the line over it either, so it comes from Buddy::VoiceLines
    # in the pet's own register - "Running **Yoga Lamp**" was every companion
    # sounding like the same job scheduler. The face moves FIRST, so the
    # expression is already there as the words land rather than catching up a
    # beat behind them (same ordering as a `[[mood:]]` marker on a real reply).
    def run!(routine, conversation:)
      routine.touch_run!
      line = Buddy::VoiceLines.pick(
        conversation&.buddy_theme, :routine_run,
        avoid: conversation&.buddy_expression, name: routine.name
      )
      Buddy::SideEffects.apply_mood(conversation, line[:mood]) if line[:mood]

      Buddy::ProposalBuilder.run_markers!(
        user:         routine.user,
        conversation: conversation,
        markers:      routine.markers,
        body:         line[:text],
      )
    end

    # Normalize rows into storable steps, raising with a readable reason when
    # one can't run. Accepts either shape of key, since these arrive both from
    # the model (a JSON array it wrote) and from `capture` (rows we built).
    #
    # Two checks, and the second is the one that matters. validate_payload gets
    # the SHAPE right - drops undeclared keys, applies defaults, coerces types -
    # but it has no idea whether the arguments point at anything real. Shape
    # alone happily saved `complete_chore(chore: "Drink Water")` against a
    # household with no chore by that name, so "water cup" was a routine that
    # could only ever fail, and it failed silently on every run.
    #
    # So each step is also RESOLVED through the tool's own confirm, which is the
    # thing that turns a fuzzy name into a record or raises. A name that matches
    # nothing gets caught here, while the person is still in the conversation
    # and can say which one they meant.
    def sanitize(rows, ctx)
      list = Array(rows)
      raise "a routine needs at least one step" if list.empty?

      steps = list.each_with_index.map { |raw, i| sanitize_step(raw, i + 1, ctx) }
      check_var_flow!(steps)
      steps
    end

    # Every `{{name}}` has to be captured by a step BEFORE the one using it.
    #
    # This is the compensation for what a placeholder costs: a step holding one
    # can't be resolved at save time (see resolves!), because the value it will
    # be given doesn't exist yet. So the one thing that CAN be checked statically
    # is checked hard - a typo in a var name is caught here rather than surfacing
    # weeks later as a step that skipped itself.
    #
    # Order matters and is the whole point: a routine that references its own
    # later answer parses perfectly and can never run.
    def check_var_flow!(steps)
      available = []
      steps.each_with_index { |step, i|
        tool    = Buddy::Tools[step["tool_name"]]
        payload = (step["payload"] || {}).transform_keys(&:to_sym)

        unmet = Buddy::StepVars.references(payload) - available
        if unmet.any?
          raise "step #{i + 1} (#{step["tool_name"]}) uses #{unmet.map { |n| "{{#{n}}}" }.join(", ")}, " \
                "but nothing before it collects that"
        end

        captured = Buddy::StepVars.captured_name(tool, payload)
        available << captured if captured
      }
    end

    # Keys that name the TOOL rather than being an argument to it.
    TOOL_KEYS = %w[tool_name tool].freeze

    def sanitize_step(raw, position, ctx)
      row      = raw.respond_to?(:to_h) ? raw.to_h.transform_keys(&:to_s) : {}
      tool_key = TOOL_KEYS.find { |k| row[k].present? }
      name     = (tool_key ? row[tool_key] : row["name"]).to_s
      tool     = Buddy::Tools[name.presence || "-"]
      raise "step #{position}: there's no tool called #{name.inspect}" if tool.nil?
      raise "step #{position}: #{name} can't be saved in a routine" unless Buddy::Tools.routinable?(tool)

      given = Buddy::Tools.normalize_function_arguments(tool, step_args(row, tool_key).transform_keys(&:to_sym))
      payload, errors = Buddy::Tools.validate_payload(tool, given)
      raise "step #{position} (#{name}): #{errors.join("; ")}" if errors.any?

      resolves!(tool, payload, name, position, ctx)
      BuddyRoutine.step(name, payload)
    end

    # The same question sanitize asks at SAVE time, asked again at RUN time.
    #
    # Saving only proves a routine could run on the day it was saved. Steps store
    # names and re-resolve every run, so the chore gets renamed, the list gets
    # archived, the Jil task gets deleted - and the step quietly becomes a marker
    # whose confirm raises, which ProposalBuilder drops without a word. A routine
    # is the one thing where that silence is unaffordable: nobody re-reads a
    # saved sequence, so it fails the same way every time and looks like it ran.
    #
    # Routines saved before save-time resolution shipped never had the check at
    # all - **water cup** stored `complete_chore(chore: "Drink Water")` against a
    # household with no chore by that name - so this is also the backstop for
    # anything already sitting in the table.
    #
    # All or nothing. Half a saved sequence is worse than none of it, because
    # the half that ran looks like the whole thing worked.
    def check_runnable!(routine, ctx)
      Array(routine.steps).each_with_index { |raw, i|
        name = raw["tool_name"].to_s
        tool = Buddy::Tools[name.presence || "-"]
        raise "step #{i + 1} of #{routine.name} uses #{name.inspect}, which isn't a tool any more" if tool.nil?

        resolves!(tool, (raw["payload"] || {}).transform_keys(&:to_sym), name, i + 1, ctx)
      }
    end

    # Does this step point at something that exists? A tool's confirm is its
    # resolver: it turns "8oz Water" into a chore or raises saying it couldn't.
    # Its resolved ids are deliberately THROWN AWAY here - the step stores the
    # name, and every run re-resolves it - so this is purely the question of
    # whether the routine can run at all.
    def resolves!(tool, payload, name, position, ctx)
      return if ctx.nil?

      tool[:confirm].call(payload, ctx)
    rescue StandardError => e
      # A step holding a `{{placeholder}}` is the one thing that can't be
      # checked here: the value it will be handed doesn't exist yet, so a
      # confirm that tries to look it up is asking about a chore literally named
      # "{{dinner}}". Its other arguments are still resolved - a wrong Jil
      # function name in the same step is caught exactly as before - and what's
      # lost is only the guarantee about the argument that's a placeholder,
      # which is unknowable by definition. check_var_flow! covers what remains.
      raise "step #{position} (#{name}): #{e.message}" if Buddy::StepVars.references(payload).empty?

      Rails.logger.info("[Buddy::Routines] step #{position} (#{name}) unresolved at save: #{e.message}")
    end

    # Both spellings of a step, because the model writes both and there was
    # never a way to know which one it would reach for:
    #
    #   { "tool_name": "trigger_jil_task", "payload": { "name": "Printer - Preheat" } }
    #   { "tool_name": "trigger_jil_task", "name": "Printer - Preheat" }
    #
    # The flat one used to fall through as an empty payload and come back
    # "missing required arg :name" - a baffling thing to be told about a step
    # whose name is sitting right there, and prod 1345 lost a routine to it.
    #
    # Flat only makes sense when the tool was named by its OWN key. If `name`
    # was doing that job then there are no arguments in this row at all, and
    # treating the tool's name as its own argument would save a step that fires
    # a task called "trigger_jil_task".
    def step_args(row, tool_key)
      nested = row["payload"] || row["args"]
      nested = (JSON.parse(nested) rescue nil) if nested.is_a?(String)
      return nested.transform_keys(&:to_s) if nested.is_a?(Hash)

      tool_key ? row.except(*TOOL_KEYS) : {}
    end

    # The last `limit` tool calls this conversation actually ran, oldest first -
    # what "save that as 'prep my printer'" means.
    #
    # Read from the two places a completed call leaves a record: the activity
    # chip a level-1 tool drops, and the executed rows on a checklist. The model
    # can't do this itself - Buddy::GPT::History deliberately keeps activity
    # chips out of the transcript, so it never sees the calls it made.
    def capture(conversation, limit: 3)
      wanted = limit.to_i.clamp(1, BuddyRoutine::MAX_STEPS)
      (chip_calls(conversation) + row_calls(conversation))
        .sort_by { |at, _, _| at }
        .last(wanted)
        .map { |_, name, args| { "tool_name" => name, "payload" => args } }
    end

    def chip_calls(conversation)
      messages = conversation.byte_messages.chronological.last(CAPTURE_WINDOW)
      messages.filter_map { |msg|
        meta = msg.metadata
        next nil unless meta.is_a?(Hash) && meta["kind"].to_s == "buddy_activity"
        # A failed call is not a step - saving it would bake the failure in.
        next nil unless meta["ok"]

        args = meta["args"] || meta["payload"] || {}
        [msg.created_at, meta["tool_name"].to_s, args]
      }
    end

    def row_calls(conversation)
      actions = ByteAction
        .where(byte_conversation_id: conversation.id, tool_name: Buddy::Supersede::PROPOSALS)
        .order(created_at: :desc)
        .limit(CAPTURE_WINDOW)

      actions.flat_map { |action|
        Array(action.buttons).filter_map { |b|
          next nil unless b["status"].to_s == "executed"

          [action.created_at, b["tool_name"].to_s, row_args(b)]
        }
      }
    end

    # A row's arguments, with HOW MANY put back.
    #
    # Three `complete_chore` calls for the same chore merge into one row that
    # runs three times, and the count of three lives on the ROW - `args` keeps
    # the first call's payload, which says one. Saving that as a routine turned
    # "cash in three waters" into a button that cashes in one, which is the same
    # failure as the routine not running at all, only harder to notice.
    def row_args(button)
      args  = (button["args"] || button["payload"] || {}).dup
      count = button["count"].to_i
      args[Buddy::Tools::COUNT_ARG.to_s] = count if count > 1
      args
    end
  end
end
