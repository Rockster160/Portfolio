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
    search_terms.values.index_with(word)
  end

  def self.stripped_sql
    all.to_sql.gsub("SELECT \"#{table_name}\".* FROM \"#{table_name}\" WHERE ", "")
  end

  def self.raw_sql(q, data=nil)
    unscoped.where(q, data).stripped_sql
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
        column = search_terms[field]
        value = node.conditions
        next if value.is_a?(Array) # Don't currently support nested string matching
        # Eventually this should detect that it's a json column and use the jsonb operators
        # Also using the column, detect if it's a date | datetime
        # Maybe? timestamp<2019-01-01

        operator = node.operator.to_sym
        text_operators = %i[: :: !: !::] # ~ !~
        numeric_operators = %i[= != < > <= >=]
        # json_operators = %i[=> ->]

        if operator.in?(text_operators)
          case operator
          when ":" then raw_sql("#{column} ILIKE ?", "%#{value}%")
          when "::" then raw_sql("#{column} ILIKE ?", value)
          when "!:" then raw_sql("#{column} NOT ILIKE ?", "%#{value}%")
          when "!::" then raw_sql("#{column} NOT ILIKE ?", value)
          end
        elsif operator.in?(numeric_operators)
          case operator
          when "=" then raw_sql("#{column} = ?", value)
          when "!=" then raw_sql("#{column} != ?", value)
          when "<" then raw_sql("#{column} < ?", value)
          when ">" then raw_sql("#{column} > ?", value)
          when "<=" then raw_sql("#{column} <= ?", value)
          when ">=" then raw_sql("#{column} >= ?", value)
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
end
