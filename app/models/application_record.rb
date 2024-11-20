class ApplicationRecord < ActiveRecord::Base
  attr_accessor :new_attributes
  self.abstract_class = true

  def self.ilike(hash, join=:OR)
    where(build_query(hash, :ILIKE, join), *hash.values)
  end

  def self.not_ilike(hash, join=:AND)
    # where(build_query(hash, "NOT ILIKE", join), *hash.values)
    where(
      # Dumb PG removes empty values when querying for a NOT for some reason
      hash.map { |k, v| "(\"#{k}\"::TEXT NOT ILIKE ? OR \"#{k}\" IS NULL)" }.join(" #{join} "),
      *hash.values
    )
  end

  def self.build_query(hash, point, join_with=:AND)
    hash.map { |k, v| "\"#{k}\"::TEXT #{point} ?" }.join(" #{join_with} ")
  end

  def self.search_scope
    # Redefine this in the model if a `joins` or other default scope is needed
    all
  end

  def self.search_terms(*set_terms)
    # alias => column
    @search_terms ||= begin
      terms = {}
      set_terms.each do |set_term|
        case set_term
        when Hash then terms.merge!(set_term)
        else terms[set_term] = set_term
        end
      end
      terms
    end
  end

  def self.search_indexed(word)
    search_terms.values.filter_map { |column|
      next column if column.to_s.include?(".")
      column_data = columns.find { |c| c.name == column.to_s }
      next column if column_data&.type.in?(%i[string text])
    }.index_with(word)
  end

  def self.stripped_sql
    all.to_sql.gsub(/(?: AND )?SELECT "#{table_name}"\.\* FROM "#{table_name}"(?: WHERE )?/, "")
  end

  def self.raw_sql(q, data=nil)
    sql = unscoped.where(q, data)
    sql.any? # validate
    sql.stripped_sql
  rescue ActiveRecord::StatementInvalid
    raise unless Rails.env.production?
  end

  def self.node_sql(node, parent_node=nil)
    field = (parent_node&.field || node.field).to_sym
    unless search_terms.key?(field)
      return unscoped.search(field).stripped_sql
    end

    column = search_terms[field].to_s
    column_data = nil
    scope_method = nil

    if !column.include?(".") && !column_names.include?(column)
      scope_method = column
      column = nil
    else
      column_data = columns.find { |c| c.name == column }
    end

    operator = (parent_node&.operator || node.operator).to_sym

    text_operators = %i[: :: !: !::] # ~ !~
    numeric_operators = %i[= != < > <= >=]
    # json_operators = %i[=> ->]
    # Eventually this should detect that it's a json column and use the jsonb operators
    Array.wrap(node.conditions).map { |value|
      next unscoped.query_by_node(value, node).stripped_sql if value.is_a?(Tokenizing::Node)

      next if value.is_a?(Tokenizing::Node)
      next unless operator.in?(text_operators + numeric_operators)

      if scope_method.present?
        unscoped.send(scope_method, *value).stripped_sql
      elsif column_data.type.in?(%i[string text])
        case operator.to_s
        when *%w[:] then raw_sql("#{column} ILIKE ?", "%#{value}%")
        when *%w[:: =] then raw_sql("#{column} ILIKE ?", value)
        when *%w[!:] then raw_sql("#{column} NOT ILIKE ?", "%#{value}%")
        when *%w[!:: !=] then raw_sql("#{column} NOT ILIKE ?", value)
        end
      elsif column_data.type.in?(%i[datetime date])
        value = parse_date_with_operator(value, operator)
        case operator.to_s
        when *%w[= : ::] then raw_sql("#{column}::DATE = ?::DATE", value)
        when *%w[!= !: !::] then raw_sql("#{column}::DATE != ?::DATE", value)
        when *%w[<] then raw_sql("#{column} < ?", value)
        when *%w[>] then raw_sql("#{column} > ?", value)
        when *%w[<=] then raw_sql("#{column} <= ?", value)
        when *%w[>=] then raw_sql("#{column} >= ?", value)
        end
      elsif column_data.type.in?(%i[integer float decimal])
        case operator.to_s
        when *%w[= : ::] then raw_sql("#{column} = ?", value.to_f)
        when *%w[!= !: !::] then raw_sql("#{column} != ?", value.to_f)
        when *%w[<] then raw_sql("#{column} < ?", value.to_f)
        when *%w[>] then raw_sql("#{column} > ?", value.to_f)
        when *%w[<=] then raw_sql("#{column} <= ?", value.to_f)
        when *%w[>=] then raw_sql("#{column} >= ?", value.to_f)
        end
      end
    }.compact_blank.then { |values|
      next values.first unless values.many?
      case node.operator
      when :AND then "((#{values.join(") AND (")}))"
      when :OR then "((#{values.join(") OR (")}))"
      when :NOT then "NOT ((#{values.join(") AND (")}))"
      end
    }
  end

  scope :assign, -> (data) {
    relation = all
    # prev = relation.instance_variable_get(:@assigned_data) || {}
    relation.instance_variable_set(:@assigned_data, data)
    relation
  }
  def self.assigned(key)
    (all.instance_variable_get(:@assigned_data) || {})[key]
  end

  scope :search, ->(q) {
    next none if search_terms.blank?

    ilike(search_indexed("%#{q}%"), :OR)
  }
  scope :unsearch, ->(q) {
    next none if search_terms.blank?

    not_ilike(search_indexed("%#{q}%"), :AND)
  }
  scope :query_by_node, ->(node, parent_node=nil) {
    # TODO: # Allow passing `offset:50` and `limit:50` to the query
    sql = (
      if node.field.nil?
        conditions = (
          if parent_node
            [node_sql(node, parent_node)]
          else
            Array.wrap(node.conditions).map { |condition|
              if condition.is_a?(Tokenizing::Node)
                unscoped.query_by_node(condition).stripped_sql
              else
                raise("Pretty sure this is deprecated")
                unscoped.search(condition).stripped_sql
              end
            }.compact_blank
          end
        )

        next if conditions.blank?

        case node.operator&.to_sym
        when :AND then "(#{conditions.join(" AND ")})"
        when :OR then "(#{conditions.join(" OR ")})"
        when :NOT then "NOT (#{conditions.join(" AND ")})"
        end
      else
        node_sql(node)
      end
    ).to_s

    # Reduce parens:
    # tz = Tokenizer.new(sql, only: { "\"" => "\"", "'" => "'" })
    # str = tz.tokenized_text
    # /\({2}(\w+ \S+ \w+)\){2}/.tap { |rx| str = str.gsub(rx, '(\1)') while str.match?(rx) }
    # sql = tz.untokenize(str)
    next if sql.blank?

    where(sql)
  }
  scope :query, ->(q) {
    breaker = ::Tokenizing::Node.parse(q)

    where(unscoped.query_by_node(breaker).stripped_sql)
  }
  scope :before, ->(time) {
    t = Time.zone.parse(time) rescue (next none)

    key = column_names.include?("timestamp") ? :timestamp : :created_at
    where(key => ..t)
  }
  scope :after, ->(time) {
    t = Time.zone.parse(time) rescue (next none)

    key = column_names.include?("timestamp") ? :timestamp : :created_at
    where(key => t..)
  }

  def new(attrs={})
    @new_attributes = attrs
    super(attrs)
  end

  def assign_attributes(attrs={})
    @new_attributes = attrs
    super(attrs)
  end

  def create(attrs={})
    @new_attributes = attrs
    super(attrs)
  end

  def update(attrs={})
    @new_attributes = attrs
    super(attrs)
  end

  def to_h
    as_json
  end

  def self.parse_date_with_operator(value, operator)
    date = Date.new(*value.split(/\D/).map(&:to_i))
    case value
    when /^\d{4}$/
      operator.in?(%w[<]) ? date.beginning_of_year : date.end_of_year
    when /^\d{4}-\d{1,2}$/
      operator.in?(%w[<]) ? date.beginning_of_month : date.end_of_month
    when /^\d{4}-\d{1,2}-\d{1,2}$/
      operator.in?(%w[<]) ? date.beginning_of_day : date.end_of_day
    else
      DateTime.parse(value)
    end
  rescue ArgumentError
    DateTime.parse(value)
  rescue ArgumentError
    value
  end
end
