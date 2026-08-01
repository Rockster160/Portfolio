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
        rows.find { |r| wanted.include?(r.name.downcase) }
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
    def run!(routine, conversation:)
      routine.touch_run!
      Buddy::ProposalBuilder.run_markers!(
        user:         routine.user,
        conversation: conversation,
        markers:      routine.markers,
        body:         "Running **#{routine.name}**",
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

          [action.created_at, b["tool_name"].to_s, b["args"] || b["payload"] || {}]
        }
      }
    end
  end
end
