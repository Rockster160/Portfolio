require "shellwords"

# Buddy tool registry. Every file under app/service/buddy/tools/ registers
# a tool with `Buddy::Tools.register(...)`. The registry is the single
# source of truth for what Buddy can propose — the persona's system prompt
# is generated from it each turn so a new tool file is immediately usable.
#
# Each tool declares:
#   name        — symbol
#   description — plain-english, teaches the LLM when to reach for it
#   args        — arg schema (validated before proposal creation)
#   confirm     — proc(payload, ctx) → { summary:, resolved: } — resolves fuzzy refs
#   label       — proc(payload, ctx) → per-row string, ONLY relevant details
#   execute     — one of:
#                   ->(payload, ctx) { ... }                            (Ruby-backed)
#                   { bash: "cmd {{arg}}", timeout: 20 }               (Bash-backed)
#                   { jil_trigger: { scope: :sym, data: ->(p) {...} }} (Jil-backed)
#   receipt     — proc(result, ctx) → human message after execution
#   merge_key   — optional proc(payload) → identity; matching keys collapse to one row
#   merge_label — optional proc(payload, count) → row label when count > 1
module Buddy
  module Tools
    module_function

    COUNT_ARG = :count

    # Buddy's spoken words for the turn, carried ON the tool call.
    #
    # Not a real tool arg — validate_payload strips it before any tool proc sees
    # it. It exists because emitting a function call ENDS the model's turn: the
    # model writes no text alongside one, so without this every action turn cost
    # a second round trip purely to collect the prose. Verified against
    # gpt-5.4-mini: instructing it to write text alongside a call does nothing
    # (0/8), while filling a `reply` field works (4/4).
    #
    # Deliberately absent from get_context, which genuinely can't speak until it
    # has read something. That one still round-trips.
    REPLY_ARG = :reply

    # Lazy loader guards against Rails dev-mode module reload wiping
    # the in-memory registry hash. Zeitwerk clears Buddy::Tools when
    # any file it depends on changes; @registry starts empty on the
    # next reference, and the boot-time initializer isn't going to
    # re-fire. Loading here means the registry is always populated by
    # the time anyone queries it. Idempotent - re-loading tool files
    # just re-registers the same entries into the hash.
    def registry
      @registry ||= {}
      load_tool_files! if @registry.empty? && !@loading_tools
      @registry
    end

    def load_tool_files!
      @loading_tools = true
      Rails.root.glob("app/service/buddy/tools/*.rb").each { |f| load f }
    ensure
      @loading_tools = false
    end

    def register(name:, description:, args:, confirm:, label:, execute:, receipt:, merge_key: nil, merge_label: nil, passthrough_args: false, auto: false, level: nil)
      # Confidence level governs how a proposal is presented (see
      # Buddy::ProposalBuilder):
      #   1 — highest confidence (reminders, car/house/light commands): fires
      #       immediately, no checkbox, just an "activity" receipt chip. Same as
      #       the legacy `auto: true`.
      #   2 — high confidence WITH undo (list add/remove, chore complete, event
      #       log): fires immediately AND shows a PRE-CHECKED row; unchecking it
      #       reverts the action. Requires the execute result to carry a
      #       `revert:` descriptor (see Buddy::Reverter).
      #   3 — medium confidence (default): a plain pending checkbox the person
      #       must tap to run.
      resolved_level = (level || (auto ? 1 : 3)).to_i
      spec = {
        name:             name.to_sym,
        description:      description.to_s,
        args:             normalize_args(args),
        confirm:          confirm,
        label:            label,
        execute:          validate_executor!(execute),
        receipt:          receipt,
        merge_key:        merge_key || ->(_payload) { "#{name}:#{SecureRandom.uuid}" },
        merge_label:      merge_label,
        level:            resolved_level,
        # Level 1 tools run WITHOUT a confirmation checkbox: the marker executes
        # immediately and drops a distinct "activity" receipt chip instead of a
        # pending checklist row.
        auto:             resolved_level == 1,
        # Tools whose real arg set is dynamic (e.g. call_jil_function, whose
        # params vary per target task) declare only `name` in :args and set
        # this so validate_payload keeps every OTHER k=v the marker carried
        # instead of dropping the undeclared ones on the floor.
        passthrough_args: passthrough_args,
      }
      registry[name.to_sym] = spec
    end

    def all
      registry.values.sort_by { |t| t[:name].to_s }
    end

    def [](name)
      registry[name.to_sym]
    end

    def known?(name)
      registry.key?(name.to_sym)
    end

    # ---- OpenAI function-calling schemas -----------------------------------
    #
    # The Responses API takes function tools FLAT — `type`, `name`,
    # `description`, `parameters`, `strict` all at the top level. (Chat
    # Completions nests them under a `function` key; that shape 400s here.)
    #
    # Strict mode demands `additionalProperties: false` and EVERY property
    # listed in `required`, so an arg that's optional to US is expressed as a
    # nullable union rather than being left out of `required`. That's safe
    # because validate_payload already treats nil as absent and applies
    # `default:` — while still rejecting a null on an arg we marked required.
    JSON_TYPES = {
      string:       :string,
      integer:      :integer,
      enum:         :string,
      boolean:      :boolean,
      iso_time:     :string,
      duration_min: :integer,
    }.freeze

    # The bare JSON type loses information the registry type carried, so hand
    # the model the format expectation in prose instead.
    TYPE_HINTS = {
      iso_time:     "ISO8601 datetime with timezone offset",
      duration_min: "Whole minutes",
    }.freeze

    def function_schemas
      all.map { |tool| function_schema(tool) }
    end

    def function_schema(tool)
      properties = {}
      tool[:args].each { |key, spec| properties[key] = json_property(spec) }
      # `count` is a registry-wide convention rather than a declared arg (see
      # validate_payload). Only advertise it on tools defining merge_label,
      # since that proc exists precisely to render a collapsed "5x Drink
      # Water" row — the other tools have no repeat semantics.
      properties[COUNT_ARG] = count_property if tool[:merge_label]
      # Pass-through tools (call_jil_function) carry args that vary per target
      # task, so they take one freeform object instead of a fixed schema.
      # A freeform object can't satisfy strict mode, hence `strict: false`.
      properties[:args] = passthrough_property if tool[:passthrough_args]
      properties[REPLY_ARG] = reply_property

      {
        type:        :function,
        name:        tool[:name],
        description: tool[:description].strip.gsub(/\s+/, " "),
        strict:      !tool[:passthrough_args],
        parameters:  {
          type:                 :object,
          properties:           properties,
          required:             properties.keys,
          additionalProperties: false,
        },
      }
    end

    # Inverse of the passthrough schema: fold the nested `args` object back
    # into a flat payload so a tool's confirm/execute procs see exactly the
    # shape they saw under the old marker protocol. Called before
    # validate_payload, which then keeps the undeclared keys via
    # :passthrough_args.
    def normalize_function_arguments(tool, parsed)
      args = (parsed || {}).transform_keys(&:to_sym)
      # REPLY_ARG is prose for the person, never a tool input. Stripping it here
      # matters most for pass-through tools, which keep every undeclared key —
      # left in, Buddy's spoken line would be handed to a Jil function as an
      # argument.
      args.delete(REPLY_ARG)
      return args unless tool[:passthrough_args]

      nested = args.delete(:args)
      return args unless nested.is_a?(Hash)

      nested.transform_keys(&:to_sym).merge(args)
    end

    # The spoken line off a set of tool calls. First non-blank wins: the model is
    # told to put it on its first call, but a stray duplicate on a second call
    # shouldn't double up the reply.
    def spoken_reply(tool_calls)
      Array(tool_calls).each do |call|
        args = call[:arguments] || {}
        value = (args[REPLY_ARG.to_s] || args[REPLY_ARG]).to_s.strip
        return value if value.present?
      end
      nil
    end

    # Substitutes {{key}} placeholders with shell-escaped payload values.
    # This is the ONLY layer that turns a payload into shell text — no other
    # caller may hand-format bash commands from tool payloads.
    def bash_template(template, payload)
      template.gsub(/\{\{(\w+)\}\}/) { |_| Shellwords.escape(payload[Regexp.last_match(1).to_sym].to_s) }
    end

    # Runs a tool's executor once. Multi-run (count > 1) is the caller's job
    # so partial-failure state stays visible at the row level.
    def dispatch(tool, payload, ctx)
      exec = tool[:execute]
      if exec.respond_to?(:call)
        { ok: true, data: exec.call(payload, ctx) }
      elsif exec.is_a?(Hash) && exec[:bash]
        run_bash(exec, payload)
      elsif exec.is_a?(Hash) && exec[:jil_trigger]
        run_jil(exec[:jil_trigger], payload, ctx)
      else
        { ok: false, error: "unknown executor shape" }
      end
    rescue StandardError => e
      { ok: false, error: "#{e.class}: #{e.message}" }
    end

    # Validate a payload hash against a tool's arg schema. Returns
    # [normalized_payload, errors]. Errors non-empty → discard the marker.
    def validate_payload(tool, raw_payload)
      normalized = {}
      errors     = []
      raw_payload = (raw_payload || {}).transform_keys(&:to_sym)

      tool[:args].each do |key, spec|
        value = raw_payload[key]
        if value.nil? || value.to_s.empty?
          if spec[:required]
            errors << "missing required arg :#{key}"
          elsif spec.key?(:default)
            normalized[key] = spec[:default]
          end
          next
        end

        cast = cast_value(value, spec[:type])
        if cast.nil?
          errors << "arg :#{key} could not be coerced to #{spec[:type]}"
          next
        end

        if spec[:type] == :enum && Array(spec[:values]).map(&:to_sym).exclude?(cast)
          errors << "arg :#{key} must be one of #{spec[:values]}"
          next
        end
        if spec[:range].is_a?(Range) && !spec[:range].cover?(cast)
          errors << "arg :#{key} out of range #{spec[:range]}"
          next
        end

        normalized[key] = cast
      end

      # `count` is a first-class convention — accept it even when the tool
      # didn't declare it (default 1).
      if raw_payload.key?(COUNT_ARG)
        count = raw_payload[COUNT_ARG].to_i
        normalized[COUNT_ARG] = count if count.positive?
      end

      # Pass-through tools (call_jil_function) keep every undeclared k=v as a
      # raw string — the downstream Jil function coerces per its signature.
      # Preserve marker order so positional Keyword.Item() reads line up.
      if tool[:passthrough_args]
        declared = tool[:args].keys
        raw_payload.each do |k, v|
          next if declared.include?(k) || k == COUNT_ARG
          next if v.nil? || v.to_s.empty?

          normalized[k] = v
        end
      end

      [normalized, errors]
    end

    class << self
      private

      # One JSON Schema property from one registry arg spec. Optional args
      # become a nullable union so strict mode can still list them all in
      # `required`; the model passes null to mean "not supplied".
      def json_property(spec)
        base = JSON_TYPES[spec[:type]] || :string
        prop = { type: spec[:required] ? base : [base, :null] }

        if spec[:type] == :enum
          values = Array(spec[:values])
          # A nullable enum has to admit null in the enum list too, or strict
          # mode rejects the null the model is otherwise obliged to send.
          prop[:enum] = spec[:required] ? values : values + [nil]
        end

        desc = [
          spec[:description].presence,
          TYPE_HINTS[spec[:type]],
          spec.key?(:default) ? "Defaults to #{spec[:default]} when null" : nil,
        ].compact.join(". ")
        prop[:description] = desc if desc.present?
        prop
      end

      def count_property
        {
          type:        [:integer, :null],
          description: "How many times this repeats. Null or 1 for a single occurrence",
        }
      end

      def reply_property
        {
          type:        [:string, :null],
          description: "What you SAY to the person this turn - the words they will see. " \
                       "Put it on your FIRST tool call and leave it null on any others. " \
                       "Never leave it null on every call, or they get an empty message",
        }
      end

      def passthrough_property
        {
          type:                 :object,
          description:          "Function arguments as key/value pairs, keys in lowercase_snake_case " \
                                "of the signature arg names, in signature order",
          additionalProperties: true,
        }
      end

      def normalize_args(args)
        (args || {}).transform_keys(&:to_sym).transform_values { |v|
          v.transform_keys(&:to_sym)
        }
      end

      def validate_executor!(exec)
        return exec if exec.respond_to?(:call)
        return exec if exec.is_a?(Hash) && (exec[:bash].is_a?(String) || exec[:jil_trigger].is_a?(Hash))

        raise ArgumentError, "tool executor must be a proc, or a hash with :bash or :jil_trigger"
      end

      def cast_value(value, type)
        case type
        when :string       then value.to_s
        when :integer      then Integer(value.to_s, exception: false)
        when :enum         then value.to_s.to_sym
        when :boolean      then ActiveModel::Type::Boolean.new.cast(value)
        when :iso_time     then Time.zone.parse(value.to_s) rescue nil
        when :duration_min then Integer(value.to_s, exception: false)
        else value
        end
      end

      def run_bash(exec, payload)
        require "open3"

        cmd = bash_template(exec[:bash], payload)
        timeout = (exec[:timeout] || 30).to_i
        started = Time.current
        stdout, stderr, status = Timeout.timeout(timeout) {
          Open3.capture3("bash", "-lc", cmd)
        }
        {
          ok:    status.success?,
          data:  {
            stdout_tail: stdout.to_s.lines.last(20).join,
            stderr_tail: stderr.to_s.lines.last(20).join,
            exit_status: status.exitstatus,
            elapsed_ms:  ((Time.current - started) * 1000).round,
          },
          error: status.success? ? nil : "exit #{status.exitstatus}: #{stderr.to_s.lines.last}",
        }
      rescue Timeout::Error
        { ok: false, error: "timed out after #{exec[:timeout]}s" }
      end

      def run_jil(spec, payload, ctx)
        scope = spec[:scope].to_sym
        data  = spec[:data].respond_to?(:call) ? spec[:data].call(payload) : {}
        ::Jil.trigger(ctx.user, scope, data)
        { ok: true, data: { jil_scope: scope, jil_data: data } }
      end
    end
  end
end
