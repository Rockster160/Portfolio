# "name::food:cereal:>thing"
# {
#   field: "name",
#   operator: "::",
#   conditions: [
#     {
#       field: "food",
#       operator: ":",
#       conditions: [
#         {
#           field: "cereal",
#           operator: ":>",
#           conditions: "thing"
#         }
#       ]
#     }
#   ]
# }

# "price < 20 price > 10 (Potter OR Rowling)"
# {
#   field: nil,
#   operator: "AND",
#   conditions: [
#     {
#       field: "price",
#       operator: "<",
#       conditions: "20"
#     },
#     {
#       field: "price",
#       operator: ">",
#       conditions: "10"
#     },
#     {
#       field: nil,
#       operator: "OR",
#       conditions: [
#         "Potter",
#         "Rowling"
#       ]
#     }
#   ]
# }

class Tokenizing::Node
  KEYWORDS = %w(NOT OR AND) # priority order?

  attr_accessor :field, :operator, :conditions

  def self.keyword?(token)
    return false if token.blank? || token.is_a?(Array)

    token.to_s.upcase.in?(KEYWORDS)
  end

  def self.operation?(token)
    return false if token.blank? || token.is_a?(Array)

    token.match?(/\A#{Tokenizing::Breaker::NON_WORD_RX}\z/)
  end

  def self.parse(tokens, compress=true) # ALWAYS returns a single Tokenizing::Node
    return tokens if tokens.is_a?(Tokenizing::Node)

    if tokens.is_a?(String)
      tz = Tokenizer.new(tokens)
      sections = tz.tokenized_text.split(/\s*(\b#{KEYWORDS.join("\\b|\\b")}\b)\s*/i)

      if sections.many?
        return parse_sections(
          sections.map { |section|
            tz.untokenize(section).then { |sec| keyword?(sec) ? sec.to_sym : sec }
          }
        )
      else
        tokens = Tokenizing::Breaker.breakdown(tokens).map { |token|
          token.is_a?(Array) ? parse(token, false) : token
        }
      end
    elsif tokens.is_a?(Array)
      return parse(tokens.first, false) if tokens.one?

      return parse_sections(
        tokens.map { |section| keyword?(section) ? section.to_sym : section }
      )
    end

    conditions = []
    node = Tokenizing::Node.new
    active_node = nil
    tokens.each do |token|
      next conditions << token if token.is_a?(Tokenizing::Node)
      raise "Splitting by keywords first!" if keyword?(token)

      if operation?(token)
        if !node.field && active_node && active_node.operator.nil?
          active_node.operator = token.to_sym
        else
          active_node = nil
          node.operator = token.to_sym
        end
      elsif node.operator || active_node&.operator
        new_node = parse("\"#{token}\"", false) # wrap in quotes to prevent breaking the string
        node.conditions << new_node
        if !node.field && active_node.is_a?(Tokenizing::Node)
          active_node.conditions << node
        else
          conditions << node
        end
        active_node = new_node.conditions.last
        node = Tokenizing::Node.new
      elsif node.field
        new_node = parse("\"#{token}\"", false) # wrap in quotes to prevent breaking the string
        node.conditions << new_node
      else
        node.field = token
      end
    end

    conditions << node if node.field || node.conditions.any?

    Tokenizing::Node.new(operator: :AND, conditions: conditions).compact(compress)
  end

  def self.unwrap_parse(val, wrap: true)
    return val.map { |v| unwrap_parse(v, wrap: false) } if val.is_a?(Array)

    if val.is_a?(String)
      unwrap_pairs_rx = {
        "(" => ")",
        "[" => "]",
        "{" => "}",
      }.map { |k, v|
        Regexp.escape(k) + ".*" + Regexp.escape(v)
      }.join("|").then { |rx| /\A#{rx}\z/ }

      val = val[1..-2] if val.match?(unwrap_pairs_rx)
    end

    parse(val, false).then { |v| wrap ? [v] : v }
  end

  def self.parse_sections(tokens)
    while tokens.include?(:NOT)
      idx = tokens.index(:NOT)
      min, max = idx, idx+1
      max += 1 while max < tokens.length && tokens[max].is_a?(Symbol) # Other Keyword
      next tokens.delete_at(idx) if idx >= tokens.length

      tokens[min..max] = Tokenizing::Node.new(operator: :NOT, conditions: unwrap_parse(tokens[max]))
    end

    while tokens.include?(:OR)
      idx = tokens.index(:OR)
      min, max = idx-1, idx+1
      min -= 1 while min >= 0 && tokens[min].is_a?(Symbol) # Other Keyword
      max += 1 while max < tokens.length && tokens[max].is_a?(Symbol) # Other Keyword
      next tokens.delete_at(idx) if min < 0 || max >= tokens.length

      a, *_or, b = tokens[min..max]
      tokens[min..max] = Tokenizing::Node.new(operator: :OR, conditions: unwrap_parse([a, b]))
    end

    while tokens.include?(:AND)
      idx = tokens.index(:AND)
      min, max = idx-1, idx+1
      min -= 1 while min >= 0 && tokens[min].is_a?(Symbol) # Other Keyword
      max += 1 while max < tokens.length && tokens[max].is_a?(Symbol) # Other Keyword
      next tokens.delete_at(idx) if min < 0 || max >= tokens.length

      a, *_and, b = tokens[min..max]
      tokens[min..max] = Tokenizing::Node.new(operator: :AND, conditions: unwrap_parse([a, b]))
    end

    Tokenizing::Node.new(field: nil, operator: :AND, conditions: unwrap_parse(tokens)).compact
  end

  def initialize(field: nil, operator: nil, conditions: [])
    @field = field
    @operator = operator
    @conditions = conditions
  end

  def compact(compress=true)
    return self unless compress
    return self unless conditions.is_a?(Array)

    return if field.nil? && operator.nil? && conditions.blank?
    return field if field.present? && operator.nil? && conditions.blank?

    if field.nil? && (operator == :AND || operator == :OR) && conditions.one?
      condition = conditions.first
      return condition.is_a?(Tokenizing::Node) ? condition.compact : condition
    end

    @conditions = @conditions.flat_map { |node|
      if node.is_a?(Tokenizing::Node)
        if operator == :AND && node.operator == :AND && field == node.field
          node.conditions.map { |cond| cond.is_a?(Tokenizing::Node) ? cond.compact : cond }
        elsif node.field.nil? && node.operator.nil?
          node.conditions.map { |cond| cond.is_a?(Tokenizing::Node) ? cond.compact : cond }
        else
          node.compact
        end
      else
        node
      end
    }

    if conditions.one? && !conditions.first.is_a?(Tokenizing::Node)
      @conditions = conditions.first
    end

    self
  end

  def as_json
    {
      field: field,
      operator: operator,
      conditions: conditions.as_json,
    }
  end
end
