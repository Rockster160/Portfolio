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
    all.to_sql.gsub("SELECT \"#{table_name}\".* FROM \"#{table_name}\" WHERE ", "")
  end

  def self.raw_sql(q, data=nil)
    sql = unscoped.where(q, data)
    sql.take # validate
    sql.stripped_sql
  rescue ActiveRecord::StatementInvalid
    raise unless Rails.env.production?
  end

  scope :assign, -> (data) {
    relation = all
    prev = relation.instance_variable_get(:@assigned_data) || {}
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
  scope :query_by_node, ->(node) {
    q = search_scope

    sql = (
      if node.field.nil?
        conditions = Array.wrap(node.conditions).map { |condition|
          if condition.is_a?(Tokenizing::Node)
            unscoped.query_by_node(condition).stripped_sql
          else
            unscoped.search(condition).stripped_sql
          end
        }

        case node.operator&.to_sym
        when :AND then "(#{conditions.join(" AND ")})"
        when :OR then "(#{conditions.join(" OR ")})"
        when :NOT then "NOT (#{conditions.join(" AND ")})"
        end
      else
        field = node.field.to_sym
        next unless search_terms.key?(field)

        column = search_terms[field].to_s
        column_data = nil
        scope_method = nil

        if !column.include?(".") && !column_names.include?(column)
          scope_method = column
          column = nil
        else
          column_data = columns.find { |c| c.name == column }
        end

        value = node.conditions
        next if value.is_a?(Array) # Don't currently support nested string matching
        # Eventually this should detect that it's a json column and use the jsonb operators
        # Allow passing `offset:50` and `limit:50` to the query

        operator = node.operator.to_sym
        text_operators = %i[: :: !: !::] # ~ !~
        numeric_operators = %i[= != < > <= >=]
        # json_operators = %i[=> ->]

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
          when *%w[= : ::] then raw_sql("#{column} = ?", value)
          when *%w[!= !: !::] then raw_sql("#{column} != ?", value)
          when *%w[<] then raw_sql("#{column} < ?", value)
          when *%w[>] then raw_sql("#{column} > ?", value)
          when *%w[<=] then raw_sql("#{column} <= ?", value)
          when *%w[>=] then raw_sql("#{column} >= ?", value)
          end
        end
      end
    )

    next if sql.nil?

    q.where(sql)
  }
  scope :query, ->(q) {
    breaker = ::Tokenizing::Node.parse(q)
    query_by_node(breaker)
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
