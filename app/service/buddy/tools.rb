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

    # Marks a call as a WAIT: it runs now, but whatever the model asked for
    # after it is held until the wait finishes on its own (see
    # Buddy::ProposalBuilder's :timer step). Only set_timer declares the arg.
    # "Start my printer, wait a minute, then preheat it" is a real sequence, and
    # without a gate in the middle the third step fires alongside the first.
    WAIT_ARG = :then_continue

    # Buddy USED to carry its spoken words on the tool call, to save the second
    # round trip. That's gone: the model now stays quiet on the call, we resolve
    # the tool, and it speaks on the follow-up with the outcome in hand. Writing
    # the words before knowing whether the chore even matched was the mechanism
    # behind "counted that" for a chore that resolved to nothing.
    #
    # The constant survives only to strip a stray `reply` key: `call_jil_function`
    # is a freeform pass-through, so an undeclared key there would be forwarded
    # to a Jil function as an argument.
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

    def register(name:, description:, args:, confirm:, label:, execute:, receipt:, merge_key: nil, merge_label: nil, passthrough_args: false, auto: false, level: nil, form: nil, supersedes: false, routinable: true, feature: Buddy::Features::CORE, gated_values: {})
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
        # Renders as an editable FORM in the thread instead of a checkbox row
        # (see Buddy::FormAction). `{ arg:, fields:, title:, submit: }` — the
        # collected values land on the payload under `arg`, and `fields` doubles
        # as the resolver, raising when the thing being edited is gone.
        form:             validate_form!(form, resolved_level),
        # Whether a LATER call with the same merge_key replaces an earlier one
        # instead of adding to it (see Buddy::Supersede). True only where the
        # target holds one state: an item is on a list once, a prompt has one
        # answer. Water drunk twice is two completions, so complete_chore and
        # log_event stay false even though they merge inside a single turn.
        supersedes:       supersedes && !merge_key.nil?,
        # Whether this call still means the same thing replayed weeks later
        # inside a BuddyRoutine. False where an argument names a specific row
        # the person pointed at in the moment — a prompt id, an idea id, "the
        # last completion". Those resolve to something different or to nothing
        # at all on the next run, so they're kept out of routines entirely
        # rather than failing quietly halfway through one.
        routinable:       routinable,
        # Enum values that only exist when the person has a given feature, as
        # `{ arg_name => { value => feature } }`. A tool can be core while some
        # of its options aren't: remind_when watching for an arrival is
        # everyone's, but watching for a CHORE completion would tell someone
        # without chores when other people in the household finished theirs.
        gated_values:     gated_values,
        # Which part of the app this tool belongs to (see Buddy::Features). A
        # person who doesn't have that feature is never shown the tool, and
        # can't run it if the model asks for it anyway. `core` is the default
        # and can't be switched off.
        feature:          feature.to_sym,
      }
      registry[name.to_sym] = spec
    end

    # A tool whose proposal is a form the person fills in.
    def form?(tool)
      tool.is_a?(Hash) && tool[:form].present?
    end

    # Safe to save into a BuddyRoutine and replay later.
    def routinable?(tool)
      tool.is_a?(Hash) && tool[:routinable] != false
    end

    # A tool where asking again means correcting, not repeating.
    def supersedes?(tool)
      tool.is_a?(Hash) && tool[:supersedes].present?
    end

    # Is THIS call a wait the rest of the turn has to line up behind?
    def waits?(tool, payload)
      return false unless tool.is_a?(Hash) && tool[:args].key?(WAIT_ARG)

      (payload || {})[WAIT_ARG].present?
    end

    # Marks a call as a question put to SOMEONE ELSE that the rest of the
    # sequence waits on. Same idea as WAIT_ARG, but the thing being waited for
    # is a person rather than a clock, so it can take days or never arrive at
    # all — which is why it gets its own step kind rather than reusing :timer.
    AWAIT_ARG = :await_reply

    def awaits_reply?(tool, payload)
      return false unless tool.is_a?(Hash) && tool[:args].key?(AWAIT_ARG)

      (payload || {})[AWAIT_ARG].present?
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
      object:       :object,
    }.freeze

    # The bare JSON type loses information the registry type carried, so hand
    # the model the format expectation in prose instead.
    # Asking for "an offset" invited the model to do the UTC arithmetic itself,
    # and it got the sign backwards: 4:45 PM at UTC-6 went out as 10:45Z, which
    # is 4:45 AM. Its own reply said "4:45 PM". So don't ask for a conversion at
    # all — the wall clock is what it already knows, and the parser applies the
    # person's zone (see cast_value's parse_iso).
    TYPE_HINTS = {
      iso_time:     "ISO8601 in the person's LOCAL wall-clock time, 24-hour, " \
                    "e.g. 2pm is \"2026-08-03T14:00:00\". Never convert to UTC and never write a Z",
      duration_min: "Whole minutes",
    }.freeze

    # `user:` drops tools belonging to a feature this person doesn't have. Not
    # offering the schema at all is the real enforcement: the model can't reach
    # for what it was never shown, so there's no refusal to write and no tokens
    # spent describing a capability that isn't there.
    def function_schemas(user: nil)
      offered = user ? all.select { |tool| Buddy::Features.allows_tool?(user, tool) } : all
      offered.map { |tool| function_schema(tool, user: user) }
    end

    def function_schema(tool, user: nil)
      properties = {}
      tool[:args].each { |key, spec| properties[key] = json_property(gate_values(tool, key, spec, user)) }
      # `count` is a registry-wide convention rather than a declared arg (see
      # validate_payload). Only advertise it on tools defining merge_label,
      # since that proc exists precisely to render a collapsed "5x Drink
      # Water" row — the other tools have no repeat semantics.
      properties[COUNT_ARG] = count_property if tool[:merge_label]
      # Pass-through tools (call_jil_function) carry args that vary per target
      # task, so they take one freeform object instead of a fixed schema.
      # A freeform object can't satisfy strict mode, hence `strict: false`.
      properties[:args] = passthrough_property if tool[:passthrough_args]

      {
        type:        :function,
        name:        tool[:name],
        description: tool[:description].strip.gsub(/\s+/, " "),
        strict:      strict?(tool),
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
      # Defensive since `reply` left the schema: a pass-through tool keeps every
      # undeclared key, so a stray one would be handed to a Jil function as an
      # argument.
      args.delete(REPLY_ARG)
      return args unless tool[:passthrough_args]

      nested = args.delete(:args)
      return args unless nested.is_a?(Hash)

      nested.transform_keys(&:to_sym).merge(args)
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
    # `zone` is the person's wall clock, and it only matters for :iso_time args
    # — pass it whenever there's a user in scope. Without it a naive ISO string
    # is read as UTC, which is a silent several-hour shift on every time the
    # model writes without an offset. Optional so the validator stays callable
    # from places that are only checking an arg's SHAPE (routine validation).
    def validate_payload(tool, raw_payload, zone: nil)
      normalized = {}
      errors     = []
      raw_payload = (raw_payload || {}).transform_keys(&:to_sym)

      tool[:args].each do |key, spec|
        value = raw_payload[key]
        if blank_arg?(value)
          if spec[:required]
            errors << "missing required arg :#{key}"
          elsif spec.key?(:default)
            normalized[key] = spec[:default]
          end
          next
        end

        cast = cast_value(value, spec[:type], zone: zone)
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

      # Absent, as far as arg validation is concerned. Nil and "" always
      # counted; an empty Hash has to as well, or a required object arg the
      # model sent as `{}` reads as supplied and sails past `required`.
      def blank_arg?(value)
        return true if value.nil?
        return value.empty? if value.respond_to?(:empty?)

        false
      end

      # One JSON Schema property from one registry arg spec. Optional args
      # become a nullable union so strict mode can still list them all in
      # `required`; the model passes null to mean "not supplied".
      # Strict mode demands a closed schema, which an open-ended object can't
      # be. Same concession pass-through tools already make, and for the same
      # reason: some args are a bag of keys we don't know until we look at what
      # they're for (a prompt's own question texts, a Jil signature's params).
      def strict?(tool)
        return false if tool[:passthrough_args]

        tool[:args].values.none? { |spec| spec[:type] == :object }
      end

      # Trims an enum down to the values this person can actually use. Returns
      # the spec untouched for everyone else, which is nearly every call.
      #
      # `dig` rather than `[]` because Buddy::SideEffects hand-builds a bare
      # `{ name:, description:, args: }` hash and calls straight in here, so a
      # registry key it never heard of has to read as absent, not blow up.
      def gate_values(tool, key, spec, user)
        gates = tool[:gated_values]&.dig(key)
        return spec if user.nil? || gates.blank?

        allowed = Array(spec[:values]).select { |v| Buddy::Features.enabled?(user, gates[v.to_sym]) }
        spec.merge(values: allowed)
      end

      def json_property(spec)
        base = JSON_TYPES[spec[:type]] || :string
        prop = { type: spec[:required] ? base : [base, :null] }
        prop[:additionalProperties] = true if base == :object

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

      # A form exists to be reviewed and sent, so it only makes sense on a tool
      # that was already waiting on the person. Level 1 and 2 run on arrival —
      # there'd be nothing left to fill in.
      def validate_form!(form, level)
        return nil if form.nil?
        raise ArgumentError, "form: needs :arg and :fields" if form[:arg].blank? || !form[:fields].respond_to?(:call)
        raise ArgumentError, "form: only makes sense on a level-3 tool" unless level == 3

        form
      end

      def validate_executor!(exec)
        return exec if exec.respond_to?(:call)
        return exec if exec.is_a?(Hash) && (exec[:bash].is_a?(String) || exec[:jil_trigger].is_a?(Hash))

        raise ArgumentError, "tool executor must be a proc, or a hash with :bash or :jil_trigger"
      end

      def cast_value(value, type, zone: nil)
        case type
        when :string       then value.to_s
        when :integer      then Integer(value.to_s, exception: false)
        when :enum         then value.to_s.to_sym
        when :boolean      then ActiveModel::Type::Boolean.new.cast(value)
        when :iso_time     then parse_iso(value.to_s, zone)
        when :duration_min then Integer(value.to_s, exception: false)
        when :object       then hashify(value)
        else value
        end
      end

      # An explicit offset is authoritative; without one the string is the
      # person's WALL CLOCK, not the server's. Time.zone is UTC app-wide, so a
      # bare "2026-08-03T16:45:00" parsed here was 10:45 AM on a UTC-6 calendar
      # — and the checklist row then displayed that shifted time, so the wrong
      # answer looked confirmed. Same rule as ToolContext#parse_in_zone, which
      # guards chore due dates; this guards every iso_time arg.
      def parse_iso(str, zone)
        return Time.zone.parse(str) if zone.nil? || str.match?(Buddy::ToolContext::HAS_OFFSET_RX)

        zone.parse(str)
      rescue ArgumentError
        nil
      end

      # An object arg arrives as a Hash from a parsed function call, but a model
      # that decides to be helpful sometimes sends the JSON as a string instead.
      # Keys stay as they came: they're the caller's own vocabulary (a prompt's
      # question texts), not our symbols.
      def hashify(value)
        return value if value.is_a?(Hash)
        return nil unless value.is_a?(String)

        parsed = JSON.parse(value) rescue nil
        parsed.is_a?(Hash) ? parsed : nil
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
