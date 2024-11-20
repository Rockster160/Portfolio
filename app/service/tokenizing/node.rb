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

# Maybe? Whitelist certain characters inside of strings.
#   in:inbox,sent timestamp<2019-01-01
# BUG: Things like ! and - affect only the next item without the previous one.
#   They will need special handling. Hacking - for now, but it's not ideal because it breaks dates.
class Tokenizing::Node
  KEYWORDS = %w(NOT ! - OR AND) # priority order?

  attr_accessor :field, :operator, :conditions

  def self.keyword?(token)
    return false if token.blank? || token.is_a?(Array)

    token.to_s.upcase.in?(KEYWORDS)
  end

  def self.operation?(token)
    return false if token.blank? || token.is_a?(Array)

    token.match?(/\A#{Tokenizing::Breaker::NON_WORD_RX}\z/)
  end

  # ALWAYS returns a single Tokenizing::Node
  def self.parse(tokens)
    node = tokenize(tokens).compact(compress: true, top: true)
    return node if node.is_a?(Tokenizing::Node)

    Tokenizing::Node.new(operator: :AND, conditions: node)
  end

  # May return a single item vs a node
  def self.tokenize(tokens, compress: false, top: true)
    return tokens if tokens.is_a?(Tokenizing::Node)

    if tokens.is_a?(String)
      tz = Tokenizer.new(tokens)
      sections = tz.tokenized_text.split(/\s*(\b#{KEYWORDS.join("\\b|\\b")}\b|\B[!-](?:\B|\b))\s*/i)

      if sections.many?
        return parse_sections(
          sections.map { |section|
            tz.untokenize(section).then { |sec| keyword?(sec) ? sec.upcase.to_sym : sec }
          }
        )
      else
        tokens = Tokenizing::Breaker.breakdown(tokens).map { |token|
          token.is_a?(Array) ? tokenize(token, compress: false, top: false) : token
        }
      end
    elsif tokens.is_a?(Array)
      return tokenize(tokens.first, compress: false, top: false) if tokens.one?

      return parse_sections(
        tokens.map { |section| keyword?(section) ? section.upcase.to_sym : section },
      )
    end

    conditions = []
    node = Tokenizing::Node.new
    active_node = nil
    tokens.each do |token|
      if token.is_a?(Tokenizing::Node)
        if node.operator || active_node&.operator
          node.conditions << token
        else
          conditions << token
        end
        next
      end
      raise "Splitting by keywords first!" if keyword?(token)

      if operation?(token)
        if !node.field && active_node && active_node.operator.nil?
          active_node.operator = token.to_sym
        else
          active_node = nil
          node.operator = token.to_sym
        end
      elsif node.operator || active_node&.operator
        new_node = parse(token)
        node.conditions << new_node
        if !node.field && active_node.is_a?(Tokenizing::Node)
          active_node.conditions << node
        else
          conditions << node
        end
        active_node = new_node
        node = Tokenizing::Node.new
      elsif node.field
        conditions << node
        node = parse(token)
      else
        node.field = token
      end
    end

    return node if conditions.blank? && node.conditions.blank?

    conditions << node if node.field || node.conditions.any?

    Tokenizing::Node.new(operator: :AND, conditions: conditions).compact(compress: compress, top: top)
  end

  def self.unwrap(str, wraps={ "(" => ")", "[" => "]", "{" => "}" })
    unwrap_pairs_rx = wraps.map { |k, v|
      Regexp.escape(k) + ".*" + Regexp.escape(v)
    }.join("|").then { |rx| /\A#{rx}\z/ }

    str.match?(unwrap_pairs_rx) ? str[1..-2] : str
  end

  def self.unwrap_parse(val, wrap: true)
    return val.map { |v| unwrap_parse(v, wrap: false) } if val.is_a?(Array)

    val = unwrap(val) if val.is_a?(String)

    tokenize(val, compress: false).then { |v| wrap ? [v] : v }
  end

  def self.parse_sections(tokens)
    while tokens.include?(:NOT) || tokens.include?(:-) || tokens.include?(:!)
      idx = tokens.index(:NOT) || tokens.index(:-) || tokens.index(:!)
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

  def unwrap_quotes(str)
    self.class.unwrap(str, { "\"" => "\"", "'" => "'" })
  end

  def compact(compress: true, top: false)
    @field = unwrap_quotes(@field) if @field.is_a?(String)
    if @conditions.is_a?(Array)
      @conditions = @conditions.map { |cond| cond.is_a?(String) ? unwrap_quotes(cond) : cond }
    elsif @conditions.is_a?(String)
      @conditions = unwrap_quotes(@conditions)
    end

    return self unless compress
    return self unless conditions.is_a?(Array)

    return field.presence if !top && field.present? && operator.nil? && conditions.blank?

    @conditions = @conditions.flat_map { |node|
      if node.is_a?(Tokenizing::Node)
        if (operator == :AND || operator == :OR) && node.operator == operator && field == node.field
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

    if top && operator == :AND && field.nil? && conditions.one? && conditions.first.is_a?(Tokenizing::Node)
      return conditions.first.compact(top: true)
    elsif conditions.one?
      condition = conditions.first

      if field.nil? && (operator == :AND || operator == :OR)
        return condition.is_a?(Tokenizing::Node) ? condition.compact : condition
      end

      unless conditions.first.is_a?(Tokenizing::Node)
        @conditions = condition
      end
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

  def to_s
    "\e[0m<Node field:\e[32m#{field || "\e[90mnil"}\e[0m operator:\e[36m#{operator}\e[0m conditions:\e[35m[\n#{Array.wrap(conditions).map(&:to_s).join(",")}]\e[0m>"
  end

  def flatten
    if conditions.is_a?(Array)
      [
        { field: field, operator: operator },
        *Array.wrap(conditions).map { |cond| cond.is_a?(Tokenizing::Node) ? cond.flatten : cond }
      ].flatten
    else
      [as_json]
    end
  end
end
