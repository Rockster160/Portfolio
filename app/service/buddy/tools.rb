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
      Dir[Rails.root.join("app/service/buddy/tools/*.rb")].sort.each { |f| load f }
    ensure
      @loading_tools = false
    end

    def register(name:, description:, args:, confirm:, label:, execute:, receipt:, merge_key: nil, merge_label: nil, passthrough_args: false, auto: false)
      spec = {
        name:             name.to_sym,
        description:      description.to_s,
        args:            normalize_args(args),
        confirm:         confirm,
        label:           label,
        execute:         validate_executor!(execute),
        receipt:         receipt,
        merge_key:       merge_key || ->(payload) { "#{name}:#{SecureRandom.uuid}" },
        merge_label:     merge_label,
        # Trusted tools run WITHOUT a confirmation checkbox: the marker
        # executes immediately and drops a distinct "activity" receipt chip
        # instead of a pending checklist row. As confidence in a tool grows,
        # flip it to `auto: true` and it stops needing approval.
        auto:            auto,
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

    # Rendered into the system prompt every turn so the persona has fresh,
    # deterministic tool docs. Kept short — one line per tool + arg list.
    def system_prompt_appendix
      lines = ["## Available tools", ""]
      lines << "Emit markers like `[[propose: <tool> arg=\"value\" arg=value count=N]]`. Each marker becomes a checkbox row for the user to confirm. Use `count=N` when the same action repeats."
      lines << ""
      all.each do |tool|
        arg_bits = tool[:args].map { |k, spec|
          req = spec[:required] ? "" : "?"
          type = spec[:type]
          "#{k}#{req}:#{type}"
        }.join(" ")
        lines << "- **#{tool[:name]}** — #{tool[:description].strip.gsub(/\s+/, " ")}"
        lines << "  args: #{arg_bits}" if arg_bits.present?
      end
      lines.join("\n")
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
    rescue => e
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

        if spec[:type] == :enum && !Array(spec[:values]).map(&:to_sym).include?(cast)
          errors << "arg :#{key} must be one of #{spec[:values]}"
          next
        end
        if spec[:range] && spec[:range].is_a?(Range) && !spec[:range].cover?(cast)
          errors << "arg :#{key} out of range #{spec[:range]}"
          next
        end

        normalized[key] = cast
      end

      # `count` is a first-class convention — accept it even when the tool
      # didn't declare it (default 1).
      if raw_payload.key?(COUNT_ARG)
        count = raw_payload[COUNT_ARG].to_i
        normalized[COUNT_ARG] = count if count > 0
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
        when :integer      then Integer(value.to_s) rescue nil
        when :enum         then value.to_s.to_sym
        when :boolean      then ActiveModel::Type::Boolean.new.cast(value)
        when :iso_time     then Time.zone.parse(value.to_s) rescue nil
        when :duration_min then Integer(value.to_s) rescue nil
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
          ok:          status.success?,
          data:        {
            stdout_tail: stdout.to_s.lines.last(20).join,
            stderr_tail: stderr.to_s.lines.last(20).join,
            exit_status: status.exitstatus,
            elapsed_ms:  ((Time.current - started) * 1000).round,
          },
          error:       status.success? ? nil : "exit #{status.exitstatus}: #{stderr.to_s.lines.last}",
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
