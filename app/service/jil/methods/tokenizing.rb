class Jil::Methods::Tokenizing < Jil::Methods::Base
  def cast(value)
    case value
    when ::String, ::Hash then value
    else value.to_s
    end
  end

  def execute(line)
    case line.methodname
    when :breakdown then breakdown(evalarg(line.arg))
    when :parse then parse(evalarg(line.arg))
    when :match?
      query, data = evalargs(line.args)
      match?(query, data)
    when :matchData
      query, data = evalargs(line.args)
      match_data(query, data)
    end
  end

  def breakdown(query)
    return {} if query.to_s.blank?

    ::Tokenizing::Breaker.call(query.to_s)
  end

  def parse(query)
    return {} if query.to_s.blank?

    ::Tokenizing::TriggerData.parse(query.to_s)
  end

  def match?(query, data)
    return false if query.to_s.blank?

    ::Tokenizing::Matcher.new(query.to_s, @jil.cast(data, :Hash) || {}).match?
  end

  def match_data(query, data)
    return { match_list: [], named_captures: {} } if query.to_s.blank?

    matcher = ::Tokenizing::Matcher.new(query.to_s, @jil.cast(data, :Hash) || {})
    matcher.match?
    matcher.match_data
  end
end
# [Tokenizing]
#   #breakdown(String)::Hash
#   #parse(String)::Hash
#   #match?(String "=~" Hash)::Boolean
#   #matchData(String "=~" Hash)::Hash
