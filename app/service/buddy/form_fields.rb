module Buddy
  # The vocabulary for an editable form rendered inside a Byte message, and the
  # gate every submitted value passes through.
  #
  # A tool declares `form:` (see Buddy::Tools.register) and gets a real form in
  # the thread instead of a checkbox row: the person reads what Buddy filled in,
  # fixes whatever is wrong, and sends. That changes the risk arithmetic — a
  # wrong guess is now visible and one tap from corrected — which is why Buddy
  # is told to fill everything it plausibly can rather than stopping to ask.
  #
  # Types deliberately mirror shared/_dynamic_form_fields, since the app's own
  # Prompt pages are the first thing this renders and a Buddy-submitted response
  # has to be indistinguishable from a tapped one.
  #
  # Descriptor:
  #   { key:, label:, type:, value:, choices:, min:, max:, step:, required:, hint: }
  #
  # `key` is separate from `label` because the value lands in a payload under
  # `key` while the person reads `label`. For prompts they happen to be the same
  # string (the question text), but nothing else has to follow that.
  module FormFields
    module_function

    TYPES = %i[
      text textarea number scale select choices checkbox date datetime time color hidden
    ].freeze

    # The one type whose value is a list rather than a scalar.
    MULTI = :choices

    # Carried through untouched: the form posts them, the person never sees them.
    HIDDEN = :hidden

    def normalize(fields)
      Array(fields).filter_map { |raw|
        field = raw.respond_to?(:to_h) ? raw.to_h.symbolize_keys : nil
        next nil if field.nil?

        key = field[:key].to_s
        next nil if key.empty?

        type = field[:type].to_s.to_sym
        type = :text unless TYPES.include?(type)
        {
          key:      key,
          label:    field[:label].to_s.presence || key,
          type:     type,
          value:    field[:value],
          choices:  Array(field[:choices]).map(&:to_s).presence,
          min:      field[:min],
          max:      field[:max],
          step:     field[:step],
          required: field.fetch(:required, true) ? true : false,
          hint:     field[:hint].to_s.presence,
        }.compact
      }
    end

    # Turn what the browser posted into the values a tool's payload wants.
    # Returns [collected, errors]. Errors are written for a person to read,
    # because they render under the field that caused them.
    #
    # Values are matched by KEY only — no fuzzy matching. The client sends back
    # the keys it was given, so anything else is a bug or a forged request, and
    # in both cases guessing is the wrong response.
    def collect(fields, values)
      posted    = (values || {}).transform_keys(&:to_s)
      collected = {}
      errors    = []

      normalize(fields).each { |field|
        if field[:type] == HIDDEN
          collected[field[:key]] = field[:value]
          next
        end

        value, error = coerce(field, posted[field[:key]])
        if error
          errors << error
        elsif blank?(value)
          errors << "#{field[:label]} needs a value" if field[:required]
        else
          collected[field[:key]] = value
        end
      }

      [collected, errors]
    end

    # Fold submitted values back onto the descriptors so a submitted form can be
    # re-rendered showing what was actually sent.
    def apply_values(fields, values)
      posted = (values || {}).transform_keys(&:to_s)
      normalize(fields).map { |field|
        posted.key?(field[:key]) ? field.merge(value: posted[field[:key]]) : field
      }
    end

    def blank?(value)
      value.nil? || (value.respond_to?(:empty?) && value.empty?)
    end

    # Returns [value, error]. Every branch produces what the matching widget in
    # shared/_dynamic_form_fields would post.
    def coerce(field, raw)
      case field[:type]
      when MULTI              then multi(field, raw)
      when :select            then one_of(field, raw)
      when :checkbox          then [truthy?(raw) ? "true" : "false", nil]
      when :number, :scale    then number(field, raw)
      when :datetime          then time(field, raw, "%Y-%m-%dT%H:%M")
      when :date              then time(field, raw, "%Y-%m-%d")
      when :time              then time(field, raw, "%H:%M")
      when :color             then color(field, raw)
      else [raw.to_s.strip, nil]
      end
    end

    def multi(field, raw)
      wanted = raw.is_a?(Array) ? raw : raw.to_s.split(",")
      picked = []
      wanted.each { |part|
        next if part.to_s.strip.empty?

        value, error = one_of(field, part)
        return [nil, error] if error

        picked << value
      }
      [picked, nil]
    end

    def one_of(field, raw)
      wanted  = raw.to_s.strip
      choices = field[:choices]
      return [wanted, nil] if choices.blank? || wanted.empty?

      found = choices.find { |c| c.casecmp?(wanted) }
      return [found, nil] if found

      [nil, "#{field[:label]}: #{wanted.inspect} isn't one of the options"]
    end

    TRUTHY = %w[true yes y on 1].freeze

    def truthy?(raw)
      return raw if [true, false].include?(raw)

      TRUTHY.include?(raw.to_s.strip.downcase)
    end

    def number(field, raw)
      text = raw.to_s.strip
      return [nil, nil] if text.empty?

      value = Float(text, exception: false)
      return [nil, "#{field[:label]} takes a number"] if value.nil?

      min, max = field[:min], field[:max]
      if (min && value < min.to_f) || (max && value > max.to_f)
        return [nil, "#{field[:label]} has to be between #{min || "any"} and #{max || "any"}"]
      end

      [(value % 1).zero? ? value.to_i.to_s : value.to_s, nil]
    end

    def time(field, raw, format)
      text = raw.to_s.strip
      return [nil, nil] if text.empty?

      parsed = Time.zone.parse(text) rescue nil
      return [nil, "#{field[:label]}: couldn't read #{text.inspect} as a time"] if parsed.nil?

      [parsed.strftime(format), nil]
    end

    # A colour input always posts #rrggbb; anything else came from somewhere
    # that isn't the form.
    def color(field, raw)
      text = raw.to_s.strip
      return [nil, nil] if text.empty?
      return [text.downcase, nil] if text.match?(/\A#[0-9a-f]{6}\z/i)

      [nil, "#{field[:label]} takes a colour like #4488ff"]
    end
  end
end
