RSpec::Matchers.define :match_hash do |expected|
  match do |actual|
    format_hash = lambda do |hash|
      hash.deep_stringify_keys.sort.to_h
    end

    formatted_expected = format_hash.call(expected)
    formatted_actual = format_hash.call(actual)

    formatted_expected == formatted_actual
  end

  failure_message do |actual|
    "expected that #{actual} would match #{expected} ignoring key types and order"
  end

  failure_message_when_negated do |actual|
    "expected that #{actual} would not match #{expected} ignoring key types and order"
  end

  description do
    "match hash ignoring key types and order"
  end
end
