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

    # Normalize rows into storable steps, raising with a readable reason when
    # one can't run. Accepts either shape of key, since these arrive both from
    # the model (a JSON array it wrote) and from `capture` (rows we built).
    #
    # validate_payload does the real work: it drops undeclared keys, applies
    # defaults, and coerces types - so what comes out is exactly what the tool
    # would receive on a live call. Pass-through tools keep their extra keys,
    # which is right, because for call_jil_function those ARE the arguments.
    def sanitize(rows)
      list = Array(rows)
      raise "a routine needs at least one step" if list.empty?

      list.each_with_index.map { |raw, i| sanitize_step(raw, i + 1) }
    end

    # Keys that name the TOOL rather than being an argument to it.
    TOOL_KEYS = %w[tool_name tool].freeze

    def sanitize_step(raw, position)
      row      = raw.respond_to?(:to_h) ? raw.to_h.transform_keys(&:to_s) : {}
      tool_key = TOOL_KEYS.find { |k| row[k].present? }
      name     = (tool_key ? row[tool_key] : row["name"]).to_s
      tool     = Buddy::Tools[name.presence || "-"]
      raise "step #{position}: there's no tool called #{name.inspect}" if tool.nil?
      raise "step #{position}: #{name} can't be saved in a routine" unless Buddy::Tools.routinable?(tool)

      given = Buddy::Tools.normalize_function_arguments(tool, step_args(row, tool_key).transform_keys(&:to_sym))
      payload, errors = Buddy::Tools.validate_payload(tool, given)
      raise "step #{position} (#{name}): #{errors.join("; ")}" if errors.any?

      BuddyRoutine.step(name, payload)
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
