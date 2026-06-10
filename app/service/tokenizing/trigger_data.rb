module Tokenizing::TriggerData
  module_function

  def parse(input, as: nil)
    return input if input.is_a?(::ApplicationRecord)

    input = input.permit!.to_h.except(:controller, :action) if input.is_a?(::ActionController::Parameters)
    input = input.to_h if input.is_a?(::ActiveSupport::HashWithIndifferentAccess)

    return unwrap(input.deep_symbolize_keys, as: as) if input.is_a?(::Hash)
    return unwrap({ data: input }, as: as) if input.is_a?(::Array)

    begin
      return parse(::JSON.parse(input), as: as) if input.is_a?(::String)
    rescue ::JSON::ParserError
      # Fall through to colon-segment parsing
    end

    return { data: input } unless input.is_a?(::String)

    pieces = top_level_pieces(input)
    if pieces.size > 1 && pieces.all? { |p| p.include?(":") }
      return pieces.each_with_object({}) { |piece, hash|
        sub = parse(piece, as: as)
        hash.deep_merge!(sub) if sub.is_a?(::Hash)
      }
    end

    segments = colon_segments(input)
    return { data: input } if segments.size < 2

    parse(segments.reverse.reduce { |value, key| { key.to_sym => value } }, as: as)
  end

  # Splits the input on top-level whitespace, keeping quoted substrings
  # (single or double) intact so `name:"Refill Item"` stays one piece.
  def top_level_pieces(input)
    tokenizer = ::Tokenizer.new(input)
    tokenizer.tokenized_text.split(/\s+/).filter_map { |seg|
      tokenizer.untokenize(seg).strip.presence
    }
  end

  # Splits a colon-delimited string into segments, tokenizing first so quoted
  # substrings (single OR double quoted) survive a colon inside them and have
  # their outer quotes stripped at the segment level. Examples:
  #   "a:b:c"                       → ["a", "b", "c"]
  #   'person:chelsea:"-15.20"'     → ["person", "chelsea", "-15.20"]
  #   'note:"has been"'             → ["note", "has been"]
  #   'command:Remind me to "x"'    → ["command", 'Remind me to "x"']
  def colon_segments(input)
    tokenizer = ::Tokenizer.new(input)
    text = tokenizer.tokenized_text
    return [] unless text.include?(":")

    text.split(":").map { |seg|
      ::Tokenizing::Breaker.unwrap(tokenizer.untokenize(seg).strip)
    }.reject(&:empty?)
  end

  def unwrap(json, as: nil)
    return json unless json.is_a?(::Hash)

    json.transform_values { |value|
      case value
      when ::Hash then unwrap(value, as: as)
      when ::Array then value.map { |v| unwrap(v, as: as) }
      when ::String then lookup(value, as: as)
      else value
      end
    }
  end

  def lookup(string, as: nil)
    # "gid://Jarvis/User/1"
    return string unless as.is_a?(::User)
    return string unless string.is_a?(::String)

    _m, klass_name, id = string.match(/\Agid:\/\/Jarvis\/(\w+)\/(\d+)\z/)&.to_a
    return string unless klass_name.present? && id.present?

    klass = klass_name.constantize
    reflection = ::User.reflections.values.find { |r| r.klass == klass }

    as.send(reflection.name).find(id)
  rescue NameError, ::ActiveRecord::RecordNotFound
    string
  end

  def serialize(data, use_global_id: true)
    case data
    when ::Hash then data.transform_values { |value| serialize(value, use_global_id: use_global_id) }
    when ::Array then data.map { |value| serialize(value, use_global_id: use_global_id) }
    when ::ApplicationRecord
      use_global_id ? data.to_global_id.to_s : data.serialize(use_global_id: use_global_id)
    when ::String then data
    else data
    end
  end
end
