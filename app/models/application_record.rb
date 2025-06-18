class ApplicationRecord < ActiveRecord::Base
  self.abstract_class = true
  attr_accessor :new_attributes

  include Jilable

  # TODO: Support `started_at: :start` to tweak the helper methods to be `start!` instead of `started!`
  def self.timestamp_bool(*cols)
    cols.map(&:to_sym).each do |col|
      bool = col.to_s.gsub(/_at\z/, "").to_sym

      define_method("#{bool}?") { send("#{col}?") }
      define_method("#{bool}!") { update!(col => ::Time.current) }
      define_method("#{bool}=") { |v| send("#{col}=", v ? ::Time.current : nil) }

      scope bool, -> { where.not(col => nil) }
      scope "not_#{bool}", -> { where(col => nil) }
    end
  end

  def self.ilike(hash, join=:OR)
    where(build_query(hash, :ILIKE, join), *hash.values)
  end

  def self.not_ilike(hash, join=:AND)
    # where(build_query(hash, "NOT ILIKE", join), *hash.values)
    where(
      # Dumb PG removes empty values when querying for a NOT for some reason
      hash.map { |k, v| "(\"#{k.to_s.gsub(".", "\".\"")}\"::TEXT NOT ILIKE ? OR \"#{k.to_s.gsub(".", "\".\"")}\" IS NULL)" }.join(" #{join} "),
      *hash.values
    )
  end

  def self.build_query(hash, point, join_with=:AND)
    hash.map { |k, v| "\"#{k.to_s.gsub(".", "\".\"")}\"::TEXT #{point} ?" }.join(" #{join_with} ")
  end

  def self.search_scope
    # Redefine this in the model if a `joins` or other default scope is needed
    unscoped
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
      .gsub(/ ?LEFT OUTER JOIN \"\w+\" ON \"\w+\".\"id\" = \"#{table_name}\".\"\w+\" WHERE/, "")
  end

  def self.raw_sql(q, *data)
    sql = search_scope.where(q, *data)
    sql.any? # validate
    sql.stripped_sql
  rescue ActiveRecord::StatementInvalid
    # puts sql.to_sql unless Rails.env.production?
    raise unless Rails.env.production?
  end

  def self.node_sql(node, parent_node=nil)
    field = (parent_node&.field || node.field).to_sym
    unless search_terms.key?(field)
      return search_scope.search(field).stripped_sql
    end

    column = search_terms[field]
    column_data = nil
    scope_method = nil

    if !column.to_s.include?(".") && !column_names.include?(column.to_s)
      scope_method = column
      column = nil
    elsif column.to_s.include?(".")
      table, table_column = column.to_s.split(".")
      column_data = table.classify.constantize.columns.find { |c| c.name == table_column }
    else
      column_data = columns.find { |c| c.name == column.to_s }
    end
    column = "#{table_name}.#{column}" if column.is_a?(Symbol)

    operator = (parent_node&.operator || node.operator).to_sym

    text_operators = %i[: :: !: !::] # ~ !~
    numeric_operators = %i[= != < > <= >=]
    # json_operators = %i[=> ->]
    # Eventually this should detect that it's a json column and use the jsonb operators
    Array.wrap(node.conditions).map { |value|
      next search_scope.query_by_node(value, node).stripped_sql if value.is_a?(Tokenizing::Node)

      next if value.is_a?(Tokenizing::Node)
      next unless operator.in?(text_operators + numeric_operators)

      if scope_method.present?
        search_scope.send(scope_method, *value).stripped_sql
      elsif column_data.type.in?(%i[string text])
        case operator
        when *%i[:] then raw_sql("#{column} ILIKE ?", "%#{value}%")
        when *%i[:: =] then raw_sql("#{column} ILIKE ?", value)
        when *%i[!:] then raw_sql("#{column} NOT ILIKE ?", "%#{value}%")
        when *%i[!:: !=] then raw_sql("#{column} NOT ILIKE ?", value)
        end
      elsif column_data.type.in?(%i[datetime date])
        case operator
        when *%i[= : ::] then raw_sql("(#{column} >= ? AND #{column} <= ?)", *parse_date(value, range: true).minmax)
        when *%i[!= !: !::] then raw_sql("(#{column} < ? OR #{column} > ?)", *parse_date(value, range: true).minmax)
        when *%i[<] then raw_sql("#{column} < ?", parse_date(value, operator: operator))
        when *%i[>] then raw_sql("#{column} > ?", parse_date(value, operator: operator))
        when *%i[<=] then raw_sql("#{column} <= ?", parse_date(value, operator: operator))
        when *%i[>=] then raw_sql("#{column} >= ?", parse_date(value, operator: operator))
        end
      elsif column_data.type.in?(%i[integer float decimal])
        case operator
        when *%i[= : ::] then raw_sql("#{column} = ?", value.to_f)
        when *%i[!= !: !::] then raw_sql("#{column} != ?", value.to_f)
        when *%i[<] then raw_sql("#{column} < ?", value.to_f)
        when *%i[>] then raw_sql("#{column} > ?", value.to_f)
        when *%i[<=] then raw_sql("#{column} <= ?", value.to_f)
        when *%i[>=] then raw_sql("#{column} >= ?", value.to_f)
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

    search_scope.ilike(search_indexed("%#{q}%"), :OR)
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
                search_scope.query_by_node(condition).stripped_sql
              else
                search_scope.search(condition).stripped_sql
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
    tz = Tokenizer.new(sql)
    str = tz.tokenized_text
    sql = tz.untokenize do |val|
      /\A\((\w+)\)\z/.tap { |rx| val = val.gsub(rx, '\1') while val.match?(rx) }
      val
    end
    next if sql.blank?

    where(sql)
  }
  scope :query, ->(q) {
    breaker = ::Tokenizing::Node.parse(q)

    search_scope.where(search_scope.query_by_node(breaker).stripped_sql)
  }
  scope :before, ->(time) { # Not used by `query` scope
    User.timezone {
      t = ::DateTime.parse(time) rescue (next none)

      key = column_names.include?("timestamp") ? :timestamp : :created_at
      where(key => ..t)
    }
  }
  scope :after, ->(time) { # Not used by `query` scope
    User.timezone {
      t = ::DateTime.parse(time) rescue (next none)

      key = column_names.include?("timestamp") ? :timestamp : :created_at
      where(key => t..)
    }
  }

  class << self
    alias_method :json_serialize, :serialize
  end

  def self.serialize(opts={})
    all.map { |item| item.serialize(opts) }
  end

  def serialize(opts={})
    as_json(opts.reverse_merge(except: [:created_at, :updated_at])).with_indifferent_access
  end

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

  def self.parse_date(value, operator: nil, range: false)
    ::User.timezone {
      begin
        now = Time.current
        year, mth, day, hr, mn, sec = vals = value.split(/\D/).map(&:to_i)

        date_str = [
          (year ||= now.year) < 1000 ? year + 2000 : year,
          (mth ||= now.month),
          (day ||= now.day),
        ].join("-")

        time_str = [
          (hr ||= now.hour).then { |h| value.match?(/pm/i) && h < 12 ? h + 12 : h },
          (mn ||= now.min),
          (sec ||= now.sec),
        ].map { |t| t.to_s.rjust(2, "0") }.join(":")

        date = Time.zone.parse("#{date_str} #{time_str}")
        units = [:year, :month, :day, :hour, :minute, :second]
        return (range ? date.all_day : date) if vals.length > units.length

        unit = units[vals.length - 1]
        if range
          date.send("beginning_of_#{unit}")..date.send("end_of_#{unit}")
        elsif operator && !operator.in?(%i[< <=])
          date.send("end_of_#{unit}")
        else
          date.send("beginning_of_#{unit}")
        end
      rescue ArgumentError, Date::Error
        DateTime.parse(value).then { |dt| range ? dt.all_day : dt }
      rescue ArgumentError, Date::Error
        value
      end
    }
  end
end
