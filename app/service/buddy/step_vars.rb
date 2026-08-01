module Buddy
  # Values one step in a sequence collects, for a later step to use.
  #
  # Everything else about a sequence is static: a step's payload is frozen when
  # the proposal is built and dispatched byte-for-byte whenever its gate
  # releases, however many minutes later. That is the right default - it is what
  # makes "prep my printer" do the same thing every time - but it cannot express
  # "ask what they want, ask her what she wants, then send both somewhere".
  #
  # So a step may CAPTURE its answer under a name (`var`), and any later step
  # may reference it as `{{name}}` in an argument. The bag of captured values
  # rides along with the deferred queue from gate to gate (see
  # ProposalBuilder#gate_input) and is discarded with it.
  #
  # Deliberately not a general template language. No expressions, no filters, no
  # nesting - a whole value or a fragment of a string, and that is all. Anything
  # more would need its own escaping rules and its own failure modes, and the
  # thing being interpolated into is a tool argument that will be acted on.
  module StepVars
    module_function

    # `{{name}}`, tolerating inner spaces because a person writing one by hand
    # will put them there. Names are the plain identifier set on purpose: what
    # is legal has to be obvious at a glance from either side.
    TOKEN = /\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/

    # The argument a capturing step stores its answer under. Same shape as
    # Tools::WAIT_ARG - the presence of the arg on the tool is what marks the
    # tool as able to do this at all.
    CAPTURE_ARG = :var

    # What a `var` is allowed to be. Same set TOKEN will match later: a name with
    # a space or a dash saves perfectly and can then never be referenced, which
    # is a sequence broken in a way nothing would ever surface.
    NAME = /\A[a-zA-Z0-9_]+\z/

    def captures?(tool)
      tool.is_a?(Hash) && tool[:args].is_a?(Hash) && tool[:args].key?(CAPTURE_ARG)
    end

    # Whether THIS call is one the rest of a sequence is waiting on.
    def awaiting?(payload)
      ActiveModel::Type::Boolean.new.cast((payload || {})[Buddy::Tools::AWAIT_ARG])
    end

    # The checked name a step will file its answer under, or nil when it isn't
    # filing one. `required` differs by tool: ask_me exists to capture, while
    # asking a partner only captures when something is waiting on the reply.
    def capture_name!(payload, required:)
      name = (payload || {})[CAPTURE_ARG].to_s.strip
      if name.empty?
        raise "waiting on an answer needs a `var` to file it under" if required

        return nil
      end
      raise "#{name.inspect} isn't a usable name - letters, numbers and underscores" unless name.match?(NAME)

      name
    end

    # The name a step captures under, or nil when it captures nothing.
    def captured_name(tool, payload)
      return nil unless captures?(tool)

      (payload || {})[CAPTURE_ARG].to_s.strip.presence
    end

    # Every `{{name}}` anywhere in a payload, in no particular order.
    def references(payload)
      (payload || {}).values.flat_map { |v| tokens_in(v) }.uniq
    end

    def tokens_in(value)
      case value
      when String then value.scan(TOKEN).flatten
      when Array  then value.flat_map { |v| tokens_in(v) }
      when Hash   then value.values.flat_map { |v| tokens_in(v) }
      else []
      end
    end

    # Fill a payload in. Returns [filled, missing] - `missing` is the names that
    # had no value, and the caller is expected to refuse to run rather than pass
    # the literal `{{hers}}` on to something that will act on it. A step quietly
    # sending the token itself is precisely the silent failure a saved sequence
    # exists to remove.
    def fill(payload, vars)
      values  = (vars || {}).transform_keys(&:to_s)
      missing = references(payload).reject { |name| values.key?(name) }
      return [payload, missing] if missing.any?
      return [payload, []] if values.empty?

      [(payload || {}).transform_values { |v| substitute(v, values) }, []]
    end

    def substitute(value, values)
      case value
      when String then fill_string(value, values)
      when Array  then value.map { |v| substitute(v, values) }
      when Hash   then value.transform_values { |v| substitute(v, values) }
      else value
      end
    end

    # A value that is nothing BUT a token keeps the captured value's own type -
    # a multi-select answer stays an array rather than becoming "[...]". Mixed
    # into a sentence it has to become text, so it is joined readably.
    def fill_string(text, values)
      whole = text.match(/\A\s*#{TOKEN}\s*\z/)
      return values[whole[1]] if whole

      text.gsub(TOKEN) { readable(values[Regexp.last_match(1)]) }
    end

    def readable(value)
      value.is_a?(Array) ? value.join(", ") : value.to_s
    end
  end
end
