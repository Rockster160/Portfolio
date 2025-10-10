RSpec::Matchers.define :match_hash do |expected|
  def format_hash(hash)
    formatted = hash.map { |k, v|
      formatted_value = v.is_a?(::Hash) ? format_hash(v) : v.inspect
      formatted_key = k.is_a?(::Symbol) || k.is_a?(::String) ? k : k.inspect
      "#{formatted_key}: #{formatted_value}"
    }
    "{ #{formatted.join(", ")} }"
  end

  match { |actual|
    format_hash = lambda { |hash|
      hash.deep_stringify_keys.sort.to_h
    }

    formatted_expected = format_hash.call(expected)
    formatted_actual = format_hash.call(actual)

    formatted_expected == formatted_actual
  }

  failure_message { |actual|
    "expected that \n    #{format_hash(actual)}\n would match \n    #{format_hash(expected)}\n ignoring key types and order"
  }

  failure_message_when_negated { |actual|
    "expected that \n    #{format_hash(actual)}\n would not match \n    #{format_hash(expected)}\n ignoring key types and order"
  }

  description {
    "match hash ignoring key types and order"
  }
end
